// The Answer panel (docs/behaviour/reviews.md, "The Answer panel"; PanelID.answer): the user
// answers the open questions of Claude on one PR of the My PRs tab, or says that they handle a
// comment themselves. The flow (AnswerFlow) holds the answers until Send to Claude.
//
// - Answer Claude in the row menu, or a click on a row with open questions, opens the panel for
//   that PR, with no answers. While the panel is open for that PR, a second open only brings it
//   forward, and the answers, a running send and its result stay. A close drops them.
// - When Reviews stops (Watch GitHub off), the panel closes.
// - Each question shows the quote of the reviewer's comment (its author and its place, with View
//   on GitHub) or only the place, then the question, a text area and "I'll handle this one
//   myself", which turns the text area off.
// - Send to Claude acts when each question has an answer or the check, and sends all of them in
//   one call: the answers start one request round, and a handled comment is handled with no
//   round. The panel then closes. Cancel closes the panel and sends nothing.
// - The reason of the last failed round of the PR shows under the intro, because the row shows
//   Needs you while questions are open.
import AppKit
import BifrostFoundation
import BifrostLayout
import BifrostLook
import BifrostReviews
import BifrostSessions
import Observation
import SwiftUI

@MainActor
@Observable
package final class AnswerPanels: PanelBodiesPart {
    nonisolated package static let introText =
        "Claude couldn't decide these on its own. Tell it what you'd like, or handle a comment "
        + "yourself."
    nonisolated package static let nothingText = "Nothing to answer right now."
    nonisolated package static let tooManyText =
        "Bifrost can send only a limited number of answers at a time (\(AnswerFlow.maxAnswers))."
    nonisolated package static let handleText = "I'll handle this one myself"
    nonisolated package static let notSentText =
        "Bifrost couldn't send your answers, because the questions changed. Check them, then "
        + "send them again."

    // The PR of the panel, or nil.
    package private(set) var pr: PRKey?
    // The flow of the open, or nil while Reviews doesn't run.
    package private(set) var flow: AnswerFlow?
    // The reason of the last send or open of a link that didn't work, until the user closes it.
    package private(set) var error: String?

    @ObservationIgnored package let links: ReviewsPanelLinks
    @ObservationIgnored private let opener: any AppOpener
    @ObservationIgnored private let look: PanelLook
    @ObservationIgnored private var host: NSView?
    // The last send or open of a link. A test waits for it.
    @ObservationIgnored package private(set) var task: Task<Void, Never>?

    package init(links: ReviewsPanelLinks, opener: any AppOpener, look: PanelLook) {
        self.links = links
        self.opener = opener
        self.look = look
    }

    var style: PanelStyle {
        PanelStyle(metrics: look.metrics, transparency: look.panelTransparency)
    }

    // Open the panel for the open questions of Claude on the PR, with no answers. While the
    // panel is open for the PR, the open only brings it forward, and the flow keeps the answers,
    // a running send and its result.
    package func open(_ pr: PRKey) {
        if pr == self.pr, flow != nil {
            links.openPanel(.answer)
            return
        }
        self.pr = pr
        error = nil
        flow = links.makeAnswerFlow(pr)
        links.openPanel(.answer)
    }

    // The open questions, or none while the panel has no flow.
    package var questions: [OpenQuestion] { flow?.questions ?? [] }

    // Send to Claude. The panel closes when the rounds took the answers. The result of a flow of
    // an earlier open does not show.
    package func send() {
        guard let flow, flow.canSubmit else { return }
        error = nil
        task = Task { [weak self] in
            let taken = await flow.submit()
            guard let self, self.flow === flow else { return }
            if taken {
                links.closePanel(.answer)
            } else {
                error = Self.notSentText
            }
        }
    }

    // Cancel: the panel closes and sends nothing.
    package func cancel() {
        links.closePanel(.answer)
    }

    // View on GitHub: the comment of the question in the browser, only at its https address on
    // github.com (Question.url).
    package func openComment(_ question: OpenQuestion) {
        guard let url = question.question.url, url.scheme == "https",
            url.host(percentEncoded: false)?.lowercased() == "github.com"
        else { return }
        let opener = opener
        task = Task { [weak self] in
            do throws(ActionRefusal) {
                try await opener.openInBrowser(url)
            } catch {
                self?.error = error.message
            }
        }
    }

    package func closeError() {
        error = nil
    }

    // The answer of the item, for its text area.
    func answer(_ item: NodeID) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.flow?.answers[item] ?? "" },
            set: { [weak self] in self?.flow?.answer(item, $0) })
    }

    // The check "I'll handle this one myself" of the item.
    func handled(_ item: NodeID) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.flow?.handled.contains(item) ?? false },
            set: { [weak self] in self?.flow?.handleMyself(item, $0) })
    }

    // Reviews stopped: the panel closes, and the flow and its answers go, because the flow holds
    // the closed store. A send that runs goes on to its end, and its result does not show.
    package func reviewsStopped() {
        let open = pr != nil || host != nil
        pr = nil
        flow = nil
        error = nil
        if open { links.closePanel(.answer) }
    }

    // MARK: - PanelBodiesPart

    package func body(for panel: PanelID) -> NSView? {
        guard panel == .answer else { return nil }
        if let host { return host }
        let host = NSHostingView(rootView: AnswerPanel(panels: self))
        host.sizingOptions = []
        self.host = host
        return host
    }

    // The PR of the panel after its title.
    package func titleSuffix(for panel: PanelID) -> String? {
        guard panel == .answer, let pr else { return nil }
        return "\(pr.repo) #\(pr.number)"
    }

    // The panel closed: the flow and its answers go.
    package func releaseBody(for panel: PanelID) {
        guard panel == .answer else { return }
        host = nil
        pr = nil
        flow = nil
        error = nil
    }
}

// The body of the Answer panel.
struct AnswerPanel: View {
    let panels: AnswerPanels

    var body: some View {
        let style = panels.style
        let questions = panels.questions
        VStack(alignment: .leading, spacing: 0) {
            if let flow = panels.flow, !questions.isEmpty {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: style.points(4)) {
                        Text(AnswerPanels.introText).fixedSize(horizontal: false, vertical: true)
                        if flow.tooMany {
                            Text(AnswerPanels.tooManyText).foregroundStyle(style.dim)
                        }
                        if let reason = flow.lastError {
                            Text(reason)
                                .foregroundStyle(style.dim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(questions) { question in
                            QuestionView(
                                panels: panels, question: question,
                                handled: flow.handled.contains(question.id), style: style)
                        }
                    }
                    .padding(.horizontal, style.points(12))
                    .padding(.vertical, style.points(8))
                }
                footer(flow, style)
            } else {
                Text(AnswerPanels.nothingText)
                    .foregroundStyle(style.dim)
                    .padding(.horizontal, style.points(12))
                    .padding(.vertical, style.points(8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if let error = panels.error {
                ErrorLineView(text: error, metrics: style.metrics) { panels.closeError() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .font(style.font)
        .foregroundStyle(ThemeTokens.text.color)
    }

    private func footer(_ flow: AnswerFlow, _ style: PanelStyle) -> some View {
        HStack(spacing: style.points(6)) {
            Spacer(minLength: 0)
            Button("Cancel") { panels.cancel() }
                .buttonStyle(RowButtonStyle(tone: .plain, style: style))
                .focusable(false)
            Button("Send to Claude") { panels.send() }
                .buttonStyle(RowButtonStyle(tone: .strong, style: style))
                .disabled(!flow.canSubmit)
                .focusable(false)
        }
        .padding(.horizontal, style.points(12))
        .padding(.vertical, style.points(6))
        .overlay(alignment: .top) { EdgeLineView(metrics: style.metrics) }
    }
}

// One question: the quote of the comment or the place, the question, the answer and the check.
private struct QuestionView: View {
    let panels: AnswerPanels
    let question: OpenQuestion
    let handled: Bool
    let style: PanelStyle

    var body: some View {
        VStack(alignment: .leading, spacing: style.points(4)) {
            if let comment = question.question.body, !comment.trimmed().isEmpty {
                quote(comment)
            } else {
                Text(question.question.place).foregroundStyle(style.dim)
            }
            Text(question.question.text)
                .foregroundStyle(ThemeTokens.textStrong.color)
                .fixedSize(horizontal: false, vertical: true)
            ReviewTextArea(
                text: panels.answer(question.id), placeholder: "Type your answer", lines: 3,
                style: style
            )
            .disabled(handled)
            .opacity(handled ? 0.4 : 1)
            Toggle(AnswerPanels.handleText, isOn: panels.handled(question.id))
                .toggleStyle(.checkbox)
                .focusable(false)
        }
        .padding(.top, style.points(8))
    }

    // The comment of the reviewer: its author and place with View on GitHub, then its text.
    private func quote(_ comment: String) -> some View {
        VStack(alignment: .leading, spacing: style.points(2)) {
            HStack(alignment: .firstTextBaseline, spacing: style.points(8)) {
                Text(question.header)
                    .foregroundStyle(style.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if question.question.url != nil {
                    Button("View on GitHub") { panels.openComment(question) }
                        .buttonStyle(.plain)
                        .underline()
                        .focusable(false)
                }
            }
            Text(comment).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, style.points(8))
        .padding(.vertical, style.points(2))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.3))
        .overlay(alignment: .leading) {
            Rectangle().fill(style.edge).frame(width: style.points(2))
        }
    }
}
