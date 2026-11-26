// What the Review panel posts with a review of Claude's findings (docs/behaviour/reviews.md, "The
// Review panel"): the post of the ticks and the summary, its checks, the fresh check of the PR,
// the guard of the one write, its result and the texts of the refusals.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

struct FindingsPlanTests {
    private let findings = FlowFixture.findings

    private func fresh(
        author: String = "user-a", state: PRLifecycle = .open, head: CommitID? = nil,
        pending: PendingDraft? = nil, url: String = "https://github.com/Owner-A/Repo-A/pull/7"
    ) throws -> FreshPR {
        FreshPR(
            id: try ReviewData.node("PR_node7"), url: url, state: state, author: author,
            headSHA: try head ?? ReviewData.commit(), pending: pending)
    }

    // Claude's mark on the head with the note and the findings: Approve with no draft, unless the
    // test gives other values.
    private func claudeMark(
        _ value: Recommendation = .approve, review: String? = nil, deleted: Bool = false
    ) throws -> RecommendationMark {
        RecommendationMark(
            value: value, why: "the retry change is correct", headSHA: try ReviewData.commit(),
            reviewID: try review.map(ReviewData.node), at: Rows.now, deleted: deleted,
            note: FlowFixture.note, findings: FlowFixture.findings)
    }

    private func pending() throws -> PendingDraft {
        PendingDraft(id: try ReviewData.node("PRR_mine"), body: "", commit: try ReviewData.commit())
    }

    // The summary comes first, then the paragraph of each ticked finding with no line comment.
    // Each ticked finding on the diff is one line comment. An unticked finding, and an index that
    // is not a finding, give nothing.
    @Test func thePostHoldsOnlyTheTickedFindingsAndTheSummary() throws {
        let post = FindingsPlan.post(findings, ticked: [2, 0, 9, -1], summary: "Looks good.")
        let bug = try #require(findings[0].comment)
        #expect(
            post == ReviewPost(body: "Looks good.\n\nNo test covers the retry.", threads: [bug]))
        #expect(bug.startLine == 10 && bug.line == 12 && bug.body == findings[0].body)
        // The ticked findings go in the order of the list.
        let both = FindingsPlan.post(findings, ticked: [2, 1], summary: " ")
        #expect(
            both.body
                == "`src/b.swift` line 40: This log line names the wrong file.\n\n"
                + "No test covers the retry.")
        #expect(both.threads.isEmpty)
        // Nothing ticked and no summary: an empty post, which is a plain approval.
        #expect(FindingsPlan.post(findings, ticked: [], summary: "\n").isEmpty)
        #expect(FindingsPlan.post([], ticked: [0], summary: "").isEmpty)
        #expect(!FindingsPlan.post(findings, ticked: [], summary: "Thanks.").isEmpty)
    }

    // A finding whose line the diff does not show goes in the review text with its path and line,
    // because GitHub refuses a whole review with a comment on such a line.
    @Test func aFindingOffTheDiffGoesInTheReviewText() {
        let post = FindingsPlan.post(findings, ticked: [1], summary: "")
        #expect(post.threads.isEmpty)
        #expect(post.body == "`src/b.swift` line 40: This log line names the wrong file.")
        // A finding on the diff is a line comment, never a paragraph.
        let onDiff = FindingsPlan.post(findings, ticked: [0, 3], summary: "")
        #expect(onDiff.body.isEmpty)
        #expect(onDiff.threads == findings.compactMap(\.comment))
    }

    @Test func aFindingWithNoPlaceGoesInTheReviewText() {
        let post = FindingsPlan.post(findings, ticked: [2], summary: "")
        #expect(post == ReviewPost(body: "No test covers the retry.", threads: []))
    }

    // With every finding ticked and a summary, neither the review text nor a line comment holds
    // Claude's private note, and nor does the write of the guard.
    @Test func thePostNeverHoldsTheNote() throws {
        let mark = try claudeMark()
        let post = FindingsPlan.post(
            mark.findings, ticked: Set(mark.findings.indices), summary: "Looks good.")
        #expect(post.threads.count == 2)
        #expect(!post.body.contains(FlowFixture.note))
        #expect(post.threads.allSatisfy { !$0.body.contains(FlowFixture.note) })
        let write = try #require(
            FindingsPlan.write(
                try fresh(), pr: try ReviewData.pr(), mark: mark, post: post, event: .comment,
                click: UserClick()))
        #expect(!String(decoding: write.input, as: UTF8.self).contains(FlowFixture.note))
    }

    // Request changes needs a summary that the user typed. Line comments alone are not enough,
    // and nor is a review text of ticked findings off the diff or with no place.
    @Test func requestChangesNeedsATypedSummary() {
        func problem(_ ticked: Set<Int>, _ summary: String) -> FindingsRefusal? {
            FindingsPlan.problem(
                FindingsPlan.post(findings, ticked: ticked, summary: summary), summary: summary,
                event: .requestChanges)
        }
        #expect(problem([], " \n") == .needsSummary)
        #expect(problem([0, 3], "") == .needsSummary)
        #expect(problem([1], "") == .needsSummary)
        #expect(problem([1, 2], "\t") == .needsSummary)
        #expect(problem([0], "Please fix the loop.") == nil)
        #expect(problem([], "Please add a test.") == nil)
    }

    // Comment needs a review text or a line comment. An empty Approve is a plain approval.
    @Test func aCommentNeedsATextOrAComment() {
        let empty = FindingsPlan.post(findings, ticked: [], summary: "  ")
        #expect(FindingsPlan.problem(empty, summary: "  ", event: .comment) == .empty)
        let line = FindingsPlan.post(findings, ticked: [0], summary: "")
        #expect(FindingsPlan.problem(line, summary: "", event: .comment) == nil)
        let text = FindingsPlan.post(findings, ticked: [], summary: "Thanks.")
        #expect(FindingsPlan.problem(text, summary: "Thanks.", event: .comment) == nil)
        let offDiff = FindingsPlan.post(findings, ticked: [1], summary: "")
        #expect(FindingsPlan.problem(offDiff, summary: "", event: .comment) == nil)
        #expect(FindingsPlan.problem(empty, summary: "  ", event: .approve) == nil)
    }

    // GitHub refuses a review text or a line comment over its limit, in UTF-16 units.
    @Test func aPostOverTheLimitIsRefused() {
        let limit = ReviewResult.maxReviewBody
        #expect(limit == 65_536)
        let over = ReviewPost(body: String(repeating: "a", count: limit + 1), threads: [])
        let full = ReviewPost(body: String(repeating: "a", count: limit), threads: [])
        for event in [ReviewEvent.approve, .comment, .requestChanges] {
            #expect(FindingsPlan.problem(over, summary: over.body, event: event) == .tooLong)
            #expect(FindingsPlan.problem(full, summary: full.body, event: event) == nil)
        }
        // One emoji is two UTF-16 units.
        let wide = ReviewPost(body: String(repeating: "a", count: limit - 1) + "😀", threads: [])
        #expect(FindingsPlan.problem(wide, summary: wide.body, event: .comment) == .tooLong)
        let thread = DraftComment(
            path: "src/a.swift", line: 1, side: .right,
            body: String(repeating: "a", count: limit + 1))
        let longThread = ReviewPost(body: "Summary.", threads: [thread])
        #expect(
            FindingsPlan.problem(longThread, summary: "Summary.", event: .requestChanges)
                == .tooLong)
    }

    // The first rule that holds wins: closed, own PR, no offered mark, a moved head, then a
    // pending review of the user.
    @Test func theFreshCheckRefusesAClosedPRAMovedHeadOrAPendingReview() throws {
        func refusal(_ read: FreshPR, _ mark: RecommendationMark) -> FindingsRefusal? {
            FindingsPlan.refusal(read, viewer: Rows.viewer, mark: mark)
        }
        let moved = try ReviewData.commit(ReviewData.oldHex)
        let mine = try pending()
        let closed = try fresh(author: Rows.viewer, state: .merged, head: moved, pending: mine)
        #expect(refusal(closed, try claudeMark()) == .closed)
        let own = try fresh(author: Rows.viewer.uppercased(), head: moved, pending: mine)
        #expect(refusal(own, try claudeMark()) == .ownPR)
        let changed = try fresh(head: moved, pending: mine)
        #expect(refusal(changed, try claudeMark(.comment)) == .notOffered)
        #expect(refusal(try fresh(), try claudeMark(review: "PRR_claude")) == .notOffered)
        #expect(refusal(try fresh(), try claudeMark(.requestChanges, deleted: true)) == .notOffered)
        #expect(refusal(changed, try claudeMark()) == .headMoved)
        #expect(refusal(try fresh(pending: mine), try claudeMark()) == .pendingReview)
        #expect(refusal(try fresh(), try claudeMark()) == nil)
    }

    // The write goes only to the PR of the row, on the reviewed commit, with no pending review
    // and no draft, and with only the line comments of the findings of the mark.
    @Test func theWriteRefusesAThreadThatIsNotAFinding() throws {
        let pr = try ReviewData.pr()
        let click = UserClick()
        let mark = try claudeMark()
        let post = FindingsPlan.post(mark.findings, ticked: [0, 1, 3], summary: "Summary.")
        #expect(FindingsPlan.threadsAreFindings(post, of: mark))
        for event in [DraftEvent.comment, .requestChanges] {
            #expect(
                FindingsPlan.write(
                    try fresh(), pr: pr, mark: mark, post: post, event: event, click: click)
                    == .reviewCommit(
                        pr: try ReviewData.node("PR_node7"), commit: try ReviewData.commit(),
                        event: ReviewEvent(event), body: post.body, threads: post.threads,
                        click: click))
        }
        func write(_ post: ReviewPost, _ read: FreshPR, mark: RecommendationMark? = nil) throws
            -> GitHubWrite?
        {
            FindingsPlan.write(
                read, pr: pr, mark: try mark ?? claudeMark(), post: post, event: .comment,
                click: click)
        }
        // An edited line comment, or one on another line, is not a finding of the mark.
        var edited = post
        edited.threads[0].body += " Also delete the file."
        #expect(try write(edited, try fresh()) == nil)
        var moved = post
        moved.threads[0].line = 13
        #expect(try write(moved, try fresh()) == nil)
        // One finding never gives two line comments.
        var twice = post
        twice.threads.append(post.threads[0])
        #expect(!FindingsPlan.threadsAreFindings(twice, of: mark))
        // A finding off the diff never gives a line comment.
        let place = try #require(mark.findings[1].place)
        let offDiff = ReviewPost(body: "", threads: [place.comment(mark.findings[1].body)])
        #expect(!FindingsPlan.threadsAreFindings(offDiff, of: mark))
        // Another PR, a pending review of the user, a moved head or a mark with a draft.
        #expect(try write(post, try fresh(url: "https://github.com/Owner-A/Repo-A/pull/8")) == nil)
        #expect(try write(post, try fresh(pending: try pending())) == nil)
        #expect(try write(post, try fresh(head: try ReviewData.commit(ReviewData.oldHex))) == nil)
        #expect(try write(post, try fresh(), mark: try claudeMark(review: "PRR_claude")) == nil)
    }

    // GitHub saved the review when its answer gives a review in the state of the event. An answer
    // with no review is unknown.
    @Test func theOutcomeNeedsTheStateOfTheEvent() throws {
        func review(_ event: ReviewEvent) throws -> GitHubWrite {
            .reviewCommit(
                pr: try ReviewData.node("PR_node7"), commit: try ReviewData.commit(),
                event: event, body: "Summary.", threads: [], click: UserClick())
        }
        let (comment, changes) = (try review(.comment), try review(.requestChanges))
        func outcome(_ write: GitHubWrite, _ event: DraftEvent, state: String?) -> FindingsRefusal?
        {
            FindingsPlan.outcome(DraftAnswers.written(write, state: state), of: write, event: event)
        }
        #expect(outcome(comment, .comment, state: "COMMENTED") == nil)
        #expect(outcome(changes, .requestChanges, state: "CHANGES_REQUESTED") == nil)
        #expect(outcome(comment, .comment, state: "CHANGES_REQUESTED") == .notAsSent)
        #expect(outcome(changes, .requestChanges, state: "COMMENTED") == .notAsSent)
        #expect(outcome(comment, .comment, state: "APPROVED") == .notAsSent)
        #expect(outcome(comment, .comment, state: nil) == .notAsSent)
        #expect(FindingsPlan.outcome(Data("{}".utf8), of: comment, event: .comment) == .unknown)
        let noID = DraftAnswers.written(comment, id: "", state: "COMMENTED")
        #expect(FindingsPlan.outcome(noID, of: comment, event: .comment) == .unknown)
    }

    // A write that GitHub can have made is unknown, and a poll shows the truth. A refusal of
    // GitHub with its line has the Event log for the details.
    @Test func aFailedWriteSaysIfTheReviewMayHaveGone() {
        #expect(FindingsPlan.failure(.unknownOutcome("HTTP 502")) == .unknown)
        #expect(FindingsPlan.failure(.timedOut) == .unknown)
        #expect(FindingsPlan.failure(.badAnswer) == .unknown)
        #expect(FindingsPlan.failure(.refused("Can not comment")) == .refusedByGitHub)
        #expect(FindingsPlan.failure(.refused("")) == .notSent(.refused("")))
        #expect(FindingsPlan.failure(.notLoggedIn) == .notSent(.notLoggedIn))
        let changed: [FindingsRefusal] = [
            .unknown, .notAsSent, .approveRefused(.unknown), .approveRefused(.notApproved),
        ]
        #expect(changed.allSatisfy { $0.mayHaveChanged })
        let unchanged: [FindingsRefusal] = [
            .notOffered, .busy, .refusedByGitHub, .notSent(.notLoggedIn), .guardRefused,
            .readFailed(.timedOut), .approveRefused(.ciRunning), .approveRefused(.busy),
        ]
        #expect(!unchanged.contains { $0.mayHaveChanged })
    }

    // The texts of the error line of the findings form, as the user approved them.
    @Test func eachRefusalHasTheApprovedText() {
        let texts: [(FindingsRefusal, String)] = [
            (
                .notOffered,
                "You can't send this review right now, its row in the Reviews panel shows why."
            ),
            (.busy, "A review of this pull request is still sending, so try again once it's done."),
            (.closed, "This pull request has been closed or merged, so the review wasn't sent."),
            (.ownPR, "You can't review your own pull request, so the review wasn't sent."),
            (
                .headMoved,
                "This pull request has changed since Claude reviewed it, so you'll need a new "
                    + "review before sending."
            ),
            (.pendingReview, ApproveRefusal.pendingReview.message),
            (.needsSummary, DraftRefusal.needsSummary.message),
            (.empty, "Add a summary or tick a finding before you comment."),
            (
                .tooLong,
                "This review is too long for GitHub, so untick some findings or shorten the "
                    + "summary."
            ),
            (
                .guardRefused,
                "This review didn't match Claude's findings, so Bifrost stopped it and nothing was "
                    + "posted."
            ),
            (
                .readFailed(.timedOut),
                "Bifrost couldn't load this pull request from GitHub, so the review wasn't sent. "
                    + GitHubError.timedOut.message
            ),
            (.refusedByGitHub, "GitHub rejected the review, check the Event log for details."),
            (
                .unknown,
                "Bifrost can't tell whether GitHub saved your review, so click Refresh to check."
            ),
            (
                .notAsSent,
                "GitHub saved the review, but it doesn't match what you sent, so check it on "
                    + "GitHub."
            ),
            (
                .notSent(.notLoggedIn),
                "Bifrost couldn't send this review. " + GitHubError.notLoggedIn.message
            ),
            (.approveRefused(.ciRunning), ApproveRefusal.ciRunning.message),
        ]
        for (refusal, text) in texts {
            #expect(refusal.message == text)
        }
        #expect(DraftRefusal.needsSummary.message == "Add a summary to request changes.")
        #expect(
            ApproveRefusal.busy.message
                == "This pull request is still being approved, so try again once it's done.")
        #expect(!ApproveRefusal.busy.mayHaveApproved)
    }
}
