// The queue of the PR rounds (docs/behaviour/reviews.md, "PR sessions"): at most maxSessions
// rounds run, the oldest ready job starts first, and a round that ends frees its slot.
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

// The rounds of the tests: each round waits at a gate until the test ends it.
@MainActor
private final class Rounds {
    private(set) var started: [PRKey] = []
    private var gates: [PRKey: CheckedContinuation<Void, Never>] = [:]
    // The rounds that an end reached before they waited at their gate.
    private var ended: Set<PRKey> = []

    func run(_ job: QueuedJob) async {
        started.append(job.pr)
        await withTaskCancellationHandler {
            await withCheckedContinuation { gate in
                if ended.remove(job.pr) != nil { gate.resume() } else { gates[job.pr] = gate }
            }
        } onCancel: {
            Task { @MainActor in self.end(job.pr) }
        }
    }

    // End the round of the PR.
    func end(_ pr: PRKey) {
        if let gate = gates.removeValue(forKey: pr) {
            gate.resume()
        } else {
            ended.insert(pr)
        }
    }
}

@MainActor
@Suite("the queue of the PR rounds", .testTimeLimit)
struct ReviewQueueTests {
    private func pr(_ number: Int) throws -> PRKey {
        try ReviewData.pr("Owner-A/Repo-A#\(number)")
    }

    private func job(_ number: Int, at seconds: Double) throws -> QueuedJob {
        QueuedJob(
            pr: try pr(number), kind: .review, since: Date(timeIntervalSince1970: seconds))
    }

    // Two slots: the two oldest jobs start, in the order of their times; the third waits until a
    // round ends. A second add of a job keeps the older time.
    @Test func atMostMaxSessionsRunAndTheOldestStartsFirst() async throws {
        let rounds = Rounds()
        let queue = ReviewQueue(maxSessions: 2) { await rounds.run($0) }
        queue.isReady = { _ in false }
        queue.add(try job(3, at: 30))
        queue.add(try job(1, at: 10))
        queue.add(try job(2, at: 20))
        queue.add(try job(3, at: 5))
        #expect(queue.waiting == [try pr(3), try pr(1), try pr(2)])
        queue.isReady = { _ in true }
        queue.wake()
        await waitUntil { rounds.started.count == 2 }
        #expect(rounds.started == [try pr(3), try pr(1)])
        #expect(queue.running == [try pr(3), try pr(1)])
        #expect(queue.waiting == [try pr(2)])
        rounds.end(try pr(1))
        await waitUntil { rounds.started.count == 3 }
        #expect(rounds.started.last == (try pr(2)))
        #expect(queue.running == [try pr(3), try pr(2)])
        // A larger limit starts more at once; a job that is not ready keeps its place.
        queue.isReady = { $0.pr.number != 4 }
        queue.add(try job(4, at: 1))
        queue.add(try job(5, at: 2))
        queue.setMax(3)
        await waitUntil { rounds.started.count == 4 }
        #expect(rounds.started.last == (try pr(5)))
        #expect(queue.waiting == [try pr(4)])
        queue.stop()
        await waitUntil { queue.running.isEmpty }
        #expect(queue.waiting.isEmpty)
    }

    // A round that ends while its session waits for the user (Needs you) frees its slot, so the
    // next job starts. The queue counts rounds, not sessions.
    @Test func aSessionThatWaitsUsesNoSlot() async throws {
        let rounds = Rounds()
        let queue = ReviewQueue(maxSessions: 1) { await rounds.run($0) }
        let first = try pr(1)
        queue.add(try job(1, at: 10))
        queue.add(try job(2, at: 20))
        await waitUntil { rounds.started == [first] }
        // The round of PR 1 ends: its session stays and waits for the user.
        rounds.end(try pr(1))
        await waitUntil { rounds.started.count == 2 }
        #expect(queue.running == [try pr(2)])
        // A cancel ends a running round and drops a waiting job.
        queue.add(try job(3, at: 30))
        queue.cancel(try pr(3))
        queue.cancel(try pr(2))
        await waitUntil { queue.running.isEmpty }
        #expect(queue.waiting.isEmpty)
        #expect(rounds.started.count == 2)
    }

    // stop() cancels each running round at once, and waitForEnd() ends only when each of them
    // ended, also a round that takes time to stop (a git that ends at the end of its grace).
    @Test func waitForEndWaitsForEachStoppedRound() async throws {
        let gate = TestGate()
        let cancels = Recorder<PRKey>()
        let queue = ReviewQueue(maxSessions: 2) { job in
            await withTaskCancellationHandler {
                await gate.pass()
            } onCancel: {
                cancels.record(job.pr)
            }
        }
        queue.add(try job(1, at: 10))
        queue.add(try job(2, at: 20))
        #expect(await gate.waitUntilHolding(2))
        queue.stop()
        #expect(Set(cancels.values) == [try pr(1), try pr(2)])
        let ended = Recorder<Void>()
        let waiting = Task {
            await queue.waitForEnd()
            ended.record(())
        }
        gate.open()
        await waitUntil { queue.running.count == 1 }
        #expect(ended.values.isEmpty)
        gate.openAll()
        await waiting.value
        #expect(queue.running.isEmpty && ended.values.count == 1)
    }

    // The reason of a halt is a part of the running job: a PR with no running job keeps none,
    // and the reason ends with the job, so it never reaches a later round of the PR. A stop gives
    // no reason.
    @Test func theReasonOfAHaltEndsWithItsJob() async throws {
        let rounds = Rounds()
        let queue = ReviewQueue(maxSessions: 2) { await rounds.run($0) }
        let (first, second) = (try pr(1), try pr(2))
        queue.setHalt(.userStop, of: first)
        #expect(queue.halt(of: first) == nil)
        queue.add(try job(1, at: 10))
        queue.add(try job(2, at: 20))
        await waitUntil { rounds.started.count == 2 }
        queue.setHalt(.requestGone, of: first)
        #expect(queue.halt(of: first) == .requestGone)
        rounds.end(first)
        await waitUntil { queue.runningJob(of: first) == nil }
        #expect(queue.halt(of: first) == nil)
        queue.setHalt(.clonesRemoved, of: second)
        queue.stop()
        #expect(queue.halt(of: second) == nil)
        await queue.waitForEnd()
    }
}
