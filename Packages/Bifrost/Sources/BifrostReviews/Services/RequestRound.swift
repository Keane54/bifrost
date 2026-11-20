// One request round (docs/behaviour/reviews.md, "Request rounds"): Claude fixes and answers the
// review comments on a PR of the user in a sandboxed session, and writes its result file. Bifrost
// trusts none of the result: it checks it strictly, and Bifrost itself commits, pushes and posts
// (the outbox of the writes, RoundWrites). The coordinator (RequestRounds) makes one RequestRound
// for each run of a job, and ends the round by how its steps stop.
//
// The steps:
// 1. The clone of the repository. An outbox of an earlier round that did not finish (Try again)
//    sends the rest of its writes first, so a new round never replaces them. As for a posting
//    round, Stop session, a drop and Remove all clones do not cancel those writes: the round
//    stops right after them. Then the trust read of Claude Code (as for a review round).
// 2. The full read of the PR (RequestQueries). A closed PR ends the round with nothing (the next
//    poll drops it). A PR of another author or from a fork fails.
// 3. The items (WorkRule), with the trigger of the job and the gate of the automatic rounds at
//    this time. No item ends the round and spends the click. A cut read with items fails and
//    holds them all, because the cut part can hide a reply of an earlier round. The read time and
//    the first Copilot review are saved.
// 4. The fetch of the head.
// 5. The turn in the one request session of the PR (PRSessions.beginTurn,
//    docs/behaviour/reviews.md, "PR sessions"). The turn first waits until no person can use the
//    session (prepare). An own request file of the user then goes first (OwnRequests): the round
//    stops with ownRequestFirst, and its job starts it again after the own request. Changes in
//    the worktree that no round made (RepoStore.unknownChanges) stay, and the round fails with
//    changesNotOnGitHub (Needs you). Only then does the round change the folders of the session:
//    the worktree of the last round at the new head (placeWorktree), the round folder with no
//    file of the last round (roundFolder), and the files of the round, each with the round ID of
//    a new token in its name (RoundFiles): the input file, the full diff (when it is not too
//    large),
//    the mode file and the rules. The first round starts the session with the sandbox
//    (RequestSandbox) in the worktree, with --restricted, so no settings file of the user or of
//    the PR head changes its rules. A later round types its prompt into the live session, or
//    resumes the stopped session. The session stays after the round. The start of the turn
//    spends the click and takes the items out of held.
// 6. The wait for the end of the turn on the result file of this round, at most requestLimit. A
//    late result of an earlier round has another name, so it never ends this turn. A prompt (for
//    example the approval of a write to a settings, git or tool configuration file under
//    --restricted) stops the session at once, and its result counts only when it is good. At the
//    end of the turn, the changes of the worktree count as changes of the round
//    (RepoStore.markLeftovers). An own request file shows that a request of the user ran in the
//    turn (a message that the user typed while the round ran): then no change counts as a change
//    of the round, so no reset removes it, and the file goes as an own request after the round.
// 7. The strict check of the result (RequestResult) against the changes of the worktree, and the
//    check that each "by" commit is a commit of the PR. Then a fresh read: a closed PR posts
//    nothing.
// 8. The outcome: each Needs you item gets its question with the place of the item, each No action
//    item is handled, and each answered question of the round goes. In the same save, the round
//    goes to the posting phase with the outbox of its writes (OutboxRules.plan); a failed save
//    writes nothing. The worktree keeps the fix for the commit.
// 9. The writes (RoundWrites): the fix commit, the push, the replies, the resolves and the new
//    review requests. Then the round ends.
// A failure from step 3 on holds the items of the round (chosen). A failure before the turn
// starts does not reset the worktree. After the turn, a reset runs only while no person uses the
// session and the worktree has no change that no round made (resetAfterTurn,
// RepoStore.resetIfKnown); the next round checks the worktree again. Writes that stop end the
// round with the items where the outbox rules put them. A round whose session ran when Bifrost
// started goes on at step 6 (resume).
import BifrostFoundation
import BifrostSessions
import Foundation
import OSLog

@MainActor
final class RequestRound {
    // How the steps of a round stop.
    enum Stop: Error {
        case failed(RoundFailure)
        // The clone needs the trust of the user. refused: claude refused the start.
        case waitForTrust(refused: Bool)
        // The task of the round was cancelled.
        case halted
        // An own request file of the user waits. The round changed nothing: the own request goes
        // first, then the job starts the round again.
        case ownRequestFirst
        // The writes of an outbox stopped. The outbox rules put the items (handled, held, or in
        // the outbox that stays for Try again).
        case wrote(RoundFailure)
    }

    // How a good round ended.
    enum Ended {
        // No item is work now. The click is spent.
        case nothing
        // The PR merged or closed. Nothing was posted.
        case closed
        // The round saved its outcome. added: the open questions that the round added.
        case accepted(RequestOutcome, added: Int)
    }

    // The services of the rounds.
    struct Parts {
        let store: ReviewsStore
        let github: GitHubClient
        let repos: RepoStore
        let setup: RepoSetup
        let sessions: PRSessions
        let writes: RoundWrites
        let own: OwnRequests
        let skills: URL
        // The home of the user in the user database, which holds the secret paths of the sandbox.
        let userHome: URL
        let now: () -> Date
    }

    private static let logger = Logger(bifrost: "reviews")
    // The Bifrost mode of the skill, below the skills folder.
    static let modeFile = "skills/bifrost-resolve-comments/bifrost-mode.md"

    let pr: PRKey
    // The items of the round, oldest first, once it chose them. A failure from then on holds them.
    private(set) var chosen: [NodeID] = []
    // The changes that the safety net found and that stopped the round, sorted. The reason of the
    // row keeps them for Discard these changes.
    private(set) var unsavedFiles: [String] = []

    private let parts: Parts
    private let trigger: RoundTrigger
    private let model: ModelChoice
    // The setting "Sign commits through GitHub" at the start of the round. The outbox keeps it.
    private let signed: Bool
    // The setting "Handle comments on my PRs automatically". The consent of the state completes
    // the gate (ReviewsState.allowsAutoFix).
    private let autoFix: () -> Bool
    private let viewer: () -> String?
    // True when the user stopped the round with Stop session.
    private let stopRequested: () -> Bool
    private let takeTryOnce: () -> Bool
    private let startedSession: () -> Void
    private let changed: () -> Void
    // Called before and after the writes of an earlier round, which a halt does not cancel. The
    // second call gives true when a halt came while they ran.
    private let holdHalts: () -> Void
    private let releaseHalts: () -> Bool

    init(
        pr: PRKey, parts: Parts, trigger: RoundTrigger, model: ModelChoice, signed: Bool,
        autoFix: @escaping () -> Bool, viewer: @escaping () -> String?,
        stopRequested: @escaping () -> Bool, takeTryOnce: @escaping () -> Bool,
        startedSession: @escaping () -> Void, changed: @escaping () -> Void,
        holdHalts: @escaping () -> Void, releaseHalts: @escaping () -> Bool
    ) {
        self.pr = pr
        self.parts = parts
        self.trigger = trigger
        self.model = model
        self.signed = signed
        self.autoFix = autoFix
        self.viewer = viewer
        self.stopRequested = stopRequested
        self.takeTryOnce = takeTryOnce
        self.startedSession = startedSession
        self.changed = changed
        self.holdHalts = holdHalts
        self.releaseHalts = releaseHalts
    }

    private var store: ReviewsStore { parts.store }
    private var repos: RepoStore { parts.repos }
    private var sessions: PRSessions { parts.sessions }

    // MARK: - The steps

    // Steps 1 to 8 of a new round, whose state is preparing.
    func start() async throws(Stop) -> Ended {
        guard let viewer = viewer() else { throw .failed(.readFailed(.notLoggedIn)) }
        do throws(RepoError) {
            try await repos.ensureClone(pr.repo)
        } catch {
            Self.logger.error("\(error.message, privacy: .private)")
            throw .failed(.prepareFailed)
        }
        try checkHalt()
        if let outbox = store.state.prs[pr]?.outbox { try await sendEarlier(outbox) }
        guard await parts.setup.trustsForStart(pr.repo) || takeTryOnce() else {
            throw .waitForTrust(refused: false)
        }
        try checkHalt()
        let full = try await read()
        guard full.state == .open else {
            await end(full, spent: false)
            return .closed
        }
        guard full.author.lowercased() == viewer.lowercased() else { throw .failed(.notYours) }
        guard !full.isCrossRepository else { throw .failed(.fork) }
        let state = store.state
        let wanted = WorkRule.wanted(
            full, state.prs[pr] ?? PRState(), fixFrom: state.fixFrom ?? state.turnedOnAt,
            viewer: viewer, trigger: trigger, autoFix: state.allowsAutoFix(autoFix()),
            baseline: Set(state.baseline))
        if full.truncated && !wanted.isEmpty {
            chosen = wanted.map(\.id)
            await markRead(full)
            throw .failed(.tooManyComments)
        }
        let items = Array(wanted.prefix(WorkRule.maxItems))
        guard !items.isEmpty else {
            await end(full, spent: true)
            return .nothing
        }
        await markRead(full)
        chosen = items.map(\.id)
        guard let base = BranchName(full.baseRef) else { throw .failed(.prepareFailed) }
        let (pr, repos) = (pr, repos)
        let fetched = try await git { () async throws(RepoError) in
            try await repos.fetchPR(pr, base: base)
        }
        try checkHalt()
        let token = UUID().uuidString.lowercased()
        // The preparation writes the input of the round. Each way to start a turn prepares it.
        var written: RequestInput?
        let begun = try await beginTurn { () async throws(RoundFailure) -> MineTurn in
            let prepared = try await prepare(
                full: full, items: items, fetched: fetched, viewer: viewer, token: token)
            written = prepared.input
            return prepared.turn
        }
        guard let input = written else { throw .failed(.startFailed) }
        let row = begun.row
        let (time, taken) = (parts.now(), Set(chosen))
        let seen = Dictionary(
            items.map { ($0.id, full.newestTime(of: $0.id) ?? $0.since) }) { first, _ in first }
        await store.update { state in
            guard var prState = state.prs[pr], var round = prState.round else { return }
            round.phase = .running
            round.headSHA = fetched.head
            // The base of a request round is the merge base: the check of a "by" commit uses it.
            round.baseSHA = fetched.mergeBase
            round.shortID = row.shortId
            round.sessionID = SessionID(row.sessionId)
            round.token = token
            round.items = seen
            // The time limit counts from the start of the turn.
            round.startedAt = time
            prState.round = round
            // Only a turn that started spends the click and takes its items out of held.
            prState.handleOlder = false
            prState.handleCopilot = false
            prState.held.removeAll { taken.contains($0) }
            state.prs[pr] = prState
        }
        changed()
        return try await finish(
            input: input, session: row.sessionId, startedAt: begun.startedAt,
            begun: row)
    }

    // A round whose session ran when Bifrost started: wait for its end, then check its result
    // against the items, the head and the token that the state saved.
    func resume(_ round: ActiveRound) async throws(Stop) -> Ended {
        chosen = round.items.sorted { ($0.value, $0.key.text) < ($1.value, $1.key.text) }
            .map(\.key)
        // The user stopped it before the quit.
        guard !round.stoppedByUser else { throw .failed(.stopped) }
        // A round with no token has no result that can count.
        guard let head = round.headSHA, let mergeBase = round.baseSHA, let token = round.token,
            let id = round.sessionID?.text, viewer() != nil
        else { throw .failed(.noResult) }
        let files = RoundFiles(
            folder: repos.layout.inputFolder(pr.repo, number: pr.number), token: token)
        let input = RequestInput(
            resumed: pr, round: token, headSHA: head, mergeBase: mergeBase,
            itemIDs: chosen, files: RequestInput.Files(files, fullDiff: false))
        let elapsed = Duration.seconds(max(parts.now().timeIntervalSince(round.startedAt), 0))
        return try await finish(
            input: input, session: id, startedAt: sessions.time - elapsed, begun: nil)
    }

    // Step 5: the turn in the one session of the PR. When the turn does not start, the round does
    // not reset the worktree: before the preparation the worktree holds only the work of a person
    // (for example after sessionBusy, or an Interrupt at the send), and after it the next round
    // checks it again after its wait. A prepared turn that waits again checks the worktree again
    // before its next send (checkWorktree).
    private func beginTurn(
        _ prepare: () async throws(RoundFailure) -> MineTurn
    ) async throws(Stop) -> BegunTurn {
        if stopRequested() { throw .failed(.stopped) }
        let worktree = repos.layout.worktree(pr.repo, number: pr.number)
        let begun: BegunTurn
        do throws(RoundFailure) {
            begun = try await sessions.beginTurn(
                pr, worktree: worktree, prepare: prepare,
                recheck: { () async throws(RoundFailure) in try await checkWorktree() })
        } catch .notTrusted {
            throw .waitForTrust(refused: true)
        } catch .ownRequestWaits {
            throw .ownRequestFirst
        } catch {
            try checkHalt()
            throw .failed(error)
        }
        startedSession()
        return begun
    }

    // Before the round changes the worktree: an own request of the user goes first, and changes
    // that no round made stay (the safety net). In both cases the round changes nothing.
    private func checkWorktree() async throws(RoundFailure) {
        if await parts.own.waits(pr) { throw .ownRequestWaits }
        guard let unknown = await repos.unknownChanges(pr) else { throw .prepareFailed }
        guard unknown.isEmpty else {
            unsavedFiles = unknown
            Self.logger.notice(
                """
                The copy of \(self.pr.text, privacy: .private) has \
                \(unknown.count, privacy: .public) changes that no round made, so the round does \
                not start.
                """)
            throw .changesNotOnGitHub
        }
    }

    // The preparation of the turn, which PRSessions runs only when no person can use the session
    // of the PR: the worktree at the head, the files of the round and the sandbox. An own request
    // of the user goes first, and changes that no round made stay (the safety net): in both
    // cases the round changes nothing.
    private func prepare(
        full: FullPR, items: [WorkItem], fetched: FetchedPR, viewer: String, token: String
    ) async throws(RoundFailure) -> (input: RequestInput, turn: MineTurn) {
        let (pr, repos) = (pr, repos)
        try await checkWorktree()
        let worktree = try await repoStep { () async throws(RepoError) in
            try await repos.placeWorktree(pr, head: fetched.head)
        }
        if Task.isCancelled { throw .stopped }
        let input = try await writeInput(
            full: full, items: items, fetched: fetched, viewer: viewer, token: token)
        if Task.isCancelled { throw .stopped }
        // Claude Code compares real paths, so the rules name the real paths of the folders and
        // --add-dir gets the real path of the input folder. With no real path or no settings, a
        // rule can miss its path, so the session does not start.
        let (clonePath, treePath, folderPath, reviewsPath, homePath) = (
            repos.layout.clone(pr.repo).plainPath, worktree.url.plainPath,
            input.files.result.deletingLastPathComponent().plainPath,
            repos.layout.folder.plainPath, parts.userHome.plainPath
        )
        let real = await BlockingExecutor.run {
            (
                RealPath.of(clonePath), RealPath.of(treePath), RealPath.of(folderPath),
                RealPath.of(reviewsPath), RealPath.of(homePath)
            )
        }
        guard let clone = real.0, let tree = real.1, let folder = real.2, let reviews = real.3,
            let home = real.4,
            let settings = RequestSandbox.settings(
                SessionPaths(
                    clone: clone, worktree: tree, inputFolder: folder, reviews: reviews,
                    home: home))
        else { throw .startFailed }
        let turn = MineTurn(
            pr: pr, model: model, inputFolder: URL(filePath: folder, directoryHint: .isDirectory),
            skills: parts.skills, settings: settings,
            prompt: PRSessionArgs.requestPrompt(input.files.input), worktree: worktree)
        return (input, turn)
    }

    // Steps 6 to 8: the end of the turn, the checks of the result, a fresh read and the outcome.
    private func finish(
        input: RequestInput, session: String, startedAt: Duration, begun: SessionRow?
    ) async throws(Stop) -> Ended {
        // The bytes of the result that the last check of the turn end accepted. The round checks
        // these bytes and never reads the file again, so a session that writes the file after the
        // end changes nothing.
        let accepted: Data?
        var blocked = false
        do throws(RoundFailure) {
            // The turn ends at once when the result passes the check of the round.
            let end: TurnEnd<Data>
            do throws(RoundFailure) {
                end = try await sessions.waitForTurnEnd(
                    id: session, startedAt: startedAt, resultFile: input.files.result,
                    limit: ReviewRounds.requestLimit, begun: begun,
                    check: { (try? RequestResult.check($0, input: input).get()) != nil ? $0 : nil })
            } catch {
                // A cancel (Stop session, a halt) ends the wait. The record of the turn runs in a
                // task of its own, so git still runs, and the reset of the stop can use it.
                await Task { await self.afterTurn() }.value
                throw error
            }
            await afterTurn()
            switch end {
            case .ended(let bytes):
                accepted = bytes
            case .blocked(let bytes):
                // A session of a round must never ask. Its result counts only when it is good.
                (accepted, blocked) = (bytes, true)
                await sessions.stop(id: session)
            }
        } catch .timeout {
            await sessions.stop(id: session)
            await resetAfterTurn(session, stoppedIt: true)
            throw .failed(.timeout)
        } catch {
            try checkHalt()
            await resetAfterTurn(session, stoppedIt: false)
            throw .failed(.stopped)
        }
        try checkHalt()
        let outcome: RequestOutcome
        do throws(RoundFailure) {
            if stopRequested() || store.state.prs[pr]?.round?.stoppedByUser == true {
                throw .stopped
            }
            outcome = try await result(accepted, input: input, blocked: blocked)
        } catch {
            try checkHalt()
            await resetAfterTurn(session, stoppedIt: blocked)
            throw .failed(error)
        }
        let full: FullPR
        do throws(Stop) {
            full = try await read()
        } catch {
            await resetAfterTurn(session, stoppedIt: blocked)
            throw error
        }
        guard full.state == .open else {
            await resetAfterTurn(session, stoppedIt: blocked)
            await end(full, spent: false)
            return .closed
        }
        // With no fix to commit, the files of the session go now.
        if outcome.commit == nil { await resetAfterTurn(session, stoppedIt: blocked) }
        let (added, outbox) = try await accept(outcome, full: full)
        try await send(outbox)
        await succeed()
        return .accepted(outcome, added: added)
    }

    // At the end of the turn: each change of the worktree is a change of the round, so a reset
    // can remove it (RepoStore.markLeftovers). An own request file shows that a request of the
    // user ran in the turn, for example a message that the user typed while the round ran. Then
    // no change counts as a change of the round: no reset removes the changes of the user, the
    // file stays, and it goes as an own request after the round (its head check refuses it when
    // the fix commit of the round moved the head, and the changes then stay with Needs you).
    private func afterTurn() async {
        guard await parts.own.waits(pr) else {
            await repos.markLeftovers(pr)
            return
        }
        parts.own.cameFromRound(pr)
        Self.logger.notice(
            """
            A request of the user ran in the turn of a round of \
            \(self.pr.text, privacy: .private), so Bifrost keeps the worktree.
            """)
    }

    // Reset the worktree after the turn, so the files of the session go. A person can use the
    // session after its turn: while its row works or shows a box, the reset does not run. The
    // reset also does not run while the worktree has a change that no round made
    // (RepoStore.resetIfKnown); the next round then stops with Needs you. stoppedIt: the round
    // stopped the session (a time limit or a prompt), so no person uses it, also while a list
    // still shows its row.
    private func resetAfterTurn(_ session: String, stoppedIt: Bool) async {
        if !stoppedIt, sessions.inUse(id: session) {
            Self.logger.notice(
                """
                A person uses the session of \(self.pr.text, privacy: .private), so Bifrost \
                keeps its worktree as it is.
                """)
            return
        }
        await repos.resetIfKnown(pr)
    }

    // Step 7: the strict check of the bytes that ended the turn, against the changes of the
    // worktree. With no accepted bytes, a read of the file gives the reason, for the text only. A
    // session that asked fails with blocked when its result is missing or bad.
    private func result(_ accepted: Data?, input: RequestInput, blocked: Bool)
        async throws(RoundFailure) -> RequestOutcome
    {
        guard let data = accepted else {
            if blocked { throw .blocked }
            let limit = RequestResult.maxBytes
            let read = await repos.readResult(at: input.files.result, limit: limit)
            throw read.failure(limit: limit) { data in
                if case .failure(let refusal) = RequestResult.check(data, input: input) {
                    refusal
                } else {
                    nil
                }
            }
        }
        guard let changed = await repos.changedPaths(pr) else { throw .endFailed }
        let failure: RoundFailure
        switch RequestResult.check(data, input: input, changed: changed) {
        case .success(let outcome):
            guard await byCommitsAreInThePR(outcome, input: input) else {
                failure = .badResult(ResultRefusal("a by commit that is not in the pull request"))
                break
            }
            return outcome
        case .failure(let refusal):
            failure = .badResult(refusal)
        }
        throw blocked ? .blocked : failure
    }

    // True when each "by" commit is a commit of the PR: after the merge base, and in the head of
    // the round.
    private func byCommitsAreInThePR(_ outcome: RequestOutcome, input: RequestInput) async -> Bool {
        for item in outcome.items {
            guard case .fixed(let by?) = item.outcome else { continue }
            guard by != input.mergeBase,
                await repos.isAncestor(input.mergeBase, of: by, in: pr.repo),
                await repos.isAncestor(by, of: input.headSHA, in: pr.repo)
            else { return false }
        }
        return true
    }

    // Step 8: the outcome in one save. A new outcome of an item ends its question. A Needs you
    // item gets a new question, with its place and the quote of the request; a No action item is
    // handled, with the time that the round read as its reply time. The round goes to the posting
    // phase with the outbox of its writes, so the items of the writes wait in the outbox and no
    // round starts on them by itself. The result is the count of the new questions and the
    // outbox. A save that fails sends no write: the outbox goes, and its items wait in held.
    private func accept(_ outcome: RequestOutcome, full: FullPR) async throws(Stop)
        -> (added: Int, outbox: Outbox)
    {
        let (pr, time, signed, order) = (pr, parts.now(), signed, chosen)
        var added = 0
        let saved = await store.update { state in
            guard var prState = state.prs[pr], var round = prState.round, round.kind == .request,
                let head = round.headSHA, let mergeBase = round.baseSHA
            else { return }
            for item in outcome.items {
                prState.questions[item.id] = nil
                let until = round.items[item.id] ?? time
                switch item.outcome {
                case .noAction:
                    prState.handled[item.id] = Handled(at: time, lastReplyAt: until)
                case .needsYou(let text):
                    prState.questions[item.id] = Self.question(
                        text, item: item.id, full: full, at: time, seenUntil: until)
                    added += 1
                case .fixed, .noFix:
                    break
                }
            }
            prState.outbox = OutboxRules.plan(
                outcome, order: order, full: full, seen: round.items, head: head,
                mergeBase: mergeBase, startedAt: time, signed: signed)
            round.phase = .posting
            prState.round = round
            prState.lastError = nil
            state.prs[pr] = prState
        }
        changed()
        let prState = store.state.prs[pr]
        guard saved, prState?.round?.phase == .posting, let outbox = prState?.outbox else {
            await store.update { $0.prs[pr]?.dropOutbox(now: time) }
            throw .wrote(.notSaved)
        }
        return (added, outbox)
    }

    // Step 9, and the writes of an earlier round: send the writes of the outbox. A cancel (a
    // quit) keeps the state for the next start.
    private func send(_ outbox: Outbox) async throws(Stop) {
        do throws(RoundFailure) {
            try await parts.writes.run(outbox, for: pr)
        } catch {
            try checkHalt()
            throw .wrote(error)
        }
        changed()
    }

    // Step 1: the writes of an earlier round. A halt does not cancel them (only a quit does), and
    // a halt that came while they ran stops the round right after them. A stop of the user then
    // fails the round with a text that says that the earlier writes went.
    // The writes of an own request of the user go through OwnRequests, with its texts, its Event
    // log lines and its Needs you. When they do not go, the round stops: the change of the user
    // is in the worktree (or in its commit, which the outbox keeps), so the round must not move
    // the worktree. The row keeps the reason of the own request.
    private func sendEarlier(_ outbox: Outbox) async throws(Stop) {
        holdHalts()
        var went = true
        if outbox.own {
            went = await parts.own.resend(pr)
        } else {
            do throws(Stop) {
                try await send(outbox)
            } catch {
                _ = releaseHalts()
                throw error
            }
        }
        let halted = releaseHalts()
        if Task.isCancelled { throw .halted }
        if !went { throw .failed(.changesNotOnGitHub) }
        guard halted else { return }
        if stopRequested() { throw .failed(.stoppedAfterEarlierWrites) }
        throw .halted
    }

    // A good round: it clears with the error of an earlier round.
    private func succeed() async {
        let pr = pr
        await store.update { state in
            guard state.prs[pr]?.round?.kind == .request else { return }
            state.prs[pr]?.round = nil
            state.prs[pr]?.lastError = nil
            state.prs[pr]?.waitsForYou = nil
        }
        changed()
    }

    // The question of a Needs you item for the Answer panel: the place of the item (the file and
    // the line, or the author of the comment) and the quote of the request. Each text is cut to
    // its limit before the save.
    static func question(
        _ text: String, item: NodeID, full: FullPR, at time: Date, seenUntil: Date
    ) -> Question {
        guard let request = full.request(of: item) else {
            return Question(text: text, place: "A deleted comment", at: time, seenUntil: seenUntil)
        }
        let place: String
        if request.inThread, let thread = full.threads.first(where: { $0.thread.id == item }) {
            let path = thread.thread.path
            place = thread.thread.line.map { "\(path) line \($0)" } ?? path
        } else {
            place = "Comment from \(request.comment.author.login)"
        }
        let body = request.comment.body
        let quote =
            body.trimmed().isEmpty
            ? nil
            : body.utf16.count <= Question.maxQuote
                ? body : body.cut(utf16: Question.maxQuote - 1) + "\u{2026}"
        return Question(
            text: text, place: place.cut(utf16: Question.maxPlace),
            author: request.comment.author.login.cut(utf16: Question.maxAuthor), body: quote,
            url: request.comment.url.flatMap { Question.commentURL($0.absoluteString) },
            kind: request.inThread ? .thread : .comment, at: time, seenUntil: seenUntil)
    }

    // MARK: - The parts of the steps

    // The read time and the first Copilot review of the full read.
    private func markRead(_ full: FullPR) async {
        let pr = pr
        await store.update { state in
            var prState = state.prs[pr] ?? PRState()
            prState.checkedAt = full.updatedAt ?? prState.checkedAt
            prState.firstCopilotReview = prState.firstCopilotReview ?? full.firstCopilotReview
            state.prs[pr] = prState
        }
    }

    // A round that ends with no session: no item (the click is spent), or a closed PR. The error
    // of an earlier round stays.
    private func end(_ full: FullPR, spent: Bool) async {
        let pr = pr
        await store.update { state in
            guard var prState = state.prs[pr] else { return }
            prState.checkedAt = full.updatedAt ?? prState.checkedAt
            prState.firstCopilotReview = prState.firstCopilotReview ?? full.firstCopilotReview
            if spent {
                prState.handleOlder = false
                prState.handleCopilot = false
            }
            prState.round = nil
            state.prs[pr] = prState
        }
        changed()
    }

    private func read() async throws(Stop) -> FullPR {
        let full: FullPR
        do throws(GitHubError) {
            full = try await RequestQueries.full(pr, client: parts.github)
        } catch {
            try checkHalt()
            Self.logger.error(
                """
                A read of \(self.pr.text, privacy: .private) failed. \
                \(error.message, privacy: .private)
                """)
            throw .failed(.readFailed(error))
        }
        try checkHalt()
        return full
    }

    // A git step of the repo store. A failure goes to the log, and the row gets a fixed text.
    private func git<Value>(_ step: () async throws(RepoError) -> Value) async throws(Stop)
        -> Value
    {
        let value: Value
        do throws(RepoError) {
            value = try await step()
        } catch {
            try checkHalt()
            Self.logger.error("\(error.message, privacy: .private)")
            throw .failed(.prepareFailed)
        }
        try checkHalt()
        return value
    }

    // A step of the repo store in the preparation of the turn. A failure goes to the log, and
    // the row gets a fixed text.
    private func repoStep<Value>(_ step: () async throws(RepoError) -> Value)
        async throws(RoundFailure) -> Value
    {
        do throws(RepoError) {
            return try await step()
        } catch {
            Self.logger.error("\(error.message, privacy: .private)")
            throw .prepareFailed
        }
    }

    // The files of the round in the round folder, each with the round ID of the token in its
    // name. The full diff comes from git in the clone, the rules from the skills. A full diff
    // over ReviewInput.maxDiffBytes stays out: the session reads the files.
    private func writeInput(
        full: FullPR, items: [WorkItem], fetched: FetchedPR, viewer: String, token: String
    ) async throws(RoundFailure) -> RequestInput {
        let (pr, repos) = (pr, repos)
        let text = try await repoStep { () async throws(RepoError) in
            try await repos.diff(pr.repo, from: fetched.mergeBase, to: fetched.head)
        }
        let diff = text.flatMap { $0.utf8.count <= ReviewInput.maxDiffBytes ? $0 : nil }
        let folder = try await repoStep { () async throws(RepoError) in
            try await repos.roundFolder(pr)
        }
        let round = RoundFiles(folder: folder, token: token)
        let input = RequestInput(
            full: full, items: items, questions: store.state.prs[pr]?.questions ?? [:],
            round: token, viewer: viewer, baseSHA: fetched.base, headSHA: fetched.head,
            mergeBase: fetched.mergeBase, files: RequestInput.Files(round, fullDiff: diff != nil))
        let (skills, modeFile) = (parts.skills, Self.modeFile)
        let rules = await BlockingExecutor.run { () -> (mode: Data, rules: Data)? in
            guard
                let mode = FileManager.default.contents(
                    atPath: skills.appending(path: modeFile).path(percentEncoded: false)),
                let rules = FileManager.default.contents(
                    atPath: skills.appending(path: "skills/bifrost-humanise/rules.md")
                        .path(percentEncoded: false))
            else { return nil }
            return (mode, rules)
        }
        guard let rules else { throw .inputFailed }
        let names = input.files
        var files: [(name: String, data: Data)] = [
            (names.mode.lastPathComponent, rules.mode),
            (names.rules.lastPathComponent, rules.rules),
            (names.input.lastPathComponent, input.fileData),
        ]
        if let diff, let path = names.fullDiff {
            files.append((path.lastPathComponent, Data(diff.utf8)))
        }
        do throws(RepoError) {
            try await repos.writeInput(pr, files)
        } catch {
            Self.logger.error("\(error.message, privacy: .private)")
            throw .inputFailed
        }
        return input
    }

    private func checkHalt() throws(Stop) {
        if Task.isCancelled { throw .halted }
    }
}
