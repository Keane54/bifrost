// The error line at the bottom of a panel: a line of the panel edge colour on top, then the full
// text, which wraps. The text is not red: red is only for the red box. A line with a close action
// has a close button after the text, and its error then stays until the user closes it. The
// Overview and the Watchlist show it.
import AppKit
import BifrostLook

@MainActor
package final class PanelErrorLine: NSView {
    // The size of the text, in layout units.
    static let textSize = 12.0

    package let label = NSTextField(wrappingLabelWithString: "")
    // The close button. It shows only when the line has a close action.
    package let closeButton = ErrorCloseButton()
    private var metrics = CanvasMetrics(interfaceScale: 100)

    // The action of the close button, or nil for a line with no close button.
    package var onClose: (() -> Void)? {
        didSet {
            closeButton.isHidden = onClose == nil
            needsLayout = true
        }
    }

    override package init(frame: NSRect) {
        super.init(frame: frame)
        label.isSelectable = false
        label.refusesFirstResponder = true
        label.textColor = ThemeTokens.text.nsColor
        addSubview(label)
        closeButton.isHidden = true
        closeButton.target = self
        closeButton.action = #selector(close)
        addSubview(closeButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override package var isFlipped: Bool { true }

    package func show(_ text: String?, metrics: CanvasMetrics) {
        self.metrics = metrics
        isHidden = text == nil
        label.stringValue = text ?? ""
        label.font = Fonts.ui(metrics.points(Self.textSize), weight: .regular)
        closeButton.show(metrics: metrics)
        needsLayout = true
        needsDisplay = true
    }

    // The height of the line for a width: the border and the wrapped text.
    package func height(for width: CGFloat) -> CGFloat {
        let textWidth = self.textWidth(width)
        label.preferredMaxLayoutWidth = textWidth
        let size = label.sizeThatFits(NSSize(width: textWidth, height: .greatestFiniteMagnitude))
        return metrics.points(1) + max(size.height.rounded(.up), buttonSide)
    }

    override package func layout() {
        super.layout()
        let padding = metrics.points(8)
        let border = metrics.points(1)
        label.frame = NSRect(
            x: padding, y: border, width: textWidth(bounds.width),
            height: max(0, bounds.height - border))
        closeButton.frame = NSRect(
            x: bounds.width - padding - buttonSide, y: border, width: buttonSide,
            height: buttonSide)
    }

    override package func draw(_ dirtyRect: NSRect) {
        ThemeTokens.panelEdge.nsColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: metrics.points(1)).fill(using: .sourceOver)
    }

    // The side of the close button, or 0 when it does not show.
    private var buttonSide: CGFloat {
        closeButton.isHidden ? 0 : metrics.points(ErrorCloseButton.side)
    }

    // The width of the text: the line less the padding at each side, and less the close button
    // and the gap of 4 units before it.
    private func textWidth(_ width: CGFloat) -> CGFloat {
        let button = closeButton.isHidden ? 0 : buttonSide + metrics.points(4)
        return max(0, width - 2 * metrics.points(8) - button)
    }

    @objc private func close() {
        onClose?()
    }
}

// The close button of an error line: 16 units square with the x icon of 12 in the dim text
// colour. Under the pointer it has the hover colour and the text colour, and a press gives the
// cyan tint. Its tooltip is the Bifrost tooltip "Close". It never takes the focus.
@MainActor
package final class ErrorCloseButton: NSButton {
    // The side of the button, in layout units.
    static let side = 16.0
    private var hovered = false {
        didSet {
            contentTintColor = (hovered ? ThemeTokens.text : ThemeTokens.textDim).nsColor
            needsDisplay = true
        }
    }

    init() {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        wantsLayer = true
        imagePosition = .imageOnly
        refusesFirstResponder = true
        // The button shows a press with its layer (updateLayer), not with the look of the cell.
        (cell as? NSButtonCell)?.highlightsBy = []
        contentTintColor = ThemeTokens.textDim.nsColor
        setAccessibilityRole(.button)
        setAccessibilityLabel("Close")
        addHoverArea(.activeInKeyWindow)
        TooltipController.shared.attach("Close", to: self, side: .top)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override package var acceptsFirstResponder: Bool { false }

    // The icon at the size of the interface scale.
    func show(metrics: CanvasMetrics) {
        let size = metrics.points(12)
        guard image?.size.width != size else { return }
        let image = Icons.image(.x)
        image.size = NSSize(width: size, height: size)
        self.image = image
    }

    override package var wantsUpdateLayer: Bool { true }

    override package func updateLayer() {
        layer?.backgroundColor =
            isHighlighted
            ? TitleButton.pressColour : hovered ? ThemeTokens.hover.cgColor : nil
    }

    override package func mouseEntered(with event: NSEvent) {
        hovered = true
    }

    override package func mouseExited(with event: NSEvent) {
        hovered = false
    }

    // A hidden button gets no exit of the pointer, so the hover goes when the button or its line
    // hides.
    override package func viewDidHide() {
        super.viewDidHide()
        hovered = false
    }
}
