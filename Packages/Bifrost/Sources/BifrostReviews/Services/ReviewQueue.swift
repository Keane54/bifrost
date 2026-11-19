// The queue of the PR rounds (docs/behaviour/reviews.md, "PR sessions"): at most maxSessions
// rounds run at one time, and the oldest job that is ready starts first. A job that is not ready
// (its repository waits for the trust of the user) keeps its place and blocks no other job.
//
// The queue owns one task for each running job: the round of the job (run). A round that ends
// frees its slot, so a session that waits for the user after its round (Needs you) uses no slot.
// cancel(_:) and stop() cancel the task of a running job, and the round ends at its next step.
// waitForEnd() waits for the end of each running job, so the owner of a stop knows when no round
// runs.
// The queue keeps no state on disk: the owner keeps the queue of state.json in step with it.
import Foundation
import Observation

// Why the running round of a PR must stop at its next step (ReviewRounds.halt). The reason is a
// part of the running job, so it ends with that job.
package enum RoundHalt: Sendable, Equatable {
    case userStop, requestGone, clonesRemoved
}

// Why a request round starts (Task 9). A review round has no trigger.
package enum RoundTrigger: Sendable, Equatable {
    case newWork, handleNow, copilot, tryAgain, answer
}

package struct QueuedJob: Sendable, Equatable {
    package var pr: PRKey
    package var kind: PRSessionKind
    // The time of the queue entry: the oldest job starts first.
    package var since: Date
    package var trigger: RoundTrigger?

    package init(pr: PRKey, kind: PRSessionKind, since: Date, trigger: RoundTrigger? = nil) {
        self.pr = pr
        self.kind = kind
        self.since = since
        self.trigger = trigger
    }
}

@MainActor
@Observable
package final class ReviewQueue {
    // The PRs of the running jobs and of the waiting jobs, oldest first.
    package private(set) var running: [PRKey] = []
    package private(set) var waiting: [PRKey] = []

    // True when the job can start now. The default says yes. The owner calls wake() when the
    // answer can have changed.
    @ObservationIgnored package var isReady: @MainActor (QueuedJob) -> Bool = { _ in true }

    @ObservationIgnored private let run: @MainActor (QueuedJob) async -> Void
    @ObservationIgnored private var maxSessions: Int
    @ObservationIgnored private var jobs: [QueuedJob] = []
    // A running job: its task, and the reason of a halt that came while it runs.
    private struct Running {
        let job: QueuedJob
        let task: Task<Void, Never>
        var halt: RoundHalt?
    }

    @ObservationIgnored private var tasks: [PRKey: Running] = [:]
    @ObservationIgnored private var stopped = false

    package init(maxSessions: Int, run: @escaping @MainActor (QueuedJob) async -> Void) {
        self.maxSessions = max(maxSessions, 1)
        self.run = run
    }

    // The task of the running job of the PR, or nil. A test waits for it.
    package func task(of pr: PRKey) -> Task<Void, Never>? { tasks[pr]?.task }

    // The running job of the PR, or nil.
    package func runningJob(of pr: PRKey) -> QueuedJob? { tasks[pr]?.job }

    // The reason of the halt of the running job of the PR, or nil.
    package func halt(of pr: PRKey) -> RoundHalt? { tasks[pr]?.halt }

    // Keep the reason of a halt with the running job of the PR. A PR with no running job keeps
    // nothing. The caller cancels the job (cancel(_:)) when the halt must stop it now.
    package func setHalt(_ reason: RoundHalt, of pr: PRKey) {
        tasks[pr]?.halt = reason
    }

    // A new limit: more slots start more jobs at once; fewer slots let the running jobs end.
    package func setMax(_ n: Int) {
        maxSessions = max(n, 1)
        wake()
    }

    // Add the job. One job of each PR and kind waits: a second add keeps the older time. A PR
    // runs one job at a time, so a job of a PR that runs waits for the end of that job.
    package func add(_ job: QueuedJob) {
        guard !stopped else { return }
        if let index = jobs.firstIndex(where: { $0.pr == job.pr && $0.kind == job.kind }) {
            if job.since < jobs[index].since { jobs[index] = job }
        } else {
            jobs.append(job)
        }
        wake()
    }

    // Drop the waiting jobs of the PR, and cancel its running job.
    package func cancel(_ pr: PRKey) {
        jobs.removeAll { $0.pr == pr }
        tasks[pr]?.task.cancel()
        publish()
    }

    // Drop each waiting job and cancel each running job. No job starts after it. A stop gives no
    // reason, so each cancelled round leaves its state for the next start.
    package func stop() {
        stopped = true
        jobs = []
        for pr in tasks.keys {
            tasks[pr]?.halt = nil
            tasks[pr]?.task.cancel()
        }
        publish()
    }

    // Wait until each job that runs now ended. After stop(), no job starts, so the wait ends
    // when the last cancelled round ended.
    package func waitForEnd() async {
        for task in tasks.values.map(\.task) { await task.value }
    }

    // Start the oldest ready jobs while slots are free.
    package func wake() {
        guard !stopped else { return }
        // The jobs of one time keep the order of their adds.
        let order = jobs.enumerated().sorted {
            ($0.element.since, $0.offset) < ($1.element.since, $1.offset)
        }
        for (_, job) in order where tasks.count < maxSessions {
            guard tasks[job.pr] == nil, isReady(job) else { continue }
            jobs.removeAll { $0 == job }
            start(job)
        }
        publish()
    }

    private func start(_ job: QueuedJob) {
        let task = Task { [weak self] in
            await self?.run(job)
            self?.finished(job.pr)
        }
        tasks[job.pr] = Running(job: job, task: task)
    }

    // The round of the job ended: its slot is free.
    private func finished(_ pr: PRKey) {
        tasks[pr] = nil
        wake()
        publish()
    }

    // The observed lists, from the jobs and the tasks.
    private func publish() {
        let ordered = jobs.sorted { $0.since < $1.since }.map(\.pr)
        let runningNow = tasks.values.sorted { $0.job.since < $1.job.since }.map(\.job.pr)
        if waiting != ordered { waiting = ordered }
        if running != runningNow { running = runningNow }
    }
}
