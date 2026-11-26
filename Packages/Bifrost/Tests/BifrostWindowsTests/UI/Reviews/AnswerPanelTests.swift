// The Answer panel (docs/behaviour/reviews.md, "The Answer panel"): the controls, the error line
// and its buttons. The panel runs on the real AnswerFlow over a Reviews store in a temporary
// folder; the answers go to a recording send in place of the request rounds (AnswerFlowTests
// covers the rounds), and a fake opener stands in for the browser. A close of a panel releases
// its body, as the canvas of the window does.
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
private final class AnswerPanelFixture {
    let folder: TemporaryFolder
    let store: ReviewsStore
    let links = ReviewsPanelLinks()
    let opener = FakeOpener()
    let panels: ReviewsPanels
    let opened = Recorder<PanelID>()
    let closed = Recorder<PanelID>()
    let sent = Recorder<[NodeID: QuestionAnswer]>()
    let sentCI = Recorder<QuestionAnswer>()
    // The question about failed CI that the flow shows, or nil.
    var ci: OpenCIQuestion?
    let pr: PRKey
    let thread: NodeID
    let comment: NodeID
    // The answer of the rounds to a send.
    var takes = true
    // Runs in each send, while the send runs.
    var during: (@MainActor () -> Void)?
    var row: ReviewRow

    // Two open questions of Claude on PR 7 of the user: one on a thread with the quote of the
    // reviewer and its link, then one on a PR comment with no quote.
    init() async throws {
        UITestApp.prepare()
        folder = try TemporaryFolder()
        let layout = ReviewsLayout(
            folder: URL(filePath: folder.realPath + "/reviews", directoryHint: .isDirectory))
        store = try await ReviewsStore.open(layout: layout, log: Recorder<StoreEvent>())
        pr = try #require(PRKey(text: "Owner-A/Repo-A#7"))
        thread = try #require(NodeID("PRRT_1"))
        comment = try #require(NodeID("IC_2"))
        row = ReviewRow(
            id: pr, state: .mine(.changesRequested, .needsYou(comments: 2, ci: false)),
            repo: "Repo-A", title: "Add the cache",
            status: RowLabel(text: "Needs you", tone: .red, tip: nil), questions: 2)
        panels = ReviewsPanels(
            links: links, opener: opener, look: PanelLook(), menu: { nil },
            clock: ManualClock(), now: { Date() })
        let (store, sent, sentCI, opened, closed, panels) = (
            store, sent, sentCI, opened, closed, panels
        )
        links.snapshot = { [weak self] in
            ReviewsSnapshot(phase: .on, mine: self.map { [$0.row] } ?? [])
        }
        links.makeAnswerFlow = { [weak self] pr in
            AnswerFlow(
                pr: pr, store: store,
                send: { answers in
                    sent.record(answers)
                    self?.during?()
                    return self?.takes ?? false
                },
                ciQuestion: { self?.ci },
                sendCI: { answer in
                    sentCI.record(answer)
                    return self?.takes ?? false
                })
        }
        links.openPanel = { opened.record($0) }
        links.closePanel = { [weak panels] in
            closed.record($0)
            panels?.releaseBody(for: $0)
        }
        let (pr, thread, comment) = (pr, thread, comment)
        let at = Date(timeIntervalSince1970: 1_794_312_000)
        await store.update { state in
            var prState = PRState()
            prState.questions[thread] = Question(
                text: "Rename it?", place: "src/a.swift line 12", author: "user-b",
                body: "The name is unclear.",
                url: URL(string: "https://github.com/Owner-A/Repo-A/pull/7#discussion_r1"),
                kind: .thread, at: at.addingTimeInterval(-120), seenUntil: at)
            prState.questions[comment] = Question(
                text: "Which limit?", place: "user-b", at: at.addingTimeInterval(-60),
                seenUntil: at)
            prState.lastError = "The last round stopped."
            state.prs[pr] = prState
        }
    }

    var answer: AnswerPanels { panels.answer }

    func end() async {
        panels.releaseBody(for: .answer)
        await store.close().value
        folder.remove()
    }
}

@MainActor
@Suite("the Answer panel", .serialized, .testTimeLimit, .tags(.window))
struct AnswerPanelTests {
    // A click on a My PRs row with questions opens the panel for its PR. The panel lists the
    // questions oldest first with the line over the quote, and the reason of the last round.
    // Send to Claude acts once each question has an answer or the check; the check turns its
    // text area off. While the panel is open for the PR, a second open keeps the answers; after
    // a close, the next open starts with none.
    @Test func theControlsFollowTheAnswers() async throws {
        let f = try await AnswerPanelFixture()
        let model = try #require(f.panels.body(for: .reviews) as? ReviewsHost).rootView.model
        model.click(f.pr, command: false)
        #expect(f.opened.values == [.answer] && f.answer.pr == f.pr)
        #expect(f.answer.body(for: .answer) != nil)
        #expect(f.panels.titleSuffix(for: .answer) == "Owner-A/Repo-A #7")
        let flow = try #require(f.answer.flow)
        #expect(f.answer.questions.map(\.id) == [f.thread, f.comment])
        #expect(f.answer.questions.map(\.header) == ["user-b on src/a.swift line 12", "user-b"])
        #expect(flow.lastError == "The last round stopped." && !flow.tooMany)
        #expect(!flow.canSubmit)
        f.answer.answer(f.thread).wrappedValue = "Yes, call it limit."
        #expect(!flow.canSubmit)
        f.answer.handled(f.comment).wrappedValue = true
        #expect(flow.canSubmit)
        f.answer.handled(f.comment).wrappedValue = false
        #expect(!flow.canSubmit)
        // Answer Claude in the menu brings the open panel forward, with the answers.
        f.answer.handled(f.comment).wrappedValue = true
        model.choose(.answerClaude, for: f.pr)
        #expect(f.opened.values == [.answer, .answer] && f.answer.flow === flow)
        #expect(flow.answers[f.thread] == "Yes, call it limit." && flow.canSubmit)
        // After a close, the next open starts with no answers.
        f.answer.cancel()
        model.choose(.answerClaude, for: f.pr)
        #expect(f.opened.values == [.answer, .answer, .answer] && f.answer.flow !== flow)
        #expect(f.answer.flow?.answers.isEmpty == true && f.answer.flow?.handled.isEmpty == true)
        #expect(
            AnswerPanels.introText
                == "Claude couldn't decide these on its own. Tell it what you'd like, or handle a "
                + "comment yourself.")
        await f.end()
    }

    // A send that the rounds don't take shows why in the error line, and the panel stays open.
    // A link that doesn't open says why too. Close clears the line.
    @Test func theErrorLineShowsTheReason() async throws {
        let f = try await AnswerPanelFixture()
        f.answer.open(f.pr)
        f.takes = false
        f.answer.answer(f.thread).wrappedValue = "Yes."
        f.answer.handled(f.comment).wrappedValue = true
        f.answer.send()
        await f.answer.task?.value
        #expect(f.answer.error == AnswerPanels.notSentText)
        #expect(f.closed.values.isEmpty)
        f.answer.closeError()
        #expect(f.answer.error == nil)
        f.opener.failure = .openFailed("The browser did not open.")
        f.answer.openComment(try #require(f.answer.questions.first))
        await f.answer.task?.value
        #expect(f.answer.error == ActionRefusal.openFailed("The browser did not open.").message)
        await f.end()
    }

    // Send to Claude gives all the answers to the rounds in one call, then closes the panel. It
    // writes nothing on GitHub itself. Cancel closes the panel and sends nothing. View on GitHub
    // opens the comment of the question at its https address.
    @Test func eachButtonSendsItsOneWrite() async throws {
        let f = try await AnswerPanelFixture()
        f.answer.open(f.pr)
        f.answer.cancel()
        #expect(f.closed.values == [.answer] && f.sent.values.isEmpty)
        #expect(f.answer.flow == nil)
        f.answer.open(f.pr)
        f.answer.answer(f.thread).wrappedValue = "  Yes, call it limit. "
        f.answer.handled(f.comment).wrappedValue = true
        f.answer.send()
        await f.answer.task?.value
        #expect(
            f.sent.values == [[f.thread: .text("Yes, call it limit."), f.comment: .handleMyself]])
        #expect(f.closed.values == [.answer, .answer])
        f.answer.open(f.pr)
        f.answer.openComment(try #require(f.answer.questions.first))
        await f.answer.task?.value
        let link = "https://github.com/Owner-A/Repo-A/pull/7#discussion_r1"
        #expect(f.opener.calls == [.browse(link)])
        // A question with no link opens nothing.
        f.answer.openComment(try #require(f.answer.questions.last))
        #expect(f.opener.calls.count == 1)
        await f.end()
    }

    // A second open while a send runs keeps the send: its result shows in the error line, and
    // the answers stay.
    @Test func aSecondOpenDuringASendKeepsItsResult() async throws {
        let f = try await AnswerPanelFixture()
        f.answer.open(f.pr)
        let flow = try #require(f.answer.flow)
        f.answer.answer(f.thread).wrappedValue = "Yes."
        f.answer.handled(f.comment).wrappedValue = true
        f.takes = false
        let (answer, pr) = (f.answer, f.pr)
        f.during = {
            #expect(flow.busy)
            answer.open(pr)
        }
        f.answer.send()
        await f.answer.task?.value
        #expect(f.opened.values == [.answer, .answer] && f.answer.flow === flow)
        #expect(f.sent.values.count == 1 && f.answer.error == AnswerPanels.notSentText)
        #expect(flow.answers[f.thread] == "Yes." && f.closed.values.isEmpty)
        await f.end()
    }

    // The block of failed CI comes first. Its title has seven characters of the head, its names
    // line has five names and the count of the rest, and the check turns its text area off. A
    // panel with only a CI question has something to show, with the intro of the CI question.
    @Test func theCIBlockShowsTheHeadTheJobsAndTheQuestion() async throws {
        let f = try await AnswerPanelFixture()
        let head = try #require(CommitID("0123456789abcdef0123456789abcdef01234567"))
        #expect(AnswerPanels.ciTitle(head) == "Failed checks on 0123456")
        #expect(AnswerPanels.ciNames([]) == nil)
        #expect(AnswerPanels.ciNames(["a", "b"]) == "Failed: a, b")
        let seven = (1...7).map { "job \($0)" }
        #expect(
            AnswerPanels.ciNames(seven) == "Failed: job 1, job 2, job 3, job 4, job 5 and 2 more")
        #expect(AnswerPanels.fixCIText == "I'll fix CI myself")
        let question = CIQuestion(
            text: "CI still fails. What next?", head: head, jobs: Array(seven.prefix(5)),
            at: Date(), byClaude: true)
        f.ci = OpenCIQuestion(question: question, failedJobs: seven)
        f.answer.open(f.pr)
        let flow = try #require(f.answer.flow)
        #expect(flow.ciQuestion?.question.text == "CI still fails. What next?")
        #expect(!f.answer.showsNothing && f.answer.intro == AnswerPanels.introText)
        f.answer.handled(f.thread).wrappedValue = true
        f.answer.handled(f.comment).wrappedValue = true
        #expect(!flow.canSubmit)
        f.answer.ciAnswer.wrappedValue = "Try the other job."
        #expect(flow.canSubmit && !f.answer.ciHandled.wrappedValue)
        f.answer.ciHandled.wrappedValue = true
        #expect(flow.ciHandled && flow.canSubmit)
        f.answer.send()
        await waitUntil { !f.closed.values.isEmpty }
        #expect(f.sentCI.values == [.handleMyself] && f.closed.values == [.answer])
        // Only a CI question: the panel shows it, and no comment send goes.
        await f.store.update { $0.prs[f.pr]?.questions = [:] }
        f.answer.open(f.pr)
        #expect(f.answer.questions.isEmpty && !f.answer.showsNothing)
        #expect(f.answer.intro == AnswerPanels.ciIntroText)
        #expect(
            AnswerPanels.ciIntroText
                == "The failed checks on this pull request need your answer before Claude can "
                + "carry on.")
        f.ci = nil
        #expect(f.answer.showsNothing)
        await f.end()
    }
}
