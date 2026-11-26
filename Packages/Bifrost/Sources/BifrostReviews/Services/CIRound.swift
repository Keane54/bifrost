// One CI round (docs/behaviour/reviews.md, "My PRs"): GitHub Actions failed on the head of a PR
// of the user, and Claude reads the logs of the failed jobs in the one request session of the PR.
// Claude decides fix, retry or needs-you in its result file, and Bifrost acts on it: it commits
// and pushes the fix (RoundWrites, never force), re-runs the failed jobs, or asks the user (the CI
// question of the Answer panel). Claude never commits, pushes or reaches GitHub, and Bifrost
// trusts none of the logs and none of the result (CIResult). The coordinator (CIRounds) makes one
// CIRound for each run of a job, and ends the round by how its steps stop. Each failure goes to
// the CI question of the PR (CIStop), never to lastError.
//
// The steps:
// 1. The clone and the trust read, as for a conflict round. Writes that wait (an outbox) end the
//    round with no text: their fix can be in the worktree.
// 2. The fresh read of the head (HeadQueries). A closed PR, a PR of another author, a fork, a PR
//    with conflicts (the conflict round goes first), checks that are not done, no failed Actions
//    job and a closed gate (the setting and its consent) end the round with no text.
// 3. The mark of the chain of the head (CIRule.chainMark) and the step (CIRule.step). With no fix
//    and no re-run left, the round asks its question with no session (limits).
// 4. One save of the mark, the job key of the failure and the head of the round, so no automatic
//    round takes the same failure again. Each end where Claude did not try the failure puts the
//    old key back (the coordinator).
// 5. The logs of the failed jobs (CILogs), the fetch of the head and of the base, and the turn in
//    the one request session of the PR (PRSessions.beginTurn). The turn first waits until no
//    person can use the session. Only then does the round change the folders of the session
//    (prepare): the safety net first, then the worktree at the head, the round folder and the
//    files of the round, each with the round ID of a new token in its name.
// 6. The wait for the end of the turn on the result file of the round, at most the limit.
// 7. needs-you: the copy goes back to the head, and the question goes to the Answer panel.
// 8. retry: the copy goes back to the head. A fresh read must show the same head and the same
//    failed jobs, and the gate must be open. One save of the re-run (posting), then one re-run
//    write for each workflow run of the failed jobs, in the order of the run IDs, each with the
//    gate checked again just before it. After a write that fails, the rest does not go, and a
//    write that GitHub may have made never goes again.
// 9. fix: the work of a person stops the fix (an own request file, or a change that no round
//    made), then the commit of the fix (RoundWrites.commit, with its checks of the listed paths),
//    a fresh read and the gate again, one save of the fix (posting), the gate again, and the push
//    (RoundWrites.push: Pusher with BranchMoved.stop, or SignedPusher, never force).
// From step 5 on, each failure resets the worktree to the head while nobody uses the session, and
// only when the worktree has no change that no round made (RepoStore.resetIfKnown). A round whose
// session ran when Bifrost started goes on at step 6 (resume), and a posting fix pushes again
// (resumePosting): the push checks the branch first, so a fix on GitHub goes no second time.
import BifrostFoundation
import BifrostSessions
import Foundation
import OSLog

@MainActor
final class CIRound {
    // How the steps of a round stop.
    enum Stop: Error {
        // The CI question of the PR gets the text of the stop (CIStop.question). An empty text is
        // a quiet end.
        case failed(CIStop)
        // The round ends with no text: Claude did not try the failure. The key goes back, and the
        // same failure waits WorkRule.readRetry.
        case quiet
        // The same, with no wait: a busy session, or an own request of the turn that goes after
        // the round.
        case untried
        // The work of a person in the worktree stops the round, and the worktree stays as it is.
        // Claude did not try the failure.
        case forYou(WaitsForYou)
        // The clone needs the trust of the user. refused: claude refused the start.
        case waitForTrust(refused: Bool)
        // An own request file of the user waits. The round changed nothing: the own request goes
        // first, then the job starts the round again.
        case ownRequestFirst
        // The task of the round was cancelled.
        case halted
    }

    // How a good round ended.
    enum Ended {
        // Bifrost pushed the fix. The commit is on the branch: the fix, or for a signed push the
        // commit that GitHub made.
        case pushed(CommitID)
        // Bifrost re-ran the failed jobs.
        case retried
        // Claude asks the user, with the text of the question.
        case asked(String)
        // The chain has no fix and no re-run left. The round had no session.
        case limits
    }

    // The services of the rounds.
    struct Parts {
        let store: ReviewsStore
        let github: GitHubClient
        let repos: RepoStore
        let setup: RepoSetup
        let sessions: PRSessions
        let own: OwnRequests
        let writes: RoundWrites
        let skills: URL
        // The home of the user in the user database, which holds the secret paths of the sandbox.
        let userHome: URL
        let now: () -> Date
    }

    // The turn of the round in the session: its input, the head, the session and its start on
    // the clock of the sessions.
    private struct Turn {
        var input: CIInput
        var head: CommitID
        var session: String
        var startedAt: Duration
        // The row of the session when the turn began, or nil after a restart.
        var begun: SessionRow?
    }

    private static let logger = Logger(bifrost: "reviews")
    // The Bifrost mode of the skill, below the skills folder.
    static let modeFile = "skills/bifrost-fix-ci/bifrost-mode.md"

    // The job key that a round saved (on its head), and the key that it replaced.
    typealias SavedKey = (head: CommitID, key: [JobID], before: (CommitID?, [JobID]))

    let pr: PRKey
    // The job key that this round saved at step 4, and the key that it replaced. nil before
    // step 4. A round that goes on after a restart (resume, resumePosting) has the key of its
    // head, and no key before it.
    private(set) var saved: SavedKey?
    // The head of the round (for the question): the head of the poll at first, then the head of
    // the fresh read.
    private(set) var head: CommitID?
    // The names of the failed jobs of the round, for the question.
    private(set) var jobNames: [String]
    // The mark of the chain of the head at step 3, and the job key of the fresh read.
    private(set) var mark: CIMark?
    private(set) var key: [JobID] = []
    // The local fix of an unsigned push whose outcome Bifrost can't tell, so it can join the
    // chain.
    private(set) var unknownFix: CommitID?
    // The head of a re-run that the round saved and did not send: the gate closed before the
    // first write. nil once a write goes, because GitHub can then have the re-run.
    private(set) var unsentRetry: CommitID?

    private let parts: Parts
    // The title of the PR in the poll, for the input file.
    private let title: String
    private let model: ModelChoice
    private let hooks: RoundHooks
    // The setting "Sign commits through GitHub" now.
    private let signed: () -> Bool
    // The proof of the gate now (ReviewsState.ciConsent): the setting and its consent.
    private let consent: () -> CIConsent?
    // True when the round answers a CI question of the user on its head.
    private var answered = false
    // The changes that the safety net found, sorted.
    private var unsavedFiles: [String] = []
    // True once the preparation moved the worktree to the head.
    private var placed = false

    init(
        pr: PRKey, parts: Parts, head: CommitID?, jobNames: [String], title: String,
        model: ModelChoice, signed: @escaping () -> Bool,
        consent: @escaping () -> CIConsent?, hooks: RoundHooks
    ) {
        self.pr = pr
        self.parts = parts
        self.head = head
        self.jobNames = jobNames
        self.title = title
        self.model = model
        self.signed = signed
        self.consent = consent
        self.hooks = hooks
    }

    private var store: ReviewsStore { parts.store }
    private var repos: RepoStore { parts.repos }
    // The steps that this round shares with the request and conflict rounds.
    private var shared: RequestSessionTurn {
        RequestSessionTurn(
            pr: pr, kind: .ci, repos: repos, sessions: parts.sessions, own: parts.own,
            skills: parts.skills, userHome: parts.userHome, model: model)
    }

    // MARK: - The steps

    // Steps 1 to 9 of a new round, whose state is preparing.
    func start() async throws(Stop) -> Ended {
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
        head = read.head
        let failed = read.checks.failedJobs
        if !failed.isEmpty { jobNames = failed.map(\.name) }
        guard read.state == .open, read.author.lowercased() == viewer.lowercased(), !read.isFork,
            read.mergeable != .conflicting, read.checks.settled, !failed.isEmpty,
            consent() != nil
        else { throw .quiet }
        let mark = CIRule.chainMark(store.state.prs[pr]?.ci, head: read.head)
        self.mark = mark
        key = read.checks.jobKey
        answered = Self.isAnswered(mark, head: read.head)
        let allowed: Set<CIAction>
        switch CIRule.step(read, mark: mark, answered: answered) {
        case .nothing: throw .quiet
        case .limits: return .limits
        case .round(let actions): allowed = actions
        }
        try await saveKey(mark, head: read.head)
        let logs = await CILogs.read(failed, repo: pr.repo, client: parts.github)
        try checkHalt()
        guard let branch = BranchName(read.baseRef) else {
            throw .failed(.session(.prepareFailed))
        }
        let fetched: FetchedPR
        do throws(RepoError) {
            fetched = try await repos.fetchPR(pr, base: branch)
        } catch {
            try checkHalt()
            Self.logger.error("\(error.message, privacy: .private)")
            throw .failed(.session(.prepareFailed))
        }
        try checkHalt()
        guard fetched.head == read.head else { throw .quiet }
        let token = UUID().uuidString.lowercased()
        var written: CIInput?
        let begun = try await beginTurn(head: read.head) { () async throws(RoundFailure) in
            let made = try await prepare(
                read: read, fetched: fetched, logs: logs, allowed: allowed, mark: mark,
                viewer: viewer, token: token)
            written = made.input
            return made.turn
        }
        guard let input = written else { throw .failed(.session(.startFailed)) }
        let row = begun.row
        let (pr, time) = (pr, parts.now())
        await store.update { state in
            guard var prState = state.prs[pr], var round = prState.round, round.kind == .ci
            else { return }
            round.phase = .running
            round.headSHA = read.head
            // The base of a CI round is the merge base of its full diff.
            round.baseSHA = fetched.mergeBase
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
            input: input, head: read.head, session: row.sessionId, startedAt: begun.startedAt,
            begun: row)
        return try await finish(turn)
    }

    // A round whose session ran when Bifrost started: wait for its end, then go on from step 6
    // with the head, the token and the session that the state saved. The minimal input has the
    // values that the check of the result uses, and the allowed outcomes of the mark now.
    func resume(_ round: ActiveRound) async throws(Stop) -> Ended {
        head = round.headSHA ?? head
        // The user stopped it before the quit.
        guard !round.stoppedByUser else { throw .failed(.session(.stopped)) }
        // A round with no token has no result that can count.
        guard let head = round.headSHA, let token = round.token, let id = round.sessionID?.text,
            let viewer = hooks.viewer()
        else { throw .failed(.session(.noResult)) }
        let mark = CIRule.chainMark(store.state.prs[pr]?.ci, head: head)
        self.mark = mark
        if mark.handledHead == head {
            key = mark.handled
            // The key that the round replaced is not known after a restart. An end where Claude
            // did not try the failure clears the key, so the failure can start a round again.
            saved = (head, mark.handled, (nil, []))
        }
        answered = Self.isAnswered(mark, head: head)
        let base = round.baseSHA ?? head
        let files = RoundFiles(
            folder: repos.layout.inputFolder(pr.repo, number: pr.number), token: token)
        let input = CIInput(
            pr: pr, round: token, url: pr.webURL.absoluteString, title: title, baseRef: "",
            headRef: "", headSHA: head, baseSHA: base, mergeBase: base, viewer: viewer,
            failed: [], other: [], allowed: CIRule.allowed(mark, answered: answered),
            tried: CIInput.Tried(fixes: mark.fixes, retries: mark.retries), answer: nil,
            files: CIInput.Files(files, fullDiff: false))
        let turn = Turn(
            input: input, head: head, session: id,
            startedAt: shared.resumedStart(since: round.startedAt, now: parts.now()), begun: nil)
        return try await finish(turn)
    }

    // A round that was posting its fix when Bifrost quit: push the fix again. The push checks the
    // branch first, so a fix that reached GitHub goes no second time. A closed PR, a PR of another
    // author and a closed gate end with no text, and the fix then does not join the chain. Each
    // stop puts the worktree back at the head. As for resume, the round has the key of its head
    // and no key before it, so an end with no text clears the key, and the fix stays counted.
    func resumePosting(_ round: ActiveRound) async throws(Stop) -> Ended {
        head = round.headSHA ?? head
        guard let head = round.headSHA, let fix = round.fixSHA, let viewer = hooks.viewer() else {
            throw .failed(.session(.endFailed))
        }
        if let mark = store.state.prs[pr]?.ci, mark.handledHead == head {
            saved = (head, mark.handled, (nil, []))
        }
        let read: HeadRead
        do throws(Stop) {
            read = try await readHead()
        } catch {
            await resetWorktree(to: head)
            throw error
        }
        guard read.state == .open, read.author.lowercased() == viewer.lowercased(),
            consent() != nil
        else {
            await resetWorktree(to: head)
            throw .quiet
        }
        let paths = try await fixPaths(fix, head: head)
        return try await push(fix, head: head, paths: paths, read: read)
    }

    // Step 5: the turn in the one session of the PR. A failure after the preparation moved the
    // worktree puts it back at the head. The work of a person stays (forYou).
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
            throw .forYou(waiting(unsavedFiles))
        } catch {
            // Before the preparation, the worktree holds only the work of a person: it stays.
            if placed { await resetWorktree(to: head) }
            try checkHalt()
            // A person uses the session. An automatic round did not try the failure, so it ends
            // with no text. A round that answers a question gets the reason.
            if error == .sessionBusy, !answered { throw .untried }
            throw .failed(.session(error))
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
    // of the PR: the safety net, the worktree at the head, the round folder, the full diff, the
    // files of the round and the sandbox.
    private func prepare(
        read: HeadRead, fetched: FetchedPR, logs: [JobLog], allowed: Set<CIAction>,
        mark: CIMark, viewer: String, token: String
    ) async throws(RoundFailure) -> (input: CIInput, turn: MineTurn) {
        let (pr, repos) = (pr, repos)
        try await checkWorktree()
        let worktree = try await RequestSessionTurn.repoStep { () async throws(RepoError) in
            try await repos.placeWorktree(pr, head: read.head)
        }
        placed = true
        if Task.isCancelled { throw .stopped }
        let folder = try await RequestSessionTurn.repoStep { () async throws(RepoError) in
            try await repos.roundFolder(pr)
        }
        let text = try await RequestSessionTurn.repoStep { () async throws(RepoError) in
            try await repos.diff(pr.repo, from: fetched.mergeBase, to: read.head)
        }
        let diff = text.flatMap { $0.utf8.count <= ReviewInput.maxDiffBytes ? $0 : nil }
        let input = try await writeInput(
            read: read, fetched: fetched, logs: logs, allowed: allowed, mark: mark,
            viewer: viewer, token: token, folder: folder, diff: diff)
        if Task.isCancelled { throw .stopped }
        let mine = try await shared.sandboxTurn(
            worktree: worktree, resultFile: input.files.result,
            prompt: PRSessionArgs.ciPrompt(input.files.input))
        return (input, mine)
    }

    // The files of the round in the round folder: the mode file, the input file, the full diff
    // (when it is not over ReviewInput.maxDiffBytes) and one file for each log with text.
    private func writeInput(
        read: HeadRead, fetched: FetchedPR, logs: [JobLog], allowed: Set<CIAction>,
        mark: CIMark, viewer: String, token: String, folder: URL, diff: String?
    ) async throws(RoundFailure) -> CIInput {
        let files = RoundFiles(folder: folder, token: token)
        let failed = logs.map { log in
            let file = log.check.job.map { CIInput.Files.log(files, job: $0) }
            return CIInput.Failed(log, file: log.text == nil ? nil : file)
        }
        let answer: CIInput.Answer? =
            if answered, let question = mark.question, let text = question.answer {
                CIInput.Answer(question: question.text, answer: text)
            } else {
                nil
            }
        let input = CIInput(
            pr: pr, round: token, url: pr.webURL.absoluteString,
            title: title, baseRef: read.baseRef, headRef: read.headRef, headSHA: read.head,
            baseSHA: fetched.base, mergeBase: fetched.mergeBase, viewer: viewer, failed: failed,
            other: read.checks.others.map(CIInput.Other.init), allowed: allowed,
            tried: CIInput.Tried(fixes: mark.fixes, retries: mark.retries), answer: answer,
            files: CIInput.Files(files, fullDiff: diff != nil))
        let (skills, modeFile) = (parts.skills, Self.modeFile)
        let mode = await BlockingExecutor.run {
            FileManager.default.contents(
                atPath: skills.appending(path: modeFile).path(percentEncoded: false))
        }
        guard let mode else { throw .inputFailed }
        let names = input.files
        var written: [(name: String, data: Data)] = [
            (names.mode.lastPathComponent, mode), (names.input.lastPathComponent, input.fileData),
        ]
        if let diff, let path = names.fullDiff {
            written.append((path.lastPathComponent, Data(diff.utf8)))
        }
        for (log, entry) in zip(logs, failed) {
            if let text = log.text, let file = entry.log {
                written.append((file.lastPathComponent, Data(text.utf8)))
            }
        }
        do throws(RepoError) {
            try await repos.writeInput(pr, written)
        } catch {
            Self.logger.error("\(error.message, privacy: .private)")
            throw .inputFailed
        }
        return input
    }

    // Steps 6 to 9: the end of the turn, then the outcome of Claude.
    private func finish(_ turn: Turn) async throws(Stop) -> Ended {
        let outcome = try await result(of: turn)
        switch outcome.decision {
        case .needsYou(let question):
            await resetWorktree(to: turn.head)
            return .asked(question)
        case .retry:
            await resetWorktree(to: turn.head)
            return try await retry(turn)
        case .fix(let plan, _):
            return try await fix(plan, turn: turn)
        }
    }

    // Step 6: the end of the turn, and the outcome of the result. With no good result, a read of
    // the file gives the reason, for the text only. A session that asked fails as blocked when its
    // result is missing or bad.
    private func result(of turn: Turn) async throws(Stop) -> CIOutcome {
        let input = turn.input
        let ended: RequestSessionTurn.TurnEnded<CIOutcome>
        do throws(RequestSessionTurn.Stopped) {
            ended = try await shared.waitForEnd(
                session: turn.session, startedAt: turn.startedAt, resultFile: input.files.result,
                begun: turn.begun, check: { try? CIResult.check($0, input: input).get() },
                reset: { await resetWorktree(to: turn.head, stoppedIt: $0) })
        } catch .timeout {
            throw .failed(.session(.timeout))
        } catch .halted {
            throw .halted
        } catch {
            throw .failed(.session(.stopped))
        }
        let (accepted, blocked) = (ended.accepted, ended.blocked)
        try checkHalt()
        if hooks.stopRequested() || store.state.prs[pr]?.round?.stoppedByUser == true {
            await resetWorktree(to: turn.head, stoppedIt: blocked)
            throw .failed(.session(.stopped))
        }
        if let accepted { return accepted }
        await resetWorktree(to: turn.head, stoppedIt: blocked)
        if blocked { throw .failed(.session(.blocked)) }
        let limit = CIResult.maxBytes
        let read = await repos.readResult(at: input.files.result, limit: limit)
        throw .failed(
            .session(
                read.failure(limit: limit) { data in
                    if case .failure(let refusal) = CIResult.check(data, input: input) {
                        refusal
                    } else {
                        nil
                    }
                }))
    }

    // Step 8: a fresh read, the gate, one save of the re-run, then one re-run write for each
    // workflow run of the failed jobs. The copy is at the head already. The gate is checked again
    // just before each write, and a closed gate sends no more writes: with no write sent, the
    // round ends with no text (unsentRetry), else as a re-run. The spent re-run stays spent.
    private func retry(_ turn: Turn) async throws(Stop) -> Ended {
        let read = try await readHead()
        guard read.state == .open, read.head == turn.head, read.checks.jobKey == key,
            consent() != nil
        else { throw .quiet }
        let (pr, head) = (pr, turn.head)
        let saved = await store.update { state in
            guard var prState = state.prs[pr], var round = prState.round, round.kind == .ci,
                var ci = prState.ci
            else { return }
            ci.retries += 1
            ci.retrying = head
            prState.ci = ci
            round.phase = .posting
            prState.round = round
            state.prs[pr] = prState
        }
        hooks.changed()
        guard saved, store.state.prs[pr]?.round?.phase == .posting else {
            throw .failed(.session(.notSaved))
        }
        unsentRetry = head
        let runs = Set(
            read.checks.failedJobs.compactMap { check -> RunID? in
                if case .actions(_, let run) = check.source { run } else { nil }
            }
        ).sorted()
        for (index, run) in runs.enumerated() {
            if index > 0 { await parts.writes.waitBetweenWrites() }
            try checkHalt()
            guard let proof = consent() else {
                if index == 0 { throw .quiet }
                return .retried
            }
            unsentRetry = nil
            do throws(GitHubError) {
                _ = try await parts.github.write(.rerunFailedJobs(pr.repo, run, consent: proof))
            } catch {
                try checkHalt()
                throw .failed(.rerun(error))
            }
        }
        return .retried
    }

    // Step 9: the checks of the work of a person, the commit, a fresh read and the gate, one save
    // of the fix, then the push.
    private func fix(_ plan: CommitPlan, turn: Turn) async throws(Stop) -> Ended {
        let head = turn.head
        switch await shared.personWork() {
        case .none:
            break
        case .ownRequest:
            // The own request goes after the round, at the end of the job. Its change can be in
            // the listed files, so the fix does not go, and the worktree stays.
            throw .untried
        case .changes(let files):
            Self.logger.notice(
                """
                The copy of \(self.pr.text, privacy: .private) changed after the turn of the CI \
                round, so Bifrost doesn't push the fix.
                """)
            throw .forYou(waiting(files))
        case .unreadable:
            throw .failed(.commit(.git("git didn't show the changes in its copy.")))
        }
        let made: RoundWrites.CommitResult
        do throws(FixCommitFailure) {
            made = try await parts.writes.commit(
                plan.paths, message: plan.message, head: head, pr: pr, own: false, stamps: nil)
        } catch {
            if Task.isCancelled { throw .halted }
            // A commit with an edit that git could not move back stays as it is: a reset would
            // remove the edit from the worktree.
            if error != .uncommitFailed { await resetWorktree(to: head) }
            throw .failed(.commit(error))
        }
        let fix: CommitID
        switch made {
        case .made(let commit): fix = commit
        case .edited(let files):
            // git moved the commit back to changes already.
            throw .forYou(waiting(files))
        }
        try checkHalt()
        let read: HeadRead
        do throws(Stop) {
            read = try await readHead()
        } catch {
            await resetWorktree(to: head)
            throw error
        }
        guard read.state == .open, read.head == head, let viewer = hooks.viewer(),
            read.author.lowercased() == viewer.lowercased(), !read.isFork, consent() != nil
        else {
            await resetWorktree(to: head)
            throw .quiet
        }
        let pr = pr
        let saved = await store.update { state in
            guard var prState = state.prs[pr], var round = prState.round, round.kind == .ci,
                var ci = prState.ci
            else { return }
            ci.fixes += 1
            prState.ci = ci
            round.phase = .posting
            round.fixSHA = fix
            prState.round = round
            state.prs[pr] = prState
        }
        hooks.changed()
        guard saved, store.state.prs[pr]?.round?.fixSHA == fix else {
            await resetWorktree(to: head)
            throw .failed(.session(.notSaved))
        }
        return try await push(fix, head: head, paths: plan.paths, read: read)
    }

    // The push of the fix to the head branch of the fresh read, with the gate checked again just
    // before it. A cancel (a quit) keeps the posting round for the next start. A push that did
    // not go puts the worktree back at the head.
    private func push(_ fix: CommitID, head: CommitID, paths: [String], read: HeadRead)
        async throws(Stop) -> Ended
    {
        guard let target = PushTarget(read) else {
            await resetWorktree(to: head)
            throw .failed(.push(.target))
        }
        guard consent() != nil else {
            await resetWorktree(to: head)
            throw .quiet
        }
        let signed = signed()
        let result: PushResult
        do throws(PushRefusal) {
            result = try await parts.writes.push(
                fix, head: head, paths: paths, signed: signed, pr: pr, target: target,
                onMove: .stop)
        } catch {
            if Task.isCancelled { throw .halted }
            // The fix can be on GitHub. Only an unsigned push knows the commit that it sent.
            if case .unknown = error, !signed { unknownFix = fix }
            await resetWorktree(to: head)
            throw .failed(.push(error))
        }
        return .pushed(result.commit)
    }

    // MARK: - The parts of the steps

    // Step 4: the mark of the chain, with the job key of the failure and the head of the round,
    // in one save. The round keeps the key that it replaced.
    private func saveKey(_ mark: CIMark, head: CommitID) async throws(Stop) {
        let pr = pr
        var next = mark
        next.handledHead = head
        next.handled = key
        let wanted = next
        let done = await store.update { state in
            guard var prState = state.prs[pr], var round = prState.round, round.kind == .ci
            else { return }
            prState.ci = wanted
            round.headSHA = head
            prState.round = round
            state.prs[pr] = prState
        }
        hooks.changed()
        saved = (head, key, (mark.handledHead, mark.handled))
        guard done, store.state.prs[pr]?.ci == wanted else { throw .failed(.session(.notSaved)) }
    }

    // The paths of the fix against the head, for the signed push of a posting fix after a restart.
    private func fixPaths(_ fix: CommitID, head: CommitID) async throws(Stop) -> [String] {
        let result = await repos.git.run(.changedPaths(head, fix), in: .clone(pr.repo))
        guard result.succeeded else {
            try checkHalt()
            await resetWorktree(to: head)
            throw .failed(.push(.git(RepoStore.reason(result))))
        }
        return result.stdout.split(separator: "\0").map(String.init)
    }

    // The reason of the row and the files for a round that the work of a person stopped.
    private func waiting(_ files: [String]) -> WaitsForYou {
        WaitsForYou(
            reason: RoundFailure.changesNotOnGitHub.message(for: .ci), files: files,
            kind: .unpushedCI)
    }

    // True when the mark has a question on the head with an answer of the user.
    private static func isAnswered(_ mark: CIMark, head: CommitID) -> Bool {
        guard let question = mark.question else { return false }
        return question.head == head && question.answer != nil
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

    // Put the worktree at the head of the round: the files of the session go. It does not run
    // while a person can use the session (it works or shows a box), and it keeps a change that no
    // round made (RepoStore.resetIfKnown). stoppedIt: the round stopped the session, so nobody
    // uses it.
    private func resetWorktree(to commit: CommitID, stoppedIt: Bool = false) async {
        await shared.reset(to: commit, use: .request, stoppedIt: stoppedIt)
    }

    private func checkHalt() throws(Stop) {
        if Task.isCancelled { throw .halted }
    }
}
