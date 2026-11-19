import AppKit

// A button of the title bar: 24 units square, the dim text colour, the panel colour and the text
// colour under the pointer, and the cyan tint during a press. The tooltip is the native tooltip
// of AppKit. The side bar and the dictation notice also use its press colour.
package final class TitleButton: NSButton {
    // The cyan tint of a press: the accent at 12 %.
    package static let pressColour: CGColor = {
        var colour = ThemeTokens.accent
        colour.a = 0.12
        return colour.cgColor
    }()

    let label: String
    // True for a button that opens a menu: it acts at the press, as a pop-up button of macOS does,
    // so a drag from the press to a row of the menu and a release there chooses the row.
    package var actsOnPress = false
    package var transparency = 15 {
        didSet { needsDisplay = true }
    }
    private var hovered = false {
        didSet {
            applyContentColour()
            needsDisplay = true
        }
    }
    private var glyph: (text: String, font: NSFont)?

    package init(label: String) {
        self.label = label
        super.init(frame: .zero)
        isBordered = false
        title = ""
        wantsLayer = true
        imagePosition = .imageOnly
        // The button shows a press with its layer (updateLayer), not with the look of the cell.
        (cell as? NSButtonCell)?.highlightsBy = []
        toolTip = label
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        addHoverArea(.activeInKeyWindow)
        applyContentColour()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    package func showImage(_ image: NSImage, size: CGFloat) {
        image.size = NSSize(width: size, height: size)
        self.image = image
        imagePosition = .imageOnly
        applyContentColour()
    }

    package func showGlyph(_ text: String, font: NSFont) {
        glyph = (text, font)
        imagePosition = .noImage
        applyContentColour()
    }

    // The colour of the image or the glyph: the text colour under the pointer, else the dim text
    // colour.
    private func applyContentColour() {
        let colour = hovered ? ThemeTokens.text : ThemeTokens.textDim
        contentTintColor = colour.nsColor
        if let glyph {
            attributedTitle = NSAttributedString(
                string: glyph.text,
                attributes: [.font: glyph.font, .foregroundColor: colour.nsColor])
        }
    }

    // The fill of the state: the cyan tint during a press, the panel colour under the pointer.
    // A press and a release of the cell mark the button for display, so this runs for both.
    package override var wantsUpdateLayer: Bool { true }

    package override func updateLayer() {
        layer?.backgroundColor =
            isHighlighted
            ? Self.pressColour
            : hovered ? ThemeTokens.panel(transparency: transparency).cgColor : nil
    }

    // A button that acts at the press sends its action and runs no tracking loop of the cell, so
    // the window gets the drag and the release of the press. It shows the press tint until the
    // release.
    package override func mouseDown(with event: NSEvent) {
        guard actsOnPress, isEnabled, let action else {
            super.mouseDown(with: event)
            return
        }
        isHighlighted = true
        needsDisplay = true
        sendAction(action, to: target)
    }

    package override func mouseUp(with event: NSEvent) {
        guard actsOnPress else {
            super.mouseUp(with: event)
            return
        }
        isHighlighted = false
        needsDisplay = true
    }

    package override func mouseEntered(with event: NSEvent) {
        hovered = true
    }

    package override func mouseExited(with event: NSEvent) {
        hovered = false
    }
}
