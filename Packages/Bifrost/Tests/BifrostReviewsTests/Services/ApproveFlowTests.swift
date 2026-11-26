// The Approve button (docs/behaviour/reviews.md, "Approve") on FakeGitHub: the fresh read before
// the write, the refusals, the one write of each kind of mark, and the progress of an approval on
// the manual clock. No test reaches GitHub.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

@MainActor
@Suite("the Approve button", .testTimeLimit)
struct ApproveFlowTests {
    private func approve(_ f: FlowFixture, panel: PanelApproval? = nil) async -> ApproveRefusal? {
        do throws(ApproveRefusal) {
            try await f.approver.approve(f.pr, panel: panel, click: UserClick())
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
        #expect(f.writes.running.isEmpty)
        await f.end()
    }

    // A head that is not the reviewed commit refuses the approval and writes nothing.
    @Test func aMovedHeadRefusesTheApproval() async throws {
        let f = try await FlowFixture()
        await f.setMark(try f.mark(.approve, draft: false))
        f.answerFresh(head: try ReviewData.commit(ReviewData.oldHex), pending: .some(nil))
        #expect(await approve(f) == .headMoved)
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

    // A review that GitHub saves in another state is not an approval, and the next poll shows
    // the truth.
    @Test func aReviewInAnotherStateIsNotAnApproval() async throws {
        let f = try await FlowFixture()
        await f.setMark(try f.mark(.approve, draft: false))
        f.answerFresh(pending: .some(nil))
        let write = GitHubWrite.approveCommit(
            pr: try ReviewData.node("PR_node7"), commit: f.head, click: UserClick())
        f.answerWrite(write, state: "APPROVED")
        #expect(await approve(f) == nil)
        #expect(f.written == [write])
        f.answerWrite(write, state: "COMMENTED")
        #expect(await approve(f) == .notApproved)
        #expect(f.polls.values.count == 2 && f.written == [write, write])
        await f.end()
    }

    // Approve never submits a draft review: Claude's old Approve draft opens in the Review panel
    // (ReviewsPanelModel.approve). So a call for a mark with a draft reads nothing and writes
    // nothing, also when the draft is the pending review on the head, and so does a panel
    // approval of that mark.
    @Test func aMarkWithADraftIsNotApprovedByTheButton() async throws {
        let f = try await FlowFixture()
        let mark = try f.mark(.approve)
        await f.setMark(mark)
        f.answerFresh()
        #expect(await approve(f) == .notSuggested)
        let panel = PanelApproval(mark: mark, post: ReviewPost(body: "", threads: []))
        #expect(await approve(f, panel: panel) == .notSuggested)
        #expect(f.github.calls.isEmpty && f.polls.values.isEmpty)
        #expect(f.writes.progress(f.pr) == nil)
        await f.end()
    }

    // While a review write of the findings form of the PR may have gone, Approve sends nothing
    // until a poll that started after that result gives a good answer. A click asks for a poll
    // and says so. Then Approve works again.
    @Test func approveWaitsForThePollOfAnUnsureReview() async throws {
        let f = try await FlowFixture()
        await f.setMark(try f.mark(.approve, draft: false))
        f.answerFresh(pending: .some(nil))
        let write = GitHubWrite.approveCommit(
            pr: try ReviewData.node("PR_node7"), commit: f.head, click: UserClick())
        f.answerWrite(write, state: "APPROVED")
        f.writes.mayHaveGone(f.pr)
        #expect(await approve(f) == .waitsForPoll)
        #expect(f.github.calls.isEmpty && f.polls.values.count == 1)
        #expect(f.writes.progress(f.pr) == nil)
        #expect(
            ApproveRefusal.waitsForPoll.message
                == "Bifrost can't tell whether GitHub saved your review, so click Refresh to "
                + "check.")
        #expect(!ApproveRefusal.waitsForPoll.mayHaveApproved)
        await f.pollAnswered()
        #expect(await approve(f) == nil)
        #expect(f.written == [write])
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
    // for a poll and leaves the line of gh in the Event log. A refusal of GitHub says so too. A
    // plain approval does not make the PR wait for a poll: a second click reads the PR first.
    @Test func anUnknownResultIsNotSentAgain() async throws {
        let f = try await FlowFixture()
        await f.setMark(try f.mark(.approve, draft: false))
        f.answerFresh(pending: .some(nil))
        let write = GitHubWrite.approveCommit(
            pr: try ReviewData.node("PR_node7"), commit: f.head, click: UserClick())
        f.github.answers[FakeGitHub.key(write)] = .failure(.unknownOutcome("HTTP 502"))
        #expect(await approve(f) == .unknown)
        #expect(f.written == [write] && f.polls.values.count == 1)
        // Only an approval of the Review panel makes the PR wait for a poll.
        #expect(!f.writes.waitsForPoll(f.pr))
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
        #expect(f.writes.running == [f.pr])
        // The gate opens only once the second call waits.
        let opener = Task { gate.open() }
        #expect(await approve(f) == .refusedByGitHub)
        #expect(await first.value == .refusedByGitHub)
        await opener.value
        #expect(f.written == [write] && f.writes.running.isEmpty)
        await f.end()
    }

    // The progress of a click: approving while the write runs, then approved when GitHub
    // confirmed it, for the time of the hold and not less. At the end of the hold the progress
    // goes, and the rows build again one time.
    // After GitHub confirmed the approval, reviewedHere has the PR with its head until an answer
    // shows the approval. A PR with a new head and a PR that left the answer leave it too.
    @Test func aConfirmedApprovalStaysUntilAnAnswerShowsIt() async throws {
        let f = try await FlowFixture()
        await f.setMark(try f.mark(.approve, draft: false))
        f.answerFresh(pending: .some(nil))
        let write = GitHubWrite.approveCommit(
            pr: try ReviewData.node("PR_node7"), commit: f.head, click: UserClick())
        f.answerWrite(write, state: "APPROVED")
        var request = try Rows.pull(f.pr.text)
        request.headSHA = f.head.hex
        let behind = Rows.answer(toReview: [request])
        let approved = ConfirmedReview(.approve, head: f.head.hex)
        #expect(f.writes.reviewedHere(behind).isEmpty)
        try await f.approver.approve(f.pr, click: UserClick())
        #expect(f.writes.reviewedHere(behind) == [f.pr: approved])
        #expect(f.writes.reviewedHere(behind) == [f.pr: approved])
        // An answer that shows the approval: the polls decide from then on.
        var shown = request
        shown.viewerReviews = [
            ViewerOpinion(state: .approved, commit: f.head.hex, submittedAt: Rows.now)
        ]
        #expect(f.writes.reviewedHere(Rows.answer(toReview: [shown])).isEmpty)
        #expect(f.writes.reviewedHere(behind).isEmpty)
        // A new head.
        try await f.approver.approve(f.pr, click: UserClick())
        var moved = request
        moved.headSHA = ReviewData.oldHex
        #expect(f.writes.reviewedHere(Rows.answer(toReview: [moved])).isEmpty)
        // A PR that left the answer.
        try await f.approver.approve(f.pr, click: UserClick())
        #expect(f.writes.reviewedHere(Rows.answer()).isEmpty)
        await f.end()
    }

    @Test func theProgressGoesFromApprovingToApprovedAndEndsAfterTheHold() async throws {
        let f = try await FlowFixture()
        await f.setMark(try f.mark(.approve, draft: false))
        f.answerFresh(pending: .some(nil))
        let write = GitHubWrite.approveCommit(
            pr: try ReviewData.node("PR_node7"), commit: f.head, click: UserClick())
        f.answerWrite(write, state: "APPROVED")
        #expect(f.writes.progress(f.pr) == nil && f.writes.held.isEmpty)
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
        #expect(f.writes.progress(f.pr) == .running(.approve))
        #expect(f.writes.running == [f.pr] && f.writes.held == [f.pr])
        gate.open()
        #expect(await click.value == nil)
        #expect(f.writes.progress(f.pr) == .confirmed(.approve))
        #expect(f.writes.running.isEmpty && f.writes.held == [f.pr])
        #expect(f.progressEnds.values.isEmpty)
        let hold = try #require(f.writes.holdTask(f.pr))
        #expect(await f.clock.waitForSleepers(1))
        f.clock.advance(by: ReviewWrites.hold - .milliseconds(1))
        #expect(f.clock.sleeperCount == 1 && f.writes.progress(f.pr) == .confirmed(.approve))
        f.clock.advance(by: .milliseconds(1))
        await hold.value
        #expect(f.writes.progress(f.pr) == nil && f.writes.held.isEmpty)
        #expect(f.progressEnds.values.count == 1)
        #expect(f.written == [write] && ReviewWrites.hold == .seconds(3))
        await f.end()
    }

    // An approval from the Review panel is the one review write of its post: the ticked findings
    // and the summary, with the event Approve. The row shows approving while it runs, then
    // approved. The mark stays.
    @Test func aPanelApprovalPostsOnlyTheTickedFindings() async throws {
        let f = try await FlowFixture()
        let mark = f.findingsMark()
        await f.setMark(mark)
        f.answerFresh(pending: .some(nil))
        let post = FindingsPlan.post(mark.findings, ticked: [0, 1], summary: "Looks good.")
        let write = GitHubWrite.reviewCommit(
            pr: try ReviewData.node("PR_node7"), commit: f.head, event: .approve, body: post.body,
            threads: post.threads, click: UserClick())
        f.answerWrite(write, state: "APPROVED")
        let gate = TestGate()
        defer { gate.openAll() }
        f.github.onWrite = { _ in await gate.pass() }
        let (approver, pr) = (f.approver, f.pr)
        let click = Task { () async -> ApproveRefusal? in
            do throws(ApproveRefusal) {
                try await approver.approve(
                    pr, panel: PanelApproval(mark: mark, post: post), click: UserClick())
                return nil
            } catch {
                return error
            }
        }
        #expect(await gate.waitUntilHolding(1))
        #expect(f.writes.progress(f.pr) == .running(.approve))
        gate.open()
        #expect(await click.value == nil)
        #expect(f.written == [write])
        #expect(f.reads == [DraftQueries.freshName])
        #expect(f.writes.progress(f.pr) == .confirmed(.approve))
        #expect(f.polls.values.count == 1 && f.savedMark == mark)
        await f.end()
    }

    // The panel approves only the mark that it showed: an older mark, or a mark that changes
    // while the fresh read runs, sends nothing.
    @Test func aPanelApprovalOfAnOlderMarkIsRefused() async throws {
        let f = try await FlowFixture()
        let old = f.findingsMark(at: Rows.at(-90))
        let mark = f.findingsMark()
        await f.setMark(mark)
        f.answerFresh(pending: .some(nil))
        let post = FindingsPlan.post(old.findings, ticked: [0], summary: "")
        #expect(await approve(f, panel: PanelApproval(mark: old, post: post)) == .notSuggested)
        #expect(f.github.calls.isEmpty)
        let (store, pr) = (f.store, f.pr)
        let newer = f.findingsMark(at: Rows.at(-1))
        f.github.onRead = { _ in
            await store.update { $0.prs[pr]?.recommendation = newer }
        }
        #expect(await approve(f, panel: PanelApproval(mark: mark, post: post)) == .notSuggested)
        #expect(f.reads == [DraftQueries.freshName] && f.written.isEmpty)
        await f.end()
    }

    // A panel approval while another write of the PR runs sends nothing and says so: it never
    // waits for a plain approval, because that approval does not post what the panel showed.
    @Test func aPanelApprovalNeverJoinsARunningApproval() async throws {
        let f = try await FlowFixture()
        let mark = f.findingsMark()
        await f.setMark(mark)
        f.answerFresh(pending: .some(nil))
        let plain = GitHubWrite.approveCommit(
            pr: try ReviewData.node("PR_node7"), commit: f.head, click: UserClick())
        f.answerWrite(plain, state: "APPROVED")
        let gate = TestGate()
        defer { gate.openAll() }
        f.github.onWrite = { _ in await gate.pass() }
        let (approver, writes, pr) = (f.approver, f.writes, f.pr)
        let first = Task { () async -> ApproveRefusal? in
            do throws(ApproveRefusal) {
                try await approver.approve(pr, click: UserClick())
                return nil
            } catch {
                return error
            }
        }
        #expect(await gate.waitUntilHolding(1))
        let panel = PanelApproval(
            mark: mark, post: FindingsPlan.post(mark.findings, ticked: [0], summary: ""))
        #expect(await approve(f, panel: panel) == .busy)
        gate.open()
        #expect(await first.value == nil)
        #expect(f.written == [plain])
        // While a send of the PR runs, a panel approval is busy too.
        let head = f.head.hex
        let sending = TestGate()
        defer { sending.openAll() }
        let send = Task { () async -> DraftRefusal? in
            do throws(DraftRefusal) {
                try await writes.send(pr, .comment, busy: .busy) {
                    () async throws(DraftRefusal) -> String in
                    await sending.pass()
                    return head
                }
                return nil
            } catch {
                return error
            }
        }
        #expect(await sending.waitUntilHolding(1))
        #expect(await approve(f, panel: panel) == .busy)
        sending.open()
        #expect(await send.value == nil)
        #expect(f.written == [plain])
        #expect(
            ApproveRefusal.busy.message
                == "This pull request is still being approved, so try again once it's done.")
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
        #expect(f.writes.progress(f.pr) == nil && f.writes.held.isEmpty)
        f.github.answers[FakeGitHub.key(write)] = .failure(.unknownOutcome("HTTP 502"))
        #expect(await approve(f) == .unknown)
        #expect(f.writes.progress(f.pr) == nil)
        f.answerFresh(head: try ReviewData.commit(ReviewData.oldHex), pending: .some(nil))
        #expect(await approve(f) == .headMoved)
        #expect(f.writes.progress(f.pr) == nil)
        #expect(f.progressEnds.values.count == 3 && f.clock.sleeperCount == 0)
        await f.end()
    }
}
