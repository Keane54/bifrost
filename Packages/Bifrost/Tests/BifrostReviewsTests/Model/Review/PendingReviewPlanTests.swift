// The pending review of a review round (docs/behaviour/reviews.md, "Review rounds").
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

private typealias D = ReviewData

@Suite("the plan of the pending review", .testTimeLimit)
struct PendingReviewPlanTests {
    private func outcome(
        _ recommendation: Recommendation = .requestChanges, summary: String = "Summary.",
        findings: [Finding] = []
    ) -> ReviewOutcome {
        ReviewOutcome(
            recommendation: recommendation, reason: "why", note: "A note for the user.",
            summary: summary, findings: findings)
    }

    private let inside = D.finding(.bug, line: 12, body: "In.", onDiff: true)

    private var insideComment: DraftComment {
        DraftComment(path: "src/a.swift", line: 12, side: .right, body: "In.")
    }

    // The bug and minor findings on lines of the diff are the line comments of the draft, in
    // their order. A nit never goes into the draft, as a comment or in the summary.
    @Test func onlyTheBugAndMinorFindingsGoInTheDraft() throws {
        let minor = D.finding(.minor, line: 11, startLine: 10, body: "Range.", onDiff: true)
        let nit = D.finding(.nit, line: 13, body: "Rename it.", onDiff: true)
        let offNit = D.finding(.nit, line: 99, body: "Order.")
        let placed = PendingReviewPlan.place(outcome(findings: [nit, inside, offNit, minor]))
        #expect(
            placed.comments == [
                insideComment,
                DraftComment(
                    path: "src/a.swift", line: 11, side: .right, startLine: 10, body: "Range."),
            ])
        #expect(placed.summary == "Summary." && placed.moved == 0)
        #expect(
            try PendingReviewPlan.plan(
                outcome(findings: [inside, nit]), head: try D.commit(), pending: nil)
                == .create(body: "Summary.", comments: [insideComment]))
    }

    // GitHub refuses a whole review with a comment outside the diff, so a finding that the diff
    // does not show moves into the summary with its path and its line, and a finding on the whole
    // PR moves in as its body. A path with backticks gets a longer fence.
    @Test func aFindingOffTheDiffMovesIntoTheSummary() throws {
        let outside = D.finding(.minor, line: 99, body: "Out.")
        let whole = D.finding(.bug, body: "The PR misses its main goal.")
        let tick = Finding(
            kind: .minor, place: FindingPlace(path: "a`b.swift", line: 3, side: .right),
            body: "Tick.", onDiff: false)
        let placed = PendingReviewPlan.place(outcome(findings: [inside, outside, whole]))
        #expect(placed.comments == [insideComment])
        #expect(placed.moved == 2)
        #expect(
            placed.summary == """
                Summary.

                `src/a.swift` line 99: Out.

                The PR misses its main goal.
                """)
        let fenced = PendingReviewPlan.place(outcome(summary: " ", findings: [tick]))
        #expect(fenced.summary == "``a`b.swift`` line 3: Tick." && fenced.moved == 1)
        let plan = try PendingReviewPlan.plan(
            outcome(findings: [inside, outside]), head: try D.commit(), pending: nil)
        #expect(
            plan == .create(
                body: "Summary.\n\n`src/a.swift` line 99: Out.", comments: [insideComment]))
    }

    // With a pending review of the user on the reviewed commit, each comment is a new thread,
    // and the summary goes below the text of the user after a blank line.
    @Test func anExistingPendingReviewGetsNewThreadsAndTheSummaryBelow() throws {
        let pending = PendingDraft(
            id: try D.node("PRR_mine"), body: "My draft.", commit: try D.commit())
        let plan = try PendingReviewPlan.plan(
            outcome(findings: [inside]), head: try D.commit(), pending: pending)
        #expect(
            plan == .add(
                review: try D.node("PRR_mine"), comments: [insideComment],
                body: "My draft.\n\nSummary."))
        // An empty draft text gets only the summary, and no summary sets no body.
        let empty = PendingDraft(id: try D.node("PRR_mine"), body: " ", commit: try D.commit())
        #expect(
            try PendingReviewPlan.plan(outcome(), head: try D.commit(), pending: empty)
                == .add(review: try D.node("PRR_mine"), comments: [], body: "Summary."))
        #expect(
            try PendingReviewPlan.plan(
                outcome(summary: "", findings: [inside]), head: try D.commit(), pending: pending)
                == .add(review: try D.node("PRR_mine"), comments: [insideComment], body: nil))
    }

    // A thread goes on the commit of the pending review, so a review on another commit fails
    // the round, and nothing is posted.
    @Test func aPendingReviewOnAnotherCommitFails() throws {
        let pending = PendingDraft(
            id: try D.node("PRR_mine"), body: "", commit: try D.commit(D.oldHex))
        #expect(throws: RoundFailure.otherCommit) {
            try PendingReviewPlan.plan(
                outcome(findings: [inside]), head: try D.commit(), pending: pending)
        }
    }

    // A result with no summary and nothing but nits has nothing to post.
    @Test func aResultWithNothingToPostPostsNothing() throws {
        let nit = D.finding(.nit, line: 12, body: "Rename it.", onDiff: true)
        #expect(
            try PendingReviewPlan.plan(
                outcome(summary: " \n", findings: [nit]), head: try D.commit(), pending: nil)
                == .nothing)
        #expect(
            try PendingReviewPlan.plan(
                outcome(summary: "Blocks.", findings: [nit]), head: try D.commit(), pending: nil)
                == .create(body: "Blocks.", comments: []))
    }

    // The text of the user and the summary together may not pass the limit of GitHub.
    @Test func aBodyOverTheLimitOfGitHubFails() throws {
        let summary = String(repeating: "s", count: 60_000)
        let pending = PendingDraft(
            id: try D.node("PRR_mine"), body: String(repeating: "u", count: 6_000),
            commit: try D.commit())
        #expect(throws: RoundFailure.draftTooLong) {
            try PendingReviewPlan.plan(
                outcome(summary: summary), head: try D.commit(), pending: pending)
        }
    }
}
