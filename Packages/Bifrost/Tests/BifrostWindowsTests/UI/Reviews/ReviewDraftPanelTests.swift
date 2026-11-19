// The Review panel and the Approve button of the Reviews panel (docs/behaviour/reviews.md,
// "Approve" and "The Review panel"): the controls, the error line, the one GitHub write of each
// button, with a click, and the progress of an approval on its row. The panels run on the real
// flows over a Reviews store in a temporary folder and FakeGitHub, so no test reaches GitHub. A
// close of a panel releases its body, as the canvas of the window does.
import AppKit
import BifrostFoundation
import BifrostLayout
import BifrostLook
import BifrostReviews
import BifrostSessions
import BifrostTestSupport
import Foundation
import SwiftUI
import Testing

@testable import BifrostWindows

@MainActor
private final class DraftPanelFixture {
    static let viewer = "viewer-a"

    let folder: TemporaryFolder
    let store: ReviewsStore
    let github = FakeGitHub()
    let client: GitHubClient
    let approver: ApproveFlow
    // The clock of the time that an approved row shows Approved.
    let clock = ManualClock()
    let links = ReviewsPanelLinks()
    let panels: ReviewsPanels
    let opened = Recorder<PanelID>()
    let closed = Recorder<PanelID>()
    let pr: PRKey
    let head: CommitID
    let review: NodeID
    let claudeComment: NodeID
    let userComment: NodeID
    // The To review row of the PR in the snapshot.
    var row: ReviewRow

    // Claude's draft of the value on PR 7, with Claude's comment and one that the user added on
    // GitHub; the row offers the Review panel (or Approve for an Approve mark).
    init(_ value: Recommendation = .comment) async throws {
        UITestApp.prepare()
        folder = try TemporaryFolder()
        let layout = ReviewsLayout(
            folder: URL(filePath: folder.realPath + "/reviews", directoryHint: .isDirectory))
        store = try await ReviewsStore.open(layout: layout, log: Recorder<StoreEvent>())
        client = GitHubClient(access: github)
        pr = try #require(PRKey(text: "Owner-A/Repo-A#7"))
        head = try #require(CommitID(String(repeating: "c", count: 40)))
        review = try #require(NodeID("PRR_claude"))
        claudeComment = try #require(NodeID("PRRC_claude"))
        userComment = try #require(NodeID("PRRC_user"))
        let (store, client) = (store, client)
        let approver = ApproveFlow(
            store: store, github: client, clock: clock, viewer: { Self.viewer })
        self.approver = approver
        row = ReviewRow(
            id: pr, state: .toReview(.draftReady), repo: "Repo-A", title: "Add the cache",
            status: RowLabel(text: "Draft ready", tone: .amber, tip: nil),
            approve: value == .approve ? .ready : nil,
            draft: value == .requestChanges ? .requestChanges : value == .comment ? .comment : nil)
        panels = ReviewsPanels(
            links: links, opener: FakeOpener(), look: PanelLook(), menu: { nil },
            clock: ManualClock(), now: { Date() })
        let (opened, closed, panels) = (opened, closed, panels)
        links.snapshot = { [weak self] in
            ReviewsSnapshot(phase: .on, toReview: self.map { [$0.row] } ?? [])
        }
        links.approver = { approver }
        links.makeDraftFlow = {
            DraftFlow(store: store, github: client, approver: approver, viewer: { Self.viewer })
        }
        links.openPanel = { opened.record($0) }
        links.closePanel = { [weak panels] in
            closed.record($0)
            panels?.releaseBody(for: $0)
        }
        await setMark(value)
        let pr = pr
        let review = review
        await store.update { state in
            state.drafts = [
                DraftRecord(
                    reviewID: review, pr: pr, path: "src/a.swift", line: 11, body: "Use <.",
                    at: Date(timeIntervalSince1970: 1_794_312_000))
            ]
        }
        answerFresh()
        github.answers[DraftQueries.draftName] = .success(
            DraftAnswers.draft(
                "PRR_claude", body: "Summary.", commit: head,
                comments: [
                    DraftRead.Comment(
                        id: claudeComment, path: "src/a.swift", line: 11, body: "Use <."),
                    DraftRead.Comment(id: userComment, path: "src/b.swift", line: 3, body: "Mine."),
                ]))
        github.answers[ReviewQueries.reviewName] = .success(DraftAnswers.reviewNow(commit: head))
    }

    // Claude's mark of the value on the head, with its draft review.
    func setMark(_ value: Recommendation) async {
        let mark = RecommendationMark(
            value: value, why: "Two small bugs.", headSHA: head, reviewID: review,
            at: Date(timeIntervalSince1970: 1_794_312_000))
        let pr = pr
        await store.update { state in
            var prState = state.prs[pr] ?? PRState()
            prState.recommendation = mark
            state.prs[pr] = prState
        }
    }

    // The fresh read: Claude's draft is the pending review on the head, unless pending is false.
    func answerFresh(head: CommitID? = nil, pending: Bool = true) {
        github.answers[DraftQueries.freshName] = .success(
            DraftAnswers.fresh(
                pr, head: head ?? self.head,
                pending: pending ? DraftAnswers.Pending(id: "PRR_claude", commit: self.head) : nil))
    }

    func answer(_ write: GitHubWrite, state: String? = nil) {
        github.answers[FakeGitHub.key(write)] = .success(DraftAnswers.written(write, state: state))
    }

    var draft: ReviewDraftPanels { panels.draft }

    // Open the Review panel and wait for the read of the draft.
    func open() async {
        draft.open(pr)
        await draft.task?.value
    }

    var written: [GitHubWrite] {
        github.calls.compactMap { if case .write(let write) = $0 { write } else { nil } }
    }

    // Move the clock to the end of the time that the approved row shows Approved, and wait for
    // the end of the progress.
    func endHold() async {
        let hold = approver.holdTask(pr)
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: ApproveFlow.hold)
        await hold?.value
    }

    func end() async {
        panels.releaseBody(for: .reviewDraft)
        await store.close().value
        folder.remove()
    }
}

@MainActor
@Suite("the Review panel", .serialized, .timeLimit(.minutes(1)), .tags(.window))
struct ReviewDraftPanelTests {
    // Comment opens the panel for the PR, which reads the draft: Claude's suggestion, the summary
    // and the comments, "Send as" set to Claude's suggestion. The buttons act while the row
    // offers the draft; a PR that changed allows only Discard draft, and a row that no longer
    // offers the draft allows nothing.
    @Test func theControlsFollowTheDraft() async throws {
        let f = try await DraftPanelFixture(.requestChanges)
        let model = try #require(f.panels.body(for: .reviews) as? ReviewsHost).rootView.model
        model.choose(.requestChanges, for: f.pr)
        #expect(f.opened.values == [.reviewDraft] && f.draft.pr == f.pr)
        #expect(f.draft.body(for: .reviewDraft) != nil)
        #expect(f.panels.titleSuffix(for: .reviewDraft) == "Owner-A/Repo-A #7")
        await f.draft.task?.value
        let flow = try #require(f.draft.flow)
        #expect(flow.shown?.recommendation == .requestChanges && flow.summary == "Summary.")
        #expect(flow.comments.map(\.yours) == [false, true])
        #expect(f.draft.event == .requestChanges)
        #expect(f.draft.canSend && f.draft.canDiscard && !f.draft.isLocked)
        #expect(f.draft.yoursCount == 1)
        #expect(
            f.draft.confirmText(.discard)
                == "Discard draft also deletes the comment you added to this draft on GitHub.")
        // The row no longer offers the draft: the panel is locked.
        f.row.draft = nil
        #expect(f.draft.isLocked && !f.draft.canSend && !f.draft.canDiscard)
        f.row.draft = .requestChanges
        // A PR that changed after the review allows only Discard draft. After a close, the next
        // open reads the draft again.
        let moved = try #require(CommitID(String(repeating: "d", count: 40)))
        f.answerFresh(head: moved)
        f.panels.releaseBody(for: .reviewDraft)
        await f.open()
        #expect(f.draft.flow?.shown?.headMoved == true)
        #expect(!f.draft.canSend && f.draft.canDiscard)
        #expect(f.written.isEmpty)
        // A close drops the flow and its edits.
        f.panels.releaseBody(for: .reviewDraft)
        #expect(f.draft.flow == nil && f.draft.pr == nil)
        await f.end()
    }

    // A refusal shows in the error line until the user closes it, and the edits stay. An open that
    // fails says why in place of the draft.
    @Test func theErrorLineShowsTheReason() async throws {
        let f = try await DraftPanelFixture()
        f.github.answers[DraftQueries.freshName] = .failure(.refused("Not Found"))
        await f.open()
        #expect(f.draft.flow?.shown == nil)
        #expect(f.draft.error == DraftRefusal.readFailed(.refused("Not Found")).message)
        f.draft.closeError()
        #expect(f.draft.error == nil)
        // An open that failed shows no draft, so the next open reads the draft again.
        f.answerFresh()
        await f.open()
        let flow = try #require(f.draft.flow)
        flow.summary = ""
        f.draft.event = .requestChanges
        f.draft.send(click: UserClick())
        await f.draft.task?.value
        #expect(f.draft.error == "Add a summary to request changes.")
        #expect(f.closed.values.isEmpty && flow.summary.isEmpty && f.written.isEmpty)
        await f.end()
    }

    // Each button gives GitHub its one write, with the click of the user: Send review submits the
    // draft as it is, Discard draft deletes it (after the confirm for the user's comment), and
    // Approve instead deletes it and approves the head. Each one that worked closes the panel. The
    // Approve button of a row approves Claude's Approve draft.
    @Test func eachButtonSendsItsOneWrite() async throws {
        let f = try await DraftPanelFixture()
        let submit = GitHubWrite.submitDraft(review: f.review, event: .comment, click: UserClick())
        f.answer(submit, state: "COMMENTED")
        await f.open()
        f.draft.send(click: UserClick())
        await f.draft.task?.value
        #expect(f.written == [submit])
        #expect(f.closed.values == [.reviewDraft])
        // Discard draft asks first, because the draft holds a comment of the user.
        await f.setMark(.comment)
        let discard = GitHubWrite.discardDraft(review: f.review, click: UserClick())
        f.answer(discard)
        await f.open()
        f.draft.discard(click: UserClick())
        #expect(f.draft.confirm == .discard && f.written.count == 1)
        f.draft.keepDraft()
        #expect(f.draft.confirm == nil)
        f.draft.discard(click: UserClick())
        f.draft.discard(click: UserClick())
        await f.draft.task?.value
        #expect(f.written == [submit, discard])
        #expect(f.closed.values.count == 2)
        // Approve instead: the delete, then the approval of the head with no text.
        await f.setMark(.comment)
        let approve = GitHubWrite.approveCommit(
            pr: try #require(NodeID("PR_node7")), commit: f.head, click: UserClick())
        f.answer(approve, state: "APPROVED")
        await f.open()
        f.github.answers[DraftQueries.freshName] = nil
        f.github.queued[DraftQueries.freshName] = [
            .success(
                DraftAnswers.fresh(
                    f.pr, head: f.head,
                    pending: DraftAnswers.Pending(id: "PRR_claude", commit: f.head))),
            .success(DraftAnswers.fresh(f.pr, head: f.head)),
        ]
        f.draft.approveInstead(click: UserClick())
        f.draft.approveInstead(click: UserClick())
        await f.draft.task?.value
        #expect(f.written == [submit, discard, discard, approve])
        #expect(f.closed.values.count == 3)
        // The row shows Approved after Approve instead too, until the end of the hold.
        #expect(f.approver.progress(f.pr) == .approved)
        await f.endHold()
        // The Approve button of a row with Claude's Approve draft submits that draft.
        await f.setMark(.approve)
        f.row.approve = .ready
        f.row.draft = nil
        f.answerFresh()
        let approveDraft = GitHubWrite.approveDraft(review: f.review, click: UserClick())
        f.answer(approveDraft, state: "APPROVED")
        let model = try #require(f.panels.body(for: .reviews) as? ReviewsHost).rootView.model
        #expect(ReviewsMenu.buttons(f.row) == [.approve])
        #expect(model.menuItems(f.pr)?.contains(.approve) == true)
        model.approve(f.pr, click: UserClick())
        await model.approval?.value
        #expect(f.written.last == approveDraft && f.written.count == 5)
        #expect(model.error == nil)
        // A refusal of the approval shows in the error line of the Reviews panel.
        await f.endHold()
        f.answerFresh(pending: false)
        model.approve(f.pr, click: UserClick())
        await model.approval?.value
        #expect(model.error == ApproveRefusal.draftMissing.message)
        #expect(f.written.count == 5)
        f.panels.releaseBody(for: .reviews)
        await f.end()
    }

    // The row shows the progress of its approval in the place of its buttons. While the write
    // runs, the row shows Approving, the menu has no Approve, and a second click writes nothing.
    // GitHub's answer gives Approved until the end of the hold, also when a refresh changes the
    // rows or drops the row. After the hold, the row has its buttons again. A refusal ends the
    // progress at once, and the reason shows in the error line.
    @Test func theRowShowsTheProgressOfItsApproval() async throws {
        let f = try await DraftPanelFixture(.approve)
        let write = GitHubWrite.approveDraft(review: f.review, click: UserClick())
        f.answer(write, state: "APPROVED")
        let gate = TestGate()
        defer { gate.openAll() }
        f.github.onWrite = { _ in await gate.pass() }
        let model = try #require(f.panels.body(for: .reviews) as? ReviewsHost).rootView.model
        #expect(model.approveProgress(f.pr) == nil && model.isEnabled(.approve, f.row))
        model.approve(f.pr, click: UserClick())
        let first = try #require(model.approval)
        #expect(await gate.waitUntilHolding(1))
        #expect(model.approveProgress(f.pr) == .approving)
        #expect(!model.isEnabled(.approve, f.row))
        #expect(model.menuItems(f.pr) == [.openOnGitHub])
        model.approve(f.pr, click: UserClick())
        model.choose(.approve, for: f.pr)
        #expect(model.approval == first)
        // A refresh of the rows keeps the progress.
        f.row.title = "Add the cache, part 2"
        #expect(model.approveProgress(f.pr) == .approving)
        gate.open()
        await first.value
        #expect(f.written == [write] && model.error == nil)
        #expect(model.approveProgress(f.pr) == .approved)
        #expect(model.menuItems(f.pr) == [.openOnGitHub])
        let row = f.row
        f.row.status = RowLabel(text: "You approved", tone: .green, tip: nil)
        f.row.approve = nil
        #expect(model.approveProgress(f.pr) == .approved)
        f.row = row
        #expect(f.clock.sleeperCount == 1)
        await f.endHold()
        #expect(model.approveProgress(f.pr) == nil)
        #expect(model.isEnabled(.approve, f.row))
        #expect(model.menuItems(f.pr) == [.openOnGitHub, .approve])
        // A refusal ends the progress and shows the reason.
        f.answerFresh(pending: false)
        model.approve(f.pr, click: UserClick())
        #expect(model.approveProgress(f.pr) == .approving)
        await model.approval?.value
        #expect(model.approveProgress(f.pr) == nil)
        #expect(model.error == ApproveRefusal.draftMissing.message)
        #expect(f.written == [write])
        #expect(ReviewsPanelModel.approvingText == "Approving\u{2026}")
        #expect(ReviewsPanelModel.approvedText == "Approved")
        f.panels.releaseBody(for: .reviews)
        await f.end()
    }

    // While the panel is open for the PR, a second open (the row's button again) only brings it
    // forward: the summary, the comment edits, the "Send as" switch and the confirm stay, and
    // nothing reads GitHub again. A newer draft of Claude for the PR, or a close, makes the next
    // open read the draft again, with no edits.
    @Test func aSecondOpenKeepsTheEdits() async throws {
        let f = try await DraftPanelFixture()
        await f.open()
        let flow = try #require(f.draft.flow)
        let reads = f.github.calls.count
        flow.summary = "My own summary."
        f.draft.text(of: f.claudeComment).wrappedValue = "Better."
        f.draft.setRemoved(f.userComment, true)
        f.draft.event = .requestChanges
        f.draft.discard(click: UserClick())
        #expect(f.draft.confirm == .discard)
        let model = try #require(f.panels.body(for: .reviews) as? ReviewsHost).rootView.model
        model.choose(.comment, for: f.pr)
        #expect(f.opened.values == [.reviewDraft, .reviewDraft])
        #expect(f.draft.flow === flow && f.github.calls.count == reads)
        #expect(flow.summary == "My own summary.")
        #expect(flow.comments.map(\.text) == ["Better.", "Mine."])
        #expect(flow.comments.map(\.removed) == [false, true])
        #expect(f.draft.event == .requestChanges && f.draft.confirm == .discard)
        // A later round left a newer draft: the next open reads it.
        await f.setMark(.requestChanges)
        f.row.draft = .requestChanges
        model.choose(.requestChanges, for: f.pr)
        await f.draft.task?.value
        let newer = try #require(f.draft.flow)
        #expect(newer !== flow && newer.summary == "Summary." && newer.isCurrent)
        #expect(f.draft.confirm == nil && f.github.calls.count == reads + 2)
        newer.summary = "Again."
        f.draft.links.closePanel(.reviewDraft)
        await f.open()
        #expect(f.draft.flow !== newer && f.draft.flow?.summary == "Summary.")
        #expect(f.written.isEmpty)
        await f.end()
    }

    // A second open while an action runs keeps the action: its result shows in the error line,
    // and the edits stay.
    @Test func aSecondOpenDuringAnActionKeepsItsResult() async throws {
        let f = try await DraftPanelFixture()
        let submit = GitHubWrite.submitDraft(review: f.review, event: .comment, click: UserClick())
        f.github.answers[FakeGitHub.key(submit)] = .failure(.refused("Something went wrong"))
        await f.open()
        let flow = try #require(f.draft.flow)
        let draft = f.draft
        let pr = f.pr
        f.github.onWrite = { _ in
            #expect(flow.busy)
            draft.open(pr)
        }
        f.draft.send(click: UserClick())
        await f.draft.task?.value
        #expect(f.opened.values == [.reviewDraft, .reviewDraft])
        #expect(f.written == [submit] && f.draft.flow === flow)
        #expect(f.draft.error == DraftRefusal.sendFailed.message)
        #expect(flow.summary == "Summary." && f.closed.values.isEmpty)
        await f.end()
    }

    // A stop of Reviews (Watch GitHub off) closes the Review panel and the Answer panel, and
    // their edits go. A second stop closes nothing.
    @Test func aStopOfReviewsClosesTheReviewAndAnswerPanels() async throws {
        let f = try await DraftPanelFixture()
        let store = f.store
        f.links.makeAnswerFlow = { pr in AnswerFlow(pr: pr, store: store) { _ in true } }
        await f.open()
        #expect(f.draft.body(for: .reviewDraft) != nil)
        f.draft.flow?.summary = "My own summary."
        f.panels.answer.open(f.pr)
        #expect(f.panels.answer.body(for: .answer) != nil && f.panels.answer.flow != nil)
        f.panels.reviewsStopped()
        #expect(f.closed.values == [.reviewDraft, .answer])
        #expect(f.draft.flow == nil && f.draft.pr == nil && f.draft.error == nil)
        #expect(f.panels.answer.flow == nil && f.panels.answer.pr == nil)
        f.panels.reviewsStopped()
        #expect(f.closed.values.count == 2 && f.written.isEmpty)
        await f.end()
    }
}
