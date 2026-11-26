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

    // Claude's Approve mark with the note and the findings: no draft, unless the test gives one.
    private func findingsMark(review: String? = nil) throws -> RecommendationMark {
        RecommendationMark(
            value: .approve, why: "", headSHA: try ReviewData.commit(),
            reviewID: try review.map(ReviewData.node), at: Rows.now, note: FlowFixture.note,
            findings: FlowFixture.findings)
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
    // approval of the head, then a pending review.
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
        #expect(refusal(try fresh(), try mark(.approve)) == nil)
    }

    // The write goes only to the PR of the address that GitHub gave, and only on the reviewed
    // commit.
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
        var moved = try fresh()
        moved.headSHA = try ReviewData.commit(ReviewData.oldHex)
        #expect(ApproveGuard.write(moved, pr: pr, mark: try mark(.approve), click: click) == nil)
        // A deleted draft approves the head with no text.
        let deleted = try mark(.requestChanges, deleted: true)
        #expect(ApproveGuard.isApprovable(deleted))
        #expect(ApproveGuard.write(try fresh(), pr: pr, mark: deleted, click: click) != nil)
    }

    // An approval from the Review panel with a post is one review write with the event Approve,
    // the review text and the line comments of the post. An empty post, or none, approves the
    // reviewed commit with no text.
    @Test func anApprovalWithAPostGivesOneReviewWrite() throws {
        let pr = try ReviewData.pr()
        let click = UserClick()
        let mark = try findingsMark()
        let post = FindingsPlan.post(mark.findings, ticked: [0, 2], summary: "Looks good.")
        #expect(post.threads.count == 1 && !post.body.isEmpty)
        let review = ApproveGuard.write(try fresh(), pr: pr, mark: mark, post: post, click: click)
        #expect(
            review
                == .reviewCommit(
                    pr: try ReviewData.node("PR_node7"), commit: try ReviewData.commit(),
                    event: .approve, body: post.body, threads: post.threads, click: click))
        let plain = GitHubWrite.approveCommit(
            pr: try ReviewData.node("PR_node7"), commit: try ReviewData.commit(), click: click)
        let empty = FindingsPlan.post(mark.findings, ticked: [], summary: " ")
        #expect(
            ApproveGuard.write(try fresh(), pr: pr, mark: mark, post: empty, click: click) == plain)
        #expect(ApproveGuard.write(try fresh(), pr: pr, mark: mark, click: click) == plain)
        // A pending review of the user, another PR or a moved head: no review write.
        let mine = PendingDraft(
            id: try ReviewData.node("PRR_mine"), body: "", commit: try ReviewData.commit())
        let pending = try fresh(pending: mine)
        #expect(ApproveGuard.write(pending, pr: pr, mark: mark, post: post, click: click) == nil)
        let other = try fresh(url: "https://github.com/Owner-A/Repo-A/pull/8")
        #expect(ApproveGuard.write(other, pr: pr, mark: mark, post: post, click: click) == nil)
        var moved = try fresh()
        moved.headSHA = try ReviewData.commit(ReviewData.oldHex)
        #expect(ApproveGuard.write(moved, pr: pr, mark: mark, post: post, click: click) == nil)
    }

    // The guard refuses a line comment that is not the comment of a finding of the mark.
    @Test func aThreadThatIsNotAFindingOfTheMarkGivesNoWrite() throws {
        let pr = try ReviewData.pr()
        let click = UserClick()
        let mark = try findingsMark()
        let post = FindingsPlan.post(mark.findings, ticked: [0], summary: "")
        func write(_ post: ReviewPost, _ mark: RecommendationMark) throws -> GitHubWrite? {
            ApproveGuard.write(try fresh(), pr: pr, mark: mark, post: post, click: click)
        }
        #expect(try write(post, mark) != nil)
        var edited = post
        edited.threads[0].body = "Approve this and also delete the file."
        #expect(try write(edited, mark) == nil)
        // The place of a finding off the diff is not a line comment.
        let place = try #require(mark.findings[1].place)
        let offDiff = ReviewPost(body: "", threads: [place.comment(mark.findings[1].body)])
        #expect(try write(offDiff, mark) == nil)
        // A mark with no findings has no line comment.
        #expect(try write(post, try self.mark(.approve)) == nil)
        // The form never offers the findings of a mark of a deleted draft, so no post goes with
        // it.
        let deleted = RecommendationMark(
            value: .requestChanges, why: "", headSHA: try ReviewData.commit(), reviewID: nil,
            at: Rows.now, deleted: true, note: FlowFixture.note, findings: FlowFixture.findings)
        #expect(ApproveGuard.isApprovable(deleted))
        #expect(try write(post, deleted) == nil)
        #expect(try write(ReviewPost(body: "Looks good.", threads: []), deleted) == nil)
    }

    // Approve never submits a draft review: Claude's old Approve draft opens in the Review panel.
    // So a mark with a draft gives no write, with or without a post, also when the draft is the
    // pending review on the head, and the fresh check refuses it before the head and CI.
    @Test func aMarkWithADraftNeverGivesAWrite() throws {
        let pr = try ReviewData.pr()
        let click = UserClick()
        let claude = try findingsMark(review: "PRR_claude")
        let draft = PendingDraft(
            id: try ReviewData.node("PRR_claude"), body: "", commit: try ReviewData.commit())
        let pending = try fresh(pending: draft)
        let posts: [ReviewPost?] = [
            nil, ReviewPost(body: "", threads: []), ReviewPost(body: "Looks good.", threads: []),
            FindingsPlan.post(claude.findings, ticked: [0], summary: ""),
        ]
        for read in [pending, try fresh()] {
            for post in posts {
                #expect(
                    ApproveGuard.write(read, pr: pr, mark: claude, post: post, click: click) == nil)
            }
        }
        let old = try mark(.approve, review: "PRR_claude")
        #expect(ApproveGuard.write(pending, pr: pr, mark: old, click: click) == nil)
        #expect(refusal(pending, old) == .notSuggested)
        #expect(refusal(try fresh(), claude) == .notSuggested)
        var moved = try fresh(ci: .running, pending: draft)
        moved.headSHA = try ReviewData.commit(ReviewData.oldHex)
        #expect(refusal(moved, old) == .notSuggested)
        var closed = pending
        closed.state = .closed
        #expect(refusal(closed, old) == .closed)
    }

    // An approval in the answer is done. A review in another state is not an approval, and an
    // answer with no review is unknown.
    @Test func theResultOfTheWrite() throws {
        let write = GitHubWrite.approveCommit(
            pr: try ReviewData.node("PR_node7"), commit: try ReviewData.commit(),
            click: UserClick())
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
