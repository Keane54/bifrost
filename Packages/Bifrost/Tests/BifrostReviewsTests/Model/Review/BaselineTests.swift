// The baseline of a review (docs/behaviour/reviews.md, "Review rounds").
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

@Suite("the baseline of a review", .testTimeLimit)
struct BaselineTests {
    private func review(_ hex: String?, at seconds: Double = 0, state: ReviewState = .approved)
        -> ViewerReview
    {
        ViewerReview(
            state: state, submittedAt: Date(timeIntervalSince1970: seconds),
            commit: hex.flatMap(CommitID.init))
    }

    // No submitted review: a first review of the full diff.
    @Test func noReviewGivesAFirstReview() throws {
        let head = try ReviewData.commit()
        #expect(Baseline.of(last: nil, head: head, isAncestor: false) == Baseline(kind: .first))
        #expect(Baseline.ancestorToCheck(last: nil, head: head) == nil)
    }

    // The last review is on the head: the full diff, unchanged.
    @Test func theHeadGivesTheFullDiffUnchanged() throws {
        let head = try ReviewData.commit()
        let last = review(ReviewData.headHex)
        #expect(Baseline.ancestorToCheck(last: last, head: head) == nil)
        #expect(
            Baseline.of(last: last, head: head, isAncestor: false)
                == Baseline(kind: .first, note: .unchanged))
    }

    // The last review is on an ancestor of the head: a re-review since that commit, with the
    // earlier threads and summaries.
    @Test func anAncestorGivesAReReview() throws {
        let head = try ReviewData.commit()
        let last = review(ReviewData.oldHex)
        let old = try ReviewData.commit(ReviewData.oldHex)
        #expect(Baseline.ancestorToCheck(last: last, head: head) == old)
        let baseline = Baseline.of(last: last, head: head, isAncestor: true)
        #expect(baseline == Baseline(kind: .reReview, since: old))
        #expect(baseline.checksEarlier)
    }

    // A rewritten history, or a commit that git cannot find, or a review with no commit: the
    // full diff, with the earlier threads and summaries.
    @Test func aRewriteGivesTheFullDiffWithTheEarlierPoints() throws {
        let head = try ReviewData.commit()
        let rewritten = Baseline.of(last: review(ReviewData.oldHex), head: head, isAncestor: false)
        #expect(rewritten == Baseline(kind: .first, note: .rewritten))
        #expect(rewritten.checksEarlier)
        #expect(
            Baseline.of(last: review(nil), head: head, isAncestor: true)
                == Baseline(kind: .first, note: .rewritten))
    }

    // The baseline is the newest submitted review: a pending review and a review with only
    // replies do not count.
    @Test func theBaselineIsTheNewestRealReview() throws {
        var context = ReviewContext(pr: try ReviewData.pr(), headSHA: try ReviewData.commit())
        context.reviews = [
            review(ReviewData.baseHex, at: 10),
            review(ReviewData.oldHex, at: 20, state: .changesRequested),
            ViewerReview(state: .commented, submittedAt: Date(timeIntervalSince1970: 30),
                commit: CommitID(ReviewData.headHex), replyOnly: true),
            review(ReviewData.headHex, at: 40, state: .pending),
        ]
        #expect(context.lastSubmittedReview?.commit == (try ReviewData.commit(ReviewData.oldHex)))
    }
}
