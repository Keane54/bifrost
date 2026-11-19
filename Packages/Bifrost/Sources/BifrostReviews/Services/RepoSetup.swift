// The clones of the repositories of the polls and their trust (docs/behaviour/reviews.md, "Clones
// and trust"). It runs after each good poll, and the Trust needed strip of the Reviews panel shows
// what it found.
//
// - The set-up: the first run with no end of the set-up in the state (the first turn-on, or the
//   first poll of a user who turned Watch GitHub on before the review rounds) clones each
//   repository of the open PRs and requests that is not ignored, one at a time, then lists the
//   ones that need trust. It sends no notification, so the user can do all the trust steps at
//   once. Then the state records the end of the set-up.
// - Each later run clones a repository that shows for the first time, and sends one
//   notification when its new clone needs trust. The state keeps the notice, so it comes once.
// - A failed clone waits one hour for its next try (RepoStore.failedRecently), and a repository
//   that needs trust waits for the user: neither stops the clones and the trust reads of the
//   others.
// - The trust read follows the real state (TrustCheck): each run reads it again (one read of the
//   file for all repositories), and the trust terminal reads it when its output settles. A
//   repository that a run finds trusted leaves the list and starts the work that waited, as a
//   trust step does. Bifrost never accepts a trust prompt itself.
// - claude itself is the last check of the trust: a clone where a PR session started counts as
//   trusted (startedSession), also when the trust read says no, for example when claude keeps its
//   trust in another place. A round reads the trust again before it starts (trustsForStart). A
//   round that finds no trust, or whose start claude refuses for trust, puts its repository in
//   the list (waitsForTrust). A repository that claude refused stays in the list until a trust
//   step ends (trusted or stepEnded), also when the trust read says yes, so a wrong read cannot
//   start the same refused round again and again.
// - A click on a clone that needs trust (allowOneStart), or the end of a trust step with no trust
//   that the read sees (stepEnded), gives the repository one start that claude judges. A round
//   takes it (takeOneStart).
// - What Reviews knows of the trust of a clone apart from the read is one value for each
//   repository (CloneTrust), so the started session, the refusal and the one start can't
//   disagree.
// - One run works at a time. A call during a run gives its poll to that run, which runs once
//   more with the newest poll.
import BifrostFoundation
import BifrostSessions
import Foundation
import Observation

@MainActor
@Observable
package final class RepoSetup {
    // The start size of a trust terminal. The terminal sends its own size after it shows.
    package static let trustSize = TerminalSize(cols: 100, rows: 30)

    // The repositories whose clone needs the trust of the user, with the count of their PRs in
    // the last poll (the PRs that wait for the trust).
    package private(set) var needsTrust: [RepoName: Int] = [:]
    // The repositories whose clone runs now or waits in this run.
    package private(set) var cloning: Set<RepoName> = []
    // The user trusted the clone of the repository: the work that waited for it can start.
    @ObservationIgnored package var onTrusted: @MainActor (RepoName) -> Void = { _ in }

    // What Reviews knows of the trust of the clone of a repository apart from the trust read.
    private enum CloneTrust: Equatable {
        // A PR session started in the clone: Claude Code trusts it.
        case sessionStarted
        // claude refused a start for trust: the repository waits for a trust step, also when the
        // read says yes. oneStart: a click gave one start, which claude judges.
        case refusedByClaude(oneStart: Bool)
        // One start, which claude judges: a click on a clone that needs trust, or the end of a
        // trust step.
        case oneStart

        var hasOneStart: Bool {
            self == .oneStart || self == .refusedByClaude(oneStart: true)
        }
    }

    @ObservationIgnored private let repos: RepoStore
    @ObservationIgnored private let store: ReviewsStore
    @ObservationIgnored private let ptys: PTYManager?
    @ObservationIgnored private let home: URL
    @ObservationIgnored private let notify: @MainActor (ReviewsNotice) -> Void
    @ObservationIgnored private let now: () -> Date
    // What Reviews knows of the trust of each clone apart from the read. No value: only the read
    // decides.
    @ObservationIgnored private var trust: [RepoName: CloneTrust] = [:]
    // The count of the PRs of each repository in the last run.
    @ObservationIgnored private var counts: [RepoName: Int] = [:]
    // The newest poll that waits for a run, and the run that works now.
    @ObservationIgnored private var waiting: (PollAnswer, [IgnoreEntry])?
    @ObservationIgnored private var running: Task<Void, Never>?
    // True after stop(): no new run starts.
    @ObservationIgnored private var stopped = false

    // ptys opens the trust terminals; nil gives no terminal. home holds the .claude.json of the
    // trust read. notify shows a notification of Reviews (ReviewsWatcher.notify).
    package init(
        repos: RepoStore, store: ReviewsStore, ptys: PTYManager?, home: URL,
        notify: @escaping @MainActor (ReviewsNotice) -> Void, now: @escaping () -> Date
    ) {
        self.repos = repos
        self.store = store
        self.ptys = ptys
        self.home = home
        self.notify = notify
        self.now = now
    }

    // The clone states for the rows.
    package var clones: CloneStates {
        CloneStates(cloning: cloning, needsTrust: Set(needsTrust.keys))
    }

    // Clone the repositories of the poll that are not ignored, then read their trust. The call
    // returns at the end of the run that takes this poll.
    package func run(for answer: PollAnswer, ignoring: [IgnoreEntry]) async {
        guard !stopped else { return }
        waiting = (answer, ignoring)
        if let running {
            await running.value
            return
        }
        let task = Task {
            while let next = waiting {
                waiting = nil
                await pass(next.0, next.1)
            }
            running = nil
        }
        running = task
        await task.value
    }

    // The store closes: the run that works ends after the clone of now, and no new run starts.
    package func stop() {
        stopped = true
        waiting = nil
        running?.cancel()
    }

    // The clones went (Remove all clones): no repository needs trust until the next run.
    package func forgetClones() {
        needsTrust = [:]
        trust = [:]
    }

    // A round of the repository found no trust, or claude refused its start for trust
    // (refusedByClaude): the repository waits for the trust step of the user. A refusal keeps a
    // one start that a click gave and the round did not take.
    package func waitsForTrust(_ repo: RepoName, refusedByClaude: Bool) {
        if refusedByClaude {
            trust[repo] = .refusedByClaude(oneStart: trust[repo]?.hasOneStart ?? false)
        }
        if needsTrust[repo] == nil { needsTrust[repo] = max(counts[repo] ?? 1, 1) }
    }

    // A click on a clone that needs trust gives one start, which claude judges.
    package func allowOneStart(_ repo: RepoName) {
        guard needsTrust[repo] != nil else { return }
        switch trust[repo] {
        case .refusedByClaude?: trust[repo] = .refusedByClaude(oneStart: true)
        case .sessionStarted?: break
        case .oneStart?, nil: trust[repo] = .oneStart
        }
    }

    // True when the repository has one start that a round can take.
    package func hasOneStart(_ repo: RepoName) -> Bool {
        trust[repo]?.hasOneStart ?? false
    }

    // Take the one start of the repository. The result is false when it has none.
    package func takeOneStart(_ repo: RepoName) -> Bool {
        switch trust[repo] {
        case .oneStart?: trust[repo] = nil
        case .refusedByClaude(oneStart: true)?: trust[repo] = .refusedByClaude(oneStart: false)
        default: return false
        }
        return true
    }

    // Remove all clones stopped the rounds: no one start is left.
    package func dropOneStarts() {
        for (repo, value) in trust {
            switch value {
            case .oneStart: trust[repo] = nil
            case .refusedByClaude(oneStart: true): trust[repo] = .refusedByClaude(oneStart: false)
            case .refusedByClaude, .sessionStarted: break
            }
        }
    }

    // MARK: - The trust

    // True when Claude Code trusts the clone of the repository (a read only).
    package func isTrusted(_ repo: RepoName) async -> Bool {
        await TrustCheck.isTrusted(repos.layout.clone(repo), home: home)
    }

    // Open a trust terminal: claude with no arguments in the clone of the repository, after the
    // check of the folder (TrustRuns.check). nil: no PTY manager, no clone, or the open failed.
    package func openTrust(_ repo: RepoName) async -> PTYRun? {
        let layout = repos.layout
        guard let ptys,
            let checked = await TrustRuns.check(
                folder: layout.clone(repo), root: layout.reposRoot)
        else { return nil }
        do throws(PTYError) {
            return try await ptys.openTrust(checked, size: Self.trustSize)
        } catch {
            return nil
        }
    }

    // True when a round can start in the clone of the repository: claude did not refuse it for
    // trust, and a PR session started there or the trust read says yes.
    package func trustsForStart(_ repo: RepoName) async -> Bool {
        switch trust[repo] {
        case .refusedByClaude?: return false
        case .sessionStarted?: return true
        case .oneStart?, nil: return await isTrusted(repo)
        }
    }

    // A PR session started in the clone of the repository, so Claude Code trusts it: it leaves
    // the list.
    package func startedSession(_ repo: RepoName) {
        trust[repo] = .sessionStarted
        needsTrust[repo] = nil
    }

    // A trust step of the repository ended with no trust that the read sees (the user closed the
    // trust panel). A refusal of claude no longer holds, and the repository gets one start, so
    // claude judges again.
    package func stepEnded(_ repo: RepoName) {
        if trust[repo] != .sessionStarted { trust[repo] = .oneStart }
    }

    // The trust terminal saw the trust of the clone: the repository leaves the list, and the
    // work that waited for it can start.
    package func trusted(_ repo: RepoName) {
        endTrustStep(repo)
        needsTrust[repo] = nil
        onTrusted(repo)
    }

    // The trust of the repository is known: a refusal and a one start go.
    private func endTrustStep(_ repo: RepoName) {
        if trust[repo] != .sessionStarted { trust[repo] = nil }
    }

    // MARK: - The run

    private func pass(_ answer: PollAnswer, _ ignoring: [IgnoreEntry]) async {
        let hidden = store.state.hidden
        // The PRs of each repository, in the order of the poll. A PR that the user removed in
        // Bifrost counts nowhere.
        var counts: [RepoName: Int] = [:]
        var order: [RepoName] = []
        for pr in answer.toReview + answer.mine {
            let repo = pr.key.repo
            guard !IgnoreRule.matches(ignoring, repo), hidden[pr.key] == nil else { continue }
            if counts[repo] == nil { order.append(repo) }
            counts[repo, default: 0] += 1
        }
        var missing: [RepoName] = []
        for repo in order where !repos.failedRecently(repo) {
            if !(await repos.hasClone(repo)) { missing.append(repo) }
        }
        cloning = Set(missing)
        var cloned: Set<RepoName> = []
        for repo in missing {
            guard !stopped, !Task.isCancelled else {
                cloning = []
                return
            }
            do throws(RepoError) {
                try await repos.ensureClone(repo)
                cloned.insert(repo)
            } catch {
                // The store logs the failure, and the next run after the wait tries again.
            }
            cloning.remove(repo)
        }
        guard !stopped, !Task.isCancelled else { return }
        var withClone: [RepoName] = []
        for repo in order {
            if await repos.hasClone(repo) { withClone.append(repo) }
        }
        let layout = repos.layout
        let read = await TrustCheck.trusted(withClone.map { layout.clone($0) }, home: home)
        guard !stopped, !Task.isCancelled else { return }
        var needs: [RepoName: Int] = [:]
        var trusted: [RepoName] = []
        for (repo, isTrusted) in zip(withClone, read) {
            let known: Bool? =
                switch trust[repo] {
                case .sessionStarted?: true
                case .refusedByClaude?: false
                case .oneStart?, nil: nil
                }
            if known ?? isTrusted {
                trusted.append(repo)
            } else {
                needs[repo] = counts[repo]
            }
        }
        self.counts = counts
        // A repository that waited for trust and is trusted now: its work can start.
        let ended = trusted.filter { needsTrust[$0] != nil }
        if needsTrust != needs { needsTrust = needs }
        for repo in ended {
            endTrustStep(repo)
            onTrusted(repo)
        }
        await notice(Set(needs.keys).intersection(cloned))
    }

    // The end of a run. The first run ends the set-up and notifies nothing. A later run notifies
    // each new clone that needs trust, one time for each repository: only after the state saved
    // the notice, and never after a stop.
    private func notice(_ fresh: Set<RepoName>) async {
        guard !stopped else { return }
        let time = now()
        guard store.state.setUpAt != nil else {
            await store.update { $0.setUpAt = time }
            return
        }
        let unseen = fresh.filter { store.state.repos[$0]?.trustNotifiedAt == nil }.sorted()
        guard !unseen.isEmpty else { return }
        let saved = await store.update { state in
            for repo in unseen { state.repos[repo, default: RepoMark()].trustNotifiedAt = time }
        }
        guard saved, !stopped else { return }
        for repo in unseen { notify(.trustNeeded(repo)) }
    }
}
