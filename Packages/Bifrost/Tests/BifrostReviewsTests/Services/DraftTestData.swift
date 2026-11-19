// The fixture of the tests of the Approve button and of the Review panel: a Reviews store in a
// temporary folder, FakeGitHub with the answers of DraftAnswers, the Approve flow, the progress of
// the review writes on a manual clock, and the polls, the ends of a progress and the Event log
// lines that the flows ask for. No test reaches GitHub.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

@MainActor
final class FlowFixture {
    static let viewer = Rows.viewer
    static let claudeReview = "PRR_claude"

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
        let (polls, progressEnds, lines) = (polls, progressEnds, lines)
        let writes = ReviewWrites(clock: clock, progressEnded: { progressEnds.record(true) })
        self.writes = writes
        approver = ApproveFlow(
            store: store, github: client, writes: writes, viewer: { Self.viewer },
            ended: { polls.record(true) }, eventLine: { lines.record($0) })
        if let mark { await setMark(mark) }
    }

    // A flow of the Review panel on the services of the fixture.
    func draftFlow() -> DraftFlow {
        let (polls, lines) = (polls, lines)
        return DraftFlow(
            store: store, github: client, approver: approver, writes: writes,
            viewer: { Self.viewer }, ended: { polls.record(true) },
            eventLine: { lines.record($0) })
    }

    func setMark(_ mark: RecommendationMark?) async {
        let pr = pr
        await store.update { state in
            var prState = state.prs[pr] ?? PRState()
            prState.recommendation = mark
            state.prs[pr] = prState
        }
    }

    // Claude's mark on the head: Approve with no draft, or a draft review of the value.
    func mark(_ value: Recommendation, draft: Bool = true) throws -> RecommendationMark {
        RecommendationMark(
            value: value, why: "The reason.", headSHA: head,
            reviewID: draft ? try ReviewData.node(Self.claudeReview) : nil, at: Rows.at(-30))
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
