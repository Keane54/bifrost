// The checks and the guard of the Approve button (docs/behaviour/reviews.md, "Approve"): the read
// of the fresh PR, the refusals in their order, the one write of each mark and its result.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

struct ApproveGuardTests {
    private let head = String(repeating: "c", count: 40)

    private func fresh(
        author: String = "user-a", ci: CIState? = nil, pending: PendingDraft? = nil,
        opinions: [ViewerOpinion] = [], url: String = "https://github.com/Owner-A/Repo-A/pull/7"
    ) throws -> FreshPR {
        FreshPR(
            id: try ReviewData.node("PR_node7"), url: url, author: author,
            headSHA: try ReviewData.commit(), ci: ci, pending: pending, opinions: opinions)
    }

    private func mark(_ value: Recommendation, review: String? = nil, deleted: Bool = false)
        throws -> RecommendationMark
    {
        RecommendationMark(
            value: value, why: "", headSHA: try ReviewData.commit(),
            reviewID: try review.map(ReviewData.node), at: Rows.now, deleted: deleted)
    }

    private func refusal(_ read: FreshPR, _ mark: RecommendationMark) -> ApproveRefusal? {
        ApproveGuard.refusal(read, viewer: Rows.viewer, mark: mark)
    }

    // The read keeps each field, takes the CI of the latest commit, and reads only a pending
    // review of the viewer. An answer with errors, or with no head, fails.
    @Test func theFreshReadDecodes() throws {
        let pr = try ReviewData.pr()
        let data = DraftAnswers.fresh(
            pr, author: "user-a", head: try ReviewData.commit(), ci: "SUCCESS",
            pending: .init(id: "PRR_1", body: "Hi.", commit: try ReviewData.commit()),
            opinions: [.init(state: "APPROVED", commit: try ReviewData.commit(), at: Rows.now)])
        let read = try FreshPR.decode(data).get()
        #expect(read.key == pr && read.state == .open && read.author == "user-a")
        let first = try ReviewData.node("PRR_1")
        #expect(read.ci == .passed && read.pending?.id == first)
        #expect(read.opinions.map(\.state) == [.approved])
        let other = DraftAnswers.fresh(
            pr, head: try ReviewData.commit(),
            pending: .init(id: "PRR_2", commit: try ReviewData.commit(), mine: false))
        #expect(try FreshPR.decode(other).get().pending == nil)
        let errors = DraftAnswers.json(["errors": [["message": "Bad."]], "data": .null])
        #expect(FreshPR.decode(errors) == .failure(.refused("Bad.")))
        let noHead = DraftAnswers.json([
            "data": ["repository": ["pullRequest": ["id": "PR_1", "state": "OPEN"]]]
        ])
        #expect(FreshPR.decode(noHead) == .failure(.badAnswer))
    }

    // The first rule that holds wins: closed, own PR, no Approve mark, a moved head, CI, an
    // approval of the head, then the draft rules.
    @Test func theRefusalsComeInTheirOrder() throws {
        let commit = try ReviewData.commit()
        var closed = try fresh(author: Rows.viewer)
        closed.state = .closed
        #expect(refusal(closed, try mark(.approve)) == .closed)
        let own = try fresh(author: Rows.viewer.uppercased())
        #expect(refusal(own, try mark(.approve)) == .ownPR)
        #expect(
            refusal(try fresh(), try mark(.comment))
                == .notSuggested)
        var moved = try fresh(ci: .failing)
        moved.headSHA = try ReviewData.commit(ReviewData.oldHex)
        #expect(refusal(moved, try mark(.approve)) == .headMoved)
        #expect(
            refusal(try fresh(ci: .running), try mark(.approve))
                == .ciRunning)
        let approved = try fresh(
            opinions: [ViewerOpinion(state: .approved, commit: head, submittedAt: Rows.now)])
        #expect(
            refusal(approved, try mark(.approve))
                == .alreadyApproved)
        let mine = PendingDraft(id: try ReviewData.node("PRR_mine"), body: "", commit: commit)
        #expect(
            refusal(try fresh(pending: mine), try mark(.approve))
                == .pendingReview)
        let claude = try mark(.approve, review: "PRR_claude")
        #expect(
            refusal(try fresh(pending: mine), claude)
                == .draftMissing)
        let elsewhere = PendingDraft(
            id: try ReviewData.node("PRR_claude"), body: "",
            commit: try ReviewData.commit(ReviewData.oldHex))
        #expect(
            refusal(try fresh(pending: elsewhere), claude)
                == .draftOtherCommit)
        let draft = PendingDraft(id: try ReviewData.node("PRR_claude"), body: "", commit: commit)
        #expect(refusal(try fresh(pending: draft), claude) == nil)
        #expect(refusal(try fresh(), try mark(.approve)) == nil)
    }

    // The write goes only to the PR of the address that GitHub gave, on the reviewed commit, and
    // only with the draft of the mark.
    @Test func theWriteGoesOnlyToTheRowAndTheReviewedCommit() throws {
        let pr = try ReviewData.pr()
        let click = UserClick()
        #expect(
            ApproveGuard.write(try fresh(), pr: pr, mark: try mark(.approve), click: click)
                == .approveCommit(
                    pr: try ReviewData.node("PR_node7"), commit: try ReviewData.commit(),
                    click: click))
        #expect(
            ApproveGuard.write(
                try fresh(url: "https://github.com/Owner-A/Repo-A/pull/8"), pr: pr,
                mark: try mark(.approve), click: click) == nil)
        let notLink = try fresh(url: "not a link")
        #expect(ApproveGuard.write(notLink, pr: pr, mark: try mark(.approve), click: click) == nil)
        let comment = try mark(.comment)
        #expect(ApproveGuard.write(try fresh(), pr: pr, mark: comment, click: click) == nil)
        let claude = try mark(.approve, review: "PRR_claude")
        let draft = PendingDraft(
            id: try ReviewData.node("PRR_claude"), body: "", commit: try ReviewData.commit())
        #expect(
            ApproveGuard.write(try fresh(pending: draft), pr: pr, mark: claude, click: click)
                == .approveDraft(review: try ReviewData.node("PRR_claude"), click: click))
        #expect(ApproveGuard.write(try fresh(), pr: pr, mark: claude, click: click) == nil)
        // A deleted draft approves the head with no text.
        let deleted = try mark(.requestChanges, deleted: true)
        #expect(ApproveGuard.isApprovable(deleted))
        #expect(ApproveGuard.write(try fresh(), pr: pr, mark: deleted, click: click) != nil)
    }

    // An approval in the answer is done. A review in another state is not an approval, and an
    // answer with no review is unknown.
    @Test func theResultOfTheWrite() throws {
        let write = GitHubWrite.approveDraft(
            review: try ReviewData.node("PRR_claude"), click: UserClick())
        let approved = DraftAnswers.written(write, state: "APPROVED")
        #expect(ApproveGuard.outcome(approved, of: write) == nil)
        #expect(
            ApproveGuard.outcome(DraftAnswers.written(write, state: "COMMENTED"), of: write)
                == .notApproved)
        #expect(ApproveGuard.outcome(Data("{}".utf8), of: write) == .unknown)
        #expect(ApproveRefusal.unknown.mayHaveApproved)
        #expect(ApproveRefusal.notApproved.mayHaveApproved)
        #expect(!ApproveRefusal.refusedByGitHub.mayHaveApproved)
    }
}
