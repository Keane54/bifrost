// The AppKit part of a Bifrost menu (docs/behaviour/menu.md, "The panel"): the borderless panel of
// one level, its list, and a view over each row. The SwiftUI view of the level (MenuView) draws
// the rows. The AppKit views take the pointer, give the accessibility of a menu, hold the
// tooltips of the disabled rows and hold the text field of a field row.
//
// The list has the accessibility role of a menu, and each row the role of a menu item. A panel
// body never sets a control role, but this rule does not apply here: a menu is a pop-up, not a
// panel body.
import AppKit
import BifrostLayout
import BifrostLook
import SwiftUI
import Synchronization

private typealias M = ThemeTokens.Menu

// The borderless panel of one level: the root menu or an open submenu. A panel does not take the
// key focus: the parent window stays the key window, and it gives the keys to the menu. Only the
// panel of the root menu can take the key focus, while its menu is open, and only for the text
// field of a field row (becomesKeyOnlyIfNeeded). While it has the key focus, each key down goes to
// the menu first.
@MainActor
final class MenuPanel: NSPanel {
    let list: MenuListView
    // True for the root panel while its menu is open.
    var takesKeys = false
    weak var owner: BifrostMenu?

    init(list: MenuListView) {
        self.list = list
        // No defer: the panel has its window number at once, so an event can name it.
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        level = .popUpMenu
        animationBehavior = .none
        collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        becomesKeyOnlyIfNeeded = true
        contentView = list
    }

    override var canBecomeKey: Bool { takesKeys }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let owner, owner.handleKey(event) { return }
        super.sendEvent(event)
    }
}

// The SwiftUI host of a level. It never takes the first responder: the list or the text field
// of a field row takes it.
typealias MenuHost = PassiveHostingView<MenuView>

// The content of a panel: the SwiftUI view of the level, and a view over each row. path is the
// path of the submenu row of the level, or [] for the root menu.
@MainActor
final class MenuListView: NSView {
    let path: [Int]
    let state: MenuLevelState
    private let host: MenuHost
    private(set) var rowViews: [MenuRowView] = []
    weak var owner: BifrostMenu?

    init(path: [Int], rows: [MenuRow], metrics: CanvasMetrics) {
        self.path = path
        state = MenuLevelState(rows: rows, metrics: metrics)
        host = MenuHost(rootView: MenuView(state: state))
        super.init(frame: .zero)
        host.sizingOptions = []
        addSubview(host)
        makeRowViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutRows()
    }

    override func layout() {
        super.layout()
        layoutRows()
    }

    // The host fills the list, and the view of each row lies over its row.
    private func layoutRows() {
        host.frame = bounds
        let metrics = state.metrics
        let border = metrics.points(M.border)
        var y = border + metrics.points(M.paddingY)
        for view in rowViews {
            let height = metrics.points(view.row.height)
            view.frame = NSRect(
                x: border, y: y, width: max(0, bounds.width - 2 * border), height: height)
            y += height
        }
    }

    // New rows of the level. Rows of the same kinds keep their views. A field shows a new text
    // only when the text of its row changed, so a draft stays.
    func setRows(_ rows: [MenuRow]) {
        let old = state.rows
        state.rows = rows
        let sameKinds =
            old.count == rows.count
            && zip(old, rows).allSatisfy { Self.kind($0) == Self.kind($1) }
        guard sameKinds else {
            for view in rowViews { view.removeFromSuperview() }
            makeRowViews()
            layoutRows()
            return
        }
        for (view, (before, after)) in zip(rowViews, zip(old, rows)) {
            view.row = after
            if case .field(_, _, let text, _) = after, case .field(_, _, let was, _) = before,
                text != was
            {
                view.field?.show(text)
            }
        }
    }

    private static func kind(_ row: MenuRow) -> Int {
        switch row {
        case .item: 0
        case .checkbox: 1
        case .radio: 2
        case .submenu: 3
        case .field: 4
        case .separator: 5
        case .check: 6
        }
    }

    private func makeRowViews() {
        rowViews = state.rows.indices.map { index in
            let view = MenuRowView(index: index, row: state.rows[index], list: self)
            addSubview(view)
            return view
        }
    }

    // The highlight, the open submenu row and the focus of the field, after a change of the
    // state.
    func stateChanged() {
        for view in rowViews {
            view.highlighted = state.highlighted == view.index
            view.open = state.openRow == view.index
        }
    }

    // The text field of a field row while it has the focus, or nil.
    var focusedField: MenuTextField? {
        rowViews.lazy.compactMap(\.field).first { $0.hasFocus }
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .menu }

    // The rows, with no separator. A field row is its text field.
    override func accessibilityChildren() -> [Any]? {
        rowViews.compactMap { view -> Any? in
            if case .separator = view.row { return nil }
            return view.field ?? view
        }
    }

    override func accessibilitySelectedChildren() -> [Any]? {
        rowViews.filter(\.highlighted)
    }
}

// The view over one row: the pointer, the accessibility of a menu item and the tooltip of a
// disabled row. A field row holds its text field.
@MainActor
final class MenuRowView: NSView {
    let index: Int
    var row: MenuRow {
        didSet {
            needsLayout = true
            mark.withLock { $0 = markChar }
        }
    }
    // The mark of the row for the old attribute API of accessibility, which AppKit calls with no
    // actor (accessibilityAttributeValue).
    private nonisolated let mark = Mutex<String?>(nil)
    var highlighted = false
    var open = false
    // The list of the open submenu of a submenu row: its accessibility child.
    weak var submenuList: MenuListView?
    private(set) var field: MenuTextField?
    private weak var list: MenuListView?
    private var tracking: NSTrackingArea?
    // The accessibility child of a submenu row while its submenu is closed: an empty menu, so a
    // submenu row always tells that it has a submenu.
    private lazy var closedSubmenu = NSAccessibilityElement.element(
        withRole: .menu, frame: .zero, label: row.spec?.label, parent: self)

    init(index: Int, row: MenuRow, list: MenuListView) {
        self.index = index
        self.row = row
        self.list = list
        super.init(frame: .zero)
        mark.withLock { $0 = markChar }
        if case .field(_, let label, let text, let maxLength) = row {
            let field = MenuTextField(
                label: label, text: text, maxLength: maxLength, metrics: list.state.metrics)
            field.onFocus = { [weak self] in self?.fieldFocused() }
            field.onFocusEnd = { [weak list] in list?.state.fieldFocused = false }
            addSubview(field)
            self.field = field
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    // A panel does not become the key window for a press, so its rows take the first press.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // The path of the row from the root menu.
    var path: [Int] { (list?.path ?? []) + [index] }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutField()
    }

    override func layout() {
        super.layout()
        layoutField()
    }

    // The text field lies in the box of the field row, inside its border and its space.
    private func layoutField() {
        guard let field, let metrics = list?.state.metrics else { return }
        let x = metrics.points(M.fieldPaddingX + M.border + M.fieldBoxPaddingX)
        let y = metrics.points(
            M.fieldPaddingY + M.lineHeight + M.fieldGap + M.border + M.fieldBoxPaddingY)
        field.frame = NSRect(
            x: x, y: y, width: max(0, bounds.width - 2 * x), height: metrics.points(M.lineHeight))
    }

    private func fieldFocused() {
        list?.state.fieldFocused = true
        list?.owner?.fieldFocused(path)
    }

    // MARK: - The pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect,
                .enabledDuringMouseDrag,
            ],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { list?.owner?.pointerMoved(to: path) }
    override func mouseMoved(with event: NSEvent) { list?.owner?.pointerMoved(to: path) }
    override func mouseExited(with event: NSEvent) { list?.owner?.pointerLeft(path) }
    override func mouseDown(with event: NSEvent) { list?.owner?.pressed(path) }

    // AppKit gives the drag and the release of a press to the view of the press. The menu finds
    // the row under the pointer, so a release on another row chooses that row.
    override func mouseDragged(with event: NSEvent) { list?.owner?.dragged(to: screenPoint(event)) }
    override func mouseUp(with event: NSEvent) { list?.owner?.released(at: screenPoint(event)) }

    private func screenPoint(_ event: NSEvent) -> NSPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool {
        switch row {
        case .separator, .field: false
        default: true
        }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .menuItem }
    override func accessibilityLabel() -> String? { row.spec?.label }

    // A check box, a check or a radio row reports 1 while it is checked, else 0.
    override func accessibilityValue() -> Any? {
        switch row {
        case .checkbox(_, let checked), .check(_, let checked), .radio(_, let checked):
            NSNumber(value: checked ? 1 : 0)
        default: nil
        }
    }

    override func isAccessibilityEnabled() -> Bool { row.spec?.enabled ?? true }

    // A disabled row gives its reason as its help.
    override func accessibilityHelp() -> String? {
        guard let spec = row.spec, !spec.enabled else { return nil }
        return spec.reason
    }

    override func isAccessibilitySelected() -> Bool { highlighted }
    override func isAccessibilityExpanded() -> Bool { open }

    // The mark of a checked check box, check or radio row, as a menu item of macOS gives it, or
    // nil.
    var markChar: String? {
        switch row {
        case .checkbox(_, true), .check(_, true), .radio(_, true): "✓"
        default: nil
        }
    }

    // The NSAccessibility protocol has no property for the mark of a menu item, so the row gives it
    // through the old attribute API, which AppKit still calls for AXMenuItemMarkChar.
    @available(macOS, deprecated: 10.10, message: "AppKit calls it for AXMenuItemMarkChar.")
    nonisolated override func accessibilityAttributeValue(
        _ attribute: NSAccessibility.Attribute
    ) -> Any? {
        if attribute.rawValue == "AXMenuItemMarkChar" { return mark.withLock { $0 } }
        return super.accessibilityAttributeValue(attribute)
    }

    override func accessibilityChildren() -> [Any]? {
        guard case .submenu = row else { return [] }
        if open, let submenuList { return [submenuList] }
        return [closedSubmenu]
    }

    override func accessibilityPerformPress() -> Bool {
        guard row.spec?.enabled == true else { return false }
        list?.owner?.clicked(path)
        return true
    }
}

// The text field of a field row: the UI font in the text colour, with no border and no fill (the
// box of the row draws them). It keeps at most maxLength Characters.
@MainActor
final class MenuTextField: NSTextField {
    private let maxLength: Int
    var onFocus: () -> Void = {}
    var onFocusEnd: () -> Void = {}

    init(label: String, text: String, maxLength: Int, metrics: CanvasMetrics) {
        self.maxLength = maxLength
        super.init(frame: .zero)
        stringValue = text
        font = Fonts.ui(metrics.points(M.textSize), weight: .regular)
        textColor = ThemeTokens.text.nsColor
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        isEditable = true
        isSelectable = true
        usesSingleLineMode = true
        lineBreakMode = .byClipping
        cell?.isScrollable = true
        cell?.wraps = false
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // True while the field edits: the field editor of the window is its first responder.
    var hasFocus: Bool { currentEditor() != nil }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus() }
        return became
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusEnd()
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        if stringValue.count > maxLength { show(String(stringValue.prefix(maxLength))) }
    }

    // Show a text, also in the field editor while the field has the focus.
    func show(_ text: String) {
        stringValue = text
        if let editor = currentEditor() {
            editor.string = text
            editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
    }
}
