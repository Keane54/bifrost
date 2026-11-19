// The Approve button (docs/behaviour/reviews.md, "Approve") on FakeGitHub: the fresh read before
// the write, the refusals, the one write of each kind of mark, and the progress of an approval on
// the manual clock. No test reaches GitHub.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

@MainActor
@Suite("the Approve button", .timeLimit(.minutes(1)))
struct ApproveFlowTests {
    private func approve(_ f: FlowFixture) async -> ApproveRefusal? {
        do throws(ApproveRefusal) {
            try await f.approver.approve(f.pr, click: UserClick())
            return nil
        } catch {
            return error
        }
    }

    // The click reads the PR from GitHub first, and only then writes. A read that fails writes
    // nothing and says why; the Event log gets the line of GitHub.
    @Test func anApprovalReadsThePRAgainFirst() async throws {
        let f = try await FlowFixture()
        await f.setMark(try f.mark(.approve, draft: false))
        f.github.answers[DraftQueries.freshName] = .failure(.refused("Not Found"))
        #expect(await approve(f) == .readFailed(.refused("Not Found")))
        #expect(f.reads == [DraftQueries.freshName] && f.written.isEmpty)
        #expect(f.lines.values.count == 1)
        f.answerFresh(pending: .some(nil))
        let write = GitHubWrite.approveCommit(
            pr: try ReviewData.node("PR_node7"), commit: f.head, click: UserClick())
        f.answerWrite(write, state: "APPROVED")
        #expect(await approve(f) == nil)
        #expect(
            f.github.calls.suffix(2)
                == [.read(DraftQueries.freshName), .write(write)])
        // The next poll shows the approval.
        #expect(f.polls.values.count == 1)
        #expect(f.approver.running.isEmpty)
        await f.end()
    }

    // A head that is not the reviewed commit refuses the approval and writes nothing, and so
    // does Claude's draft on another commit.
    @Test func aMovedHeadRefusesTheApproval() async throws {
        let f = try await FlowFixture()
        await f.setMark(try f.mark(.approve, draft: false))
        f.answerFresh(head: try ReviewData.commit(ReviewData.oldHex), pending: .some(nil))
        #expect(await approve(f) == .headMoved)
        await f.setMark(try f.mark(.approve))
        f.answerFresh(
            pending: DraftAnswers.Pending(
                id: FlowFixture.claudeReview, commit: try ReviewData.commit(ReviewData.oldHex)))
        #expect(await approve(f) == .draftOtherCommit)
        #expect(f.written.isEmpty && f.polls.values.isEmpty)
        #expect(
            ApproveRefusal.headMoved.message
                == "This pull request changed after Claude's review, so Bifrost didn't approve "
                + "it. It needs a new review.")
        await f.end()
    }

    // The user can't approve their own PR, or a closed one. Running or failing CI, an approval
    // of the head, and a pending review of the user each refuse too. None of them writes.
    @Test func anOwnPRIsRefused() async throws {
        let f = try await FlowFixture()
        await f.setMark(try f.mark(.approve, draft: false))
        f.answerFresh(author: FlowFixture.viewer.uppercased(), pending: .some(nil))
        #expect(await approve(f) == .ownPR)
        f.answerFresh(state: "MERGED", pending: .some(nil))
        #expect(await approve(f) == .closed)
        f.answerFresh(ci: "PENDING", pending: .some(nil))
        #expect(await approve(f) == .ciRunning)
        f.answerFresh(ci: "FAILURE", pending: .some(nil))
        #expect(await approve(f) == .ciFailing)
        f.answerFresh(
            pending: .some(nil),
            opinions: [.init(state: "APPROVED", commit: f.head, at: Rows.at(-5))])
        #expect(await approve(f) == .alreadyApproved)
        f.answerFresh(pending: DraftAnswers.Pending(id: "PRR_mine", commit: f.head))
        #expect(await approve(f) == .pendingReview)
        #expect(f.written.isEmpty)
        #expect(ApproveRefusal.ownPR.message == "You can't approve your own pull request.")
        await f.end()
    }

    // A mark with Claude's draft submits that draft as the approval. A review that GitHub saves
    // in another state is not an approval, and the next poll shows the truth.
    @Test func aDraftIsSubmittedAsTheApproval() async throws {
        let f = try await FlowFixture()
        await f.setMark(try f.mark(.approve))
        f.answerFresh()
        let write = GitHubWrite.approveDraft(
            review: try ReviewData.node(FlowFixture.claudeReview), click: UserClick())
        f.answerWrite(write, state: "APPROVED")
        #expect(await approve(f) == nil)
        #expect(f.written == [write])
        f.answerWrite(write, state: "COMMENTED")
        #expect(await approve(f) == .notApproved)
        #expect(f.polls.values.count == 2)
        // Claude's draft that is not the pending review any more: nothing goes.
        f.answerFresh(pending: DraftAnswers.Pending(id: "PRR_other", commit: f.head))
        #expect(await approve(f) == .draftMissing)
        #expect(f.written.count == 2)
        await f.end()
    }

    // A mark with no draft approves the reviewed commit with no text; a mark whose draft the user
    // deleted (Approve instead) does the same. A mark that doesn't suggest Approve, or a round
    // that waits, reads nothing and writes nothing.
    @Test func withNoDraftTheReviewedCommitIsApproved() async throws {
        let f = try await FlowFixture()
        let write = GitHubWrite.approveCommit(
            pr: try ReviewData.node("PR_node7"), commit: f.head, click: UserClick())
        f.answerFresh(pending: .some(nil))
        f.answerWrite(write, state: "APPROVED")
        await f.setMark(
            RecommendationMark(
                value: .comment, why: "", headSHA: f.head, reviewID: nil, at: Rows.at(-9),
                deleted: true))
        #expect(await approve(f) == nil)
        #expect(f.written == [write])
        await f.setMark(try f.mark(.comment))
        #expect(await approve(f) == .notSuggested)
        await f.setMark(try f.mark(.approve, draft: false))
        let pr = f.pr
        await f.store.update {
            $0.queue.append(QueueEntry(pr: pr, kind: .review, at: Rows.at(-1)))
        }
        #expect(await approve(f) == .notSuggested)
        #expect(f.reads.count == 1 && f.written == [write])
        await f.end()
    }

    // A write that GitHub can have made is never sent again by itself: the click says so, asks
    // for a poll and leaves the line of gh in the Event log. A refusal of GitHub says so too.
    @Test func anUnknownResultIsNotSentAgain() async throws {
        let f = try await FlowFixture()
        await f.setMark(try f.mark(.approve, draft: false))
        f.answerFresh(pending: .some(nil))
        let write = GitHubWrite.approveCommit(
            pr: try ReviewData.node("PR_node7"), commit: f.head, click: UserClick())
        f.github.answers[FakeGitHub.key(write)] = .failure(.unknownOutcome("HTTP 502"))
        #expect(await approve(f) == .unknown)
        #expect(f.written == [write] && f.polls.values.count == 1)
        f.github.answers[FakeGitHub.key(write)] = .failure(.refused("Can not approve"))
        #expect(await approve(f) == .refusedByGitHub)
        #expect(f.written.count == 2 && f.polls.values.count == 1)
        #expect(f.lines.values.count == 2)
        #expect(
            ApproveRefusal.unknown.message
                == "Bifrost couldn't tell if GitHub saved your approval. Click Refresh to check.")
        // A closed store writes nothing.
        await f.store.close().value
        #expect(await approve(f) == .notReady)
        #expect(f.written.count == 2)
        f.folder.remove()
    }

    // A call while an approval of the PR runs sends nothing: it waits for that approval and gives
    // its result, so Approve instead never reports an approval that didn't go.
    @Test func aSecondCallGivesTheResultOfTheRunningApproval() async throws {
        let f = try await FlowFixture()
        await f.setMark(try f.mark(.approve, draft: false))
        f.answerFresh(pending: .some(nil))
        let write = GitHubWrite.approveCommit(
            pr: try ReviewData.node("PR_node7"), commit: f.head, click: UserClick())
        f.github.answers[FakeGitHub.key(write)] = .failure(.refused("Can not approve"))
        let gate = TestGate()
        defer { gate.openAll() }
        f.github.onWrite = { _ in await gate.pass() }
        let (approver, pr) = (f.approver, f.pr)
        let first = Task { () async -> ApproveRefusal? in
            do throws(ApproveRefusal) {
                try await approver.approve(pr, click: UserClick())
                return nil
            } catch {
                return error
            }
        }
        #expect(await gate.waitUntilHolding(1))
        #expect(f.approver.running == [f.pr])
        // The gate opens only once the second call waits.
        let opener = Task { gate.open() }
        #expect(await approve(f) == .refusedByGitHub)
        #expect(await first.value == .refusedByGitHub)
        await opener.value
        #expect(f.written == [write] && f.approver.running.isEmpty)
        await f.end()
    }

    // The progress of a click: approving while the write runs, then approved when GitHub
    // confirmed it, for the time of the hold and not less. At the end of the hold the progress
    // goes, and the rows build again one time.
    @Test func theProgressGoesFromApprovingToApprovedAndEndsAfterTheHold() async throws {
        let f = try await FlowFixture()
        await f.setMark(try f.mark(.approve, draft: false))
        f.answerFresh(pending: .some(nil))
        let write = GitHubWrite.approveCommit(
            pr: try ReviewData.node("PR_node7"), commit: f.head, click: UserClick())
        f.answerWrite(write, state: "APPROVED")
        #expect(f.approver.progress(f.pr) == nil && f.approver.held.isEmpty)
        let gate = TestGate()
        defer { gate.openAll() }
        f.github.onWrite = { _ in await gate.pass() }
        let (approver, pr) = (f.approver, f.pr)
        let click = Task { () async -> ApproveRefusal? in
            do throws(ApproveRefusal) {
                try await approver.approve(pr, click: UserClick())
                return nil
            } catch {
                return error
            }
        }
        #expect(await gate.waitUntilHolding(1))
        #expect(f.approver.progress(f.pr) == .approving)
        #expect(f.approver.running == [f.pr] && f.approver.held == [f.pr])
        gate.open()
        #expect(await click.value == nil)
        #expect(f.approver.progress(f.pr) == .approved)
        #expect(f.approver.running.isEmpty && f.approver.held == [f.pr])
        #expect(f.progressEnds.values.isEmpty)
        let hold = try #require(f.approver.holdTask(f.pr))
        #expect(await f.clock.waitForSleepers(1))
        f.clock.advance(by: ApproveFlow.hold - .milliseconds(1))
        #expect(f.clock.sleeperCount == 1 && f.approver.progress(f.pr) == .approved)
        f.clock.advance(by: .milliseconds(1))
        await hold.value
        #expect(f.approver.progress(f.pr) == nil && f.approver.held.isEmpty)
        #expect(f.progressEnds.values.count == 1)
        #expect(f.written == [write] && ApproveFlow.hold == .seconds(3))
        await f.end()
    }

    // A refusal ends the progress at once, with no hold: a refusal of GitHub, a result that
    // GitHub can have saved, and a refusal before the write. Each end builds the rows again.
    @Test func aRefusalEndsTheProgressAtOnce() async throws {
        let f = try await FlowFixture()
        await f.setMark(try f.mark(.approve, draft: false))
        f.answerFresh(pending: .some(nil))
        let write = GitHubWrite.approveCommit(
            pr: try ReviewData.node("PR_node7"), commit: f.head, click: UserClick())
        f.github.answers[FakeGitHub.key(write)] = .failure(.refused("Can not approve"))
        #expect(await approve(f) == .refusedByGitHub)
        #expect(f.approver.progress(f.pr) == nil && f.approver.held.isEmpty)
        f.github.answers[FakeGitHub.key(write)] = .failure(.unknownOutcome("HTTP 502"))
        #expect(await approve(f) == .unknown)
        #expect(f.approver.progress(f.pr) == nil)
        f.answerFresh(head: try ReviewData.commit(ReviewData.oldHex), pending: .some(nil))
        #expect(await approve(f) == .headMoved)
        #expect(f.approver.progress(f.pr) == nil)
        #expect(f.progressEnds.values.count == 3 && f.clock.sleeperCount == 0)
        await f.end()
    }
}
