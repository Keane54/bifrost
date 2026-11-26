// The fixture of the tests of the Approve button and of the Review panel: a Reviews store in a
// temporary folder, FakeGitHub with the answers of DraftAnswers, the Approve flow, the progress of
// the review writes on a manual clock, and the polls, the ends of a progress and the Event log
// lines that the flows ask for. No test reaches GitHub.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

// The polls of the watcher as ReviewWrites reads them (ReviewsWatcher.polls), with the rules of
// ReviewsWatcher.refresh: polls never overlap, and a request for a poll while one runs starts one
// more poll at the end of that poll. A test starts a timer poll and gives the good answer of the
// poll that runs.
@MainActor
final class FakePolls {
    private(set) var count = PollCount()
    // True while a poll runs. again: one more poll starts at its end.
    private(set) var running = false
    private var again = false

    // A timer poll starts. No poll runs.
    func start() {
        #expect(!running, "a poll runs already")
        count.started += 1
        running = true
    }

    // A flow asks for a poll (ended): a poll starts now, or after the poll that runs.
    func refresh() {
        if running { again = true } else { start() }
    }

    // The poll that runs gives a good answer. A poll that a flow asked for meanwhile starts.
    func answer() {
        #expect(running, "no poll runs")
        count.answered = count.started
        running = false
        if again {
            again = false
            start()
        }
    }
}

@MainActor
final class FlowFixture {
    static let viewer = Rows.viewer
    static let claudeReview = "PRR_claude"
    // The private note of the findings mark. No write may hold it.
    nonisolated static let note = "PRIVATE-NOTE-4c1e"
    // The findings of the findings mark: a bug on the diff (a range), a minor finding off the
    // diff, a minor finding with no place, and a nit on the diff.
    nonisolated static let findings: [Finding] = [
        Finding(
            kind: .bug,
            place: FindingPlace(path: "src/a.swift", line: 12, side: .right, startLine: 10),
            body: "This loop never ends when the list is empty.", onDiff: true),
        Finding(
            kind: .minor, place: FindingPlace(path: "src/b.swift", line: 40, side: .right),
            body: "This log line names the wrong file.", onDiff: false),
        Finding(kind: .minor, place: nil, body: "No test covers the retry.", onDiff: false),
        Finding(
            kind: .nit, place: FindingPlace(path: "src/a.swift", line: 3, side: .right),
            body: "A clearer name would help here.", onDiff: true),
    ]

    let folder: TemporaryFolder
    let store: ReviewsStore
    let github = FakeGitHub()
    let client: GitHubClient
    let approver: ApproveFlow
    let writes: ReviewWrites
    let clock = ManualClock()
    let polls = Recorder<Bool>()
    let progressEnds = Recorder<Bool>()
    let lines = Recorder<String>()
    // The polls of the watcher. ended() records a poll request in polls and asks watcherPolls for
    // a poll, as the shell does (ReviewsWatcher.refresh).
    let watcherPolls = FakePolls()
    let pr: PRKey
    let head: CommitID

    // mark: the mark of the PR in the state.
    init(mark: RecommendationMark? = nil) async throws {
        folder = try TemporaryFolder()
        let layout = ReviewsLayout(
            folder: URL(filePath: folder.realPath + "/reviews", directoryHint: .isDirectory))
        store = try await ReviewsStore.open(layout: layout, log: Recorder<StoreEvent>())
        client = GitHubClient(access: github)
        pr = try ReviewData.pr()
        head = try ReviewData.commit()
        let (polls, progressEnds, lines, watcherPolls) = (polls, progressEnds, lines, watcherPolls)
        let client = client
        let writes = ReviewWrites(
            clock: clock, polls: { watcherPolls.count },
            progressEnded: { progressEnds.record(true) },
            ownReviews: { pr in
                try? await DraftQueries.ownReviews(pr, viewer: Self.viewer, on: client)
            }, now: { Rows.now })
        self.writes = writes
        approver = ApproveFlow(
            store: store, github: client, writes: writes, viewer: { Self.viewer },
            ended: {
                polls.record(true)
                watcherPolls.refresh()
            }, eventLine: { lines.record($0) })
        // Your own reviews on the PR: none, unless a test gives some.
        github.answers[DraftQueries.ownReviewsName] = .success(DraftAnswers.ownReviews([]))
        if let mark { await setMark(mark) }
    }

    // A flow of the Review panel on the services of the fixture.
    func draftFlow() -> DraftFlow {
        let lines = lines
        return DraftFlow(
            store: store, github: client, approver: approver, writes: writes,
            viewer: { Self.viewer }, ended: ended, eventLine: { lines.record($0) })
    }

    // A flow of the findings form of the Review panel on the services of the fixture.
    func findingsFlow() -> FindingsFlow {
        let lines = lines
        return FindingsFlow(
            store: store, github: client, approver: approver, writes: writes,
            viewer: { Self.viewer }, ended: ended, eventLine: { lines.record($0) })
    }

    // A request of a flow for a poll: it is recorded, and the watcher starts the poll.
    private var ended: @MainActor () -> Void {
        let (polls, watcherPolls) = (polls, watcherPolls)
        return {
            polls.record(true)
            watcherPolls.refresh()
        }
    }

    // The next poll of the watcher gives a good answer: the poll that runs, or a new one. As in
    // the shell, any unsure Comment is then checked against your own reviews, and this waits for
    // that check.
    func pollAnswered() async {
        if !watcherPolls.running { watcherPolls.start() }
        watcherPolls.answer()
        writes.checkComments()
        await writes.checkTask(pr)?.value
    }

    func setMark(_ mark: RecommendationMark?) async {
        let pr = pr
        await store.update { state in
            var prState = state.prs[pr] ?? PRState()
            prState.recommendation = mark
            state.prs[pr] = prState
        }
    }

    // Claude's mark on the head: Approve with no draft, or a draft review of the value, with
    // the private note.
    func mark(_ value: Recommendation, draft: Bool = true, note: String = "") throws
        -> RecommendationMark
    {
        RecommendationMark(
            value: value, why: "The reason.", headSHA: head,
            reviewID: draft ? try ReviewData.node(Self.claudeReview) : nil, at: Rows.at(-30),
            note: note)
    }

    // Claude's Approve mark on the head with no draft, with the private note and the findings.
    func findingsMark(at: Date = Rows.at(-30)) -> RecommendationMark {
        RecommendationMark(
            value: .approve, why: "the retry change is correct", headSHA: head, reviewID: nil,
            at: at, note: Self.note, findings: Self.findings)
    }

    // The fresh read of the PR: open, by user-a, on the head, with Claude's draft as the pending
    // review, unless the test gives other values. pending: .some(nil) gives no pending review.
    func answerFresh(
        head: CommitID? = nil, author: String = "user-a", state: String = "OPEN",
        ci: String? = nil, pending: DraftAnswers.Pending?? = .none,
        opinions: [DraftAnswers.Opinion] = []
    ) {
        let claude = DraftAnswers.Pending(id: Self.claudeReview, commit: self.head)
        github.answers[DraftQueries.freshName] = .success(
            DraftAnswers.fresh(
                pr, state: state, author: author, head: head ?? self.head, ci: ci,
                pending: pending ?? claude, opinions: opinions))
    }

    // The read of Claude's draft: the summary and the comments, pending on the head.
    func answerDraft(
        body: String, comments: [DraftRead.Comment], state: String = "PENDING"
    ) {
        github.answers[DraftQueries.draftName] = .success(
            DraftAnswers.draft(
                Self.claudeReview, state: state, body: body, commit: head, comments: comments))
    }

    // The answer of a write.
    func answerWrite(_ write: GitHubWrite, state: String? = nil) {
        github.answers[FakeGitHub.key(write)] = .success(DraftAnswers.written(write, state: state))
    }

    var written: [GitHubWrite] {
        github.calls.compactMap { if case .write(let write) = $0 { write } else { nil } }
    }

    var reads: [String] {
        github.calls.compactMap { if case .read(let name) = $0 { name } else { nil } }
    }

    var savedMark: RecommendationMark? { store.state.prs[pr]?.recommendation }

    func end() async {
        await store.close().value
        folder.remove()
    }
}
