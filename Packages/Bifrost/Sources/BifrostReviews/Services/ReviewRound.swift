// One review round (docs/behaviour/reviews.md, "Review rounds"): Claude reviews the PR of another
// person in a read-only session. A Request changes or Comment result leaves a pending review that
// only the user sees. An Approve result leaves no write, only the mark of the PR. The coordinator
// (ReviewRounds) makes one ReviewRound for each run of a job, and ends the round by how its steps
// stop.
//
// The steps, after a click on Review:
// 1. The clone of the repository (a click tries a failed clone again at once), and the trust read
//    of Claude Code. A clone with no trust waits for the trust step, unless the round has the one
//    start of a click or of the end of a trust step: claude then judges the trust itself, and
//    Bifrost never answers a trust prompt (a background start has none: it fails).
// 2. A read of the PR on GitHub, and the fetch of its head and its base branch. A PR that closed,
//    or whose head moved during the read, fails. The draft review of Bifrost for this commit
//    fails the round: a new round would add each comment again.
// 3. The earlier session of the PR goes first, so it can never write into the folders of this
//    round. Then the worktree at the head, and the input folder: input.json, full.diff,
//    since.diff for a re-review (Baseline), mode.md and humanise-rules.md. input.json holds a
//    new token of the round, which result.json must give back: a result of another session (an
//    earlier one, a session that a stop left, or the session of another PR) never counts.
// 4. The session (PRSessions.start), then the wait for the end of its turn
//    (PRSessions.waitForTurnEnd). Then the worktree is reset and its changes counted.
// 5. The strict check of result.json (ReviewResult), made at the end of the turn: the round uses
//    that checked result and never reads the file again. An Approve result writes nothing to
//    GitHub: the mark of the PR keeps its note and its findings for the Review panel. For another
//    result, the state saves the posting phase before the first write, so a quit during the
//    writes never posts again (closedWhilePosting at the next start). A second read of the PR
//    gives the pending review of the user, and the writes go through PendingReviewWrites: the
//    summary and each bug and minor finding. A nit and the note never go to GitHub. The mark
//    keeps the note and all the findings.
// A round whose session ran when Bifrost started goes on at step 4 (resume).
import BifrostFoundation
import BifrostSessions
import Foundation
import OSLog

@MainActor
final class ReviewRound {
    // How the steps of a round stop.
    enum Stop: Error {
        case failed(RoundFailure)
        // The clone needs the trust of the user. refused: claude refused the start.
        case waitForTrust(refused: Bool)
        // The task of the round was cancelled.
        case halted
    }

    // How a good round ended: it left a pending review (drafted), or it posted nothing because
    // Claude suggests Approve (reviewed).
    enum Ended {
        case drafted, reviewed
    }

    // The services of the rounds.
    struct Parts {
        let store: ReviewsStore
        let github: GitHubClient
        let repos: RepoStore
        let setup: RepoSetup
        let sessions: PRSessions
        let skills: URL
        let now: () -> Date
    }

    private static let logger = Logger(bifrost: "reviews")

    let pr: PRKey
    // True after the save of the posting phase: GitHub can hold a part of the writes.
    private(set) var posting = false

    private let parts: Parts
    private let model: ModelChoice
    private let viewer: () -> String?
    // True when the user stopped the round with Stop session.
    private let stopRequested: () -> Bool
    // Take the one start of the repository that a click or the end of a trust step gave, when
    // there is one.
    private let takeTryOnce: () -> Bool
    // A session started in the clone: Claude Code trusts it.
    private let startedSession: () -> Void
    private let changed: () -> Void

    init(
        pr: PRKey, parts: Parts, model: ModelChoice, viewer: @escaping () -> String?,
        stopRequested: @escaping () -> Bool, takeTryOnce: @escaping () -> Bool,
        startedSession: @escaping () -> Void, changed: @escaping () -> Void
    ) {
        self.pr = pr
        self.parts = parts
        self.model = model
        self.viewer = viewer
        self.stopRequested = stopRequested
        self.takeTryOnce = takeTryOnce
        self.startedSession = startedSession
        self.changed = changed
    }

    private var store: ReviewsStore { parts.store }
    private var repos: RepoStore { parts.repos }
    private var sessions: PRSessions { parts.sessions }

    // MARK: - The steps

    // Steps 1 to 5 of a new round, whose state is preparing.
    func start() async throws(Stop) -> Ended {
        guard let viewer = viewer() else { throw .failed(.readFailed(.notLoggedIn)) }
        do throws(RepoError) {
            try await repos.ensureClone(pr.repo)
        } catch {
            Self.logger.error("\(error.message, privacy: .private)")
            throw .failed(.prepareFailed)
        }
        try checkHalt()
        // The trust follows the real state: it is read again before each round. The one start of
        // a click lets claude judge a clone that the read calls untrusted.
        guard await parts.setup.trustsForStart(pr.repo) || takeTryOnce() else {
            throw .waitForTrust(refused: false)
        }
        try checkHalt()
        let context = try await read(viewer: viewer)
        guard context.state == .open else { throw .failed(.prClosed) }
        if let own = store.state.prs[pr]?.recommendation?.reviewID, own == context.pending?.id,
            context.pending?.commit == context.headSHA
        {
            throw .failed(.ownDraft)
        }
        guard let base = BranchName(context.baseRef) else { throw .failed(.prepareFailed) }
        let (pr, repos) = (pr, repos)
        let fetched = try await git { () async throws(RepoError) in
            try await repos.fetchPR(pr, base: base)
        }
        guard fetched.head == context.headSHA else { throw .failed(.prChanged) }
        try checkHalt()
        // Each round starts a new session. The earlier one goes before the folders of this round
        // are made, so it never writes into them, and the new session can take its name.
        await sessions.remove(pr, .review)
        try checkHalt()
        let worktree = try await git { () async throws(RepoError) in
            try await repos.prepareWorktree(pr, head: fetched.head)
        }
        let token = UUID().uuidString.lowercased()
        let input = try await writeInput(
            context: context, fetched: fetched, viewer: viewer, token: token)
        try checkHalt()
        let args = PRSessionArgs.review(
            name: sessions.name(pr, .review), model: model,
            inputFolder: input.files.result.deletingLastPathComponent(), skills: parts.skills,
            prompt: PRSessionArgs.reviewPrompt(input.files.input))
        let row: SessionRow
        do throws(RoundFailure) {
            row = try await sessions.start(pr, .review, args: args, in: worktree)
        } catch .notTrusted {
            throw .waitForTrust(refused: true)
        } catch {
            throw .failed(error)
        }
        startedSession()
        let startedAt = sessions.time
        let time = parts.now()
        await store.update { state in
            guard var round = state.prs[pr]?.round else { return }
            round.phase = .running
            round.headSHA = fetched.head
            round.baseSHA = fetched.mergeBase
            round.shortID = row.shortId
            round.sessionID = SessionID(row.sessionId)
            round.token = token
            // The time limit counts from the start of the session.
            round.startedAt = time
            state.prs[pr]?.round = round
        }
        changed()
        return try await finish(input: input, session: row.sessionId, startedAt: startedAt)
    }

    // A round whose session ran when Bifrost started: wait for its end, then finish it with the
    // diff of the clone. The diff never comes from the input folder, which the session can change.
    func resume(_ round: ActiveRound) async throws(Stop) -> Ended {
        // The user stopped it before the quit.
        guard !round.stoppedByUser else { throw .failed(.stopped) }
        guard let head = round.headSHA, let base = round.baseSHA,
            let id = round.sessionID?.text, let viewer = viewer()
        else { throw .failed(.noResult) }
        let (pr, repos) = (pr, repos)
        // The merge base of the base and the head: an Electron round saved the tip of the base
        // branch, and the merge base of a merge base is itself.
        let mergeBase = (try? await repos.mergeBase(pr.repo, base, head)) ?? base
        let text = try await git { () async throws(RepoError) in
            try await repos.diff(pr.repo, from: mergeBase, to: head)
        }
        guard let text else { throw .failed(.tooLarge) }
        let folder = repos.layout.inputFolder(pr.repo, number: pr.number)
        let input = ReviewInput(
            pr: pr, round: round.token, baseSHA: base, headSHA: head, mergeBase: mergeBase,
            viewer: viewer, baseline: Baseline(kind: .first),
            files: ReviewInput.Files(folder: folder, reReview: false),
            diff: DiffLines.parse(text))
        let elapsed = Duration.seconds(max(parts.now().timeIntervalSince(round.startedAt), 0))
        return try await finish(input: input, session: id, startedAt: sessions.time - elapsed)
    }

    // Steps 4 and 5: the end of the turn, the reset of the worktree, the check of the result and
    // the pending review.
    private func finish(input: ReviewInput, session: String, startedAt: Duration)
        async throws(Stop) -> Ended
    {
        // The result that the last check of the turn end accepted. The round uses this result and
        // never reads the file again, so a session that writes the file after the end changes
        // nothing.
        let accepted: ReviewOutcome?
        var blocked = false
        do throws(RoundFailure) {
            // The turn ends at once when the result passes the check of the round.
            let end = try await sessions.waitForTurnEnd(
                id: session, startedAt: startedAt, resultFile: input.files.result,
                limit: ReviewRounds.limit,
                check: { try? ReviewResult.check($0, input: input).get() })
            switch end {
            case .ended(let outcome):
                accepted = outcome
            case .blocked(let outcome):
                // A session of a round must never ask. Its result counts only when it is good.
                (accepted, blocked) = (outcome, true)
                await sessions.stop(id: session)
            }
        } catch .timeout {
            await sessions.stop(id: session)
            await repos.resetWorktree(pr)
            throw .failed(.timeout)
        } catch {
            try checkHalt()
            await repos.resetWorktree(pr)
            throw .failed(.stopped)
        }
        // The session can write any file of its worktree.
        await repos.resetWorktree(pr)
        try checkHalt()
        guard let outcome = accepted else {
            let failure = await resultFailure(input: input)
            throw .failed(blocked ? .blocked : failure)
        }
        return try await post(outcome, input: input)
    }

    // Why the result file gave no good result (a read for the failure text only): a session that
    // ended with no accepted result.
    private func resultFailure(input: ReviewInput) async -> RoundFailure {
        let limit = ReviewResult.maxBytes
        return await repos.readResult(pr, limit: limit).failure(limit: limit) { data in
            if case .failure(let refusal) = ReviewResult.check(data, input: input) {
                refusal
            } else {
                nil
            }
        }
    }

    // Step 5: the pending review. An Approve never writes in the round, whatever its findings:
    // the mark keeps them, and the user sees them before anything goes to GitHub.
    private func post(_ outcome: ReviewOutcome, input: ReviewInput) async throws(Stop) -> Ended {
        let (pr, head) = (pr, input.headSHA)
        let placed = PendingReviewPlan.place(outcome)
        if outcome.recommendation == .approve
            || (placed.summary.trimmed().isEmpty && placed.comments.isEmpty)
        {
            await succeed(outcome, head: head, review: nil, drafts: [])
            return .reviewed
        }
        // The posting phase is saved before the first write: after a quit, the next start
        // fails this round and never posts it again.
        // An update that finds no round changes nothing and still gives true, so the phase of
        // the state is checked too: a round that Remove all clones cleared never posts.
        let saved = await store.update { $0.prs[pr]?.round?.phase = .posting }
        guard saved, store.state.prs[pr]?.round?.phase == .posting else {
            throw .failed(.notSaved)
        }
        posting = true
        changed()
        guard let viewer = viewer() else { throw .failed(.readFailed(.notLoggedIn)) }
        let again = try await read(viewer: viewer)
        guard again.state == .open else { throw .failed(.prClosed) }
        if stopRequested() || store.state.prs[pr]?.round?.stoppedByUser == true {
            throw .failed(.stopped)
        }
        let review: NodeID
        do throws(RoundFailure) {
            let plan = try PendingReviewPlan.plan(outcome, head: head, pending: again.pending)
            review = try await PendingReviewWrites(github: parts.github).send(
                plan, pr: pr, head: head)
        } catch {
            throw .failed(error)
        }
        let time = parts.now()
        // The draft texts, so the voice of later drafts can learn from the texts that the user
        // sends. The summary has no path.
        var drafts = placed.comments.map {
            DraftRecord(
                reviewID: review, pr: pr, path: $0.path, line: $0.line, body: $0.body, at: time)
        }
        if !placed.summary.isEmpty {
            drafts.append(
                DraftRecord(
                    reviewID: review, pr: pr, path: "", line: 0, body: placed.summary, at: time))
        }
        await succeed(outcome, head: head, review: review, drafts: drafts)
        return .drafted
    }

    // A good round: the round clears with its error, and the PR keeps the recommendation with
    // the note and all the findings of the result, the reviewed commit and the draft texts.
    private func succeed(
        _ outcome: ReviewOutcome, head: CommitID, review: NodeID?, drafts: [DraftRecord]
    ) async {
        let pr = pr
        let mark = RecommendationMark(
            value: outcome.recommendation, why: outcome.reason, headSHA: head, reviewID: review,
            at: parts.now(), note: outcome.note, findings: outcome.findings)
        await store.update { state in
            var prState = state.prs[pr] ?? PRState()
            prState.round = nil
            prState.lastError = nil
            prState.lastReviewedCommit = head
            prState.recommendation = mark
            state.prs[pr] = prState
            state.drafts = Array((state.drafts + drafts).suffix(ReviewsState.maxDrafts))
        }
        changed()
    }

    // MARK: - The parts of the steps

    private func read(viewer: String) async throws(Stop) -> ReviewContext {
        let context: ReviewContext
        do throws(GitHubError) {
            context = try await ReviewQueries.context(pr, viewer: viewer, on: parts.github)
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
        return context
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

    // Step 3: the input folder. The diffs come from git in the clone, the rules from the skills.
    private func writeInput(
        context: ReviewContext, fetched: FetchedPR, viewer: String, token: String
    ) async throws(Stop) -> ReviewInput {
        let (pr, repos) = (pr, repos)
        let last = context.lastSubmittedReview
        var ancestor = false
        if let commit = Baseline.ancestorToCheck(last: last, head: fetched.head) {
            ancestor = await repos.isAncestor(commit, of: fetched.head, in: pr.repo)
        }
        let baseline = Baseline.of(last: last, head: fetched.head, isAncestor: ancestor)
        let full = try await git { () async throws(RepoError) in
            try await repos.diff(pr.repo, from: fetched.mergeBase, to: fetched.head)
        }
        guard let full, full.utf8.count <= ReviewInput.maxDiffBytes else {
            throw .failed(.tooLarge)
        }
        var since: String?
        if let commit = baseline.since {
            let text = try await git { () async throws(RepoError) in
                try await repos.diff(pr.repo, from: commit, to: fetched.head)
            }
            guard let text, text.utf8.count <= ReviewInput.maxDiffBytes else {
                throw .failed(.tooLarge)
            }
            since = text
        }
        let folder = try await git { () async throws(RepoError) in
            try await repos.inputFolder(pr)
        }
        let input = ReviewInput(
            context: context, round: token, viewer: viewer, baseSHA: fetched.base,
            mergeBase: fetched.mergeBase, baseline: baseline,
            files: ReviewInput.Files(folder: folder, reReview: since != nil),
            diff: DiffLines.parse(full))
        let skills = parts.skills
        let rules = await BlockingExecutor.run { () -> (mode: Data, rules: Data)? in
            guard
                let mode = FileManager.default.contents(
                    atPath: skills.appending(path: "skills/bifrost-review/bifrost-mode.md")
                        .path(percentEncoded: false)),
                let rules = FileManager.default.contents(
                    atPath: skills.appending(path: "skills/bifrost-humanise/rules.md")
                        .path(percentEncoded: false))
            else { return nil }
            return (mode, rules)
        }
        guard let rules else { throw .failed(.inputFailed) }
        var files: [(name: String, data: Data)] = [
            ("full.diff", Data(full.utf8)), ("mode.md", rules.mode),
            ("humanise-rules.md", rules.rules), ("input.json", input.fileData),
        ]
        if let since { files.append(("since.diff", Data(since.utf8))) }
        do throws(RepoError) {
            try await repos.writeInput(pr, files)
        } catch {
            Self.logger.error("\(error.message, privacy: .private)")
            throw .failed(.inputFailed)
        }
        return input
    }

    private func checkHalt() throws(Stop) {
        if Task.isCancelled { throw .halted }
    }
}
