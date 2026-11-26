// The Review panel (docs/behaviour/reviews.md, "The Review panel"; PanelID.reviewDraft) for one
// To review row. It has two forms, and it shows one of them at a time:
// - The draft form: the user checks Claude's draft review, edits it, and sends it, discards it or
//   approves instead. The flow (DraftFlow) reads the draft from GitHub at the open and again
//   before each write, and holds the edits until Send review.
// - The findings form (ReviewFindingsPanel.swift): the user reads Claude's note and findings of
//   an approval, ticks the findings to post, can type a summary, and then comments, requests
//   changes or approves. The flow (FindingsFlow) reads only the state at the open.
//
// - Comment or Request changes on a row (or in its menu) opens the draft form for that PR: it
//   reads the draft and starts with no edits. Approve on Claude's old Approve draft opens the
//   same form. Approve on a finding above a nit, and See Claude's review, open the findings form:
//   the bug and minor findings start ticked, the nits start unticked under the closed Nits row.
// - While the panel is open for that PR and shows what the row offers, or an action runs, a
//   second open of the same form only brings it forward, and the edits (or the ticks and the
//   summary), the action and its result stay. A close drops them.
// - When Reviews stops (Watch GitHub off), the panel closes.
// - The draft form shows Claude's suggestion and its reason, Claude's private note, the summary,
//   and each comment with its place, the last lines of its diff hunk and "Added by you" for a
//   comment that the user added on GitHub. A comment can be removed and brought back (Undo). All
//   text from GitHub and from Claude's result shows as plain text only. The note never goes into
//   a write.
// - The footer has Discard draft and Approve instead, the "Send as" switch (Comment or Request
//   changes, at first Claude's suggestion) and Send review. Each button makes the click of the
//   user in its action, and the action starts in the click. A PR that changed after the review
//   allows only Discard draft, and a row that no longer offers the draft allows nothing and says
//   so. While a send of the draft runs, its progress takes the place of Send review
//   (WriteProgressLabel), as on the row, so a second click finds no button. The place of the
//   button keeps one width, so "Send as" and the switch do not move (SendSlot).
// - While a review write of the PR may have gone and no poll after it has shown the true state
//   (ReviewWrites.waitsForPoll), no button of either form acts, and a strip above the footer says
//   why, so the panel explains itself however you got there.
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
    nonisolated package static let notOpenedFindingsText = "Bifrost couldn't open Claude's review."
    nonisolated package static let lockedFindingsText =
        "You can't send this review right now, its row in the Reviews panel shows why."

    // The form of the last open: Claude's draft, or Claude's findings.
    enum Form {
        case draft, findings
    }

    // The PR of the panel, or nil.
    package private(set) var pr: PRKey?
    // The form of the last open. The placeholder of an open that failed follows it.
    private(set) var form = Form.draft
    // The flow of the draft form, or nil while Reviews doesn't run or the findings form shows.
    package private(set) var flow: DraftFlow?
    // The flow of the findings form, or nil while Reviews doesn't run or the draft form shows.
    package private(set) var findings: FindingsFlow?
    // True while the Nits row of the findings form is open. Each open closes it.
    package private(set) var nitsOpen = false
    // The "Send as" switch.
    package var event = DraftEvent.comment
    // The delete that waits for the confirm, or nil.
    package private(set) var confirm: Confirm?
    // The reason of the open or of the last action that didn't work, until the user closes it.
    package private(set) var error: String? {
        didSet { if error == nil { errorMayHaveChanged = false } }
    }
    // True when the error line is about a write that GitHub may have acted on, so it already says
    // as much as the wait strip would, in its own words.
    private var errorMayHaveChanged = false

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
        form = .draft
        findings = nil
        nitsOpen = false
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

    // Open the panel on Claude's findings of the PR. While the panel shows the findings of the
    // PR that the row offers, or an action of the findings form runs, the open only brings it
    // forward: the ticks, the summary, the Nits row, the action and its result stay. Else a new
    // flow shows the note and the findings of the mark, which are in the state, so the open reads
    // nothing from GitHub. An action of an earlier flow goes on to its end, and its result no
    // longer shows.
    package func openFindings(_ pr: PRKey) {
        if pr == self.pr, let findings, findings.busy || findings.isCurrent {
            links.openPanel(.reviewDraft)
            return
        }
        self.pr = pr
        form = .findings
        flow = nil
        confirm = nil
        error = nil
        nitsOpen = false
        let findings = links.makeFindingsFlow()
        self.findings = findings
        links.openPanel(.reviewDraft)
        guard let findings else {
            error = FindingsRefusal.notOffered.message
            return
        }
        do throws(FindingsRefusal) {
            try findings.open(pr)
        } catch {
            self.error = error.message
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
        return row?.offersDraft != true
    }

    // The count of the comments that the user added to the draft on GitHub.
    package var yoursCount: Int { flow?.comments.count(where: \.yours) ?? 0 }

    // True while a review write of the PR may have gone and no poll after it has shown the true
    // state on GitHub (ReviewWrites.waitsForPoll). No button of the panel acts then.
    var waitsForPoll: Bool {
        guard let pr else { return false }
        return links.writes()?.waitsForPoll(pr) == true
    }

    // What the strip above the footer says while the PR waits for a poll, or nil. It shows in both
    // forms, also after a close and a new open or when the wait started elsewhere, but not while
    // the error line is about a write that GitHub may have acted on: that line already explains
    // the wait, and two takes on it would only disagree.
    package var waitText: String? {
        guard waitsForPoll, flow?.shown != nil || findings?.shown != nil else { return nil }
        if error != nil && errorMayHaveChanged { return nil }
        return FindingsRefusal.unknown.message
    }

    // Discard draft acts while a draft shows, no action runs, the row offers the draft and no
    // review write of the PR waits for a poll.
    package var canDiscard: Bool {
        guard let flow, flow.shown != nil, !flow.busy else { return false }
        return !isLocked && !waitsForPoll
    }

    // Send review and Approve instead also need the reviewed commit as the head of the PR.
    package var canSend: Bool {
        canDiscard && flow?.shown?.headMoved == false
    }

    // The review of the send of the draft of the PR while it runs, or nil (ReviewWrites). Its
    // progress shows in the place of Send review.
    package var sending: ReviewVerdict? {
        guard let pr, case .running(let review)? = links.writes()?.progress(pr),
            review != .approve
        else { return nil }
        return review
    }

    // MARK: - What the findings form shows

    // True when the row no longer offers the findings that the form shows (a round, a newer mark
    // of Claude, an answer that changed the row, Reviews off), or a check found your unsure
    // Comment on GitHub, while no action of the form runs.
    package var findingsLocked: Bool {
        guard let findings, findings.shown != nil, !findings.busy else { return false }
        return row?.findingsPanel != true || !findings.isCurrent || findings.commentFound
    }

    // Comment, Request changes and Approve act while the findings show, no action runs, the form
    // is not locked, no review write of the PR runs and none waits for a poll.
    package var canPost: Bool {
        guard let findings, findings.shown != nil, !findings.busy else { return false }
        return !findingsLocked && !findings.waitsForPoll && posting == nil
    }

    // The review of the write of the PR while it runs and the findings form shows, or nil
    // (ReviewWrites). Its progress takes the place of the three buttons.
    package var posting: ReviewVerdict? {
        guard let pr, findings?.shown != nil,
            case .running(let review)? = links.writes()?.progress(pr)
        else { return nil }
        return review
    }

    // The indexes of the findings above a nit, as the form lists them: the bugs, then the minor
    // findings, each in the order of the result.
    package var findingRows: [Int] {
        guard let found = findings?.shown?.findings else { return [] }
        return [FindingKind.bug, .minor].flatMap { kind in
            found.indices.filter { found[$0].kind == kind }
        }
    }

    // The indexes of the nits, in the order of the result. They show under the Nits row.
    package var nitRows: [Int] {
        guard let found = findings?.shown?.findings else { return [] }
        return found.indices.filter { found[$0].kind == .nit }
    }

    // The line above the three buttons: what a button posts now. It counts the ticked findings,
    // and a summary that is all white space counts as no summary.
    package var postHint: String {
        guard let findings, let shown = findings.shown else { return "" }
        let count = findings.ticked.count(where: { shown.findings.indices.contains($0) })
        let summary = !findings.summary.trimmed().isEmpty
        let ticks = count == 1 ? "the finding you ticked" : "the \(count) findings you ticked"
        switch (count > 0, summary) {
        case (false, false): return "Approve will post just your approval, with no comment."
        case (true, false): return "Your review will include \(ticks)."
        case (false, true): return "Your review will include your summary."
        case (true, true): return "Your review will include your summary and \(ticks)."
        }
    }

    // The tick of the finding at the index of the mark.
    func ticked(_ index: Int) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.findings?.ticked.contains(index) == true },
            set: { [weak self] on in
                guard let findings = self?.findings else { return }
                if on {
                    findings.ticked.insert(index)
                } else {
                    findings.ticked.remove(index)
                }
            })
    }

    // The summary that the user types in the findings form.
    var findingSummary: Binding<String> {
        Binding(
            get: { [weak self] in self?.findings?.summary ?? "" },
            set: { [weak self] text in self?.findings?.summary = text })
    }

    // Open or close the Nits row.
    package func toggleNits() {
        nitsOpen.toggle()
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

    // Approve in the findings form: the ticked findings and the summary go with the approval,
    // and with nothing ticked and no summary it is a plain approval with no text.
    package func approveFindings(click: UserClick) {
        guard canPost, let findings else { return }
        runFindings(findings) { () async throws(FindingsRefusal) in
            try await findings.approve(click: click)
        }
    }

    // Comment or Request changes in the findings form: one review write of the ticked findings
    // and the summary with the event.
    package func sendFindings(_ event: DraftEvent, click: UserClick) {
        guard canPost, let findings else { return }
        runFindings(findings) { () async throws(FindingsRefusal) in
            try await findings.send(event, click: click)
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
    // The action starts in the click, so the flow is busy and a send shows its progress before a
    // second click can come.
    private func run(
        _ flow: DraftFlow, _ action: @escaping @MainActor () async throws(DraftRefusal) -> Void
    ) {
        error = nil
        task = Task.immediate { [weak self] in
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
                errorMayHaveChanged = refusal.mayHaveChanged
            } else {
                links.closePanel(.reviewDraft)
            }
        }
    }

    // Run an action of the findings form, as run does for the draft form. One that worked closes
    // the panel. After a refusal the ticks and the summary stay. The result of a flow of an
    // earlier open does not show.
    private func runFindings(
        _ findings: FindingsFlow,
        _ action: @escaping @MainActor () async throws(FindingsRefusal) -> Void
    ) {
        error = nil
        task = Task.immediate { [weak self] in
            let refusal: FindingsRefusal?
            do throws(FindingsRefusal) {
                try await action()
                refusal = nil
            } catch {
                refusal = error
            }
            guard let self, self.findings === findings else { return }
            if let refusal {
                error = refusal.message
                errorMayHaveChanged = refusal.mayHaveChanged
            } else {
                links.closePanel(.reviewDraft)
            }
        }
    }

    // Reviews stopped: the panel closes, and the flows with the edits and the ticks go, because a
    // flow holds the closed store. An action that runs goes on to its end, and its result does
    // not show.
    package func reviewsStopped() {
        let open = pr != nil || host != nil
        pr = nil
        flow = nil
        findings = nil
        nitsOpen = false
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

    // The panel closed: the flows with the edits and the ticks go.
    package func releaseBody(for panel: PanelID) {
        guard panel == .reviewDraft else { return }
        host = nil
        pr = nil
        flow = nil
        findings = nil
        nitsOpen = false
        confirm = nil
        error = nil
    }
}

// The body of the Review panel: the findings form, the draft form, or a line in their place.
// The error line stays at the bottom for both forms.
struct ReviewDraftPanel: View {
    let panels: ReviewDraftPanels

    var body: some View {
        let style = panels.style
        VStack(alignment: .leading, spacing: 0) {
            if let findings = panels.findings, let shown = findings.shown {
                ReviewFindingsBody(panels: panels, findings: findings, shown: shown, style: style)
            } else if let flow = panels.flow, let shown = flow.shown {
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

    // The open of the findings form reads nothing, so it never loads: with no findings shown,
    // it failed.
    private var placeholder: String {
        guard panels.pr != nil else { return ReviewDraftPanels.nothingText }
        switch panels.form {
        case .findings: return ReviewDraftPanels.notOpenedFindingsText
        case .draft:
            return panels.error == nil
                ? ReviewDraftPanels.loadingText : ReviewDraftPanels.notOpenedText
        }
    }

    @ViewBuilder
    private func draft(_ flow: DraftFlow, _ shown: DraftFlow.Shown, _ style: PanelStyle)
        -> some View
    {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: style.points(4)) {
                SuggestionLine(recommendation: shown.recommendation, why: shown.why)
                NoteBox(note: shown.note, style: style)
                if shown.headMoved {
                    Text(ReviewDraftPanels.changedText).foregroundStyle(style.dim)
                }
                Self.label("Summary", style)
                ReviewTextArea(
                    text: Binding(get: { flow.summary }, set: { flow.summary = $0 }),
                    placeholder: "Write a summary", lines: 4, style: style
                )
                .disabled(flow.busy)
                Self.label("Comments (\(flow.comments.count))", style)
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
            Self.strip(style) { Text(ReviewDraftPanels.lockedText).foregroundStyle(style.dim) }
        }
        if let wait = panels.waitText { Self.waitStrip(wait, style) }
        DraftFooter(panels: panels, style: style)
    }

    // The strip that says why the buttons are off while the PR waits for a poll.
    static func waitStrip(_ text: String, _ style: PanelStyle) -> some View {
        strip(style) {
            Text(text).foregroundStyle(style.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    // A label of a part of a form: the text in capitals, in the small dim font.
    static func label(_ text: String, _ style: PanelStyle) -> some View {
        Text(text.uppercased())
            .font(style.font(10))
            .foregroundStyle(style.dim)
            .padding(.top, style.points(8))
    }

    private func confirmStrip(_ confirm: ReviewDraftPanels.Confirm, _ style: PanelStyle)
        -> some View
    {
        Self.strip(style) {
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

    // A strip of a form under its scroll view: a row with a line of the panel edge colour on top.
    static func strip(_ style: PanelStyle, @ViewBuilder _ content: () -> some View) -> some View {
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

// The footer of the draft form: Discard draft and Approve instead, then "Send as", the switch and
// Send review on the right. The panel opens wide enough for all of it on one line, and if you make
// it narrower the right part drops to a second line instead of being cut off. Send review keeps
// the same width either way.
struct DraftFooter: View {
    let panels: ReviewDraftPanels
    let style: PanelStyle

    var body: some View {
        ReviewDraftPanel.strip(style) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: style.points(6)) {
                    draftButtons
                    Spacer(minLength: style.points(8))
                    sendBar
                }
                VStack(alignment: .leading, spacing: style.points(6)) {
                    HStack(spacing: style.points(6)) { draftButtons }
                    HStack(spacing: style.points(6)) {
                        Spacer(minLength: 0)
                        sendBar
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var draftButtons: some View {
        Button("Discard draft") { panels.discard(click: UserClick()) }
            .buttonStyle(RowButtonStyle(tone: .plain, style: style))
            .disabled(!panels.canDiscard)
            .focusable(false)
        Button("Approve instead") { panels.approveInstead(click: UserClick()) }
            .buttonStyle(RowButtonStyle(tone: .tinted(.green), style: style))
            .disabled(!panels.canSend)
            .focusable(false)
    }

    // "Send as", the switch and Send review.
    @ViewBuilder
    private var sendBar: some View {
        Text("Send as").foregroundStyle(style.dim).fixedSize()
        HStack(spacing: 0) {
            ForEach([DraftEvent.comment, .requestChanges], id: \.self) { event in
                SendAsButton(
                    title: event == .comment ? "Comment" : "Request changes",
                    on: panels.event == event, tone: ReviewDraftPanel.tone(event), style: style
                ) { panels.event = event }
                .disabled(panels.flow?.busy != false)
            }
        }
        .overlay { Rectangle().strokeBorder(style.edge, lineWidth: style.points(1)) }
        DraftSendButton(panels: panels, style: style)
    }
}

// Send review of the draft form, with the progress of a send of the draft in its place. The place
// keeps one width (SendSlot), so "Send as" and the switch to its left do not move.
struct DraftSendButton: View {
    let panels: ReviewDraftPanels
    let style: PanelStyle

    var body: some View {
        SendSlot(progress: panels.sending, style: style) { live in
            Button("Send review") { panels.send(click: UserClick()) }
                .buttonStyle(
                    RowButtonStyle(tone: .tinted(ReviewDraftPanel.tone(panels.event)), style: style)
                )
                .disabled(!live || !panels.canSend)
                .focusable(false)
        }
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
