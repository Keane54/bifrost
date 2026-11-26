// The findings form of the Review panel (docs/behaviour/reviews.md, "The Review panel"): the open
// from the row, the ticks and the Nits row, the hint, the one GitHub write of each button with a
// click, the private note that never goes, the lock, the wait for a poll and the place of the
// buttons during a write. The panels run on the real flows of DraftPanelFixture, so no test
// reaches GitHub.
import AppKit
import BifrostFoundation
import BifrostLayout
import BifrostLook
import BifrostReviews
import BifrostTestSupport
import Foundation
import SwiftUI
import Testing

@testable import BifrostWindows

@MainActor
@Suite("the findings form of the Review panel", .serialized, .testTimeLimit, .tags(.window))
struct ReviewFindingsPanelTests {
    // The findings of the fixture by index: 0 a minor finding off the diff, 1 a bug on the diff,
    // 2 a nit on the diff, 3 a minor finding with no place, 4 a nit with no place.

    // The line comment of the bug, and the review text of the two minor findings, which have no
    // line comment: what the ticks of the open post.
    private static let bugComment = DraftComment(
        path: "src/a.swift", line: 12, side: .right, startLine: 10,
        body: "This loop never ends when the list is empty.")
    private static let minorText =
        "`src/b.swift` line 40: This log line names the wrong file.\n\nNo test covers the retry."
    // The approved text of the wait for a poll.
    private static let waitText =
        "Bifrost can't tell whether GitHub saved your review, so click Refresh to check."

    // A fixture whose row offers Approve on Claude's findings: Claude's Approve mark with no
    // draft, the note and the findings, and a fresh read of the PR with no pending review.
    private func fixture() async throws -> DraftPanelFixture {
        let f = try await DraftPanelFixture(.approve, draft: false)
        await f.setFindingsMark()
        f.answerFresh(pending: false)
        f.row.approveCheck = .findings
        f.row.findingsPanel = true
        return f
    }

    // The fixture with the findings form open on its PR.
    private func opened() async throws -> DraftPanelFixture {
        let f = try await fixture()
        f.draft.openFindings(f.pr)
        return f
    }

    // The one review write of the PR with the event, the review text and the line comments.
    private func review(
        _ f: DraftPanelFixture, _ event: ReviewEvent, body: String, threads: [DraftComment]
    ) throws -> GitHubWrite {
        .reviewCommit(
            pr: try #require(NodeID("PR_node7")), commit: f.head, event: event, body: body,
            threads: threads, click: UserClick())
    }

    // Approve on a row where Claude found something above a nit opens the Review panel on the
    // findings form of the PR, with Claude's suggestion, the note and each finding from the
    // mark. Nothing goes to GitHub, and the open reads nothing.
    @Test func approveOnAFindingsRowOpensThePanel() async throws {
        let f = try await fixture()
        let model = try #require(f.panels.body(for: .reviews) as? ReviewsHost).rootView.model
        model.approve(f.pr, click: UserClick())
        #expect(f.opened.values == [.reviewDraft] && f.draft.pr == f.pr)
        #expect(f.panels.titleSuffix(for: .reviewDraft) == "Owner-A/Repo-A #7")
        #expect(f.draft.body(for: .reviewDraft) != nil)
        let findings = try #require(f.draft.findings)
        #expect(f.draft.flow == nil && f.draft.error == nil && findings.isCurrent)
        let shown = try #require(findings.shown)
        #expect(shown.why == "the retry change is correct" && shown.note == DraftPanelFixture.note)
        #expect(shown.findings == DraftPanelFixture.findings)
        #expect(f.draft.canPost && !f.draft.findingsLocked && f.draft.posting == nil)
        #expect(
            String(SuggestionLine.text(.approve, why: "the retry change is correct").characters)
                == "Claude suggests: Approve - the retry change is correct.")
        #expect(FindingsText.noteLabel == "Claude's note")
        #expect(FindingsText.noteHint == "Claude's notes are not posted to GitHub.")
        #expect(FindingsText.findings(3) == "Findings (3)" && FindingsText.nits(2) == "Nits (2)")
        #expect(FindingsText.nothingFound(nits: false) == "Claude found nothing to change.")
        #expect(
            FindingsText.nothingFound(nits: true)
                == "Claude found nothing to change, only the nits below.")
        #expect(
            DraftPanelFixture.findings.map(FindingsText.tag)
                == ["Minor", "Bug", "Nit", "Minor", "Nit"])
        #expect(
            DraftPanelFixture.findings.map(FindingsText.offDiff)
                == [
                    "This line isn't in the diff, so it'll go in the main review comment instead.",
                    nil, nil, nil, nil,
                ])
        #expect(
            FindingsText.summaryPlaceholder
                == "Add a summary if you want, you'll need one if requesting changes.")
        #expect(model.approval == nil && f.github.calls.isEmpty)
        f.panels.releaseBody(for: .reviews)
        await f.end()
    }

    // The bug and the minor findings start ticked, the nits start unticked under the closed Nits
    // row. The findings show bugs first, then minor findings, each in the order of the result. A
    // new open (another PR, or the same PR after a close) closes the Nits row again.
    @Test func bugsAndMinorStartTickedAndTheNitsStartClosedAndUnticked() async throws {
        let f = try await opened()
        let findings = try #require(f.draft.findings)
        #expect(findings.ticked == [0, 1, 3])
        #expect(f.draft.findingRows == [1, 0, 3] && f.draft.nitRows == [2, 4])
        #expect(f.draft.ticked(1).wrappedValue && !f.draft.ticked(2).wrappedValue)
        #expect(!f.draft.nitsOpen)
        f.draft.toggleNits()
        #expect(f.draft.nitsOpen)
        f.draft.ticked(2).wrappedValue = true
        f.draft.ticked(0).wrappedValue = false
        #expect(findings.ticked == [1, 2, 3])
        let other = try #require(PRKey(text: "Owner-A/Repo-A#8"))
        await f.setFindingsMark(on: other)
        f.draft.openFindings(other)
        #expect(f.draft.pr == other && !f.draft.nitsOpen)
        #expect(f.draft.findings !== findings && f.draft.findings?.ticked == [0, 1, 3])
        f.draft.toggleNits()
        f.links.closePanel(.reviewDraft)
        f.draft.openFindings(other)
        #expect(!f.draft.nitsOpen && f.draft.findings?.ticked == [0, 1, 3])
        #expect(f.github.calls.isEmpty)
        await f.end()
    }

    // With nothing ticked and no summary, Approve approves the reviewed commit with no text, and
    // the panel closes. The progress takes the place of the buttons from the click on.
    @Test func approveWithNothingTickedApprovesWithNoText() async throws {
        let f = try await opened()
        let approve = GitHubWrite.approveCommit(
            pr: try #require(NodeID("PR_node7")), commit: f.head, click: UserClick())
        f.answer(approve, state: "APPROVED")
        for index in DraftPanelFixture.findings.indices {
            f.draft.ticked(index).wrappedValue = false
        }
        f.draft.findingSummary.wrappedValue = " \n"
        f.draft.approveFindings(click: UserClick())
        #expect(f.draft.posting == .approve && !f.draft.canPost)
        await f.draft.task?.value
        #expect(f.written == [approve] && f.closed.values == [.reviewDraft])
        #expect(f.draft.findings == nil && f.draft.error == nil)
        #expect(f.writes.progress(f.pr) == .confirmed(.approve))
        await f.endHold()
        await f.end()
    }

    // Approve with the ticks of the open sends one review write with the event Approve: the bug
    // as a line comment, and the minor findings off the diff and with no place in the review
    // text. The panel closes.
    @Test func approvePostsTheTickedFindings() async throws {
        let f = try await opened()
        let write = try review(f, .approve, body: Self.minorText, threads: [Self.bugComment])
        f.answer(write, state: "APPROVED")
        f.draft.approveFindings(click: UserClick())
        await f.draft.task?.value
        #expect(f.written == [write] && f.closed.values == [.reviewDraft])
        #expect(f.draft.error == nil)
        await f.end()
    }

    // Comment sends one review write of the ticked findings with the event Comment. Request
    // changes with no summary says why and sends nothing, and with a summary it sends one review
    // write with the event Request changes, the summary first.
    @Test func commentAndRequestChangesPostTheTickedFindings() async throws {
        let f = try await opened()
        let comment = try review(f, .comment, body: Self.minorText, threads: [Self.bugComment])
        f.answer(comment, state: "COMMENTED")
        f.draft.sendFindings(.comment, click: UserClick())
        await f.draft.task?.value
        #expect(f.written == [comment] && f.closed.values == [.reviewDraft])
        await f.endHold()
        f.draft.openFindings(f.pr)
        f.draft.sendFindings(.requestChanges, click: UserClick())
        await f.draft.task?.value
        #expect(f.draft.error == "Add a summary to request changes.")
        #expect(f.written == [comment] && f.closed.values.count == 1)
        #expect(f.draft.findings?.ticked == [0, 1, 3])
        f.draft.findingSummary.wrappedValue = "Please fix the loop first."
        let changes = try review(
            f, .requestChanges, body: "Please fix the loop first.\n\n" + Self.minorText,
            threads: [Self.bugComment])
        f.answer(changes, state: "CHANGES_REQUESTED")
        f.draft.sendFindings(.requestChanges, click: UserClick())
        await f.draft.task?.value
        #expect(f.draft.error == nil)
        #expect(f.written == [comment, changes] && f.closed.values.count == 2)
        await f.end()
    }

    // With every finding ticked and a summary, no write of Approve, Comment or Request changes
    // holds Claude's private note: each holds only the summary and the findings.
    @Test func thePanelNeverPostsTheNote() async throws {
        let f = try await fixture()
        let all = Set(DraftPanelFixture.findings.indices)
        let post = FindingsPlan.post(DraftPanelFixture.findings, ticked: all, summary: "Summary.")
        let draft = f.draft
        let actions: [(ReviewEvent, String, @MainActor () -> Void)] = [
            (.approve, "APPROVED", { draft.approveFindings(click: UserClick()) }),
            (.comment, "COMMENTED", { draft.sendFindings(.comment, click: UserClick()) }),
            (
                .requestChanges, "CHANGES_REQUESTED",
                { draft.sendFindings(.requestChanges, click: UserClick()) }
            ),
        ]
        for (event, state, act) in actions {
            f.draft.openFindings(f.pr)
            for index in all { f.draft.ticked(index).wrappedValue = true }
            f.draft.findingSummary.wrappedValue = "Summary."
            f.answer(try review(f, event, body: post.body, threads: post.threads), state: state)
            act()
            await f.draft.task?.value
            #expect(f.draft.error == nil)
        }
        #expect(f.written.count == 3 && f.closed.values.count == 3)
        for write in f.written {
            #expect(!String(decoding: write.input, as: UTF8.self).contains("PRIVATE-NOTE-4c1e"))
            guard case .reviewCommit(_, _, _, let body, let threads, _) = write else {
                Issue.record("A write that is not a review: \(write)")
                continue
            }
            #expect(body.hasPrefix("Summary.") && threads.count == 2)
            #expect(!body.contains("PRIVATE-NOTE") && !body.contains("Line two of the note."))
        }
        await f.end()
    }

    // The line above the buttons says what a button posts, and it follows each tick and each
    // edit of the summary. A blank summary counts as no summary.
    @Test func theHintSaysWhatBifrostPosts() async throws {
        let f = try await opened()
        #expect(f.draft.postHint == "Your review will include the 3 findings you ticked.")
        for index in [0, 3] { f.draft.ticked(index).wrappedValue = false }
        #expect(f.draft.postHint == "Your review will include the finding you ticked.")
        f.draft.findingSummary.wrappedValue = "Looks good."
        #expect(
            f.draft.postHint
                == "Your review will include your summary and the finding you ticked.")
        f.draft.ticked(2).wrappedValue = true
        #expect(
            f.draft.postHint
                == "Your review will include your summary and the 2 findings you ticked.")
        for index in [1, 2] { f.draft.ticked(index).wrappedValue = false }
        #expect(f.draft.postHint == "Your review will include your summary.")
        f.draft.findingSummary.wrappedValue = " \n\t"
        #expect(f.draft.postHint == "Approve will post just your approval, with no comment.")
        #expect(f.github.calls.isEmpty)
        await f.end()
    }

    // While the panel shows the findings of the PR, a second open (Approve on the row, See
    // Claude's review) only brings it forward: the ticks, the summary and the Nits row stay.
    // After a refusal the ticks and the summary stay, and a second open keeps them and the
    // reason. A close drops them, so the next open starts again.
    @Test func aSecondOpenBringsThePanelForwardAndKeepsTheTicks() async throws {
        let f = try await opened()
        let findings = try #require(f.draft.findings)
        f.draft.ticked(0).wrappedValue = false
        f.draft.ticked(2).wrappedValue = true
        f.draft.findingSummary.wrappedValue = "My own summary."
        f.draft.toggleNits()
        let model = try #require(f.panels.body(for: .reviews) as? ReviewsHost).rootView.model
        model.approve(f.pr, click: UserClick())
        model.choose(.seeReview, for: f.pr)
        #expect(f.opened.values == [.reviewDraft, .reviewDraft, .reviewDraft])
        #expect(f.draft.findings === findings && findings.ticked == [1, 2, 3])
        #expect(findings.summary == "My own summary." && f.draft.nitsOpen)
        f.github.answers[DraftQueries.freshName] = .failure(.refused("Not Found"))
        f.draft.sendFindings(.comment, click: UserClick())
        await f.draft.task?.value
        let reason = FindingsRefusal.readFailed(.refused("Not Found")).message
        #expect(f.draft.error == reason && f.closed.values.isEmpty)
        #expect(findings.ticked == [1, 2, 3] && findings.summary == "My own summary.")
        f.draft.openFindings(f.pr)
        #expect(f.draft.findings === findings && f.draft.error == reason)
        #expect(findings.ticked == [1, 2, 3] && findings.summary == "My own summary.")
        #expect(f.written.isEmpty)
        f.links.closePanel(.reviewDraft)
        f.draft.openFindings(f.pr)
        #expect(f.draft.findings !== findings && f.draft.findings?.ticked == [0, 1, 3])
        #expect(f.draft.findings?.summary == "" && !f.draft.nitsOpen && f.draft.error == nil)
        f.panels.releaseBody(for: .reviews)
        await f.end()
    }

    // A new mark of Claude after the open (a new round) locks the panel: it shows the old
    // findings, and no button acts. A new open shows the new mark. A row that no longer offers
    // the findings locks the panel too.
    @Test func aNewMarkLocksThePanel() async throws {
        let f = try await opened()
        #expect(!f.draft.findingsLocked && f.draft.canPost)
        await f.setFindingsMark(at: Date(timeIntervalSince1970: 1_794_315_600))
        #expect(f.draft.findingsLocked && !f.draft.canPost)
        #expect(
            ReviewDraftPanels.lockedFindingsText
                == "You can't send this review right now, its row in the Reviews panel shows why.")
        f.draft.approveFindings(click: UserClick())
        f.draft.sendFindings(.comment, click: UserClick())
        #expect(f.draft.task == nil && f.github.calls.isEmpty)
        f.draft.openFindings(f.pr)
        #expect(!f.draft.findingsLocked && f.draft.canPost)
        f.row.findingsPanel = false
        #expect(f.draft.findingsLocked && !f.draft.canPost)
        await f.end()
    }

    // A stop of Reviews (Watch GitHub off) closes the panel, and the findings, the ticks and the
    // Nits row go. A second stop closes nothing.
    @Test func aStopOfReviewsClosesTheFindings() async throws {
        let f = try await opened()
        let closed = f.closed
        f.links.closePanel = { closed.record($0) }
        f.draft.toggleNits()
        #expect(f.draft.body(for: .reviewDraft) != nil)
        f.panels.reviewsStopped()
        #expect(f.closed.values == [.reviewDraft])
        #expect(f.draft.findings == nil && !f.draft.nitsOpen && f.draft.pr == nil)
        f.panels.releaseBody(for: .reviewDraft)
        f.panels.reviewsStopped()
        #expect(f.closed.values.count == 1 && f.github.calls.isEmpty)
        await f.end()
    }

    // When a wait for a poll starts while the panel is open, for example from the row, the three
    // buttons go off and the panel says why. A poll that started after the result ends the wait
    // and the text goes with it.
    @Test func theButtonsWaitForThePollOfAnUnsureReview() async throws {
        let f = try await opened()
        #expect(f.draft.waitText == nil)
        f.writes.mayHaveGone(f.pr)
        #expect(f.draft.findings?.waitsForPoll == true)
        #expect(!f.draft.canPost && !f.draft.findingsLocked)
        #expect(f.draft.waitText == Self.waitText)
        f.draft.approveFindings(click: UserClick())
        f.draft.sendFindings(.comment, click: UserClick())
        #expect(f.draft.task == nil && f.github.calls.isEmpty)
        f.watcherPolls.answered()
        #expect(f.draft.canPost && f.draft.waitText == nil)
        await f.end()
    }

    // After an unsure Comment the error line already gives the reason, so the strip stays quiet.
    // Once the panel is closed and opened again during the wait, the strip says it instead, and
    // the buttons stay off until the poll's check of your own reviews ends the wait.
    @Test func aNewOpenDuringTheWaitSaysWhy() async throws {
        let f = try await opened()
        let comment = try review(f, .comment, body: Self.minorText, threads: [Self.bugComment])
        f.github.answers[FakeGitHub.key(comment)] = .failure(.unknownOutcome("HTTP 502"))
        f.draft.sendFindings(.comment, click: UserClick())
        await f.draft.task?.value
        #expect(f.draft.error == Self.waitText && f.draft.waitText == nil)
        #expect(!f.draft.canPost && f.written == [comment])
        f.links.closePanel(.reviewDraft)
        f.draft.openFindings(f.pr)
        #expect(f.draft.error == nil && f.draft.waitText == Self.waitText)
        #expect(!f.draft.canPost && !f.draft.findingsLocked)
        await f.pollAnswered()
        #expect(f.draft.canPost && f.draft.waitText == nil)
        #expect(f.written == [comment])
        await f.end()
    }

    // When the check after an unsure Comment finds it on GitHub, the panel locks with its usual
    // strip, as the row now says You commented, and nothing can go again for that head.
    @Test func aCommentThatTheCheckFindsLocksThePanel() async throws {
        let f = try await opened()
        let comment = try review(f, .comment, body: Self.minorText, threads: [Self.bugComment])
        f.github.answers[FakeGitHub.key(comment)] = .failure(.unknownOutcome("HTTP 502"))
        f.draft.sendFindings(.comment, click: UserClick())
        let unsure = f.draft.task
        await unsure?.value
        f.github.answers[DraftQueries.ownReviewsName] = .success(
            DraftAnswers.ownReviews([
                DraftAnswers.Opinion(state: "COMMENTED", commit: f.head, at: DraftPanelFixture.wall)
            ]))
        await f.pollAnswered()
        #expect(f.draft.findingsLocked && !f.draft.canPost && f.draft.waitText == nil)
        f.links.closePanel(.reviewDraft)
        f.draft.openFindings(f.pr)
        #expect(f.draft.findingsLocked && !f.draft.canPost)
        f.answer(comment, state: "COMMENTED")
        f.draft.sendFindings(.comment, click: UserClick())
        #expect(f.draft.task == unsure && f.written == [comment])
        await f.end()
    }

    // The strip stays quiet while the error line is about a write that GitHub may have acted on,
    // as that line already explains the wait in its own words: an unsure Approve, or a Comment
    // that GitHub saved in another state. A new open drops the error line, and the strip shows.
    @Test func theStripStaysQuietWhileTheErrorLineExplains() async throws {
        let f = try await opened()
        let approval = try review(f, .approve, body: Self.minorText, threads: [Self.bugComment])
        f.github.answers[FakeGitHub.key(approval)] = .failure(.unknownOutcome("HTTP 502"))
        f.draft.approveFindings(click: UserClick())
        await f.draft.task?.value
        #expect(f.draft.error == ApproveRefusal.unknown.message)
        #expect(!f.draft.canPost && f.draft.waitText == nil)
        await f.pollAnswered()
        #expect(f.draft.canPost)
        let comment = try review(f, .comment, body: Self.minorText, threads: [Self.bugComment])
        f.answer(comment, state: "APPROVED")
        f.draft.sendFindings(.comment, click: UserClick())
        await f.draft.task?.value
        #expect(f.draft.error == FindingsRefusal.notAsSent.message)
        #expect(!f.draft.canPost && f.draft.waitText == nil)
        f.links.closePanel(.reviewDraft)
        f.draft.openFindings(f.pr)
        #expect(f.draft.error == nil && f.draft.waitText == Self.waitText)
        await f.end()
    }

    // The place of the three buttons keeps its width while a review write runs, so the hint
    // above them and the panel around them do not move: the progress ("Requesting changes…")
    // takes the place of the buttons from the click on, and a hidden copy of the buttons holds
    // the width. A second open during the write brings the panel forward and keeps the write.
    @Test func theButtonsKeepTheirPlaceDuringAWrite() async throws {
        let f = try await opened()
        f.draft.findingSummary.wrappedValue = "Please fix the loop first."
        let write = try review(
            f, .requestChanges, body: "Please fix the loop first.\n\n" + Self.minorText,
            threads: [Self.bugComment])
        f.answer(write, state: "CHANGES_REQUESTED")
        let gate = TestGate()
        defer { gate.openAll() }
        f.github.onWrite = { _ in await gate.pass() }
        let (draft, style) = (f.draft, f.draft.style)
        func width() -> CGFloat {
            NSHostingView(rootView: FindingsButtons(panels: draft, style: style)).fittingSize.width
        }
        let progress = NSHostingView(
            rootView: WriteProgressLabel(progress: .running(.requestChanges), style: style)
        ).fittingSize.width
        let idle = width()
        #expect(idle > progress)
        f.draft.sendFindings(.requestChanges, click: UserClick())
        #expect(f.draft.posting == .requestChanges && !f.draft.canPost)
        #expect(width() == idle)
        #expect(await gate.waitUntilHolding(1))
        #expect(width() == idle)
        let findings = f.draft.findings
        f.draft.openFindings(f.pr)
        #expect(f.draft.findings === findings && f.draft.posting == .requestChanges)
        gate.open()
        await f.draft.task?.value
        #expect(f.written == [write] && f.closed.values == [.reviewDraft])
        #expect(width() == idle)
        await f.endHold()
        await f.end()
    }
}
