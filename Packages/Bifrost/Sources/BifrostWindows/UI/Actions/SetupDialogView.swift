// The box of the Setup dialog (docs/behaviour/live.md, "The Setup dialog"): the title, the text
// of the view, the changes of the step as a numbered list, the lines, the problem of the Live
// details status with Try again, the dim note, the reason of the last failed step and the
// buttons. SetupDialogModel gives what each view shows, and each button acts through it. The
// texts can be selected. The dim note has the font of the dialog (13 units), and the reason has
// the font of a reason line of a dialog (12 units, DialogNote).
import BifrostLive
import BifrostLook
import BifrostSettings
import SwiftUI

struct SetupDialogView: View {
    let model: SetupDialogModel
    let style: PanelStyle

    var body: some View {
        let content = model.content
        VStack(alignment: .leading, spacing: style.points(12)) {
            DialogTitle(text: SetupDialogModel.title, style: style)
            paragraph(content.intro)
            if !content.steps.isEmpty {
                steps(content.steps)
            }
            ForEach(Array(content.lines.enumerated()), id: \.offset) { _, line in
                // The state line of the installed view has the strong text colour.
                let strong = model.view == .installed
                paragraph(line, color: (strong ? ThemeTokens.textStrong : ThemeTokens.text).color)
            }
            if let problem = content.problem {
                HStack(alignment: .top, spacing: style.points(8)) {
                    paragraph(problem).frame(maxWidth: .infinity, alignment: .leading)
                    button(.retry)
                }
            }
            if let note = content.note {
                paragraph(note, color: style.dim)
            }
            if let error = content.error {
                DialogNote(text: error, style: style, dim: false)
            }
            HStack(spacing: style.points(8)) {
                Spacer(minLength: 0)
                ForEach(content.buttons, id: \.self) { button($0) }
            }
        }
        .accessibilityLabel(SetupDialogModel.title)
    }

    private func paragraph(_ text: String, color: Color = ThemeTokens.text.color) -> some View {
        Text(text)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    // The changes of the step, as a numbered list.
    private func steps(_ steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: style.points(4)) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: style.points(6)) {
                    Text("\(index + 1).").monospacedDigit()
                    Text(step).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
        .padding(.leading, style.points(8))
    }

    private func button(_ id: SetupButton) -> some View {
        Button(id.label) { Task { await model.press(id) } }
            .buttonStyle(DialogButtonStyle(style: style))
            .disabled(model.isOff(id))
    }
}
