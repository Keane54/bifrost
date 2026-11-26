// One conflict round (docs/behaviour/reviews.md, "Merge conflicts"): Bifrost merges the base
// branch into the head of a PR of the user in its clone, Claude resolves the conflicts in the one
// request session of the PR, and Bifrost checks the result, commits the merge (never signed) and
// pushes it (Pusher, never force). Claude never commits, pushes or reaches GitHub, and Bifrost
// trusts none of the result file (ConflictResult). The coordinator (ConflictRounds) makes one
// ConflictRound for each run of a job, and ends the round by how its steps stop. Each failure
// goes to the conflict mark of the pair of the round (ConflictMark), never to lastError.
//
// The steps:
// 1. The clone and the trust read, as for a request round. Writes that wait (an outbox) end the
//    round with no text: their fix can be in the worktree.
// 2. The fresh read of the head (HeadQueries). A closed PR, a PR with no conflicts now, and an
//    automatic round whose gate is closed (the setting and its consent) end with no text. A PR of
//    another author or from a fork fails.
// 3. The mark of the pair of the read (working), so no automatic round tries this pair again.
// 4. The fetch of the head and of the base branch. A head that moved since the read ends with no
//    text. Then the merge in the clone (ConflictMerge.start).
// 5. The turn in the one request session of the PR (PRSessions.beginTurn). The turn first waits
//    until no person can use the session. Only then does the round change the folders of the
//    session (prepare): an own request file of the user goes first, and changes that no round
//    made stop the round with Needs you (the safety net). Then the worktree moves to the merge
//    with the markers (placeWorktree), ConflictMerge.checkWorktree refuses a filter attribute or
//    a submodule before Claude starts, and the round folder gets the files of the round, each
//    with the round ID of a new token in its name.
// 6. The wait for the end of the turn on the result file of the round, at most the limit. An
//    own request file at the end of the turn shows that Claude changed files for a request in the
//    turn: Bifrost refuses the file, commits nothing, keeps the worktree and asks the user (Needs
//    you). A result of needs-you fails with the reason of Claude.
// 7. The commit of the merge (ConflictMerge.commit): "Merge <base> into <branch>". A change of the
//    worktree that no round made, before or after the commit, stops the round with Needs you, and
//    the merge does not go.
// 8. A fresh read again: a closed PR, a head that moved, and an automatic round whose gate is
//    closed now end with no text.
// 9. The posting phase with the merge, then the push (Pusher): the parents of the merge must be
//    the head and the base, and a branch with new commits gets nothing (BranchMoved.stop).
// 10. The end. A push that went: the worktree goes to the merge. A push that did not go: the
//    worktree goes back to the head. A moved or a rewritten branch ends with no text.
// From step 5 on, each failure resets the worktree to the head while nobody uses the session, and
// only when the worktree has no change that no round made (RepoStore.resetIfKnown). A round whose
// session ran when Bifrost started goes on at step 6 (resume), and a posting round pushes again
// (resumePosting): the push checks the branch first.
import BifrostFoundation
import BifrostSessions
import Foundation
import OSLog

@MainActor
final class ConflictRound {
    // How the steps of a round stop.
    enum Stop: Error {
        // The mark of the pair of the round gets the text of the failure. An empty text (a moved
        // or a rewritten branch) is a quiet end.
        case failed(ConflictFailure)
        // The round ends with no text, and its working mark goes: the pair was not tried.
        case quiet
        // The work of a person in the worktree stops the round, and the worktree stays as it is.
        // The working mark goes. The row shows Needs you with the reason, or with the reason that
        // the row has already (nil).
        case forYou(WaitsForYou?)
        // The clone needs the trust of the user. refused: claude refused the start.
        case waitForTrust(refused: Bool)
        // An automatic round found the session in use by a person. The round ends with no text and
        // its working mark goes, as for quiet, but the next free poll may start it again.
        case busy
        // The task of the round was cancelled.
        case halted
        // An own request file of the user waits. The round changed nothing: the own request goes
        // first, then the job starts the round again.
        case ownRequestFirst
    }

    // The services of the rounds.
    struct Parts {
        let store: ReviewsStore
        let github: GitHubClient
        let repos: RepoStore
        let setup: RepoSetup
        let sessions: PRSessions
        let own: OwnRequests
        let skills: URL
        // The home of the user in the user database, which holds the secret paths of the sandbox.
        let userHome: URL
        let now: () -> Date
    }

    // The head and the base of an attempt: the pair that the conflict mark names.
    struct Pair: Sendable, Equatable {
        var head: CommitID
        var base: CommitID
    }

    // The names of the base branch and of the head branch, for the message of the merge.
    private struct Names {
        var base: String
        var branch: String
    }

    // The turn of the round in the session: its input, the merge to resolve, the head, the base
    // tip of the merge, the session and its start on the clock of the sessions.
    private struct Turn {
        var input: ConflictInput
        var start: MergeStart
        var head: CommitID
        var base: CommitID
        var session: String
        var startedAt: Duration
        // The row of the session when the turn began, or nil after a restart.
        var begun: SessionRow?
    }

    private static let logger = Logger(bifrost: "reviews")
    // The Bifrost mode of the skill, below the skills folder.
    static let modeFile = "skills/bifrost-resolve-conflicts/bifrost-mode.md"

    let pr: PRKey
    // The pair of the attempt: the pair of the poll at first, then the pair of the fresh read.
    private(set) var pair: Pair?

    private let parts: Parts
    // The title of the PR in the poll, for the input file.
    private let title: String
    // True for a round of a Resolve now click: the setting does not gate it.
    private let clicked: Bool
    private let model: ModelChoice
    // The gate of an automatic round now: the setting and its consent
    // (ReviewsState.allowsConflictFix).
    private let allowed: () -> Bool
    private let hooks: RoundHooks
    // A failure of the preparation of the turn that is a failure of the merge (the check of the
    // worktree, the input), which the turn gives as a failure of the session.
    private var refused: ConflictFailure?
    // The changes that the safety net found, sorted.
    private var unsavedFiles: [String] = []
    // True once the preparation moved the worktree to the merge with the markers.
    private var placed = false

    init(
        pr: PRKey, parts: Parts, pair: Pair?, title: String, clicked: Bool, model: ModelChoice,
        allowed: @escaping () -> Bool, hooks: RoundHooks
    ) {
        self.pr = pr
        self.parts = parts
        self.pair = pair
        self.title = title
        self.clicked = clicked
        self.model = model
        self.allowed = allowed
        self.hooks = hooks
    }

    private var store: ReviewsStore { parts.store }
    private var repos: RepoStore { parts.repos }
    private var sessions: PRSessions { parts.sessions }
    // The steps that this round shares with the request round.
    private var shared: RequestSessionTurn { sharedAtEnd(conflicted: []) }

    // The conflicted files count only at the end of the turn (RequestSessionTurn.Kind).
    private func sharedAtEnd(conflicted: [String]) -> RequestSessionTurn {
        RequestSessionTurn(
            pr: pr, kind: .conflict(Set(conflicted)), repos: repos, sessions: sessions,
            own: parts.own, skills: parts.skills, userHome: parts.userHome, model: model)
    }

    // MARK: - The steps

    // Steps 1 to 10 of a new round, whose state is preparing. The result is the merge on GitHub.
    func start() async throws(Stop) -> CommitID {
        guard let viewer = hooks.viewer() else {
            throw .failed(.session(.readFailed(.notLoggedIn)))
        }
        do throws(RepoError) {
            try await repos.ensureClone(pr.repo)
        } catch {
            Self.logger.error("\(error.message, privacy: .private)")
            throw .failed(.session(.prepareFailed))
        }
        try checkHalt()
        guard store.state.prs[pr]?.outbox == nil else { throw .quiet }
        guard await parts.setup.trustsForStart(pr.repo) || hooks.takeTryOnce() else {
            throw .waitForTrust(refused: false)
        }
        try checkHalt()
        let read = try await readHead()
        guard read.state == .open else { throw .quiet }
        if let base = read.base { pair = Pair(head: read.head, base: base) }
        guard read.author.lowercased() == viewer.lowercased() else {
            throw .failed(.session(.notYours))
        }
        guard !read.isFork else { throw .failed(.session(.fork)) }
        guard read.mergeable == .conflicting, let readBase = read.base, gateOpen() else {
            throw .quiet
        }
        await markWorking(Pair(head: read.head, base: readBase))
        guard let branch = BranchName(read.baseRef) else {
            throw .failed(.session(.prepareFailed))
        }
        let fetched: FetchedPR
        do throws(RepoError) {
            fetched = try await repos.fetchPR(pr, base: branch)
        } catch {
            try checkHalt()
            throw .failed(.git(error.message))
        }
        try checkHalt()
        guard fetched.head == read.head else { throw .quiet }
        let start = try await merge(head: read.head, base: fetched.base)
        let token = UUID().uuidString.lowercased()
        var written: ConflictInput?
        let begun = try await beginTurn(head: read.head) { () async throws(RoundFailure) in
            let made = try await prepare(
                read: read, fetched: fetched, start: start, viewer: viewer, token: token)
            written = made.input
            return made.turn
        }
        guard let input = written else { throw .failed(.session(.startFailed)) }
        let row = begun.row
        let (pr, time) = (pr, parts.now())
        await store.update { state in
            guard var prState = state.prs[pr], var round = prState.round, round.kind == .conflict
            else { return }
            round.phase = .running
            round.headSHA = read.head
            // The base of a conflict round is the tip of the base branch that it merged.
            round.baseSHA = fetched.base
            round.startSHA = start.auto
            round.shortID = row.shortId
            round.sessionID = SessionID(row.sessionId)
            round.token = token
            // The time limit counts from the start of the turn.
            round.startedAt = time
            prState.round = round
            state.prs[pr] = prState
        }
        hooks.changed()
        let turn = Turn(
            input: input, start: start, head: read.head, base: fetched.base,
            session: row.sessionId, startedAt: begun.startedAt, begun: row)
        return try await finish(turn, names: Names(base: read.baseRef, branch: read.headRef))
    }

    // A round whose session ran when Bifrost started: wait for its end, then go on from step 6
    // with the head, the base, the merge to resolve and the token that the state saved. The
    // conflicted paths come from the merge again; the worktree stays at the saved merge.
    func resume(_ round: ActiveRound) async throws(Stop) -> CommitID {
        pair = savedPair() ?? pair
        // The user stopped it before the quit.
        guard !round.stoppedByUser else { throw .failed(.session(.stopped)) }
        // A round with no token has no result that can count.
        guard let head = round.headSHA, let base = round.baseSHA, let auto = round.startSHA,
            let token = round.token, let id = round.sessionID?.text, let viewer = hooks.viewer()
        else { throw .failed(.session(.noResult)) }
        let again = try await merge(head: head, base: base)
        let start = MergeStart(auto: auto, conflicted: again.conflicted)
        let mergeBase: CommitID
        do throws(RepoError) {
            mergeBase = try await repos.mergeBase(pr.repo, head, base)
        } catch {
            try checkHalt()
            throw .failed(.git(error.message))
        }
        let files = RoundFiles(
            folder: repos.layout.inputFolder(pr.repo, number: pr.number), token: token)
        let input: ConflictInput
        do throws(ConflictFailure) {
            // Only the token, the PR, the commits and the conflicts count for the check of the
            // result.
            input = try ConflictInput(
                pr: pr, round: token, url: pr.webURL.absoluteString, title: title, baseRef: "",
                headRef: "", headSHA: head, baseSHA: base, mergeBase: mergeBase, viewer: viewer,
                conflicts: start.conflicted,
                files: ConflictInput.Files(files, oursDiff: false, theirsDiff: false))
        } catch {
            throw .failed(error)
        }
        let turn = Turn(
            input: input, start: start, head: head, base: base, session: id,
            startedAt: shared.resumedStart(since: round.startedAt, now: parts.now()), begun: nil)
        return try await finish(turn, names: nil)
    }

    // A round that was posting when Bifrost quit: push the merge again. The push checks the
    // branch first, so a merge that reached GitHub goes no second time.
    func resumePosting(_ round: ActiveRound) async throws(Stop) -> CommitID {
        pair = savedPair() ?? pair
        guard let head = round.headSHA, let base = round.baseSHA, let merge = round.fixSHA,
            let viewer = hooks.viewer()
        else { throw .failed(.session(.endFailed)) }
        let read = try await readHead()
        // A merge that reached GitHub before the quit is a good end, also when the gate is
        // closed now: the coordinator records it as pushed.
        if await isOnBranch(merge, read: read) {
            await moveToMerge(merge)
            return merge
        }
        guard read.state == .open, gateOpen() else {
            await resetWorktree(to: head)
            throw .quiet
        }
        guard read.author.lowercased() == viewer.lowercased() else {
            await resetWorktree(to: head)
            throw .failed(.session(.notYours))
        }
        return try await push(merge, head: head, base: base, read: read)
    }

    // Step 5: the turn in the one session of the PR. A failure after the preparation moved the
    // worktree to the merge puts it back at the head. The work of a person stays (forYou).
    private func beginTurn(
        head: CommitID, _ prepare: () async throws(RoundFailure) -> MineTurn
    ) async throws(Stop) -> BegunTurn {
        if hooks.stopRequested() { throw .failed(.session(.stopped)) }
        let begun: BegunTurn
        do throws(RoundFailure) {
            begun = try await shared.begin(
                prepare: prepare,
                recheck: { () async throws(RoundFailure) in try await checkWorktree() })
        } catch .notTrusted {
            throw .waitForTrust(refused: true)
        } catch .ownRequestWaits {
            throw .ownRequestFirst
        } catch .changesNotOnGitHub {
            throw .forYou(
                WaitsForYou(
                    reason: RoundFailure.changesNotOnGitHub.message(for: .conflict),
                    files: unsavedFiles, kind: .unpushed))
        } catch {
            // Before the preparation, the worktree holds only the work of a person: it stays.
            if placed { await resetWorktree(to: head) }
            try checkHalt()
            // A person uses the session. An automatic round did not try the pair, so it ends with
            // no text. A click gets the reason.
            if error == .sessionBusy, !clicked, refused == nil { throw .busy }
            throw .failed(refused ?? .session(error))
        }
        hooks.startedSession()
        return begun
    }

    // Before the round changes the worktree: an own request of the user goes first, and changes
    // that no round made stay (the safety net). In both cases the round changes nothing.
    private func checkWorktree() async throws(RoundFailure) {
        try await shared.checkWorktree { unsavedFiles = $0 }
    }

    // The preparation of the turn, which PRSessions runs only when no person can use the session
    // of the PR: the safety net, the worktree at the merge with the markers, its check, the files
    // of the round and the sandbox. A failure of the check or of the input is kept in refused.
    private func prepare(
        read: HeadRead, fetched: FetchedPR, start: MergeStart, viewer: String, token: String
    ) async throws(RoundFailure) -> (input: ConflictInput, turn: MineTurn) {
        let (pr, repos) = (pr, repos)
        try await checkWorktree()
        let worktree = try await RequestSessionTurn.repoStep { () async throws(RepoError) in
            try await repos.placeWorktree(pr, head: start.auto)
        }
        placed = true
        if Task.isCancelled { throw .stopped }
        do throws(ConflictFailure) {
            try await ConflictMerge.checkWorktree(pr: pr, start: start, git: repos.git)
        } catch {
            refused = error
            throw .prepareFailed
        }
        let input = try await writeInput(
            read: read, fetched: fetched, start: start, viewer: viewer, token: token)
        if Task.isCancelled { throw .stopped }
        let mine = try await shared.sandboxTurn(
            worktree: worktree, resultFile: input.files.result,
            prompt: PRSessionArgs.conflictPrompt(input.files.input))
        return (input, mine)
    }

    // The files of the round in the round folder, each with the round ID of the token in its
    // name: the input file, the mode file, and the diff of each side on the conflicted paths
    // since the merge base. A diff over ReviewInput.maxDiffBytes stays out: the session reads the
    // changes with git.
    private func writeInput(
        read: HeadRead, fetched: FetchedPR, start: MergeStart, viewer: String, token: String
    ) async throws(RoundFailure) -> ConflictInput {
        let (pr, repos, paths) = (pr, repos, start.conflicted)
        func diff(to commit: CommitID) async throws(RoundFailure) -> String? {
            let text = try await RequestSessionTurn.repoStep { () async throws(RepoError) in
                try await repos.diff(pr.repo, from: fetched.mergeBase, to: commit, paths: paths)
            }
            return text.flatMap { $0.utf8.count <= ReviewInput.maxDiffBytes ? $0 : nil }
        }
        let ours = try await diff(to: read.head)
        let theirs = try await diff(to: fetched.base)
        let folder = try await RequestSessionTurn.repoStep { () async throws(RepoError) in
            try await repos.roundFolder(pr)
        }
        let input: ConflictInput
        do throws(ConflictFailure) {
            input = try ConflictInput(
                pr: pr, round: token, url: pr.webURL.absoluteString, title: title,
                baseRef: read.baseRef, headRef: read.headRef, headSHA: read.head,
                baseSHA: fetched.base, mergeBase: fetched.mergeBase, viewer: viewer,
                conflicts: paths,
                files: ConflictInput.Files(
                    RoundFiles(folder: folder, token: token), oursDiff: ours != nil,
                    theirsDiff: theirs != nil))
        } catch {
            refused = error
            throw .inputFailed
        }
        let (skills, modeFile) = (parts.skills, Self.modeFile)
        let mode = await BlockingExecutor.run {
            FileManager.default.contents(
                atPath: skills.appending(path: modeFile).path(percentEncoded: false))
        }
        guard let mode else { throw .inputFailed }
        let names = input.files
        var files: [(name: String, data: Data)] = [
            (names.mode.lastPathComponent, mode), (names.input.lastPathComponent, input.fileData),
        ]
        if let ours, let path = names.oursDiff {
            files.append((path.lastPathComponent, Data(ours.utf8)))
        }
        if let theirs, let path = names.theirsDiff {
            files.append((path.lastPathComponent, Data(theirs.utf8)))
        }
        do throws(RepoError) {
            try await repos.writeInput(pr, files)
        } catch {
            Self.logger.error("\(error.message, privacy: .private)")
            throw .inputFailed
        }
        return input
    }

    // Steps 6 to 10: the end of the turn, the result, the commit, a fresh read and the push.
    // names: the names of the branches, or nil after a restart (a fresh read gives them).
    private func finish(_ turn: Turn, names: Names?) async throws(Stop) -> CommitID {
        if case .needsYou(let reason) = try await result(of: turn) {
            await resetWorktree(to: turn.head)
            throw .failed(.claude(reason))
        }
        let branches: Names
        if let names {
            branches = names
        } else {
            let read = try await readAgain(turn)
            branches = Names(base: read.baseRef, branch: read.headRef)
        }
        let merge = try await commit(turn, branches)
        let read = try await readAgain(turn)
        return try await post(merge, turn: turn, read: read)
    }

    // Step 6: the end of the turn, and the answer of the result. With no good result, a read of
    // the file gives the reason, for the text only. A session that asked fails as blocked when its
    // result is missing or bad.
    private func result(of turn: Turn) async throws(Stop) -> ConflictAnswer {
        let input = turn.input
        let ended: RequestSessionTurn.TurnEnded<ConflictAnswer>
        do throws(RequestSessionTurn.Stopped) {
            ended = try await sharedAtEnd(conflicted: turn.start.conflicted).waitForEnd(
                session: turn.session, startedAt: turn.startedAt, resultFile: input.files.result,
                begun: turn.begun,
                check: { try? ConflictResult.check($0, input: input).get() },
                reset: { await resetWorktree(to: turn.head, stoppedIt: $0) })
        } catch .timeout {
            throw .failed(.session(.timeout))
        } catch .halted {
            throw .halted
        } catch {
            throw .failed(.session(.stopped))
        }
        let (accepted, blocked, request) = (ended.accepted, ended.blocked, ended.ownRequest)
        try checkHalt()
        if request { try await refuseOwnRequest() }
        if hooks.stopRequested() || store.state.prs[pr]?.round?.stoppedByUser == true {
            await resetWorktree(to: turn.head, stoppedIt: blocked)
            throw .failed(.session(.stopped))
        }
        if let accepted { return accepted }
        await resetWorktree(to: turn.head, stoppedIt: blocked)
        if blocked { throw .failed(.session(.blocked)) }
        let limit = ConflictResult.maxBytes
        let read = await repos.readResult(at: input.files.result, limit: limit)
        throw .failed(
            .session(
                read.failure(limit: limit) { data in
                    if case .failure(let refusal) = ConflictResult.check(data, input: input) {
                        refusal
                    } else {
                        nil
                    }
                }))
    }

    // An own request file of the turn, or one that came before the commit: the worktree holds the
    // merge, so Bifrost commits neither the request nor the merge. The file goes with its reason
    // on the row (OwnRequests.refuse), and the worktree stays for the user.
    private func refuseOwnRequest() async throws(Stop) -> Never {
        await parts.own.refuse(pr, .conflictMerge)
        throw .forYou(nil)
    }

    // Step 7: the commit of the merge. A person can change the worktree after the turn (a message
    // typed into the session): a change that no round made, before the commit or while git adds
    // the files, stops the round, so no part of it goes into the merge.
    private func commit(_ turn: Turn, _ names: Names) async throws(Stop) -> CommitID {
        try await checkNoPersonWork()
        let message = ConflictRule.mergeMessage(base: names.base, branch: names.branch)
        let merge: CommitID
        do throws(ConflictFailure) {
            merge = try await ConflictMerge.commit(
                pr: pr, start: turn.start, head: turn.head, base: turn.base, message: message,
                git: repos.git)
        } catch {
            try checkHalt()
            await resetWorktree(to: turn.head)
            throw .failed(error)
        }
        try checkHalt()
        try await checkNoPersonWork()
        return merge
    }

    // An own request file, or a change of the worktree that no round made, stops the round with
    // Needs you, and the worktree stays as it is (RequestSessionTurn.personWork).
    private func checkNoPersonWork() async throws(Stop) {
        switch await shared.personWork() {
        case .none:
            return
        case .ownRequest:
            try await refuseOwnRequest()
        case .unreadable:
            throw .failed(.git("Bifrost couldn't read the changes of its copy."))
        case .changes(let unknown):
            Self.logger.notice(
                """
                The copy of \(self.pr.text, privacy: .private) changed after the turn of the \
                conflict round, so Bifrost doesn't push the merge.
                """)
            throw .forYou(
                WaitsForYou(
                    reason: RoundFailure.changesNotOnGitHub.message(for: .conflict),
                    files: unknown, kind: .unpushed))
        }
    }

    // Step 8, and the names of the branches after a restart: a fresh read of the head. A closed
    // PR, a head that moved and an automatic round whose gate is closed now end with no text.
    private func readAgain(_ turn: Turn) async throws(Stop) -> HeadRead {
        let read: HeadRead
        do throws(Stop) {
            read = try await readHead()
        } catch {
            await resetWorktree(to: turn.head)
            throw error
        }
        guard read.state == .open, read.head == turn.head, gateOpen() else {
            await resetWorktree(to: turn.head)
            throw .quiet
        }
        guard let viewer = hooks.viewer(), read.author.lowercased() == viewer.lowercased() else {
            await resetWorktree(to: turn.head)
            throw .failed(.session(.notYours))
        }
        return read
    }

    // Step 9: the posting phase with the merge in one save, then the push. A failed save pushes
    // nothing.
    private func post(_ merge: CommitID, turn: Turn, read: HeadRead) async throws(Stop)
        -> CommitID
    {
        let pr = pr
        let saved = await store.update { state in
            guard var prState = state.prs[pr], var round = prState.round, round.kind == .conflict
            else { return }
            round.phase = .posting
            round.fixSHA = merge
            prState.round = round
            state.prs[pr] = prState
        }
        hooks.changed()
        guard saved, store.state.prs[pr]?.round?.phase == .posting else {
            await resetWorktree(to: turn.head)
            throw .failed(.session(.notSaved))
        }
        return try await push(merge, head: turn.head, base: turn.base, read: read)
    }

    // The push of the merge to the head branch of the fresh read, never signed. A cancel (a quit)
    // keeps the posting round for the next start. A push that went moves the worktree to the
    // merge; else the worktree goes back to the head.
    private func push(_ merge: CommitID, head: CommitID, base: CommitID, read: HeadRead)
        async throws(Stop) -> CommitID
    {
        guard let target = PushTarget(read) else {
            await resetWorktree(to: head)
            throw .failed(.push(.target))
        }
        let pusher = Pusher(git: repos.git, address: repos.address(of: pr.repo))
        do throws(PushRefusal) {
            _ = try await pusher.push(
                merge, head: head, pr: pr, to: target, parents: [head, base], onMove: .stop)
        } catch {
            if Task.isCancelled { throw .halted }
            await resetWorktree(to: head)
            throw .failed(.push(error))
        }
        await moveToMerge(merge)
        return merge
    }

    // After a merge on GitHub: the worktree goes to the merge. When the reset does not run (a
    // person uses the session, or the worktree holds a change that no round made), HEAD and the
    // index still move to the merge, and the files stay. So the copy is not left on the commit
    // with the markers, which GitHub does not have.
    private func moveToMerge(_ merge: CommitID) async {
        if await resetWorktree(to: merge) { return }
        await repos.uncommit(pr, to: merge)
    }

    // True when the merge is on the head branch of the PR on GitHub (a fetch of the branch).
    private func isOnBranch(_ merge: CommitID, read: HeadRead) async -> Bool {
        guard let target = PushTarget(read) else { return false }
        let pusher = Pusher(git: repos.git, address: repos.address(of: pr.repo))
        guard let remote = try? await pusher.fetchBranch(target.branch, pr: pr) else {
            return false
        }
        return (try? await pusher.isAncestor(merge, of: remote, pr: pr)) == true
    }

    // MARK: - The parts of the steps

    // True when the round can act: a Resolve now click, or the gate of the automatic rounds.
    private func gateOpen() -> Bool {
        clicked || allowed()
    }

    // Step 3: the mark of the pair, as working, so no automatic round tries the pair again.
    private func markWorking(_ pair: Pair) async {
        let (pr, time) = (pr, parts.now())
        self.pair = pair
        await store.update { state in
            guard var prState = state.prs[pr], prState.round?.kind == .conflict else { return }
            prState.conflict = ConflictMark(
                head: pair.head, base: pair.base, at: time, outcome: .working)
            state.prs[pr] = prState
        }
        hooks.changed()
    }

    // The pair of the conflict mark of the state, for a round that goes on after a restart.
    private func savedPair() -> Pair? {
        store.state.prs[pr]?.conflict.map { Pair(head: $0.head, base: $0.base) }
    }

    // The merge of the base into the head in the clone (ConflictMerge.start).
    private func merge(head: CommitID, base: CommitID) async throws(Stop) -> MergeStart {
        let start: MergeStart
        do throws(ConflictFailure) {
            start = try await ConflictMerge.start(pr: pr, head: head, base: base, git: repos.git)
        } catch {
            try checkHalt()
            throw .failed(error)
        }
        try checkHalt()
        return start
    }

    // The fresh read of the head of the PR.
    private func readHead() async throws(Stop) -> HeadRead {
        let read: HeadRead
        do throws(GitHubError) {
            read = try await HeadQueries.read(pr, client: parts.github)
        } catch {
            try checkHalt()
            Self.logger.error(
                """
                A head read of \(self.pr.text, privacy: .private) failed. \
                \(error.message, privacy: .private)
                """)
            throw .failed(.session(.readFailed(error)))
        }
        try checkHalt()
        return read
    }

    // Put the worktree at the commit (the head of the PR, or the merge that went): the merge with
    // the markers and the files of the session go. It does not run while a person can use the
    // session (it works or shows a box), and it keeps a change that no round made
    // (RepoStore.resetIfKnown). stoppedIt: the round stopped the session, so nobody uses it.
    // The result is true when the reset ran.
    @discardableResult
    private func resetWorktree(to commit: CommitID, stoppedIt: Bool = false) async -> Bool {
        await shared.reset(to: commit, use: .request, stoppedIt: stoppedIt)
    }

    private func checkHalt() throws(Stop) {
        if Task.isCancelled { throw .halted }
    }
}
