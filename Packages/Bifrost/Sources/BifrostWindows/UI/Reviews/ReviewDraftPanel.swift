// The Review panel (docs/behaviour/reviews.md, "The Review panel"; PanelID.reviewDraft): the user
// checks Claude's draft review for one To review row, edits it, and sends it, discards it or
// approves instead. The flow (DraftFlow) reads the draft from GitHub at the open and again before
// each write, and holds the edits until Send review.
//
// - Comment or Request changes on a row (or in its menu) opens the panel for that PR: it reads
//   the draft and starts with no edits. While the panel is open for that PR and shows the draft
//   that the row offers, or an action runs, a second open only brings it forward, and the edits,
//   the action and its result stay. A close drops them.
// - When Reviews stops (Watch GitHub off), the panel closes.
// - The panel shows Claude's suggestion and its reason, the summary, and each comment with its
//   place, the last lines of its diff hunk and "Added by you" for a comment that the user added
//   on GitHub. A comment can be removed and brought back (Undo). All text from GitHub shows as
//   plain text only.
// - The footer has Discard draft and Approve instead, the "Send as" switch (Comment or Request
//   changes, at first Claude's suggestion) and Send review. Each button makes the click of the
//   user in its action. A PR that changed after the review allows only Discard draft, and a row
//   that no longer offers the draft allows nothing and says so.
// - A delete of a draft that holds comments of the user asks first (Keep draft, or the button
//   again in the strip).
// - An action that worked closes the panel. A refusal shows in the error line, and the edits stay.
import AppKit
import BifrostFoundation
import BifrostLayout
import BifrostLook
import BifrostReviews
import Observation
import SwiftUI

@MainActor
@Observable
package final class ReviewDraftPanels: PanelBodiesPart {
    // A delete that waits for the confirm of the user.
    package enum Confirm: Sendable, Equatable {
        case discard, approve
    }

    nonisolated package static let nothingText = "Nothing to review right now."
    nonisolated package static let loadingText = "Loading the draft from GitHub\u{2026}"
    nonisolated package static let notOpenedText = "Bifrost couldn't open the draft."
    nonisolated package static let changedText =
        "This pull request changed after Claude's review, so you can't send or approve this "
        + "draft. You can still discard it."
    nonisolated package static let lockedText =
        "You can't change this draft right now. The row in the Reviews panel shows why."

    // The PR of the panel, or nil.
    package private(set) var pr: PRKey?
    // The flow of the open, or nil while Reviews doesn't run.
    package private(set) var flow: DraftFlow?
    // The "Send as" switch.
    package var event = DraftEvent.comment
    // The delete that waits for the confirm, or nil.
    package private(set) var confirm: Confirm?
    // The reason of the open or of the last action that didn't work, until the user closes it.
    package private(set) var error: String?

    @ObservationIgnored package let links: ReviewsPanelLinks
    @ObservationIgnored private let look: PanelLook
    @ObservationIgnored private var host: NSView?
    // The last open or action. A test waits for it.
    @ObservationIgnored package private(set) var task: Task<Void, Never>?

    package init(links: ReviewsPanelLinks, look: PanelLook) {
        self.links = links
        self.look = look
    }

    var style: PanelStyle {
        PanelStyle(metrics: look.metrics, transparency: look.panelTransparency)
    }

    // Open the panel for Claude's draft of the PR. While the panel is open for the PR and its
    // flow runs an action or shows the draft that the row offers, the open only brings it
    // forward: the flow keeps the edits, the action and its result. Else (an open that failed, a
    // newer draft of Claude) a new flow reads the draft from GitHub. An action of an earlier flow
    // goes on to its end (a write is never cut), and its result no longer shows.
    package func open(_ pr: PRKey) {
        if pr == self.pr, let flow, flow.busy || flow.isCurrent {
            links.openPanel(.reviewDraft)
            return
        }
        self.pr = pr
        confirm = nil
        error = nil
        event = .comment
        let flow = links.makeDraftFlow()
        self.flow = flow
        links.openPanel(.reviewDraft)
        guard let flow else {
            error = DraftRefusal.notOffered.message
            return
        }
        task = Task { [weak self] in
            do throws(DraftRefusal) {
                try await flow.open(pr)
                guard let self, self.flow === flow, let shown = flow.shown else { return }
                event = shown.recommendation == .requestChanges ? .requestChanges : .comment
            } catch {
                guard let self, self.flow === flow else { return }
                self.error = error.message
            }
        }
    }

    // MARK: - What the panel shows

    // The row of the PR in the To review tab of now, or nil.
    var row: ReviewRow? {
        guard let pr else { return nil }
        return links.snapshot().toReview.first { $0.id == pr }
    }

    // True when the row no longer offers the draft (an unknown result, a round, a draft that went,
    // Reviews off), while no action of the panel runs.
    package var isLocked: Bool {
        guard let flow, flow.shown != nil, !flow.busy else { return false }
        return row?.draft == nil
    }

    // The count of the comments that the user added to the draft on GitHub.
    package var yoursCount: Int { flow?.comments.count(where: \.yours) ?? 0 }

    // Discard draft acts while a draft shows, no action runs and the row offers the draft.
    package var canDiscard: Bool {
        guard let flow, flow.shown != nil, !flow.busy else { return false }
        return !isLocked
    }

    // Send review and Approve instead also need the reviewed commit as the head of the PR.
    package var canSend: Bool {
        canDiscard && flow?.shown?.headMoved == false
    }

    // The text of the confirm strip.
    package func confirmText(_ confirm: Confirm) -> String {
        let button = confirm == .discard ? "Discard draft" : "Approve instead"
        let count = yoursCount
        let what = count == 1 ? "the comment" : "the \(count) comments"
        return "\(button) also deletes \(what) you added to this draft on GitHub."
    }

    // MARK: - The actions

    // Send review with the event of the switch.
    package func send(click: UserClick) {
        guard canSend, let flow else { return }
        let event = event
        run(flow) { () async throws(DraftRefusal) in try await flow.send(event, click: click) }
    }

    // Discard draft. A draft with comments of the user asks first.
    package func discard(click: UserClick) {
        guard canDiscard, let flow else { return }
        if yoursCount > 0 && confirm != .discard {
            confirm = .discard
            return
        }
        run(flow) { () async throws(DraftRefusal) in try await flow.discard(click: click) }
    }

    // Approve instead. A draft with comments of the user asks first.
    package func approveInstead(click: UserClick) {
        guard canSend, let flow else { return }
        if yoursCount > 0 && confirm != .approve {
            confirm = .approve
            return
        }
        run(flow) { () async throws(DraftRefusal) in
            try await flow.approveInstead(click: click)
        }
    }

    // Keep draft: the user does not confirm the delete.
    package func keepDraft() {
        confirm = nil
    }

    package func closeError() {
        error = nil
    }

    // The text of a comment in the panel, by its ID.
    func text(of comment: NodeID) -> Binding<String> {
        Binding(
            get: { [weak self] in
                self?.flow?.comments.first { $0.id == comment }?.text ?? ""
            },
            set: { [weak self] text in
                guard let flow = self?.flow,
                    let index = flow.comments.firstIndex(where: { $0.id == comment })
                else { return }
                flow.comments[index].text = text
            })
    }

    // Remove the comment, or bring it back.
    func setRemoved(_ comment: NodeID, _ removed: Bool) {
        guard let flow, let index = flow.comments.firstIndex(where: { $0.id == comment }) else {
            return
        }
        flow.comments[index].removed = removed
    }

    // Run an action of the flow. One that worked closes the panel. After a refusal the edits
    // stay, so the user can try again. The result of a flow of an earlier open does not show.
    private func run(
        _ flow: DraftFlow, _ action: @escaping @MainActor () async throws(DraftRefusal) -> Void
    ) {
        error = nil
        task = Task { [weak self] in
            let refusal: DraftRefusal?
            do throws(DraftRefusal) {
                try await action()
                refusal = nil
            } catch {
                refusal = error
            }
            guard let self, self.flow === flow else { return }
            confirm = nil
            if let refusal {
                error = refusal.message
            } else {
                links.closePanel(.reviewDraft)
            }
        }
    }

    // Reviews stopped: the panel closes, and the flow and its edits go, because the flow holds
    // the closed store. An action that runs goes on to its end, and its result does not show.
    package func reviewsStopped() {
        let open = pr != nil || host != nil
        pr = nil
        flow = nil
        confirm = nil
        error = nil
        if open { links.closePanel(.reviewDraft) }
    }

    // MARK: - PanelBodiesPart

    package func body(for panel: PanelID) -> NSView? {
        guard panel == .reviewDraft else { return nil }
        if let host { return host }
        let host = NSHostingView(rootView: ReviewDraftPanel(panels: self))
        host.sizingOptions = []
        self.host = host
        return host
    }

    // The PR of the panel after its title.
    package func titleSuffix(for panel: PanelID) -> String? {
        guard panel == .reviewDraft, let pr else { return nil }
        return "\(pr.repo) #\(pr.number)"
    }

    // The panel closed: the flow and its edits go.
    package func releaseBody(for panel: PanelID) {
        guard panel == .reviewDraft else { return }
        host = nil
        pr = nil
        flow = nil
        confirm = nil
        error = nil
    }
}

// The body of the Review panel.
struct ReviewDraftPanel: View {
    let panels: ReviewDraftPanels

    var body: some View {
        let style = panels.style
        VStack(alignment: .leading, spacing: 0) {
            if let flow = panels.flow, let shown = flow.shown {
                draft(flow, shown, style)
            } else {
                Text(placeholder)
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

    private var placeholder: String {
        guard panels.pr != nil else { return ReviewDraftPanels.nothingText }
        return panels.error == nil ? ReviewDraftPanels.loadingText : ReviewDraftPanels.notOpenedText
    }

    @ViewBuilder
    private func draft(_ flow: DraftFlow, _ shown: DraftFlow.Shown, _ style: PanelStyle)
        -> some View
    {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: style.points(4)) {
                suggestion(shown)
                if shown.headMoved {
                    Text(ReviewDraftPanels.changedText).foregroundStyle(style.dim)
                }
                label("Summary", style)
                ReviewTextArea(
                    text: Binding(get: { flow.summary }, set: { flow.summary = $0 }),
                    placeholder: "Write a summary", lines: 4, style: style
                )
                .disabled(flow.busy)
                label("Comments (\(flow.comments.count))", style)
                if flow.comments.isEmpty {
                    Text("No comments in this draft.").foregroundStyle(style.dim)
                }
                ForEach(flow.comments) { comment in
                    CommentBox(panels: panels, comment: comment, busy: flow.busy, style: style)
                }
            }
            .padding(.horizontal, style.points(12))
            .padding(.vertical, style.points(8))
        }
        if let confirm = panels.confirm { confirmStrip(confirm, style) }
        if panels.isLocked {
            strip(style) { Text(ReviewDraftPanels.lockedText).foregroundStyle(style.dim) }
        }
        footer(style)
    }

    // "Claude suggests: Request changes. Why."
    private func suggestion(_ shown: DraftFlow.Shown) -> some View {
        let name = RowText.recommendation(shown.recommendation)
        var text = AttributedString("Claude suggests: ")
        var value = AttributedString(name)
        value.foregroundColor = Self.tone(shown.recommendation).colour
        text += value
        text += AttributedString(shown.why.isEmpty ? "." : ". \(shown.why)")
        return Text(text).fixedSize(horizontal: false, vertical: true)
    }

    private func label(_ text: String, _ style: PanelStyle) -> some View {
        Text(text.uppercased())
            .font(style.font(10))
            .foregroundStyle(style.dim)
            .padding(.top, style.points(8))
    }

    private func confirmStrip(_ confirm: ReviewDraftPanels.Confirm, _ style: PanelStyle)
        -> some View
    {
        strip(style) {
            Text(panels.confirmText(confirm)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: style.points(8))
            Button("Keep draft") { panels.keepDraft() }
                .buttonStyle(RowButtonStyle(tone: .plain, style: style))
                .focusable(false)
            Button(confirm == .discard ? "Discard draft" : "Approve instead") {
                if confirm == .discard {
                    panels.discard(click: UserClick())
                } else {
                    panels.approveInstead(click: UserClick())
                }
            }
            .buttonStyle(RowButtonStyle(tone: .plain, style: style))
            .disabled(confirm == .discard ? !panels.canDiscard : !panels.canSend)
            .focusable(false)
        }
    }

    private func footer(_ style: PanelStyle) -> some View {
        strip(style) {
            Button("Discard draft") { panels.discard(click: UserClick()) }
                .buttonStyle(RowButtonStyle(tone: .plain, style: style))
                .disabled(!panels.canDiscard)
                .focusable(false)
            Button("Approve instead") { panels.approveInstead(click: UserClick()) }
                .buttonStyle(RowButtonStyle(tone: .tinted(.green), style: style))
                .disabled(!panels.canSend)
                .focusable(false)
            Spacer(minLength: style.points(8))
            Text("Send as").foregroundStyle(style.dim)
            HStack(spacing: 0) {
                ForEach([DraftEvent.comment, .requestChanges], id: \.self) { event in
                    SendAsButton(
                        title: event == .comment ? "Comment" : "Request changes",
                        on: panels.event == event, tone: Self.tone(event), style: style
                    ) { panels.event = event }
                    .disabled(panels.flow?.busy != false)
                }
            }
            .overlay { Rectangle().strokeBorder(style.edge, lineWidth: style.points(1)) }
            Button("Send review") { panels.send(click: UserClick()) }
                .buttonStyle(RowButtonStyle(tone: .tinted(Self.tone(panels.event)), style: style))
                .disabled(!panels.canSend)
                .focusable(false)
        }
    }

    private func strip(_ style: PanelStyle, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: style.points(6)) { content() }
            .padding(.horizontal, style.points(12))
            .padding(.vertical, style.points(6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { EdgeLineView(metrics: style.metrics) }
    }

    // The colour of a recommendation and of an event: green, amber or red.
    static func tone(_ recommendation: Recommendation) -> RowTone {
        switch recommendation {
        case .approve: .green
        case .comment: .amber
        case .requestChanges: .red
        }
    }

    static func tone(_ event: DraftEvent) -> RowTone {
        event == .comment ? .amber : .red
    }
}

// One comment of the draft: the place, "Added by you", Remove or Undo, the last lines of the diff
// hunk and the text.
private struct CommentBox: View {
    let panels: ReviewDraftPanels
    let comment: DraftCommentEdit
    let busy: Bool
    let style: PanelStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: style.points(8)) {
                Text(comment.place)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if comment.yours { Text("Added by you").foregroundStyle(style.dim) }
                Button(comment.removed ? "Undo" : "Remove") {
                    panels.setRemoved(comment.id, !comment.removed)
                }
                .buttonStyle(.plain)
                .underline()
                .foregroundStyle(style.dim)
                .disabled(busy)
                .focusable(false)
            }
            .padding(.horizontal, style.points(8))
            .padding(.vertical, style.points(2))
            .background(Color.white.opacity(0.04))
            if comment.removed {
                Text("You removed this comment.")
                    .foregroundStyle(style.dim)
                    .padding(.horizontal, style.points(8))
                    .padding(.vertical, style.points(4))
            } else {
                if !comment.hunk.isEmpty {
                    Text(comment.hunk.joined(separator: "\n"))
                        .font(.system(size: style.points(11), design: .monospaced))
                        .foregroundStyle(style.dim)
                        .lineLimit(nil)
                        .padding(.horizontal, style.points(8))
                        .padding(.vertical, style.points(4))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.4))
                }
                ReviewTextArea(
                    text: panels.text(of: comment.id), placeholder: "", lines: 3, style: style
                )
                .disabled(busy)
            }
        }
        .overlay { Rectangle().strokeBorder(style.edge, lineWidth: style.points(1)) }
        .padding(.bottom, style.points(4))
    }
}

// One side of the "Send as" switch: the colour of its event while it is on.
private struct SendAsButton: View {
    let title: String
    let on: Bool
    let tone: RowTone
    let style: PanelStyle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, style.points(6))
                .frame(minHeight: style.points(16))
                .foregroundStyle(on ? tone.colour : style.dim)
                .background(on ? tone.colour.opacity(0.12) : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

// A text area of the Reviews panels: plain text of many lines, in the look of the text fields of
// the panels, with a placeholder while it is empty.
struct ReviewTextArea: View {
    @Binding var text: String
    let placeholder: String
    // The height of the area in lines.
    let lines: Int
    let style: PanelStyle

    var body: some View {
        TextEditor(text: $text)
            .font(style.font)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, style.points(2))
            .padding(.vertical, style.points(2))
            .frame(minHeight: style.points(Double(lines) * 17 + 8))
            .background(alignment: .topLeading) {
                if text.isEmpty && !placeholder.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(style.dim)
                        .padding(.horizontal, style.points(7))
                        .padding(.vertical, style.points(2))
                        .allowsHitTesting(false)
                }
            }
            .background(Color.black.opacity(0.35))
            .overlay { Rectangle().strokeBorder(style.edge, lineWidth: style.points(1)) }
    }
}
