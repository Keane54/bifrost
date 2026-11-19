// The title bar of a frame: the tabs of a stack, or else one title, then the lock glyph of a locked
// frame, the Panel menu button, Minimise and Close. The title bar is 28 units high, on the title
// colour. Its parts are a row (a stack view) with a space of 4 at the left, 12 at the right and 4
// between the parts. The sizes are in layout units, so they scale with the Interface scale setting.
// While the chat of the active panel listens, the mic and the level bar (DictationMeter) come
// first.
//
// A title can have a suffix after it, in the dim text colour: the name of the tab set of an
// Overview in brackets (OverviewTitle). The suffix is in the tab and in the title of the frame.
//
// A press on the title bar starts a move of the frame. A press on a tab of a stack can tear the tab
// out. A click on a tab activates it. The title bar gets the press and the drag of a tab: the tab
// views take no pointer input. So the drag goes on when a tear-out changes the tabs.
import AppKit
import BifrostDictation
import BifrostLayout
import BifrostLook

final class TitleBarView: NSView {
    // The sizes in layout units. The height of the title bar, the space before the first part
    // and after the last part of the row, and the space between two parts.
    static let height = Geometry.titleHeight
    static let leadingSpace = 4.0, trailingSpace = 12.0, spacing = 4.0
    // The side of a button, of the lock glyph and of the image of the Panel menu button.
    static let buttonSize = 24.0, lockSize = 12.0, iconSize = 16.0
    // The space between the edge of a tab (or of the title) and its text.
    static let textInset = 8.0
    // The size of the title text and of the glyphs of the buttons, and the height of a line.
    static let textSize = 12.0, glyphSize = 16.0, lineHeight = 16.0
    // The height of the line under the active tab.
    static let underline = 2.0

    // The panels, the titles, the suffixes and the lock that the title bar shows.
    private struct Content: Equatable {
        var panels: [PanelID]
        var active: PanelID
        var titles: [String]
        var suffixes: [String?]
        var locked: Bool
    }

    weak var frameView: FrameView?
    // The row of the parts, from the left: the meter, the title or the tabs, the lock glyph and
    // the three buttons. A hidden part takes no space. The title or the tabs take the space that
    // the other parts leave.
    private let row = NSStackView()
    // The tab group of a stack. It is hidden for a frame with one panel.
    let tabStrip = TabStripView()
    var tabViews: [TabView] { tabStrip.tabs }
    // The title of a frame with one panel. It is hidden for a stack.
    private let title = TitleTextView()
    let lockView = NSImageView()
    // The Panel menu opens at the press of its button.
    let menuButton: TitleButton = {
        let button = TitleButton(label: "Panel menu")
        button.actsOnPress = true
        return button
    }()
    let minimiseButton = TitleButton(label: "Minimise")
    let closeButton = TitleButton(label: "Close")
    // The mic and the level bar of a chat that listens.
    let meter = DictationMeter()

    private var metrics = CanvasMetrics(interfaceScale: 100)
    private var transparency = 15
    // The fixed sizes of the lock glyph and the buttons.
    private var sizes: [ScaledLength] = []
    // The content that shows, or nil before the first update.
    private var shown: Content?
    // The tab of the press that runs.
    private var pressedTab: TabView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = ThemeTokens.title.cgColor
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.detachesHiddenViews = true
        // A title bar that is too small for its parts cuts them off at the edge.
        row.setClippingResistancePriority(.defaultLow, for: .horizontal)
        row.setClippingResistancePriority(.defaultLow, for: .vertical)
        row.frame = bounds
        row.autoresizingMask = [.width, .height]
        addSubview(row)
        tabStrip.isHidden = true
        lockView.image = Icons.image(.lockGlyph)
        lockView.imageScaling = .scaleProportionallyUpOrDown
        lockView.contentTintColor = ThemeTokens.textDim.nsColor
        lockView.setAccessibilityLabel("Locked")
        lockView.setAccessibilityRole(.image)
        lockView.isHidden = true
        for view in [meter, title, tabStrip, lockView] as [NSView] + buttons {
            row.addArrangedSubview(view)
        }
        // The title and the tabs fill the height, so the line under a tab is at the bottom.
        for view in [title, tabStrip] as [NSView] {
            view.heightAnchor.constraint(equalTo: row.heightAnchor).isActive = true
        }
        sizes =
            lockView.scaledSize(width: Self.lockSize, height: Self.lockSize)
            + buttons.flatMap { $0.scaledSize(width: Self.buttonSize, height: Self.buttonSize) }
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    var buttons: [TitleButton] { [menuButton, minimiseButton, closeButton] }

    // The title of a frame with one panel, or nil for a stack.
    var titleLabel: NSTextField? { title.isHidden ? nil : title.label }

    // Show the panels of the frame. A stack shows one tab for each panel. A frame with one panel
    // shows its title. A panel with a suffix shows the suffix after its title. The same panels,
    // titles, suffixes and lock change nothing.
    func update(
        panels: [PanelID], active: PanelID, titles: [PanelID: String],
        suffixes: [PanelID: String] = [:], locked: Bool
    ) {
        let content = Content(
            panels: panels, active: active, titles: panels.map { titles[$0] ?? $0.text },
            suffixes: panels.map { suffixes[$0] }, locked: locked)
        guard content != shown else { return }
        shown = content
        if panels.count > 1 {
            let old = tabViews
            let style = tabStyle
            let tabs = panels.indices.map { index in
                let panel = panels[index]
                let tab = old.first { $0.panel == panel } ?? TabView(panel: panel, bar: self)
                tab.apply(style)
                tab.show(
                    title: content.titles[index], suffix: content.suffixes[index],
                    active: panel == active)
                return tab
            }
            tabStrip.show(tabs)
            // A new title gives its tab a new width. The row takes the new widths only after an
            // update of its constraints.
            tabStrip.tabsChanged()
            tabStrip.isHidden = false
            title.isHidden = true
        } else {
            tabStrip.show([])
            tabStrip.isHidden = true
            title.isHidden = false
            title.show(title: titles[active] ?? active.text, suffix: suffixes[active])
        }
        lockView.isHidden = !locked
    }

    // The scale and the panel transparency (the hover colour of the buttons).
    func apply(metrics: CanvasMetrics, transparency: Int) {
        self.metrics = metrics
        self.transparency = transparency
        restyle()
    }

    // Show the meter with the level, or hide it for nil.
    func showMeter(_ level: Double?) {
        let hidden = level == nil
        if let level { meter.show(level: level) }
        if meter.isHidden != hidden { meter.isHidden = hidden }
    }

    // The parts that show, for accessibility: the tab group or the title, the lock glyph, then
    // the three buttons.
    var accessibilityParts: [NSView] {
        var parts: [NSView] = meter.isHidden ? [] : [meter.bar]
        parts.append(titleLabel ?? tabStrip)
        if !lockView.isHidden { parts.append(lockView) }
        return parts + buttons
    }

    // MARK: - The look

    private func points(_ value: Double) -> CGFloat { metrics.points(value) }

    private var tabStyle: TabView.Style {
        TabView.Style(
            font: Fonts.ui(points(Self.textSize), weight: .regular),
            textInset: points(Self.textInset), lineHeight: points(Self.lineHeight),
            underline: points(Self.underline), height: points(Self.height))
    }

    // The sizes and the fonts of the scale, and the hover colour of the buttons.
    private func restyle() {
        row.spacing = points(Self.spacing)
        row.edgeInsets = NSEdgeInsets(
            top: 0, left: points(Self.leadingSpace), bottom: 0, right: points(Self.trailingSpace))
        sizes.apply(metrics)
        meter.apply(metrics: metrics)
        let style = tabStyle
        title.apply(font: style.font, textInset: style.textInset, lineHeight: style.lineHeight)
        for tab in tabViews { tab.apply(style) }
        tabStrip.tabsChanged()
        let glyphFont = Fonts.ui(points(Self.glyphSize), weight: .regular)
        menuButton.showImage(Icons.image(.ellipsisVertical), size: points(Self.iconSize))
        minimiseButton.showGlyph("\u{2212}", font: glyphFont)
        closeButton.showGlyph("\u{00D7}", font: glyphFont)
        for button in buttons { button.transparency = transparency }
    }

    // MARK: - Input

    // A button gets its press. Each other point of the title bar is the title bar.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        let p = convert(point, from: superview)
        guard bounds.contains(p) else { return nil }
        return button(at: p) ?? self
    }

    // The button at a point in the coordinates of the title bar.
    func button(at p: CGPoint) -> NSButton? {
        buttons.first {
            !$0.isHiddenOrHasHiddenAncestor && convert($0.bounds, from: $0).contains(p)
        }
    }

    // The tab at a point in the coordinates of the title bar.
    func tab(at p: CGPoint) -> TabView? {
        guard !tabStrip.isHidden else { return nil }
        return tabViews.first { convert($0.bounds, from: $0).contains(p) }
    }

    // A press on a tab of a stack can start a tear-out. Each other press starts a move.
    override func mouseDown(with event: NSEvent) {
        guard let frameView, let canvas = frameView.canvas else { return }
        canvas.focus(frameView.id)
        let tab = tab(at: convert(event.locationInWindow, from: nil))
        pressedTab = tab
        tab?.pressed = true
        _ = canvas.beginDrag(frameView.id, mode: tab.map { .tab($0.panel) } ?? .move, event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        frameView?.canvas?.dragged(event)
    }

    // A release ends the drag. A click on a tab that did not tear out activates the tab.
    override func mouseUp(with event: NSEvent) {
        let tab = pressedTab
        pressedTab = nil
        tab?.pressed = false
        guard let frameView, let canvas = frameView.canvas else { return }
        canvas.released(event)
        guard let tab,
            canvas.model.layout.frame(of: tab.panel)?.id == frameView.id,
            self.tab(at: convert(event.locationInWindow, from: nil))?.panel == tab.panel
        else { return }
        canvas.model.apply(.activate(tab.panel))
    }

    func activate(_ panel: PanelID) {
        frameView?.canvas?.model.apply(.activate(panel))
    }

    // The title bar is not an element of its own. Its parts are children of the frame.
    override func isAccessibilityElement() -> Bool { false }
}

// The title of a frame with one panel: one line of text, in the middle of the height, with the
// text inset at each side. The text truncates at its end. The title has the text colour, and its
// suffix the dim text colour.
final class TitleTextView: NSView {
    let label = NSTextField(labelWithString: "")
    private var textInset: CGFloat = 8
    private var lineHeight: CGFloat = 16
    private var title = ""
    private var suffix: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.usesSingleLineMode = true
        label.textColor = ThemeTokens.text.nsColor
        label.setAccessibilityRole(.staticText)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { false }

    func apply(font: NSFont, textInset: CGFloat, lineHeight: CGFloat) {
        if label.font != font {
            label.font = font
            showText()
        }
        self.textInset = textInset
        self.lineHeight = lineHeight
        needsLayout = true
    }

    func show(title: String, suffix: String?) {
        guard title != self.title || suffix != self.suffix else { return }
        self.title = title
        self.suffix = suffix
        showText()
    }

    private func showText() {
        guard let suffix, let font = label.font else {
            label.stringValue = title
            return
        }
        label.attributedStringValue = TitleText.attributed(
            title, colour: ThemeTokens.text, suffix: suffix, font: font)
    }

    // The text starts at the inset. A text field draws its text inside its alignment rect.
    override func layout() {
        super.layout()
        label.frame = label.frame(
            forAlignmentRect: CGRect(
                x: textInset, y: (bounds.height - lineHeight) / 2,
                width: max(0, bounds.width - textInset * 2), height: lineHeight))
    }
}

// The tab group of a stack (role="tablist"): a tab group of radio buttons. The tabs are a row at
// the left. Each tab is as wide as its text and its insets while the tabs fit. When they do not
// fit, each tab gets less, in proportion to its width.
final class TabStripView: NSView {
    private(set) var tabs: [TabView] = []
    private let tabRow = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        tabRow.orientation = .horizontal
        tabRow.alignment = .centerY
        tabRow.distribution = .fillProportionally
        tabRow.spacing = 0
        tabRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabRow)
        NSLayoutConstraint.activate([
            tabRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabRow.topAnchor.constraint(equalTo: topAnchor),
            tabRow.bottomAnchor.constraint(equalTo: bottomAnchor),
            tabRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    // Show the tabs in this order. A tab that is not in the list leaves the strip.
    func show(_ next: [TabView]) {
        guard next != tabs else { return }
        for tab in tabs where !next.contains(tab) {
            tabRow.removeArrangedSubview(tab)
            tab.removeFromSuperview()
        }
        // A new tab goes in at its place. A new order of the tabs that stay makes the row again.
        let staying = tabRow.arrangedSubviews
        if next.filter(staying.contains) == staying {
            for (index, tab) in next.enumerated() where !staying.contains(tab) {
                tabRow.insertArrangedSubview(tab, at: index)
            }
        } else {
            for view in staying {
                tabRow.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            for tab in next { tabRow.addArrangedSubview(tab) }
        }
        tabs = next
        tabsChanged()
    }

    // The width of a tab changed. The proportions of the row follow the new widths only after an
    // update of its constraints.
    func tabsChanged() {
        tabRow.needsUpdateConstraints = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { !isHidden }
    override func accessibilityRole() -> NSAccessibility.Role? { .tabGroup }
    override func accessibilityChildren() -> [Any]? { tabs }
    override func accessibilityTabs() -> [Any]? { tabs }
    override func accessibilityValue() -> Any? { tabs.first(where: \.isActive) }
}

// One tab of a stack: the title in the UI font at 12, truncated, with the text inset at each
// side. The active tab has the strong text colour and a 2 unit line of that colour under it. The
// other tabs have the dim text colour, and the text colour under the pointer. A press gives the
// cyan tint.
final class TabView: NSView {
    // The font and the sizes of the scale, in points.
    struct Style: Equatable {
        var font: NSFont
        var textInset: CGFloat
        var lineHeight: CGFloat
        var underline: CGFloat
        var height: CGFloat
    }

    let panel: PanelID
    private(set) var title = ""
    // The dim text after the title, or nil.
    private(set) var suffix: String?
    private(set) var isActive = false
    private weak var bar: TitleBarView?
    private let label = NSTextField(labelWithString: "")
    private let line = NSView()
    private var style = Style(
        font: .systemFont(ofSize: 12), textInset: 8, lineHeight: 16, underline: 2, height: 28)
    private var hovered = false {
        didSet { applyTextColour() }
    }
    var pressed = false {
        didSet { needsDisplay = true }
    }

    init(panel: PanelID, bar: TitleBarView) {
        self.panel = panel
        self.bar = bar
        super.init(frame: .zero)
        wantsLayer = true
        focusRingType = .exterior
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.usesSingleLineMode = true
        label.setAccessibilityElement(false)
        addSubview(label)
        line.wantsLayer = true
        addSubview(line)
        // A tab is never wider than its text and its insets, and it gets narrower when the tabs
        // do not fit.
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
        addHoverArea(.activeInKeyWindow)
        applyTextColour()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(title: String, suffix: String? = nil, active: Bool) {
        if title != self.title || suffix != self.suffix {
            self.title = title
            self.suffix = suffix
            applyTextColour()
            invalidateIntrinsicContentSize()
        }
        if active != isActive {
            isActive = active
            applyTextColour()
            needsDisplay = true
        }
    }

    func apply(_ style: Style) {
        guard style != self.style else { return }
        self.style = style
        if label.font != style.font {
            label.font = style.font
            applyTextColour()
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    // The whole text of the tab: the title, then the suffix after a space.
    private var text: String { TitleText.joined(title, suffix) }

    // The width of the text and its insets, and the height of the title bar.
    override var intrinsicContentSize: NSSize {
        let text = (text as NSString).size(withAttributes: [.font: style.font]).width
        return NSSize(width: text.rounded(.up) + style.textInset * 2, height: style.height)
    }

    // The text is in the middle of the height above the line. A text field draws its text inside
    // its alignment rect.
    override func layout() {
        super.layout()
        let above = max(0, bounds.height - style.underline)
        label.frame = label.frame(
            forAlignmentRect: CGRect(
                x: style.textInset, y: (above - style.lineHeight) / 2,
                width: max(0, bounds.width - style.textInset * 2), height: style.lineHeight))
        line.frame = CGRect(
            x: 0, y: bounds.height - style.underline, width: bounds.width,
            height: style.underline)
    }

    // The title has the colour of the state of the tab, and the suffix the dim text colour.
    private func applyTextColour() {
        let colour =
            isActive ? ThemeTokens.textStrong : hovered ? ThemeTokens.text : ThemeTokens.textDim
        label.textColor = colour.nsColor
        guard let suffix, let font = label.font else {
            label.stringValue = title
            return
        }
        label.attributedStringValue = TitleText.attributed(
            title, colour: colour, suffix: suffix, font: font)
    }

    // The fills of the state: the cyan tint during a press, and the line under the active tab.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = pressed ? TitleButton.pressColour : nil
        line.layer?.backgroundColor = isActive ? ThemeTokens.textStrong.cgColor : nil
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
    }
    // MARK: - The keyboard

    // A tab gets the keyboard focus as a button does: with Full Keyboard Access on. Space and
    // Return activate it.
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool {
        NSApp.isFullKeyboardAccessEnabled && !isHiddenOrHasHiddenAncestor
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { bounds.fill() }

    override func keyDown(with event: NSEvent) {
        guard event.charactersIgnoringModifiers == " " || event.keyCode == Self.returnKey,
            let bar
        else {
            super.keyDown(with: event)
            return
        }
        bar.activate(panel)
    }

    // The key code of the Return key.
    private static let returnKey: UInt16 = 36

    // MARK: - Accessibility: a radio button of the tab group

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
    override func accessibilityLabel() -> String? { text }
    override func accessibilityValue() -> Any? { isActive ? 1 : 0 }
    override func isAccessibilitySelected() -> Bool { isActive }
    override func accessibilityChildren() -> [Any]? { [] }

    override func accessibilityPerformPress() -> Bool {
        guard let bar else { return false }
        bar.activate(panel)
        return true
    }
}

// The text of a title with its suffix: the title in its colour, a space, then the suffix in the
// dim text colour. The text truncates at its end, as a plain title does.
@MainActor
enum TitleText {
    static func joined(_ title: String, _ suffix: String?) -> String {
        suffix.map { "\(title) \($0)" } ?? title
    }

    static func attributed(
        _ title: String, colour: TokenColour, suffix: String, font: NSFont
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: font, .foregroundColor: colour.nsColor, .paragraphStyle: paragraph,
            ])
        text.append(
            NSAttributedString(
                string: " \(suffix)",
                attributes: [
                    .font: font, .foregroundColor: ThemeTokens.textDim.nsColor,
                    .paragraphStyle: paragraph,
                ]))
        return text
    }
}
