// The findings form of the Review panel (docs/behaviour/reviews.md, "The Review panel"), and the
// views that both forms of the panel share. ReviewDraftPanels holds the state of the form.
//
// - The form shows Claude's suggestion, Claude's private note with the line that Bifrost never
//   posts it, the findings above a nit with a check box each (bugs first, then minor findings,
//   each in the order of the result), the closed Nits row with the nits under it, and the
//   optional summary.
// - Each finding shows its kind tag, its text and its place. A finding with a place that the diff
//   does not show says that it goes in the review text.
// - While the PR waits for a poll after a review that might have reached GitHub, a strip above
//   the footer says so and the three buttons are off.
// - The footer has the line of what a button posts (it follows each tick and each edit), then
//   Comment, Request changes and Approve. Each button makes the click of the user in its action.
//   While a review write of the PR runs, its progress takes the place of the three buttons, in a
//   place of one width (SendSlot), so nothing moves.
// - All text from Claude's result (the note, each text, each path) shows as plain text only: a
//   Text of a String, never a string interpolation into Text, which SwiftUI reads as Markdown.
// - No control takes the focus, as in the other Reviews panels.
import BifrostFoundation
import BifrostLook
import BifrostReviews
import SwiftUI

// The texts of the findings form, exactly as the user approved them.
enum FindingsText {
    static let noteLabel = "Claude's note"
    static let noteHint = "Claude's notes are not posted to GitHub."
    static let summaryPlaceholder =
        "Add a summary if you want, you'll need one if requesting changes."

    static func findings(_ count: Int) -> String { "Findings (\(count))" }
    static func nits(_ count: Int) -> String { "Nits (\(count))" }

    // The line in place of the findings when none is above a nit.
    static func nothingFound(nits: Bool) -> String {
        nits
            ? "Claude found nothing to change, only the nits below."
            : "Claude found nothing to change."
    }

    // The tag of the kind of a finding.
    static func tag(_ finding: Finding) -> String {
        switch finding.kind {
        case .bug: "Bug"
        case .minor: "Minor"
        case .nit: "Nit"
        }
    }

    // The line under a finding whose place the diff does not show, or nil. Such a finding goes in
    // the review text, as a finding with no place does.
    static func offDiff(_ finding: Finding) -> String? {
        guard finding.place != nil, !finding.onDiff else { return nil }
        return "This line isn't in the diff, so it'll go in the main review comment instead."
    }

    // The colour of the tag of a kind: red, amber, or the dim text colour.
    static func tone(_ kind: FindingKind) -> RowTone {
        switch kind {
        case .bug: .red
        case .minor: .amber
        case .nit: .dim
        }
    }
}

// The place of the send buttons of a form of the Review panel (user decision, 2026-11-25): the
// buttons, or the progress of the review write of the PR in their place. The place is always as
// wide as the wider of the buttons and the widest progress ("Requesting changes…"), so nothing to
// its left moves when a write starts or ends: hidden copies of both lie under the shown content.
// A hidden copy keeps its size, but it shows nothing and takes no click. buttons(false) gives the
// hidden copy of the buttons, which are off.
struct SendSlot<Buttons: View>: View {
    let progress: ReviewVerdict?
    let style: PanelStyle
    @ViewBuilder let buttons: (_ live: Bool) -> Buttons

    var body: some View {
        ZStack(alignment: .trailing) {
            Group {
                WriteProgressLabel(progress: ReviewRowActions.widest, style: style, turns: false)
                buttons(false)
            }
            .hidden()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            if let progress {
                WriteProgressLabel(progress: .running(progress), style: style)
            } else {
                buttons(true)
            }
        }
        .fixedSize()
    }
}

// "Claude suggests: <name> - <why>." with the name in the colour of the recommendation. The why
// is plain text.
struct SuggestionLine: View {
    let recommendation: Recommendation
    let why: String

    var body: some View {
        Text(Self.text(recommendation, why: why)).fixedSize(horizontal: false, vertical: true)
    }

    static func text(_ recommendation: Recommendation, why: String) -> AttributedString {
        var text = AttributedString("Claude suggests: ")
        var name = AttributedString(RowText.recommendation(recommendation))
        name.foregroundColor = ReviewDraftPanel.tone(recommendation).colour
        text += name
        text += AttributedString(RowText.sentenceEnd(why))
        return text
    }
}

// Claude's private note: the label, the note as plain text with its line breaks in a box, and the
// dim line that Bifrost never posts it. Nothing shows for an empty note.
struct NoteBox: View {
    let note: String
    let style: PanelStyle

    var body: some View {
        if !note.isEmpty {
            VStack(alignment: .leading, spacing: style.points(4)) {
                ReviewDraftPanel.label(FindingsText.noteLabel, style)
                Text(verbatim: note)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, style.points(8))
                    .padding(.vertical, style.points(6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.35))
                    .overlay { Rectangle().strokeBorder(style.edge, lineWidth: style.points(1)) }
                Text(FindingsText.noteHint)
                    .font(style.font(11))
                    .foregroundStyle(style.dim)
            }
        }
    }
}

// One finding: the check box, then the kind tag with the text, the place under it in the dim
// colour, and the line of a finding off the diff in amber. A line of the panel edge colour is
// under it. The check box is off while an action runs.
struct FindingBox: View {
    let finding: Finding
    @Binding var ticked: Bool
    let busy: Bool
    let style: PanelStyle

    var body: some View {
        HStack(alignment: .top, spacing: style.points(8)) {
            Toggle("", isOn: $ticked)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .tint(ThemeTokens.accent.color)
                .disabled(busy)
                .focusable(false)
            VStack(alignment: .leading, spacing: style.points(2)) {
                HStack(alignment: .firstTextBaseline, spacing: style.points(6)) {
                    KindTag(finding: finding, style: style)
                    Text(verbatim: finding.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(verbatim: finding.placeText)
                    .font(style.font(11))
                    .foregroundStyle(style.dim)
                    .fixedSize(horizontal: false, vertical: true)
                if let offDiff = FindingsText.offDiff(finding) {
                    Text(offDiff)
                        .font(style.font(11))
                        .foregroundStyle(RowTone.amber.colour)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, style.points(6))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { EdgeLineView(metrics: style.metrics) }
    }
}

// The tag of the kind of a finding: its text and its border in the colour of the kind.
private struct KindTag: View {
    let finding: Finding
    let style: PanelStyle

    var body: some View {
        let colour = FindingsText.tone(finding.kind).colour
        Text(FindingsText.tag(finding))
            .font(style.font(10))
            .foregroundStyle(colour)
            .padding(.horizontal, style.points(4))
            .overlay { Rectangle().strokeBorder(colour, lineWidth: style.points(1)) }
            .fixedSize()
    }
}

// The Nits row: a button of the full width, as the Details row of the Performance panel, with the
// chevron that turns down while the row is open and "Nits (<n>)".
struct NitsHeader: View {
    let count: Int
    let open: Bool
    let style: PanelStyle
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: style.points(6)) {
                ButtonIcon(icon: .chevronRight, size: style.points(12))
                    .rotationEffect(.degrees(open ? 90 : 0))
                Text(FindingsText.nits(count))
                Spacer(minLength: 0)
            }
            .padding(.vertical, style.points(5))
        }
        .buttonStyle(IconButtonStyle(style: style, fills: true))
        .focusable(false)
    }
}

// The body of the findings form: the scroll view with the suggestion, the note, the findings, the
// Nits row and the summary, then the locked strip while the form is locked, then the footer.
struct ReviewFindingsBody: View {
    let panels: ReviewDraftPanels
    let findings: FindingsFlow
    let shown: FindingsFlow.Shown
    let style: PanelStyle

    var body: some View {
        let rows = panels.findingRows
        let nits = panels.nitRows
        VStack(alignment: .leading, spacing: 0) {
            form(rows: rows, nits: nits)
            if panels.findingsLocked {
                ReviewDraftPanel.strip(style) {
                    Text(ReviewDraftPanels.lockedFindingsText)
                        .foregroundStyle(style.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let wait = panels.waitText { ReviewDraftPanel.waitStrip(wait, style) }
            footer
        }
    }

    private func form(rows: [Int], nits: [Int]) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: style.points(4)) {
                SuggestionLine(recommendation: .approve, why: shown.why)
                NoteBox(note: shown.note, style: style)
                ReviewDraftPanel.label(FindingsText.findings(rows.count), style)
                if rows.isEmpty {
                    Text(FindingsText.nothingFound(nits: !nits.isEmpty))
                        .foregroundStyle(style.dim)
                }
                ForEach(rows, id: \.self) { index in box(index) }
                if !nits.isEmpty {
                    NitsHeader(count: nits.count, open: panels.nitsOpen, style: style) {
                        panels.toggleNits()
                    }
                    if panels.nitsOpen {
                        ForEach(nits, id: \.self) { index in box(index) }
                    }
                }
                ReviewDraftPanel.label("Summary", style)
                ReviewTextArea(
                    text: panels.findingSummary, placeholder: FindingsText.summaryPlaceholder,
                    lines: 3, style: style
                )
                .disabled(findings.busy)
            }
            .padding(.horizontal, style.points(12))
            .padding(.vertical, style.points(8))
        }
    }

    private func box(_ index: Int) -> some View {
        FindingBox(
            finding: shown.findings[index], ticked: panels.ticked(index), busy: findings.busy,
            style: style)
    }

    // The line of what a button posts, then the three buttons at the right.
    private var footer: some View {
        VStack(alignment: .leading, spacing: style.points(6)) {
            Text(panels.postHint).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                FindingsButtons(panels: panels, style: style)
            }
        }
        .padding(.horizontal, style.points(12))
        .padding(.vertical, style.points(6))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { EdgeLineView(metrics: style.metrics) }
    }
}

// Comment (amber), Request changes (red) and Approve (green) of the findings form, with the
// progress of a review write of the PR in their place (SendSlot). Each button makes the click of
// the user in its action.
struct FindingsButtons: View {
    let panels: ReviewDraftPanels
    let style: PanelStyle

    var body: some View {
        SendSlot(progress: panels.posting, style: style) { live in
            HStack(spacing: style.points(6)) {
                Button("Comment") { panels.sendFindings(.comment, click: UserClick()) }
                    .buttonStyle(RowButtonStyle(tone: .tinted(.amber), style: style))
                    .disabled(!live || !panels.canPost)
                    .focusable(false)
                Button("Request changes") {
                    panels.sendFindings(.requestChanges, click: UserClick())
                }
                .buttonStyle(RowButtonStyle(tone: .tinted(.red), style: style))
                .disabled(!live || !panels.canPost)
                .focusable(false)
                Button("Approve") { panels.approveFindings(click: UserClick()) }
                    .buttonStyle(RowButtonStyle(tone: .tinted(.green), style: style))
                    .disabled(!live || !panels.canPost)
                    .focusable(false)
            }
        }
    }
}
