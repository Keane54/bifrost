// The parts of the look that the panel bodies, the dialogs and the Settings panel share: the
// style values of a panel at the Interface scale (PanelStyle), the dialog button, the small icon
// button, the stack tab, the error line with its close button, the icon of a button, the anchor
// of a Bifrost tooltip in SwiftUI, and the hosting view and the table that never take the focus
// (the section "The UI" of the architecture design).
import AppKit
import SwiftUI

// The sizes, the fonts and the colours of a panel, a dialog and the Settings panel at the
// Interface scale and the Panel transparency.
@MainActor
package struct PanelStyle {
    package let metrics: CanvasMetrics
    package let transparency: Int

    package init(metrics: CanvasMetrics, transparency: Int) {
        self.metrics = metrics
        self.transparency = transparency
    }

    // A length in layout units as a length in points.
    package func points(_ units: Double) -> CGFloat { metrics.points(units) }

    // The UI font at the size in units.
    package func font(_ size: Double, weight: NSFont.Weight = .regular) -> Font {
        Font(Fonts.ui(points(size), weight: weight) as CTFont)
    }

    // The UI font at 12 units, for AppKit and for SwiftUI.
    package var nsFont: NSFont { Fonts.ui(points(12), weight: .regular) }
    package var font: Font { Font(nsFont as CTFont) }

    package var edge: Color { ThemeTokens.panelEdge.color }
    package var dim: Color { ThemeTokens.textDim.color }
    // The colour under the pointer: the colour of a panel.
    package var hover: Color { ThemeTokens.panel(transparency: transparency).color }
    // The short cyan tint of a press.
    package var press: Color { ThemeTokens.accent.opacity(0.12).color }
    // The border of a field with the focus.
    package var focusEdge: Color { ThemeTokens.textStrong.opacity(0.3).color }
}

// A button of a dialog and of the Settings panel: a border of the edge colour, the panel colour
// under the pointer, the cyan tint during a press. A disabled button is at 40 % opacity. strong
// gives the strong text colour (the confirm button in its second step).
package struct DialogButtonStyle: ButtonStyle {
    let style: PanelStyle
    let strong: Bool

    package init(style: PanelStyle, strong: Bool = false) {
        self.style = style
        self.strong = strong
    }

    package func makeBody(configuration: Configuration) -> some View {
        DialogButton(configuration: configuration, style: style, strong: strong)
    }

    private struct DialogButton: View {
        let configuration: Configuration
        let style: PanelStyle
        let strong: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle((strong ? ThemeTokens.textStrong : ThemeTokens.text).color)
                .padding(.horizontal, style.points(8))
                .padding(.vertical, style.points(2))
                .background(background)
                .overlay {
                    Rectangle().strokeBorder(style.edge, lineWidth: style.points(1))
                        .accessibilityHidden(true)
                }
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }

        private var background: Color {
            guard enabled else { return .clear }
            if configuration.isPressed { return style.press }
            return hovered ? style.hover : .clear
        }
    }
}

// A small icon button: its colour (the dim text colour by default), the hover colour (the text
// colour by default) and the hover fill (the panel colour by default) under the pointer, the cyan
// tint during a press, and 40 % opacity while it is off. fills: the label takes the whole frame
// of the button, so the fill covers it.
package struct IconButtonStyle: ButtonStyle {
    let style: PanelStyle
    let colour: Color?
    let hoverColour: Color?
    let hoverFill: Color?
    let fills: Bool

    package init(
        style: PanelStyle, colour: Color? = nil, hoverColour: Color? = nil,
        hoverFill: Color? = nil, fills: Bool = false
    ) {
        self.style = style
        self.colour = colour
        self.hoverColour = hoverColour
        self.hoverFill = hoverFill
        self.fills = fills
    }

    package func makeBody(configuration: Configuration) -> some View {
        IconButton(configuration: configuration, look: self)
    }

    private struct IconButton: View {
        let configuration: Configuration
        let look: IconButtonStyle
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .frame(
                    maxWidth: look.fills ? .infinity : nil,
                    maxHeight: look.fills ? .infinity : nil
                )
                .foregroundStyle(colour)
                .background(background)
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }

        private var colour: Color {
            let rest = look.colour ?? look.style.dim
            return enabled && hovered ? look.hoverColour ?? ThemeTokens.text.color : rest
        }

        private var background: Color {
            guard enabled else { return .clear }
            if configuration.isPressed { return look.style.press }
            return hovered ? look.hoverFill ?? look.style.hover : .clear
        }
    }
}

// The stack tab style of a frame, for the tabs inside a panel (the sections of Settings, the work
// areas of the Daily update panel): the strong text and a line under the active tab, the dim text
// colour for the other tabs (the text colour under the pointer), and the cyan tint during a press.
// A tab that is off gets no hover colour and no tint.
package struct StackTabStyle: ButtonStyle {
    let style: PanelStyle
    let active: Bool

    package init(style: PanelStyle, active: Bool) {
        self.style = style
        self.active = active
    }

    package func makeBody(configuration: Configuration) -> some View {
        Tab(configuration: configuration, style: style, active: active)
    }

    private struct Tab: View {
        let configuration: Configuration
        let style: PanelStyle
        let active: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .lineLimit(1)
                .padding(.horizontal, style.points(8))
                .frame(maxHeight: .infinity)
                .foregroundStyle(colour)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(active ? ThemeTokens.textStrong.color : .clear)
                        .frame(height: style.points(2))
                }
                .background(enabled && configuration.isPressed ? style.press : .clear)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }

        private var colour: Color {
            if active { return ThemeTokens.textStrong.color }
            return enabled && hovered ? ThemeTokens.text.color : style.dim
        }
    }
}

// The error line of a panel or a row in SwiftUI: a line of the panel edge colour on top, then
// the full text, which wraps, and the close button. The text is not red: red is only for the red
// box. PanelErrorLine of BifrostWindows is the AppKit line with the same look. With no close, the
// line has no close button: a line that stays until its cause ends, for example the line of gh
// in the Reviews panel.
package struct ErrorLineView: View {
    let text: String
    let metrics: CanvasMetrics
    let close: (@MainActor () -> Void)?

    package init(text: String, metrics: CanvasMetrics, close: (@MainActor () -> Void)?) {
        self.text = text
        self.metrics = metrics
        self.close = close
    }

    package var body: some View {
        HStack(alignment: .top, spacing: metrics.points(4)) {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let close { ErrorCloseButtonView(metrics: metrics, action: close) }
        }
        .padding(.horizontal, metrics.points(8))
        .padding(.top, metrics.points(1))
        .overlay(alignment: .top) { EdgeLineView(metrics: metrics) }
    }
}

// A line of 1 unit in the panel edge colour between two parts of a panel, for example on top of
// an error line or under a tab bar. It is hidden from accessibility.
package struct EdgeLineView: View {
    let metrics: CanvasMetrics

    package init(metrics: CanvasMetrics) {
        self.metrics = metrics
    }

    package var body: some View {
        Rectangle().fill(ThemeTokens.panelEdge.color).frame(height: metrics.points(1))
            .accessibilityHidden(true)
    }
}

// The close button of an error line: 16 units square with the x icon of 12 in the dim text
// colour. Under the pointer it has the hover colour and the text colour, and a press gives the
// cyan tint. Its tooltip is the Bifrost tooltip "Close". It never takes the focus.
private struct ErrorCloseButtonView: View {
    let metrics: CanvasMetrics
    let action: @MainActor () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            ButtonIcon(icon: .x, size: metrics.points(12))
                .frame(width: metrics.points(16), height: metrics.points(16))
                .foregroundStyle(hovered ? ThemeTokens.text.color : ThemeTokens.textDim.color)
                .background(hovered ? ThemeTokens.hover.color : .clear)
        }
        .buttonStyle(PressTintStyle())
        .focusable(false)
        .onHover { hovered = $0 }
        .accessibilityLabel("Close")
        .background(TipAnchor(text: "Close", side: .top))
    }
}

// The icon of a button. It takes no pointer input and is hidden from accessibility: the button
// has the label.
package struct ButtonIcon: View {
    let icon: IconName
    let size: CGFloat

    package init(icon: IconName, size: CGFloat) {
        self.icon = icon
        self.size = size
    }

    package var body: some View {
        Image(nsImage: Icons.image(icon))
            .renderingMode(.template)
            .resizable()
            .frame(width: size, height: size)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// The anchor of a Bifrost tooltip in SwiftUI: a view behind the button that holds the tooltip. It
// takes no pointer input, so the button gets each press. A keyboard focus on the button shows the
// tooltip at once.
package struct TipAnchor: NSViewRepresentable {
    let text: String
    let side: TooltipSide
    var focused = false

    package init(text: String, side: TooltipSide, focused: Bool = false) {
        self.text = text
        self.side = side
        self.focused = focused
    }

    package func makeNSView(context: Context) -> TipAnchorView {
        TipAnchorView(text: text, side: side)
    }

    package func updateNSView(_ view: TipAnchorView, context: Context) {
        view.set(text: text, side: side)
        view.setFocused(focused)
    }

    package static func dismantleNSView(_ view: TipAnchorView, coordinator: ()) {
        view.detach()
    }
}

package final class TipAnchorView: NSView {
    package private(set) var text: String
    package private(set) var side: TooltipSide
    private var focused = false

    init(text: String, side: TooltipSide) {
        self.text = text
        self.side = side
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override package func hitTest(_ point: NSPoint) -> NSView? { nil }
    override package func isAccessibilityElement() -> Bool { false }

    func set(text: String, side: TooltipSide) {
        guard text != self.text || side != self.side else { return }
        self.text = text
        self.side = side
        if window != nil { TooltipController.shared.attach(text, to: self, side: side) }
    }

    override package func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            detach()
        } else {
            TooltipController.shared.attach(text, to: self, side: side)
        }
    }

    func setFocused(_ focused: Bool) {
        guard focused != self.focused else { return }
        self.focused = focused
        if focused {
            TooltipController.shared.focused(self)
        } else {
            TooltipController.shared.unfocused(self)
        }
    }

    func detach() {
        TooltipController.shared.detach(from: self)
    }
}

// A hosting view that never takes the first responder and is not in the Tab loop of the window:
// the host of the SwiftUI part of a panel body. An AppKit view inside it, such as a text field,
// takes the focus itself.
open class PassiveHostingView<Content: View>: NSHostingView<Content> {
    override open var acceptsFirstResponder: Bool { false }
    override open var canBecomeKeyView: Bool { false }
    // A call of makeFirstResponder does not ask acceptsFirstResponder, so the host also refuses
    // here.
    override open func becomeFirstResponder() -> Bool { false }
}

// A table of a panel body with the plain look of the panels: no background, no grid, no space
// between the cells, no selection highlight, no type select and rows of a fixed height. It never
// takes the first responder, it is not in the Tab loop of the window, it gives each key to the
// next responder, and it has no menu of its own.
@MainActor
open class PassiveTableView: NSTableView {
    public init() {
        super.init(frame: .zero)
        style = .plain
        backgroundColor = .clear
        intercellSpacing = .zero
        gridStyleMask = []
        selectionHighlightStyle = .none
        allowsColumnSelection = false
        allowsEmptySelection = true
        allowsMultipleSelection = false
        allowsTypeSelect = false
        usesAlternatingRowBackgroundColors = false
        usesAutomaticRowHeights = false
        rowSizeStyle = .custom
        focusRingType = .none
        floatsGroupRows = false
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    override open var acceptsFirstResponder: Bool { false }
    override open var canBecomeKeyView: Bool { false }
    // A call of makeFirstResponder does not ask acceptsFirstResponder, so the table also refuses
    // here.
    override open func becomeFirstResponder() -> Bool { false }

    override open func keyDown(with event: NSEvent) {
        nextResponder?.keyDown(with: event)
    }

    override open func keyUp(with event: NSEvent) {
        nextResponder?.keyUp(with: event)
    }

    override open func menu(for event: NSEvent) -> NSMenu? { nil }
}
