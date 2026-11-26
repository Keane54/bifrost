// The Review panel and the Approve button of the Reviews panel (docs/behaviour/reviews.md,
// "Approve" and "The Review panel"): the controls, the error line, the one GitHub write of each
// button, with a click, and the progress of an approval and of a send on the row and in the
// panel. The panels run on the real flows of DraftPanelFixture, so no test reaches GitHub.
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
@Suite("the Review panel", .serialized, .testTimeLimit, .tags(.window))
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
    // Approve button of a row with Claude's old Approve draft opens that draft in the panel and
    // writes nothing.
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
        #expect(f.writes.progress(f.pr) == .confirmed(.approve))
        await f.endHold()
        // The Approve button of a row with Claude's old Approve draft opens that draft.
        await f.setMark(.approve)
        f.row.approve = .ready
        f.row.draft = nil
        f.row.approveCheck = .draft
        f.answerFresh()
        let model = try #require(f.panels.body(for: .reviews) as? ReviewsHost).rootView.model
        #expect(ReviewsMenu.buttons(f.row) == [.approve])
        #expect(model.menuItems(f.pr)?.contains(.approve) == true)
        model.approve(f.pr, click: UserClick())
        #expect(model.approval == nil && f.draft.pr == f.pr)
        #expect(f.opened.values.count == 4 && f.opened.values.last == .reviewDraft)
        await f.draft.task?.value
        #expect(f.draft.flow?.shown?.recommendation == .approve)
        #expect(f.written.count == 4 && model.error == nil)
        f.panels.releaseBody(for: .reviews)
        await f.end()
    }

    // The panel on Claude's old Approve draft is not locked: the row offers that draft through
    // its Approve button, so Discard draft and Send review act. A row that no longer offers it
    // locks the panel.
    @Test func anOldApproveDraftIsNotLocked() async throws {
        let f = try await DraftPanelFixture(.approve)
        #expect(f.row.draft == nil && f.row.offersDraft)
        await f.open()
        #expect(f.draft.flow?.shown?.recommendation == .approve)
        #expect(!f.draft.isLocked && f.draft.canDiscard && f.draft.canSend)
        let submit = GitHubWrite.submitDraft(review: f.review, event: .comment, click: UserClick())
        f.answer(submit, state: "COMMENTED")
        f.draft.send(click: UserClick())
        await f.draft.task?.value
        #expect(f.written == [submit] && f.closed.values == [.reviewDraft])
        await f.setMark(.approve)
        await f.open()
        f.row.approveCheck = nil
        #expect(f.draft.isLocked && !f.draft.canDiscard && !f.draft.canSend)
        await f.end()
    }

    // The row shows the progress of its approval in the place of its buttons. While the write
    // runs, the row shows Approving, the menu has no Approve, and a second click writes nothing.
    // GitHub's answer gives Approved until the end of the hold, also when a refresh changes the
    // rows or drops the row. After the hold, the row has its buttons again. A refusal ends the
    // progress at once, and the reason shows in the error line.
    @Test func theRowShowsTheProgressOfItsApproval() async throws {
        let f = try await DraftPanelFixture(.approve, draft: false)
        f.answerFresh(pending: false)
        let write = GitHubWrite.approveCommit(
            pr: try #require(NodeID("PR_node7")), commit: f.head, click: UserClick())
        f.answer(write, state: "APPROVED")
        let gate = TestGate()
        defer { gate.openAll() }
        f.github.onWrite = { _ in await gate.pass() }
        let model = try #require(f.panels.body(for: .reviews) as? ReviewsHost).rootView.model
        #expect(model.progress(f.pr) == nil && model.isEnabled(.approve, f.row))
        #expect(!f.row.status.text.isEmpty && model.shownStatus(f.row) == f.row.status)
        model.approve(f.pr, click: UserClick())
        let first = try #require(model.approval)
        #expect(await gate.waitUntilHolding(1))
        #expect(model.progress(f.pr) == .running(.approve))
        // The progress takes the place of the state text.
        #expect(model.shownStatus(f.row) == nil)
        #expect(!model.isEnabled(.approve, f.row))
        #expect(model.menuItems(f.pr) == [.openOnGitHub])
        model.approve(f.pr, click: UserClick())
        model.choose(.approve, for: f.pr)
        #expect(model.approval == first)
        // A refresh of the rows keeps the progress.
        f.row.title = "Add the cache, part 2"
        #expect(model.progress(f.pr) == .running(.approve))
        gate.open()
        await first.value
        #expect(f.written == [write] && model.error == nil)
        #expect(model.progress(f.pr) == .confirmed(.approve))
        #expect(model.shownStatus(f.row) == nil)
        #expect(model.menuItems(f.pr) == [.openOnGitHub])
        let row = f.row
        f.row.status = RowLabel(text: "You approved", tone: .green, tip: nil)
        f.row.approve = nil
        #expect(model.progress(f.pr) == .confirmed(.approve))
        f.row = row
        #expect(f.clock.sleeperCount == 1)
        await f.endHold()
        #expect(model.progress(f.pr) == nil)
        #expect(model.isEnabled(.approve, f.row))
        #expect(model.menuItems(f.pr) == [.openOnGitHub, .approve])
        // A refusal ends the progress and shows the reason: here a pending review of the user.
        f.answerFresh(pending: true)
        model.approve(f.pr, click: UserClick())
        #expect(model.progress(f.pr) == .running(.approve))
        await model.approval?.value
        #expect(model.progress(f.pr) == nil)
        #expect(model.shownStatus(f.row) == f.row.status)
        #expect(model.error == ApproveRefusal.pendingReview.message)
        #expect(f.written == [write])
        #expect(RowText.progress(.running(.approve)).text == "Approving\u{2026}")
        #expect(RowText.progress(.confirmed(.approve)).text == "Approved")
        f.panels.releaseBody(for: .reviews)
        await f.end()
    }

    // The place of the state text and the buttons of a row keeps one width while a review write
    // runs, so nothing to the left of it moves when the progress starts, when GitHub confirms the
    // write, or when the progress ends. The place is as wide as the wider of its idle content and
    // the widest progress ("Requesting changes…"), so a row with a short text keeps that width.
    @Test func theRowKeepsTheWidthOfItsActionsDuringAWrite() async throws {
        let f = try await DraftPanelFixture(.approve, draft: false)
        f.answerFresh(pending: false)
        let write = GitHubWrite.approveCommit(
            pr: try #require(NodeID("PR_node7")), commit: f.head, click: UserClick())
        f.answer(write, state: "APPROVED")
        let gate = TestGate()
        defer { gate.openAll() }
        f.github.onWrite = { _ in await gate.pass() }
        let model = try #require(f.panels.body(for: .reviews) as? ReviewsHost).rootView.model
        let style = model.style
        func width(_ row: ReviewRow) -> CGFloat {
            NSHostingView(rootView: ReviewRowActions(model: model, row: row, style: style))
                .fittingSize.width
        }
        let widest = NSHostingView(
            rootView: WriteProgressLabel(progress: .running(.requestChanges), style: style)
        ).fittingSize.width
        var narrow = f.row
        narrow.approve = nil
        narrow.status = RowLabel(text: "Queued", tone: .plain, tip: nil)
        let idle = width(f.row)
        #expect(idle >= widest && width(narrow) == widest)
        model.approve(f.pr, click: UserClick())
        #expect(await gate.waitUntilHolding(1))
        #expect(model.progress(f.pr) == .running(.approve))
        #expect(width(f.row) == idle && width(narrow) == widest)
        gate.open()
        await model.approval?.value
        #expect(model.progress(f.pr) == .confirmed(.approve))
        #expect(width(f.row) == idle && width(narrow) == widest)
        await f.endHold()
        #expect(model.progress(f.pr) == nil)
        #expect(width(f.row) == idle && width(narrow) == widest)
        #expect(f.written == [write])
        f.panels.releaseBody(for: .reviews)
        await f.end()
    }

    // A send shows its progress from the click: Send review gives way to "Requesting changes…",
    // the row shows the same progress in the place of its state text and its buttons, its menu
    // has no Request changes, and a second click sends nothing. GitHub's answer closes the panel,
    // and the row shows Changes requested until the end of the hold. A refusal ends the progress
    // at once, and the reason shows in the error line of the panel.
    @Test func aSendShowsItsProgressInThePanelAndOnTheRow() async throws {
        let f = try await DraftPanelFixture(.requestChanges)
        let submit = GitHubWrite.submitDraft(
            review: f.review, event: .requestChanges, click: UserClick())
        f.answer(submit, state: "CHANGES_REQUESTED")
        let gate = TestGate()
        defer { gate.openAll() }
        f.github.onWrite = { _ in await gate.pass() }
        let model = try #require(f.panels.body(for: .reviews) as? ReviewsHost).rootView.model
        await f.open()
        #expect(f.draft.event == .requestChanges && f.draft.sending == nil && f.draft.canSend)
        #expect(model.menuItems(f.pr) == [.openOnGitHub, .requestChanges])
        #expect(model.isEnabled(.requestChanges, f.row))
        f.draft.send(click: UserClick())
        let first = try #require(f.draft.task)
        // The send starts in the click.
        #expect(f.draft.sending == .requestChanges && !f.draft.canSend)
        #expect(model.progress(f.pr) == .running(.requestChanges))
        #expect(model.shownStatus(f.row) == nil && !model.isEnabled(.requestChanges, f.row))
        #expect(model.menuItems(f.pr) == [.openOnGitHub])
        f.draft.send(click: UserClick())
        model.choose(.requestChanges, for: f.pr)
        #expect(f.draft.task == first && f.opened.values == [.reviewDraft])
        #expect(await gate.waitUntilHolding(1))
        gate.open()
        await first.value
        #expect(f.written == [submit] && f.closed.values == [.reviewDraft])
        #expect(f.draft.error == nil && f.draft.sending == nil)
        #expect(model.progress(f.pr) == .confirmed(.requestChanges))
        #expect(model.shownStatus(f.row) == nil && model.menuItems(f.pr) == [.openOnGitHub])
        #expect(
            RowText.progress(.running(.requestChanges)).text == "Requesting changes\u{2026}")
        #expect(RowText.progress(.confirmed(.requestChanges)).text == "Changes requested")
        await f.endHold()
        #expect(model.progress(f.pr) == nil && model.shownStatus(f.row) == f.row.status)
        // A refusal of GitHub ends the progress at once, and the edits stay.
        f.github.onWrite = nil
        f.github.answers[FakeGitHub.key(submit)] = .failure(.refused("Something went wrong"))
        await f.setMark(.requestChanges)
        await f.open()
        f.draft.send(click: UserClick())
        await f.draft.task?.value
        #expect(f.draft.error == DraftRefusal.sendFailed.message)
        #expect(f.draft.sending == nil && f.draft.canSend && model.progress(f.pr) == nil)
        #expect(f.written == [submit, submit] && f.closed.values == [.reviewDraft])
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

    // The draft form shows Claude's suggestion and, under it, Claude's private note from the
    // mark. A mark from before the notes has no note, so the form shows none.
    @Test func theDraftFormShowsTheNote() async throws {
        let f = try await DraftPanelFixture(.requestChanges)
        await f.setMark(.requestChanges, note: DraftPanelFixture.note)
        await f.open()
        #expect(f.draft.flow?.shown?.note == DraftPanelFixture.note)
        #expect(
            String(SuggestionLine.text(.requestChanges, why: "Two small bugs.").characters)
                == "Claude suggests: Request changes - Two small bugs.")
        f.links.closePanel(.reviewDraft)
        await f.setMark(.requestChanges)
        await f.open()
        #expect(f.draft.flow?.shown?.note == "")
        #expect(f.written.isEmpty)
        await f.end()
    }

    // The place of Send review is always as wide as the widest progress ("Requesting
    // changes…"), so the "Send as" switch to its left does not move when a send starts or ends.
    @Test func theSendButtonKeepsItsPlaceDuringASend() async throws {
        let f = try await DraftPanelFixture(.requestChanges)
        let submit = GitHubWrite.submitDraft(
            review: f.review, event: .requestChanges, click: UserClick())
        f.answer(submit, state: "CHANGES_REQUESTED")
        let gate = TestGate()
        defer { gate.openAll() }
        f.github.onWrite = { _ in await gate.pass() }
        await f.open()
        let (draft, style) = (f.draft, f.draft.style)
        func width() -> CGFloat {
            NSHostingView(rootView: DraftSendButton(panels: draft, style: style)).fittingSize.width
        }
        let widest = NSHostingView(
            rootView: WriteProgressLabel(progress: .running(.requestChanges), style: style)
        ).fittingSize.width
        #expect(width() == widest)
        f.draft.send(click: UserClick())
        #expect(f.draft.sending == .requestChanges)
        #expect(width() == widest)
        #expect(await gate.waitUntilHolding(1))
        gate.open()
        await f.draft.task?.value
        #expect(f.written == [submit] && f.closed.values == [.reviewDraft])
        #expect(width() == widest)
        await f.endHold()
        await f.end()
    }

    // While a review from the findings form of the PR might have reached GitHub and no poll has
    // shown it yet, Send review, Discard draft and Approve instead are off and the draft form says
    // why, also after a close and a new open. A poll that started after the result ends the wait,
    // and the text goes with it.
    @Test func theDraftButtonsWaitForThePollOfAnUnsureReview() async throws {
        let f = try await DraftPanelFixture()
        await f.open()
        let open = f.draft.task
        let calls = f.github.calls.count
        #expect(f.draft.canSend && f.draft.canDiscard && f.draft.waitText == nil)
        f.writes.mayHaveGone(f.pr)
        #expect(!f.draft.canSend && !f.draft.canDiscard && !f.draft.isLocked)
        #expect(f.draft.waitText == FindingsRefusal.unknown.message)
        f.draft.send(click: UserClick())
        f.draft.discard(click: UserClick())
        f.draft.approveInstead(click: UserClick())
        #expect(f.draft.task == open && f.draft.confirm == nil)
        #expect(f.github.calls.count == calls)
        f.links.closePanel(.reviewDraft)
        await f.open()
        #expect(!f.draft.canSend && f.draft.waitText == FindingsRefusal.unknown.message)
        f.watcherPolls.answered()
        #expect(f.draft.canSend && f.draft.canDiscard && f.draft.waitText == nil)
        #expect(f.written.isEmpty)
        await f.end()
    }

    // The panel opens 700 wide, which leaves room for the whole draft footer on one line, send
    // slot included. Make it narrower than that and the right part moves to a second line.
    @Test func theFooterFitsOnOneLineAtTheDefaultWidth() async throws {
        let f = try await DraftPanelFixture(.requestChanges)
        await f.open()
        let style = f.draft.style
        let host = NSHostingController(rootView: DraftFooter(panels: f.draft, style: style))
        func height(_ width: CGFloat) -> CGFloat {
            host.sizeThatFits(in: CGSize(width: width, height: 10_000)).height
        }
        #expect(PanelKind.reviewDraft.defaultSize.w == 700)
        // The body of a frame is the frame less its border on each side.
        let body = style.points(PanelKind.reviewDraft.defaultSize.w - 2 * FrameView.border)
        let oneLine = height(5_000)
        #expect(height(body) == oneLine)
        #expect(height(style.points(620 - 2 * FrameView.border)) > oneLine)
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
