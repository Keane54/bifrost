// The pending review of a review round (docs/behaviour/reviews.md, "Review rounds").
import Foundation
import Testing

@testable import BifrostReviews

private typealias D = ReviewData

@Suite("the plan of the pending review", .timeLimit(.minutes(1)))
struct PendingReviewPlanTests {
    private func outcome(
        _ recommendation: Recommendation = .requestChanges, summary: String = "Summary.",
        comments: [DraftComment] = []
    ) -> ReviewOutcome {
        ReviewOutcome(
            recommendation: recommendation, reason: "Why.", summary: summary, comments: comments)
    }

    private let inside = DraftComment(path: "src/a.swift", line: 12, side: .right, body: "In.")

    // GitHub refuses a whole review with a comment outside the diff, so such a comment moves into
    // the summary with its path and its line. A path with backticks gets a longer fence.
    @Test func aCommentOutsideTheDiffMovesIntoTheSummary() throws {
        let outside = DraftComment(path: "src/a.swift", line: 40, side: .right, body: "Out.")
        let wrongSide = DraftComment(path: "src/a.swift", line: 14, side: .left, body: "Left.")
        let tick = DraftComment(path: "a`b.swift", line: 3, side: .right, body: "Tick.")
        let range = DraftComment(
            path: "src/a.swift", line: 12, side: .right, startLine: 9, body: "Range.")
        let placed = PendingReviewPlan.place(
            outcome(comments: [inside, outside, wrongSide, tick, range]), diff: D.diff)
        #expect(placed.comments == [inside])
        #expect(placed.moved == 4)
        #expect(
            placed.summary == """
                Summary.

                `src/a.swift` line 40: Out.

                `src/a.swift` line 14: Left.

                ``a`b.swift`` line 3: Tick.

                `src/a.swift` line 12: Range.
                """)
        let plan = try PendingReviewPlan.plan(
            outcome(comments: [inside, outside]), diff: D.diff, head: try D.commit(), pending: nil)
        #expect(
            plan == .create(
                body: "Summary.\n\n`src/a.swift` line 40: Out.", comments: [inside]))
    }

    // With a pending review of the user on the reviewed commit, each comment is a new thread,
    // and the summary goes below the text of the user after a blank line.
    @Test func anExistingPendingReviewGetsNewThreadsAndTheSummaryBelow() throws {
        let pending = PendingDraft(
            id: try D.node("PRR_mine"), body: "My draft.", commit: try D.commit())
        let plan = try PendingReviewPlan.plan(
            outcome(comments: [inside]), diff: D.diff, head: try D.commit(), pending: pending)
        #expect(
            plan == .add(
                review: try D.node("PRR_mine"), comments: [inside],
                body: "My draft.\n\nSummary."))
        // An empty draft text gets only the summary, and no summary sets no body.
        let empty = PendingDraft(id: try D.node("PRR_mine"), body: " ", commit: try D.commit())
        #expect(
            try PendingReviewPlan.plan(
                outcome(), diff: D.diff, head: try D.commit(), pending: empty)
                == .add(review: try D.node("PRR_mine"), comments: [], body: "Summary."))
        #expect(
            try PendingReviewPlan.plan(
                outcome(summary: "", comments: [inside]), diff: D.diff, head: try D.commit(),
                pending: pending)
                == .add(review: try D.node("PRR_mine"), comments: [inside], body: nil))
    }

    // A thread goes on the commit of the pending review, so a review on another commit fails
    // the round, and nothing is posted.
    @Test func aPendingReviewOnAnotherCommitFails() throws {
        let pending = PendingDraft(
            id: try D.node("PRR_mine"), body: "", commit: try D.commit(D.oldHex))
        #expect(throws: RoundFailure.otherCommit) {
            try PendingReviewPlan.plan(
                outcome(comments: [inside]), diff: D.diff, head: try D.commit(), pending: pending)
        }
    }

    // An Approve with no summary and no comments posts nothing.
    @Test func anApproveWithNothingToSayPostsNothing() throws {
        #expect(
            try PendingReviewPlan.plan(
                outcome(.approve, summary: " \n"), diff: D.diff, head: try D.commit(),
                pending: nil) == .nothing)
        #expect(
            try PendingReviewPlan.plan(
                outcome(.approve, summary: "Looks good."), diff: D.diff, head: try D.commit(),
                pending: nil) == .create(body: "Looks good.", comments: []))
    }

    // The text of the user and the summary together may not pass the limit of GitHub.
    @Test func aBodyOverTheLimitOfGitHubFails() throws {
        let summary = String(repeating: "s", count: 60_000)
        let pending = PendingDraft(
            id: try D.node("PRR_mine"), body: String(repeating: "u", count: 6_000),
            commit: try D.commit())
        #expect(throws: RoundFailure.draftTooLong) {
            try PendingReviewPlan.plan(
                outcome(summary: summary), diff: D.diff, head: try D.commit(), pending: pending)
        }
    }
}
