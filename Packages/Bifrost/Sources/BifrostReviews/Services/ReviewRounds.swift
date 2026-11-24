// The PR rounds (docs/behaviour/reviews.md, "Review rounds" and "Request rounds"): the owner of
// the queue and of the rounds of both kinds.
// - A review round: Claude reviews the PR of another person in a read-only session and leaves a
//   pending review that only the user sees; ReviewRound holds its steps. A failed round posts
//   nothing more and never tries again by itself: its row shows "Review failed" with the reason
//   and Try again, and no notification goes out. A round that left a draft (or an Approve with
//   nothing to post) notifies once and polls at once, so the row shows its result.
// - A request round: Claude fixes and answers the review comments on a PR of the user in a
//   sandboxed session, and Bifrost commits, pushes and posts its result; the extension in
//   RequestRounds.swift holds the clicks, the jobs and the ends of this kind, RequestRound the
//   steps of one round and RoundWrites its writes.
// - A conflict round: Bifrost merges the base branch into a PR of the user that has conflicts,
//   Claude resolves them in the request session of the PR, and Bifrost checks, commits and pushes
//   the merge. The extension in ConflictRounds.swift holds the poll, Resolve now, the jobs and the
//   ends of this kind, and ConflictRound the steps of one round. Each failure goes to the conflict
//   mark of the PR, never to lastError.
//
// The state of state.json and the queue go together: a click (or a poll) adds the entry to the
// queue of the file, the start of the round moves it to the round of the PR, and the end clears
// the round. At the next start, a preparing round goes back to the queue and a running round
// waits for its session. A posting review round fails; a posting request round sends the rest
// of its writes; a posting conflict round pushes its merge again.
//
// A round that runs stops at its next step when the request of the PR went (a review) or the PR
// merged or closed (a request), when the clones go, or when the user stops its session. A round
// that posts is never cancelled: its writes end first. A request round that sends the writes of
// an earlier round first (finishingWrites) is not cancelled either: it stops right after those
// writes. Watch GitHub off and the quit cancel each round, and the state keeps them for the next
// start. While Remove all clones runs, no round starts, and the clicks, the polls and the ends of
// trust steps change nothing.
//
// An own request of the user (OwnRequests, docs/behaviour/reviews.md, "Your own requests") runs
// in a task of ReviewRounds while no round of the PR runs, and no round of the PR starts while it
// runs. Like a posting round, a drop and Remove all clones wait for its writes.
//
// The tasks of the rounds have owners: the queue owns the task of each round, ReviewRounds the
// task of each drop, of each own request and of Remove all clones, and PRSessions its claude
// commands. stop() cancels the rounds and the own requests, and waitForEnd() waits for each of
// those tasks, so no git, gh or claude of the rounds outlives Reviews.
import BifrostFoundation
import BifrostSessions
import Foundation
import OSLog

// The answer of the user to one open question of Claude (the Answer panel).
package enum QuestionAnswer: Sendable, Equatable {
    // The text goes into the input of the next round.
    case text(String)
    // The user handles the item: it is handled, and no round starts for it.
    case handleMyself
}

@MainActor
package final class ReviewRounds {
    // The time limit of a review session and of a request session.
    package static let limit = Duration.seconds(30 * 60)

    package let sessions: PRSessions
    // The writes of the request rounds (RequestRounds.swift).
    private(set) lazy var writes = RoundWrites(
        store: store, github: github, repos: repos, clock: clock, now: now,
        viewer: { [weak self] in self?.answer()?.viewer },
        eventLine: { [weak self] in self?.eventLine($0) },
        inUse: { [weak self] in self?.sessions.requestInUse($0) ?? false })
    // The own requests of the user (RequestRounds.swift).
    private(set) lazy var own = OwnRequests(
        store: store, repos: repos, writes: writes, now: now,
        signed: { [weak self] in self?.config.signedCommits ?? false },
        eventLine: { [weak self] in self?.eventLine($0) },
        changed: { [weak self] in self?.changed() })
    // The queue runs the round of each job (run).
    package private(set) lazy var queue: ReviewQueue = {
        let queue = ReviewQueue(maxSessions: config.maxSessions) { [weak self] job in
            await self?.run(job)
        }
        queue.isReady = { [weak self] in self?.isReady($0) ?? false }
        return queue
    }()

    // The last good poll: the viewer and the PRs. A round waits for the first one.
    package var answer: @MainActor () -> PollAnswer? = { nil }
    // The state changed: the rows build again.
    package var changed: @MainActor () -> Void = {}
    // A round ended: a poll runs at once, so the row shows the result of GitHub.
    package var ended: @MainActor () -> Void = {}
    package var notify: @MainActor (ReviewsNotice) -> Void = { _ in }
    // A line for the Event log: the reason of git or of GitHub for a write that stopped.
    package var eventLine: @MainActor (String) -> Void = { _ in }
    // A new review round of the PR starts (ReviewWrites.forget). The default does nothing.
    package var reviewStarted: @MainActor (PRKey) -> Void = { _ in }

    private static let logger = Logger(bifrost: "reviews")

    // The services of the rounds, which the request part uses too.
    let store: ReviewsStore
    let github: GitHubClient
    let repos: RepoStore
    let setup: RepoSetup
    let skills: URL
    let userHome: URL
    let now: () -> Date
    // The clock of the wait between two GitHub writes.
    private let clock: any Clock<Duration>
    // The time since the start on clock, for the wait after a failed full read.
    let timeline: Timeline
    // The time of the last failed full read of a request round of each PR. The poll waits
    // WorkRule.readRetry after it before it queues the PR again (waitsAfterReadFailure).
    var readFailures: [PRKey: Duration] = [:]
    // The pair of the poll of each PR whose last automatic conflict round ended with no text, and
    // the time of that end. The poll waits WorkRule.readRetry after it (waitsAfterQuietEnd).
    var quietPairs: [PRKey: (pair: ConflictRound.Pair, at: Duration)] = [:]
    private(set) var config: ReviewsConfig
    // Remove all clones while it runs (removeAll). Its result is the failure of the removal of
    // the folders.
    private var removal: Task<String?, Never>?
    // True after stop(): a poll starts no drop and no own request.
    private(set) var stopped = false
    // The drop of each PR whose drop runs now. Each drop leaves the list at its end.
    private(set) var drops: [PRKey: Task<Void, Never>] = [:]
    // The own request of each PR that runs now apart from a round (checkOwnRequest). Each one
    // leaves the list at its end.
    var ownRuns: [PRKey: Task<Void, Never>] = [:]
    // The discard of each PR that runs now (discardChanges). Each one leaves the list at its end.
    var discards: [PRKey: Task<DiscardOutcome, Never>] = [:]
    // The checks for an own request file at the end of a request job (run), by number. Each one
    // leaves the list at its end.
    private var jobEndChecks: [Int: Task<Void, Never>] = [:]
    private var jobEndCount = 0
    // The PRs whose request round sends the writes of an earlier round now. A halt does not
    // cancel those writes (halt).
    private var finishingWrites: Set<PRKey> = []

    // skills is the bundled skills folder (AppServices.skillsSource). userHome is the home of the
    // user in the user database, whose secret paths the sandbox of a request session refuses.
    // clock runs the wait between two GitHub writes of a request round.
    package init(
        store: ReviewsStore, github: GitHubClient, repos: RepoStore, setup: RepoSetup,
        sessions: PRSessions, skills: URL, userHome: URL, config: ReviewsConfig,
        now: @escaping () -> Date, clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.store = store
        self.github = github
        self.repos = repos
        self.setup = setup
        self.sessions = sessions
        self.skills = skills
        self.userHome = userHome
        self.config = config
        self.now = now
        self.clock = clock
        timeline = Timeline(clock)
    }

    // MARK: - Start and stop

    // Take the rounds of the state: a posting review round fails, a posting request round sends
    // the rest of its writes, a preparing round goes back to the queue (or fails when the user
    // stopped it), and a running round waits for its session. A request round that fails holds
    // its items. A conflict round that runs or posts goes on in its job, which also ends a round
    // that the user stopped; its failures go to its conflict mark. A CI round of the state goes
    // with no text (the CI rounds do not run yet). Then queue each entry of the file, oldest
    // first.
    package func start() {
        // The end of a turn of a request session: an own request of the user can go now.
        sessions.requestFree = { [weak self] pr in self?.checkOwnRequest(pr) }
        sessions.start()
        var resumed: [QueuedJob] = []
        store.change { state in
            for (pr, prState) in state.prs {
                guard let round = prState.round else { continue }
                var next = prState
                let kind = round.kind
                // A request round that fails holds its items and spends its click.
                func failed(_ failure: RoundFailure) {
                    next.round = nil
                    next.lastError = failure.message(for: kind)
                    guard kind == .request else { return }
                    next.hold(Self.ordered(round.items))
                    next.handleOlder = false
                    next.handleCopilot = false
                }
                switch (kind, round.phase) {
                case (.ci, _):
                    // The CI rounds come in a later task. Until then a CI round of the state goes.
                    next.round = nil
                case (.request, .posting), (.conflict, .posting), (.conflict, .running):
                    resumed.append(QueuedJob(pr: pr, kind: kind, since: round.at))
                case (_, .posting):
                    failed(.closedWhilePosting)
                case (.conflict, .preparing) where round.stoppedByUser:
                    next.round = nil
                    next.resolveNow = false
                    next.conflict = Self.stopped(next.conflict)
                case (_, .preparing) where round.stoppedByUser:
                    failed(.stopped)
                case (_, .preparing):
                    next.round = nil
                    if !state.queue.contains(where: { $0.pr == pr && $0.kind == kind }) {
                        state.queue.append(QueueEntry(pr: pr, kind: kind, at: round.at))
                    }
                case (_, .running) where round.stoppedByUser:
                    // The user stopped it before the quit: it never waits for its session again.
                    failed(.stopped)
                case (_, .running):
                    resumed.append(QueuedJob(pr: pr, kind: kind, since: round.at))
                }
                state.prs[pr] = next
            }
            state.queue.sort { $0.at < $1.at }
        }
        changed()
        for job in resumed { queue.add(job) }
        for entry in store.state.queue {
            let trigger =
                entry.kind == .request ? Self.requestTrigger(store.state.prs[entry.pr]) : nil
            queue.add(
                QueuedJob(pr: entry.pr, kind: entry.kind, since: entry.at, trigger: trigger))
        }
    }

    // Watch GitHub off, or the quit: each round stops at its next step, and the state keeps it.
    // waitForEnd() waits for the end of the rounds.
    package func stop() {
        stopped = true
        queue.stop()
        for run in ownRuns.values { run.cancel() }
        for check in jobEndChecks.values { check.cancel() }
        sessions.stop()
    }

    // Wait until each round, each drop, a Remove all clones that runs and each claude command of
    // the PR sessions ended. A round that stop() cancelled ends soon: each git waits for the end
    // of its program, which a stop ends within RepoGit.stopGrace.
    package func waitForEnd() async {
        await queue.waitForEnd()
        for run in ownRuns.values { await run.value }
        for check in jobEndChecks.values { await check.value }
        for discard in discards.values { _ = await discard.value }
        for drop in drops.values { await drop.value }
        _ = await removal?.value
        await sessions.waitForEnd()
    }

    // True while Remove all clones runs.
    var removing: Bool { removal != nil }

    // New settings: the count of the sessions, the models and the automatic rounds.
    package func apply(_ new: ReviewsConfig) {
        config = new
        queue.setMax(new.maxSessions)
    }

    // A good poll: the rounds that waited for the viewer can start, the review work of each PR
    // whose request went goes, the work of each PR of the user that merged or closed goes, each
    // PR of the user with new work gets a request round while the automatic rounds are on, and
    // each PR of the user with conflicts gets a conflict round while the automatic conflict rounds
    // are on. Only a complete answer shows that a request went or a PR closed.
    package func afterPoll(_ poll: PollAnswer) {
        guard !removing, !stopped else { return }
        queue.wake()
        if !poll.toReviewCut && poll.errors.isEmpty { dropGone(poll, mine: false) }
        if !poll.mineCut && poll.errors.isEmpty { dropGone(poll, mine: true) }
        queueNewWork(poll)
        queueConflicts(poll)
        // A round that starts now lets a waiting own request go first itself.
        checkOwnRequests(poll)
    }

    // Drop the work of each PR that the poll does not list as open, on one side: the review work
    // of the To review PRs, or the work of the PRs of the user (mine: the request, conflict and
    // CI rounds, which share the request session of the PR).
    private func dropGone(_ poll: PollAnswer, mine: Bool) {
        let open = Set((mine ? poll.mine : poll.toReview).map(\.key))
        let state = store.state
        var keys = Set(state.queue.filter { $0.kind.isMine == mine }.map(\.pr))
        for (pr, prState) in state.prs where prState.round?.kind.isMine == mine {
            keys.insert(pr)
        }
        for (pr, prState) in state.prs {
            let work =
                mine
                ? prState.requestSession != nil || !prState.questions.isEmpty
                    || !prState.held.isEmpty || prState.outbox != nil || prState.conflict != nil
                    || prState.ci != nil || prState.resolveNow
                : prState.reviewSession != nil
            if work { keys.insert(pr) }
        }
        for pr in keys where !open.contains(pr) && drops[pr] == nil {
            // A round that posts, or an own request, ends its writes first. The next poll drops
            // the PR.
            if state.prs[pr]?.round?.phase == .posting || ownRuns[pr] != nil
                || discards[pr] != nil
            {
                continue
            }
            if mine {
                // The search can leave out an open PR. The drop first reads the state of the PR.
                drops[pr] = Task {
                    await dropIfClosed(pr)
                    drops[pr] = nil
                    queue.wake()
                }
            } else if let job = queue.runningJob(of: pr) {
                if !job.kind.isMine { halt(pr, .requestGone) }
            } else {
                queue.cancel(pr)
                drops[pr] = Task {
                    await drop(pr)
                    drops[pr] = nil
                }
            }
        }
    }

    // The search did not list the PR of the user. One read gives its state. Only a PR that is
    // merged, closed or not found loses its work. After a failed read, or for an open PR, the work
    // stays and the next poll looks again. The work of a round that runs stops first, and the
    // next poll drops the PR. When the worktree has changes that no round made, one line of the
    // Event log names them.
    private func dropIfClosed(_ pr: PRKey) async {
        let lifecycle: PRLifecycle?
        do throws(GitHubError) {
            lifecycle = try await RequestQueries.stateOrGone(pr, client: github)
        } catch {
            Self.logger.notice(
                """
                Bifrost could not read the state of \(pr.text, privacy: .private): \
                \(error.message, privacy: .private). It keeps it.
                """)
            return
        }
        guard lifecycle != .open, !removing, !stopped, !Task.isCancelled else { return }
        // A round that posts, or an own request, ends its writes first.
        if store.state.prs[pr]?.round?.phase == .posting || ownRuns[pr] != nil
            || discards[pr] != nil
        {
            return
        }
        if let job = queue.runningJob(of: pr) {
            if job.kind.isMine { halt(pr, .requestGone) }
            return
        }
        queue.cancel(pr)
        let (files, unread) = await changesOfNoRound(pr)
        await dropRequest(pr)
        if unread {
            eventLine(
                "Reviews: Bifrost deleted its copy of \(pr.text), but git didn't show the changes "
                    + "in it first, so some may not be on GitHub.")
        }
        if !files.isEmpty {
            let names = files.prefix(3).joined(separator: ", ")
            let more = files.count > 3 ? ", and more" : ""
            eventLine(
                "Reviews: Bifrost deleted its copy of \(pr.text) with \(files.count) "
                    + "\(files.count == 1 ? "change" : "changes") that no round made and that "
                    + "are not on GitHub: \(names)\(more).")
        }
    }

    // The files of the worktree of the PR that no round made: the unknown changes, the files that
    // the row keeps, and the files of an own request that did not go. Each file is there once.
    // The second value is true when git did not show the unknown changes.
    private func changesOfNoRound(_ pr: PRKey) async -> (files: [String], unread: Bool) {
        let prState = store.state.prs[pr]
        let unknown = await repos.unknownChanges(pr)
        var files = unknown ?? []
        files += prState?.waiting?.files ?? []
        if let outbox = prState?.outbox, outbox.own {
            for post in outbox.posts {
                if case .commit(let paths, _, _) = post.write { files += paths }
            }
        }
        var seen: Set<String> = []
        return (files.filter { seen.insert($0).inserted }, unknown == nil)
    }

    // The trust step of the repository ended: its rounds can start.
    package func trusted(_ repo: RepoName) {
        guard !removing else { return }
        queue.wake()
    }

    // The user closed the trust panel of the repository, and the trust read sees no trust: the
    // repository gets one start, which claude judges.
    package func trustStepEnded(_ repo: RepoName) {
        guard !removing else { return }
        setup.stepEnded(repo)
        queue.wake()
    }

    // Remove all clones, from the stop of the rounds to the end of removeClones (the removal of
    // the folders). The waiting jobs go first, so no round starts in a slot that a stopped round
    // frees. Then each running round stops (a round that posts ends its writes first), each PR
    // session goes, and the queued rounds go with their clicks; a request round holds its items,
    // and the working conflict mark of a conflict round goes.
    // An outbox whose fix commit or push did not go names a commit of a clone that goes, so it
    // goes too, and its items wait in held.
    // The result is the failure of removeClones. A second call while one runs waits for the end
    // of the first and gives the same result.
    package func removeAll(
        then removeClones: @escaping @MainActor @Sendable () async -> String?
    ) async -> String? {
        if let removal { return await removal.value }
        let removal = Task { await removeAllNow(then: removeClones) }
        self.removal = removal
        return await removal.value
    }

    // The steps of Remove all clones (removeAll), in the task of the removal.
    private func removeAllNow(then removeClones: @MainActor () async -> String?) async -> String? {
        for pr in queue.waiting { queue.cancel(pr) }
        // An own request ends its writes first, as a posting round does, and a discard ends.
        for run in ownRuns.values { await run.value }
        for discard in discards.values { _ = await discard.value }
        for drop in drops.values { await drop.value }
        let running = queue.running
        for pr in running where store.state.prs[pr]?.round?.phase != .posting {
            halt(pr, .clonesRemoved)
        }
        for pr in running { await queue.task(of: pr)?.value }
        for (pr, prState) in store.state.prs {
            if prState.reviewSession != nil { await sessions.remove(pr, .review) }
            if prState.requestSession != nil { await sessions.remove(pr, .request) }
        }
        let time = now()
        await store.update { state in
            for entry in state.queue where entry.kind.isMine {
                state.prs[entry.pr]?.handleOlder = false
                state.prs[entry.pr]?.handleCopilot = false
                state.prs[entry.pr]?.resolveNow = false
            }
            state.queue.removeAll()
            for (pr, prState) in state.prs {
                // A request round that posts keeps its writes.
                if prState.round?.phase != .posting, let outbox = prState.outbox,
                    outbox.posts.contains(where: Self.needsClone)
                {
                    state.prs[pr]?.dropOutbox(now: time)
                }
                guard let round = prState.round, round.kind == .review || round.phase != .posting
                else { continue }
                state.prs[pr]?.round = nil
                if round.kind == .request { state.prs[pr]?.hold(Self.ordered(round.items)) }
                if round.kind == .conflict {
                    state.prs[pr]?.resolveNow = false
                    state.prs[pr]?.conflict = Self.withoutWorking(prState.conflict)
                }
            }
        }
        changed()
        setup.dropOneStarts()
        let failure = await removeClones()
        removal = nil
        queue.wake()
        return failure
    }

    // MARK: - The clicks

    // Review, or Try again: queue a review round of a PR of the last poll that has no round and
    // no entry. A PR with failing CI gets no review.
    package func review(_ pr: PRKey) async {
        guard !removing, let polled = answer()?.toReview.first(where: { $0.key == pr }),
            polled.ci != .failing
        else { return }
        let state = store.state
        guard state.prs[pr]?.round == nil,
            !state.queue.contains(where: { $0.pr == pr && $0.kind == .review }),
            queue.runningJob(of: pr) == nil
        else { return }
        let time = now()
        // A click on a clone that needs trust gives one start, which claude judges.
        setup.allowOneStart(pr.repo)
        // The click counts as an act of the user on the request. The mark of the last round
        // stays until the round ends: the round reads it to find the draft of Bifrost.
        await store.update { state in
            var prState = state.prs[pr] ?? PRState()
            prState.actedAt = time
            prState.lastError = nil
            state.prs[pr] = prState
            state.queue.append(QueueEntry(pr: pr, kind: .review, at: time))
        }
        changed()
        queue.add(QueuedJob(pr: pr, kind: .review, since: time))
    }

    // Cancel review: the queued review of the PR goes. A round that runs stays.
    package func cancel(_ pr: PRKey) async {
        guard store.state.prs[pr]?.round == nil, queue.runningJob(of: pr) == nil else { return }
        queue.cancel(pr)
        await store.update { state in
            state.queue.removeAll { $0.pr == pr && $0.kind == .review }
        }
        changed()
    }

    // Stop session: a round that has not posted yet stops and posts nothing. The sessions of the
    // PR stop and stay, so the user can open their chat.
    package func stopSession(_ pr: PRKey) async {
        if let round = store.state.prs[pr]?.round, round.phase != .posting {
            await store.update { $0.prs[pr]?.round?.stoppedByUser = true }
            if queue.runningJob(of: pr) != nil { halt(pr, .userStop) }
        }
        await sessions.stop(pr, .review)
        await sessions.stop(pr, .request)
    }

    // The session row of the review of the PR while it is not parked: the user can open its chat.
    package func session(of pr: PRKey) -> SessionRow? {
        sessions.row(pr, .review)
    }

    // MARK: - The queue

    // A job can start after the first poll, while its repository needs no trust step and no own
    // request, discard or drop of its PR runs.
    private func isReady(_ job: QueuedJob) -> Bool {
        guard answer() != nil, !removing, ownRuns[job.pr] == nil, discards[job.pr] == nil,
            drops[job.pr] == nil
        else { return false }
        // A round that runs or posts after a restart can always go on.
        switch store.state.prs[job.pr]?.round?.phase {
        case .running?, .posting?: return true
        default: break
        }
        let repo = job.pr.repo
        return !setup.clones.needsTrust.contains(repo) || setup.hasOneStart(repo)
    }

    // The round of a job of the queue. At the end of a job on a PR of the user, an own request
    // file of the user that waits (for example one that ran in the turn of a request round) can
    // go: the check runs in a new task, after the queue frees the PR, and starts an own request
    // only when the file is there.
    private func run(_ job: QueuedJob) async {
        let pr = job.pr
        defer {
            if job.kind.isMine { checkAtJobEnd(pr) }
        }
        // A halt that came before the task ran (a drop at the first poll, for example) stops it
        // here, with its clean-up.
        if Task.isCancelled {
            await Task { await self.halted(job, chosen: []) }.value
            return
        }
        if let saved = store.state.prs[pr]?.round {
            guard saved.kind == job.kind else { return }
            switch (job.kind, saved.phase) {
            case (.review, .running):
                let round = makeRound(pr)
                await settle(job, round) { () async throws(ReviewRound.Stop) in
                    try await round.resume(saved)
                }
            case (.request, .running), (.request, .posting):
                await runRequest(job, saved: saved)
            case (.conflict, .running), (.conflict, .posting):
                await runConflict(job, saved: saved)
            default:
                // A CI round comes with the CI rounds.
                break
            }
            return
        }
        guard store.state.queue.contains(where: { $0.pr == pr && $0.kind == job.kind }) else {
            return
        }
        switch job.kind {
        case .request:
            await runRequest(job, saved: nil)
            return
        case .conflict:
            await runConflict(job, saved: nil)
            return
        case .review, .ci:
            break
        }
        // Only a review job goes on from here: a job of another kind never makes a review round.
        // A CI job does not run here yet: its entry goes, so the row does not show Queued for it.
        guard job.kind == .review else {
            await store.update { $0.queue.removeAll { $0.pr == pr && $0.kind == job.kind } }
            changed()
            return
        }
        if answer()?.toReview.first(where: { $0.key == pr })?.ci == .failing {
            // The click no longer counts as an act, and the row says why nothing started.
            await store.update { state in
                state.queue.removeAll { $0.pr == pr && $0.kind == .review }
                state.prs[pr]?.actedAt = nil
                state.prs[pr]?.lastError = RoundFailure.ciFailing.message
            }
            changed()
            return
        }
        let time = now()
        await store.update { state in
            state.queue.removeAll { $0.pr == pr && $0.kind == .review }
            var prState = state.prs[pr] ?? PRState()
            prState.round = ActiveRound(
                phase: .preparing, startedAt: time, at: job.since, kind: .review)
            state.prs[pr] = prState
        }
        // The user acts on the request again, so a review result that Bifrost keeps for the PR
        // ends.
        reviewStarted(pr)
        changed()
        let round = makeRound(pr)
        await settle(job, round) { () async throws(ReviewRound.Stop) in try await round.start() }
    }

    // The check for an own request file at the end of a request job, in a task of ReviewRounds.
    // The task starts now and runs after the queue frees the PR. It starts an own request only
    // when the file is there.
    private func checkAtJobEnd(_ pr: PRKey) {
        jobEndCount += 1
        let number = jobEndCount
        jobEndChecks[number] = Task { [weak self] in
            if let self, await self.own.waits(pr), !Task.isCancelled { self.checkOwnRequest(pr) }
            self?.jobEndChecks[number] = nil
        }
    }

    // One review round of the PR on the services of the rounds.
    private func makeRound(_ pr: PRKey) -> ReviewRound {
        ReviewRound(
            pr: pr,
            parts: ReviewRound.Parts(
                store: store, github: github, repos: repos, setup: setup, sessions: sessions,
                skills: skills, now: now),
            model: config.reviewModel, viewer: { [weak self] in self?.answer()?.viewer },
            stopRequested: { [weak self] in self?.userStopped(pr) ?? false },
            takeTryOnce: { [weak self] in self?.setup.takeOneStart(pr.repo) ?? false },
            startedSession: { [weak self] in self?.startedSession(pr.repo) },
            changed: { [weak self] in self?.changed() })
    }

    // Run the steps of the review round, then end it by how they stopped: a good end notifies
    // once and polls at once; a failure shows its reason, and polls when GitHub can hold a part
    // of the writes.
    private func settle(
        _ job: QueuedJob, _ round: ReviewRound,
        _ steps: () async throws(ReviewRound.Stop) -> ReviewRound.Ended
    ) async {
        let pr = job.pr
        do throws(ReviewRound.Stop) {
            switch try await steps() {
            case .drafted: notify(.draftReady(pr))
            case .reviewed: notify(.reviewed(pr))
            }
            ended()
        } catch {
            // A cancel stops the round, whatever the step that saw it gave.
            let stop: ReviewRound.Stop = Task.isCancelled ? .halted : error
            switch stop {
            case .failed(let failure):
                await fail(pr, failure)
                if round.posting { ended() }
            case .waitForTrust(let refused): await waitForTrust(job, refused: refused)
            // The task of the round is cancelled, so the clean-up runs in a task of its own:
            // its git, its session commands and its file calls must not stop at the cancel.
            case .halted: await Task { await self.halted(job, chosen: []) }.value
            }
        }
    }

    // MARK: - The ends

    // A failed review round: the round clears, and the row shows the reason with Try again.
    private func fail(_ pr: PRKey, _ failure: RoundFailure) async {
        await store.update { state in
            state.prs[pr]?.round = nil
            state.prs[pr]?.lastError = failure.message
        }
        changed()
    }

    // The clone needs the trust of the user: the job goes back to the queue with its first time,
    // and waits until the repository is trusted.
    func waitForTrust(_ job: QueuedJob, refused: Bool) async {
        await store.update { state in
            state.prs[job.pr]?.round = nil
            if !state.queue.contains(where: { $0.pr == job.pr && $0.kind == job.kind }) {
                state.queue.append(QueueEntry(pr: job.pr, kind: job.kind, at: job.since))
                state.queue.sort { $0.at < $1.at }
            }
        }
        setup.waitsForTrust(job.pr.repo, refusedByClaude: refused)
        changed()
        queue.add(job)
    }

    // A cancelled round. The user stop fails it; the request that went (or the PR that closed)
    // drops the PR; the clones that went clear it. A request round holds its items (chosen, else
    // the items of its state). With no reason (Watch GitHub off, the quit), the state keeps it.
    func halted(_ job: QueuedJob, chosen: [NodeID]) async {
        let pr = job.pr
        let saved = Self.ordered(store.state.prs[pr]?.round?.items ?? [:])
        let items = chosen.isEmpty ? saved : chosen
        switch (queue.halt(of: pr), job.kind) {
        case (.userStop?, .review):
            await repos.resetWorktree(pr)
            await fail(pr, .stopped)
        case (.userStop?, .request):
            // The worktree keeps a fix that the outbox has not committed yet. Before the turn of
            // the round started (no session ID), the worktree holds only the work of a person in
            // the session, so it stays too.
            let prState = store.state.prs[pr]
            if prState?.round?.sessionID != nil,
                prState?.outbox.map(OutboxRules.commitOpen) != true
            {
                // A change of a person in the turn (an own request file) stays.
                await repos.resetIfKnown(pr)
            }
            await failRequest(pr, .stopped, hold: items)
        case (.userStop?, .conflict):
            // A conflict round keeps its failures in its mark, never in lastError: the mark gets
            // the text of the stop, so no automatic round tries the pair again. The worktree goes
            // back to the head; a change that no round made stays (resetIfKnown).
            let prState = store.state.prs[pr]
            if let head = prState?.round?.headSHA ?? Self.working(prState?.conflict)?.head {
                await repos.resetIfKnown(pr, to: head)
            }
            await failConflict(pr, .session(.stopped), pair: conflictPair(pr))
        case (.userStop?, .ci):
            // A CI round keeps its failures in its own mark (the CI rounds). The stop ends it.
            await store.update { $0.prs[pr]?.round = nil }
            changed()
        case (.requestGone?, .review):
            await drop(pr)
        case (.requestGone?, .request), (.requestGone?, .conflict), (.requestGone?, .ci):
            await dropRequest(pr)
        case (.clonesRemoved?, let kind):
            // A request round holds its items, and its click goes, as the clicks of the queue do.
            // A conflict round loses its click and its working mark: the clone of its merge went.
            await store.update { state in
                state.prs[pr]?.round = nil
                switch kind {
                case .request:
                    state.prs[pr]?.hold(items)
                    state.prs[pr]?.handleOlder = false
                    state.prs[pr]?.handleCopilot = false
                case .conflict:
                    let mark = state.prs[pr]?.conflict
                    state.prs[pr]?.resolveNow = false
                    state.prs[pr]?.conflict = Self.withoutWorking(mark)
                case .review, .ci:
                    break
                }
            }
            changed()
        case (nil, _):
            break
        }
    }

    // The request of the PR went: its review session, worktree, input folder and queue entry go,
    // and its review fields clear. Nothing posts.
    private func drop(_ pr: PRKey) async {
        await sessions.remove(pr, .review)
        await repos.removePR(pr)
        await store.update { state in
            state.queue.removeAll { $0.pr == pr && $0.kind == .review }
            guard var prState = state.prs[pr] else { return }
            prState.actedAt = nil
            prState.recommendation = nil
            prState.reviewSession = nil
            if prState.round == nil || prState.round?.kind == .review {
                prState.round = nil
                prState.lastError = nil
            }
            state.prs[pr] = prState
        }
        changed()
    }

    // Stop the round of the PR that runs, for the reason. A round that sends the writes of an
    // earlier round (finishingWrites) is not cancelled: the halt waits, and the round stops right
    // after those writes, as a posting round ends its writes first.
    private func halt(_ pr: PRKey, _ reason: RoundHalt) {
        queue.setHalt(reason, of: pr)
        if !finishingWrites.contains(pr) { queue.cancel(pr) }
    }

    // MARK: - The gates of the request part

    // The calls that a request round and a conflict round of the PR make back to the coordinator.
    func roundHooks(_ pr: PRKey) -> RoundHooks {
        RoundHooks(
            viewer: { [weak self] in self?.answer()?.viewer },
            stopRequested: { [weak self] in self?.userStopped(pr) ?? false },
            takeTryOnce: { [weak self] in self?.setup.takeOneStart(pr.repo) ?? false },
            startedSession: { [weak self] in self?.startedSession(pr.repo) },
            changed: { [weak self] in self?.changed() })
    }

    // The request round of the PR starts to send the writes of an earlier round: from now on, a
    // halt does not cancel it.
    func holdHalts(_ pr: PRKey) {
        finishingWrites.insert(pr)
    }

    // The writes of the earlier round ended. The result is true when a halt came while they ran,
    // so the round must stop now.
    func releaseHalts(_ pr: PRKey) -> Bool {
        finishingWrites.remove(pr)
        return queue.halt(of: pr) != nil
    }

    // True when the user stopped the round of the PR that runs.
    func userStopped(_ pr: PRKey) -> Bool {
        queue.halt(of: pr) == .userStop
    }

    // The session of a round of the repository started: the clone is trusted, and the queue can
    // start the next job.
    func startedSession(_ repo: RepoName) {
        setup.startedSession(repo)
        queue.wake()
    }

    // A write of an outbox that needs the clone: the fix commit or its push, not done or dropped.
    private static func needsClone(_ post: OutboxPost) -> Bool {
        switch post.write {
        case .commit, .push: post.state == .todo || post.state == .sending
        default: false
        }
    }

    // The items of a round in the order of their times, then of their IDs.
    nonisolated static func ordered(_ items: [NodeID: Date]) -> [NodeID] {
        items.sorted { ($0.value, $0.key.text) < ($1.value, $1.key.text) }.map(\.key)
    }
}
