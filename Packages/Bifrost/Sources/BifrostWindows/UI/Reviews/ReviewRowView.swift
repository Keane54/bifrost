// One row of the Reviews panel (docs/behaviour/reviews.md, "The panel"): the two lines of the
// design (layout B). The rules give each text, its colour and its tip (ReviewRow), so the row
// only lays them out.
//
// - Line 1: the dot of Claude's result, the repository, the PR number (a link to the PR on
//   GitHub), the title, then the team tag (To review) or the cross of the failed checks (My PRs).
// - Line 2 of To review: the notes (the author, the size and the age, or the line of Claude's
//   result), then at the right the state text with its tip ("Review failed" with the reason of a
//   failed round) and the buttons of the row (ReviewsMenu.buttons): Approve (green) while the row
//   offers it, Comment (amber) or Request changes (red) for Claude's draft, Remove for a row that
//   others approved, Review (Try again on a failed row) while a round can start, and Pause for a
//   new request. Review on a new request has the strong text colour. Approve makes the click of
//   the user in its action, and waits while CI runs. While a review write of the PR has a
//   progress (an approval, or a send of the Review panel), the progress takes the place of the
//   state text and the buttons (WriteProgressLabel).
// - Line 2 of My PRs: the review status with its square, the reviewers in the colours of their
//   opinions, the notes (later Copilot comments, older comments), then at the right the Claude
//   state with its tip. Needs you has the red box of the Overview before its text.
// - The left part of line 2 shrinks first, so the text at the right always shows.
// - A new request flashes while the Row flash setting is on: a red layer behind the row whose
//   opacity goes from 1 to 0.25 and back in 1 s, as the brackets of the red box of the Overview.
//   The box of Needs you flashes the same way.
// - A plain click on the row goes to the model. The host gives Cmd+click and the menu. No part of
//   the row takes the focus.
import BifrostFoundation
import BifrostLook
import BifrostReviews
import SwiftUI

struct ReviewRowView: View {
    let model: ReviewsPanelModel
    let row: ReviewRow
    // The first row of the list has no line above it.
    let first: Bool
    let rowFlash: Bool
    // The look of the panel: the sizes at the Interface scale, the fonts and the press tint.
    let style: PanelStyle

    var body: some View {
        VStack(alignment: .leading, spacing: style.points(2)) {
            lineOne
            switch row.tab {
            case .toReview: toReviewLine
            case .mine: myPRLine
            }
        }
        .padding(.horizontal, style.points(6))
        .padding(.vertical, style.points(4))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if row.flash && rowFlash {
                Flashing { Rectangle().fill(ThemeTokens.boxRed.opacity(0.35).color) }
            }
        }
        .overlay(alignment: .top) {
            if !first { EdgeLineView(metrics: style.metrics) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.click(row.id, command: false) }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Line 1

    private var lineOne: some View {
        HStack(alignment: .center, spacing: style.points(6)) {
            if let dot = row.dot {
                Rectangle().fill(dot.colour)
                    .frame(width: style.points(6), height: style.points(6))
                    .accessibilityHidden(true)
            }
            Text(row.repo).lineLimit(1).fixedSize()
            PRNumberLink(number: row.id.number) {
                model.choose(.openOnGitHub, for: row.id)
            }
            Text(row.title)
                .foregroundStyle(ThemeTokens.textStrong.color)
                .lineLimit(1)
                .truncationMode(.tail)
            if let tag = row.tag { tagView(tag) }
            Spacer(minLength: 0)
        }
    }

    // The team tag of a To review row has a border. The cross of a My PRs row is red, with its
    // tip.
    @ViewBuilder
    private func tagView(_ tag: RowLabel) -> some View {
        switch row.tab {
        case .toReview:
            Text(tag.text)
                .font(style.font(10))
                .foregroundStyle(tag.tone.colour)
                .padding(.horizontal, style.points(2))
                .overlay {
                    Rectangle().strokeBorder(
                        ThemeTokens.panelEdge.color, lineWidth: style.points(1))
                }
                .fixedSize()
        case .mine:
            Text(tag.text)
                .foregroundStyle(tag.tone.colour)
                .fixedSize()
                .tip(tag.tip)
        }
    }

    // MARK: - Line 2

    private var toReviewLine: some View {
        HStack(alignment: .center, spacing: style.points(10)) {
            notes
            Spacer(minLength: 0)
            HStack(spacing: style.points(6)) {
                if let status = model.shownStatus(row) { label(status) }
                if let progress = model.progress(row.id) {
                    WriteProgressLabel(progress: progress, style: style)
                } else {
                    ForEach(ReviewsMenu.buttons(row), id: \.self) { item in
                        Button(item.label) {
                            if item == .approve {
                                model.approve(row.id, click: UserClick())
                            } else {
                                model.choose(item, for: row.id)
                            }
                        }
                        .buttonStyle(RowButtonStyle(tone: tone(item), style: style))
                        .disabled(!model.isEnabled(item, row))
                        .focusable(false)
                        .tip(model.tip(item, row))
                    }
                }
            }
            .fixedSize()
        }
        .foregroundStyle(ThemeTokens.textDim.color)
    }

    private var myPRLine: some View {
        HStack(alignment: .center, spacing: style.points(10)) {
            if let review = row.review {
                HStack(spacing: style.points(6)) {
                    Rectangle().fill(review.tone.colour)
                        .frame(width: style.points(6), height: style.points(6))
                        .accessibilityHidden(true)
                    Text(review.text)
                }
                .foregroundStyle(review.tone.colour)
                .fixedSize()
                .tip(review.tip)
            }
            if !row.reviewers.isEmpty {
                Text(reviewerNames).lineLimit(1).truncationMode(.tail)
            }
            ForEach(row.notes, id: \.self) { note in
                Text(note).lineLimit(1).fixedSize()
            }
            Spacer(minLength: 0)
            HStack(spacing: style.points(6)) {
                if case .mine(_, let claude) = row.state, claude.needsTheUser {
                    Flashing(on: rowFlash) {
                        Rectangle().strokeBorder(
                            ThemeTokens.boxRed.color, lineWidth: style.points(1))
                    }
                    .frame(width: style.points(10), height: style.points(10))
                    .accessibilityHidden(true)
                }
                label(row.status)
                ForEach(ReviewsMenu.buttons(row), id: \.self) { item in
                    Button(ReviewsMenu.buttonLabel(item, row)) {
                        model.choose(item, for: row.id)
                    }
                    .buttonStyle(RowButtonStyle(tone: .plain, style: style))
                    .disabled(!model.isEnabled(item, row))
                    .focusable(false)
                }
            }
            .fixedSize()
        }
        .foregroundStyle(ThemeTokens.textDim.color)
    }

    // The notes of a To review row: the author, the size and the age, or the line of Claude's
    // result. The first note shrinks first.
    private var notes: some View {
        HStack(spacing: style.points(10)) {
            ForEach(Array(row.notes.enumerated()), id: \.offset) { index, note in
                if index == 0 {
                    Text(note).lineLimit(1).truncationMode(.tail)
                } else {
                    Text(note).lineLimit(1).fixedSize()
                }
            }
        }
    }

    // A text of the row in its colour, with its tip.
    private func label(_ label: RowLabel) -> some View {
        Text(label.text)
            .foregroundStyle(label.tone.colour)
            .lineLimit(1)
            .tip(label.tip)
    }

    // The reviewer names in the colours of their opinions, with dim commas between them.
    private var reviewerNames: AttributedString {
        var text = AttributedString()
        for (index, reviewer) in row.reviewers.enumerated() {
            if index > 0 {
                var comma = AttributedString(", ")
                comma.foregroundColor = ThemeTokens.textDim.color
                text += comma
            }
            var name = AttributedString(reviewer.name)
            name.foregroundColor = reviewer.tone.colour
            text += name
        }
        return text
    }

    // The tone of a button: each result of Claude has its colour, Remove is dim, and Review on a
    // new request is strong.
    private func tone(_ item: ReviewsMenuItem) -> RowButtonStyle.Tone {
        switch item {
        case .approve: .tinted(.green)
        case .comment: .tinted(.amber)
        case .requestChanges: .tinted(.red)
        case .remove: .dim
        case .review where row.state == .toReview(.newRequest): .strong
        default: .plain
        }
    }
}

extension RowTone {
    // The soft green of an approval (the colour svc-ok of the Electron app).
    static let approveGreen = TokenColour.rgb(0x86, 0xc4, 0x8f)

    // The colour of the tone in the look: green, the amber of a yellow box, the red of a red
    // box, the blue of the priority 3, the text colour and the dim text colour.
    @MainActor var colour: Color {
        switch self {
        case .green: Self.approveGreen.color
        case .amber: ThemeTokens.boxYellow.color
        case .red: ThemeTokens.boxRed.color
        case .blue: ThemeTokens.priorities[2].color
        case .plain: ThemeTokens.text.color
        case .dim: ThemeTokens.textDim.color
        }
    }
}

extension View {
    // The Bifrost tooltip of the view, or none for no text.
    @ViewBuilder
    fileprivate func tip(_ text: String?) -> some View {
        if let text {
            background(TipAnchor(text: text, side: .top))
        } else {
            self
        }
    }
}

// The flash of the red box of the Overview: the opacity of the content goes from 1 to 0.25 and
// back in 1 s, ease in and out, with no end. With on false, the content does not flash. The flash
// takes no pointer input.
private struct Flashing<Content: View>: View {
    var on = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            if on {
                content().phaseAnimator([1.0, 0.25]) { view, opacity in
                    view.opacity(opacity)
                } animation: { _ in
                    .easeInOut(duration: 0.5)
                }
            } else {
                content()
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// The progress of a review write in the place of the buttons of its row, and of Send review in
// the Review panel (RowText.progress): the lucide loader that turns one time each second, linear
// and with no end, with "Approving…", "Commenting…" or "Requesting changes…" in the text colour,
// then the lucide check with "Approved", "Commented" or "Changes requested" in the colour of the
// review. With Reduce Motion on, the loader does not turn. The label has the height and the side
// padding of a row button, so the row keeps its height. It is not a button: it takes no click.
struct WriteProgressLabel: View {
    // The time of one turn of the loader, in seconds.
    nonisolated static let turn: TimeInterval = 1

    let progress: ReviewWriteProgress
    let style: PanelStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let label = RowText.progress(progress)
        HStack(spacing: style.points(4)) {
            switch progress {
            case .running: loader
            case .confirmed: ButtonIcon(icon: .check, size: style.points(12))
            }
            Text(label.text)
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, style.points(6))
        .frame(minHeight: style.points(16))
        .foregroundStyle(label.tone.colour)
    }

    // A turn ends at 360 degrees, which looks the same as the start, so the repeat has no jump.
    @ViewBuilder
    private var loader: some View {
        let icon = ButtonIcon(icon: .loader, size: style.points(12))
        if reduceMotion {
            icon
        } else {
            icon.keyframeAnimator(initialValue: Angle.zero, repeating: true) { view, angle in
                view.rotationEffect(angle)
            } keyframes: { _ in
                LinearKeyframe(Angle.degrees(360), duration: Self.turn)
            }
        }
    }
}

// The PR number of line 1: a link to the PR on GitHub in the dim text colour, with the text
// colour and an underline under the pointer.
private struct PRNumberLink: View {
    let number: Int
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            Text("#\(number)")
                .underline(hovered)
                .foregroundStyle((hovered ? ThemeTokens.text : ThemeTokens.textDim).color)
                .lineLimit(1)
                .fixedSize()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.15), value: hovered)
        .onHover { hovered = $0 }
        .pointerStyle(.link)
        .focusable(false)
        .accessibilityLabel("Open PR #\(number) on GitHub")
    }
}

// A small button of the panel: a border, a dark fill, the strong text colour under the pointer
// and the press tint of the panel during a press. dim gives the dim text colour (Remove), strong
// the strong text colour (Review on a new request), and tinted the colour of a result of Claude
// for the text and the border (Approve, Comment, Request changes). A disabled button is faint.
struct RowButtonStyle: ButtonStyle {
    enum Tone {
        case plain, dim, strong
        case tinted(RowTone)
    }

    let tone: Tone
    let style: PanelStyle

    func makeBody(configuration: Configuration) -> some View {
        RowButton(configuration: configuration, tone: tone, style: style)
    }

    private struct RowButton: View {
        let configuration: Configuration
        let tone: Tone
        let style: PanelStyle
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, style.points(6))
                .frame(minHeight: style.points(16))
                .foregroundStyle(colour)
                .background(
                    configuration.isPressed && enabled ? style.press : Color.black.opacity(0.35))
                .overlay {
                    Rectangle().strokeBorder(edge, lineWidth: style.points(1))
                }
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
                .animation(.easeInOut(duration: 0.15), value: hovered)
        }

        private var colour: Color {
            if hovered && enabled { return ThemeTokens.textStrong.color }
            switch tone {
            case .plain: return ThemeTokens.text.color
            case .dim: return ThemeTokens.textDim.color
            case .strong: return ThemeTokens.textStrong.color
            case .tinted(let tint): return tint.colour
            }
        }

        private var edge: Color {
            if case .tinted(let tint) = tone { return tint.colour }
            return style.edge
        }
    }
}
