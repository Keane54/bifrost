// The dictation notice at the top of a chat panel (docs/behaviour/dictation.md, "The look"). It
// covers no part of Claude's prompt at the bottom, and it does not change the size of the terminal.
// Only its button takes pointer input. The line is one text in a box: the dim text at 12, the panel
// edge colour as the border and the background colour at 90 % behind it, in the middle at the top
// with a space of 8 around it. A notice of a denied microphone has the "Open System Settings"
// button, which opens the Microphone pane of Privacy & Security, because the prompt of macOS shows
// only once.
import AppKit
import BifrostLook

package final class DictationNoticeView: NSView {
    // The Microphone pane of Privacy & Security.
    package static let microphoneSettings =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"

    // The sizes in layout units: the space around the box, the space between the edge of the box
    // and its parts, the space between the text and the button, the size of the button and of
    // the space at each side of its text, and the size of the text.
    static let margin = 8.0, boxInsetX = 8.0, boxInsetY = 4.0, spacing = 8.0
    static let buttonHeight = 20.0, buttonTextInset = 8.0, textSize = 12.0

    // The box is a row: the text, then the button. Only the text wraps.
    let box = NSStackView()
    let label = NoticeText(wrappingLabelWithString: "")
    let button = NoticeButton()
    // The click of the button. The chat terminal gives the opener of System Settings.
    package var openSettings: () -> Void = {}
    // Tell VoiceOver the text of a new line, as a status line does. A test gives its own
    // function.
    var announce: @MainActor (String) -> Void = DictationNoticeView.announceToVoiceOver
    // The line that shows, or nil.
    private(set) var line: NoticeLine?
    private var metrics = CanvasMetrics(interfaceScale: 100)
    // The box keeps its space above and below the text, and also above and below the button
    // while the button shows. A stack view keeps these spaces only at a low priority.
    private var textSpace: [NSLayoutConstraint] = []
    private var buttonSpace: NSLayoutConstraint?
    // The margin above the box and at its sides.
    private var margins: [NSLayoutConstraint] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        box.orientation = .horizontal
        box.alignment = .centerY
        box.detachesHiddenViews = true
        box.wantsLayer = true
        box.layer?.backgroundColor = ThemeTokens.bg.nsColor.withAlphaComponent(0.9).cgColor
        box.layer?.borderColor = ThemeTokens.panelEdge.cgColor
        box.layer?.borderWidth = 1
        label.textColor = ThemeTokens.textDim.nsColor
        label.isSelectable = false
        label.setAccessibilityRole(.staticText)
        // The text is as wide as its lines, and it gives its width to the button first.
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        button.target = self
        button.action = #selector(clicked)
        box.addArrangedSubview(label)
        box.addArrangedSubview(button)
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)
        textSpace = [
            label.topAnchor.constraint(greaterThanOrEqualTo: box.topAnchor),
            box.bottomAnchor.constraint(greaterThanOrEqualTo: label.bottomAnchor),
        ]
        buttonSpace = box.heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
        // The box is at the top, in the middle, with the margin at each side. A notice that is
        // narrower than the margins (a body with no size yet) gives up the side margin, not the
        // middle.
        let side = box.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor)
        side.priority = .defaultHigh
        margins = [box.topAnchor.constraint(equalTo: topAnchor), side]
        NSLayoutConstraint.activate(
            textSpace + margins + [box.centerXAnchor.constraint(equalTo: centerXAnchor)])
        setMetrics(metrics)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    package override var isFlipped: Bool { true }

    // Show the line, or nothing for nil. A new text is announced to VoiceOver one time.
    package func show(_ next: NoticeLine?) {
        let changed = next?.text != line?.text
        line = next
        label.stringValue = next?.text ?? ""
        button.isHidden = next?.opensSettings != true
        buttonSpace?.isActive = !button.isHidden
        isHidden = next == nil
        updateTextWidth()
        if changed, let text = next?.text { announce(text) }
    }

    // An announcement of VoiceOver at the medium priority, so it does not stop the speech that
    // runs.
    static func announceToVoiceOver(_ text: String) {
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [
                .announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
    }

    package func setMetrics(_ metrics: CanvasMetrics) {
        self.metrics = metrics
        let font = Fonts.ui(metrics.points(Self.textSize), weight: .regular)
        label.font = font
        button.setTitle(
            DictationNoticeText.openSettings, font: font,
            textInset: metrics.points(Self.buttonTextInset),
            height: metrics.points(Self.buttonHeight))
        let insetX = metrics.points(Self.boxInsetX)
        let insetY = metrics.points(Self.boxInsetY)
        box.edgeInsets = NSEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
        box.spacing = metrics.points(Self.spacing)
        for constraint in textSpace { constraint.constant = insetY }
        buttonSpace?.constant = metrics.points(Self.buttonHeight) + insetY * 2
        for constraint in margins { constraint.constant = metrics.points(Self.margin) }
        updateTextWidth()
    }

    // A wrapping text needs the width of its lines: the width of the notice without the margins,
    // the insets of the box and the button. The text width changes with the width of the notice,
    // so the text gets it before the layout pass.
    package override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTextWidth()
    }

    // The width of the lines of the text.
    private func updateTextWidth() {
        let buttonPart =
            button.isHidden ? 0 : button.intrinsicContentSize.width + metrics.points(Self.spacing)
        let room =
            bounds.width - metrics.points(Self.margin) * 2 - metrics.points(Self.boxInsetX) * 2
            - buttonPart
        let width = max(0, room).rounded(.down)
        if label.preferredMaxLayoutWidth != width { label.preferredMaxLayoutWidth = width }
    }

    // Only the button takes pointer input. Each other point goes to the terminal below.
    package override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, !button.isHidden, let hit = super.hitTest(point) else { return nil }
        return hit === button || hit.isDescendant(of: button) ? button : nil
    }

    // A right or other-button press, drag or release on the button comes up to the notice,
    // which hands it straight to the chat body, as FrameView does with the canvas. Through
    // super AppKit handed it to the terminal under the notice at that point, and the terminal
    // took a press that was meant for the button.
    package override func rightMouseDown(with event: NSEvent) {
        nextResponder?.rightMouseDown(with: event)
    }

    package override func rightMouseDragged(with event: NSEvent) {
        nextResponder?.rightMouseDragged(with: event)
    }

    package override func rightMouseUp(with event: NSEvent) {
        nextResponder?.rightMouseUp(with: event)
    }

    package override func otherMouseDown(with event: NSEvent) {
        nextResponder?.otherMouseDown(with: event)
    }

    package override func otherMouseDragged(with event: NSEvent) {
        nextResponder?.otherMouseDragged(with: event)
    }

    package override func otherMouseUp(with event: NSEvent) {
        nextResponder?.otherMouseUp(with: event)
    }

    package override func isAccessibilityElement() -> Bool { false }

    package override func accessibilityChildren() -> [Any]? {
        guard !isHidden else { return [] }
        return button.isHidden ? [label] : [label, button]
    }

    @objc private func clicked() {
        openSettings()
    }
}

// The text of the notice. The box measures the text from the frame of the text field, so the
// text keeps the inset of its cell inside the box.
final class NoticeText: NSTextField {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
}

// The button of the notice: the panel edge colour as the border, the text colour, the hover
// colour under the pointer and the cyan tint during a press.
final class NoticeButton: NSButton {
    // The hover colour: white at 5 %.
    static let hoverColour = TokenColour.rgb(255, 255, 255, alpha: 0.05).cgColor

    private var hovered = false {
        didSet { needsDisplay = true }
    }
    // The space at each side of the text, and the height.
    private var textInset: CGFloat = 8
    private var height: CGFloat = 20
    private var textFont = NSFont.systemFont(ofSize: 12)

    init() {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        // The button shows a press with its layer (updateLayer), not with the look of the cell.
        (cell as? NSButtonCell)?.highlightsBy = []
        setAccessibilityRole(.button)
        addHoverArea(.activeInKeyWindow)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // The width of the text and its inset at each side, and the height of the button.
    override var intrinsicContentSize: NSSize {
        let text = (title as NSString).size(withAttributes: [.font: textFont]).width.rounded(.up)
        return NSSize(width: text + textInset * 2, height: height)
    }

    func setTitle(_ text: String, font: NSFont, textInset: CGFloat, height: CGFloat) {
        textFont = font
        self.textInset = textInset
        self.height = height
        title = text
        attributedTitle = NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: ThemeTokens.text.nsColor])
        setAccessibilityLabel(text)
        invalidateIntrinsicContentSize()
    }

    // The look of the state: the cyan tint during a press, the hover colour under the pointer.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.borderWidth = 1
        layer?.borderColor = ThemeTokens.panelEdge.cgColor
        layer?.backgroundColor =
            isHighlighted ? TitleButton.pressColour : hovered ? Self.hoverColour : nil
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
    }
}
