// The SwiftUI controls of the look that more than one panel body uses: the colour of a token for
// SwiftUI, the plain button with the press tint, and the check box of Bifrost with its square.
import SwiftUI

@MainActor
extension TokenColour {
    // The colour in the sRGB colour space, for SwiftUI.
    package var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

// A plain button with the cyan tint during a press, as the buttons of the title bar have. A
// button that is off has no tint.
package struct PressTintStyle: ButtonStyle {
    package init() {}

    package func makeBody(configuration: Configuration) -> some View {
        PressTint(configuration: configuration)
    }

    private struct PressTint: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .background(
                    configuration.isPressed && enabled
                        ? Color(cgColor: TitleButton.pressColour) : .clear
                )
                .contentShape(Rectangle())
        }
    }
}

// The check box of Bifrost, not the system check box: the square of the look (CheckSquare) and the
// label. A click on the label also changes the box. A disabled box is at 40 % opacity, and a press
// gives the cyan tint. In a panel the box is not focusable: a SwiftUI control that moves with a
// frame never takes the focus. In a dialog (keyboardFocus) it takes the focus with Full Keyboard
// Access, as a macOS check box does.
package struct BifrostCheckboxStyle: ToggleStyle {
    let metrics: CanvasMetrics
    let keyboardFocus: Bool

    package init(metrics: CanvasMetrics, keyboardFocus: Bool = false) {
        self.metrics = metrics
        self.keyboardFocus = keyboardFocus
    }

    package func makeBody(configuration: Configuration) -> some View {
        CheckBox(configuration: configuration, metrics: metrics, keyboardFocus: keyboardFocus)
    }

    private struct CheckBox: View {
        let configuration: ToggleStyleConfiguration
        let metrics: CanvasMetrics
        let keyboardFocus: Bool
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let on = configuration.isOn
            Button { configuration.isOn.toggle() } label: {
                HStack(spacing: metrics.points(8)) {
                    CheckSquare(on: on, metrics: metrics)
                        .opacity(enabled ? 1 : 0.4)
                    configuration.label
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressTintStyle())
            .modifier(NoFocus(on: !keyboardFocus))
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
        }
    }
}

// The square of the Bifrost check box: a dark square of 14 units with a border of 1 unit, and the
// check of lucide while it is on. The border has the dim text colour while the square is off, and
// the text colour while it is on, so an off square shows as an empty box. The check box style
// and the check box rows of a Bifrost menu draw it.
package struct CheckSquare: View {
    // The sizes in layout units: the square, its border, the check and the line of the check.
    package static let size = 14.0
    package static let border = 1.0
    package static let checkSize = 10.0
    package static let checkLine = 1.25

    private let on: Bool
    private let metrics: CanvasMetrics

    package init(on: Bool, metrics: CanvasMetrics) {
        self.on = on
        self.metrics = metrics
    }

    package var body: some View {
        ZStack {
            Rectangle().fill(ThemeTokens.bg.color)
            Rectangle().strokeBorder(
                (on ? ThemeTokens.text : ThemeTokens.textDim).color,
                lineWidth: metrics.points(Self.border))
            if on {
                CheckMark()
                    .stroke(
                        ThemeTokens.textStrong.color,
                        style: StrokeStyle(
                            lineWidth: metrics.points(Self.checkLine), lineCap: .round,
                            lineJoin: .round))
                    .frame(
                        width: metrics.points(Self.checkSize),
                        height: metrics.points(Self.checkSize))
            }
        }
        .frame(width: metrics.points(Self.size), height: metrics.points(Self.size))
    }
}

// The check of lucide (the path M20 6 9 17l-5-5 in a box of 24), drawn in the box of the view.
private struct CheckMark: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = rect.width / 24
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 20 * unit, y: rect.minY + 6 * unit))
        path.addLine(to: CGPoint(x: rect.minX + 9 * unit, y: rect.minY + 17 * unit))
        path.addLine(to: CGPoint(x: rect.minX + 4 * unit, y: rect.minY + 12 * unit))
        return path
    }
}

// A control that never takes the focus while on is true.
private struct NoFocus: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on { content.focusable(false) } else { content }
    }
}
