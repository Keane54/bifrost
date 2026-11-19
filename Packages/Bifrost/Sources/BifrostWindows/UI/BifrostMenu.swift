// The Bifrost menu (docs/behaviour/menu.md): the one menu type of the menus inside the window.
// The system menu bar stays an NSMenu.
//
// A menu is a borderless panel above the window (MenuPanel), with SwiftUI rows (MenuView), and
// each open submenu is one more panel. MenuNavigation has the rules of the keys and the pointer.
// This presenter gives it each key and each pointer move with the time of the clock, and runs its
// effects: the highlight, the submenus, a choice and the close.
//
// - The parent window stays the key window, as with each menu of macOS. A BifrostWindow gives each
//   key down to the open menu. The root panel takes the key focus only while the text field of a
//   field row edits, and gives it back to the parent when the highlight leaves the field.
// - These close the menu: a press outside it (also in another app), Esc, a chosen row that closes
//   the menu, the loss of the key focus by the parent or by the root panel (but not to a window of
//   the menu), the deactivation of the app, a menu of the menu bar, an item of the menu bar that
//   acts (but not an edit of the field of the menu) and a close of the parent. At each close, the
//   old first responder of the parent gets the focus back. After a field edit, the parent becomes
//   the key window again when no window of the active app has the key focus.
// - The owner sets what a press outside the menu in the app does after the close (OutsidePress):
//   it goes no further, as with a context menu over a backdrop, or it goes on to its view.
// - A chosen row that closes the menu acts after the close, so an action that moves the focus
//   (for example to a dialog) keeps it.
// - The panel orders in only over a window that shows. A test window never shows, so the tests
//   read the panels with no window on the screen.
import AppKit
import BifrostFoundation
import BifrostKeyboard
import BifrostLayout
import BifrostLook

private typealias M = ThemeTokens.Menu

@MainActor
package final class BifrostMenu {
    package enum Placement: Sendable {
        // At the point of a right-click, in screen coordinates: the top left corner of the menu.
        case point(NSPoint)
        // Below a button (its rect in screen coordinates), belowGap units under it. rightEdge
        // puts the right edge of the menu at the right edge of the button, else the left edges
        // line up.
        case below(NSRect, rightEdge: Bool)

        // The point that gives the screen of the menu.
        var anchor: NSPoint {
            switch self {
            case .point(let point): point
            case .below(let button, _): NSPoint(x: button.midX, y: button.midY)
            }
        }
    }

    // What a press outside the open menu, in the app, does after it closes the menu. A press in
    // another app always goes on to that app.
    package enum OutsidePress: Sendable {
        // The press goes no further, as with a context menu over a backdrop: no view gets it.
        case closesOnly
        // The press goes on to the view under it. A press on the button of a menu below a button
        // still goes no further, so the button does not open the menu again.
        case goesOn
    }

    // The accessibility notifications of a menu that opens and closes, and of a menu item that
    // gets the highlight, as the menus of macOS post them.
    private static let menuOpened = NSAccessibility.Notification(rawValue: "AXMenuOpened")
    private static let menuClosed = NSAccessibility.Notification(rawValue: "AXMenuClosed")
    private static let itemSelected = NSAccessibility.Notification(rawValue: "AXMenuItemSelected")

    private let look: PanelLook
    private let tooltips: TooltipController
    private let timeline: Timeline
    // The timer of the submenu delay.
    private let submenuTimer: TimerSlot
    // The open menu, or nil.
    private var shown: Shown?

    // The center of the notifications of the app that close the menu: the deactivation of the
    // app, a menu of the menu bar that opens and an item of the menu bar that acts. A test gives
    // a center of its own, so the menu bar of a test that runs at the same time does not close
    // its menu. The notifications of the windows always come from the default center.
    var appNotifications = NotificationCenter.default

    // The visible frame of the screen of an anchor point (screen coordinates): the menu stays
    // inside it. A test gives a fixed frame.
    var visibleFrame: (NSPoint) -> NSRect = { point in
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
        return (screen ?? NSScreen.main)?.visibleFrame ?? .zero
    }

    package init(look: PanelLook, tooltips: TooltipController, clock: any Clock<Duration>) {
        self.look = look
        self.tooltips = tooltips
        timeline = Timeline(clock)
        submenuTimer = TimerSlot(clock: clock)
    }

    // A menu that goes away while it shows takes its panels and its watches with it. The owner
    // gets no onClose.
    isolated deinit {
        if let shown { tearDown(shown) }
    }

    package var isOpen: Bool { shown != nil }

    // The panels of the open menu: the root menu, then each open submenu, the outer first. Empty
    // while the menu is closed.
    var panels: [MenuPanel] { shown?.panels ?? [] }

    // The window of the open menu, or nil.
    var parentWindow: NSWindow? { shown?.parent }

    // True while the menu watches the presses outside it, in the app and in the other apps.
    var watchesPresses: Bool { shown?.pressMonitor != nil && shown?.otherAppsMonitor != nil }

    // Show a menu of the rows over the window. A menu that shows closes first. width is the width
    // of the root menu in layout units, or nil for the width of its rows (at least minWidth).
    // outsidePress tells what a press outside the menu does after the close. onChoose gets the ID
    // of a chosen row, onField the ID and the text of a field row at Enter, and onClose runs at
    // each close of this menu.
    package func show(
        _ rows: [MenuRow], width: Double?, at placement: Placement, in window: NSWindow,
        outsidePress: OutsidePress, onChoose: @escaping (String) -> Void,
        onField: @escaping (String, String) -> Void, onClose: @escaping () -> Void
    ) {
        close()
        let shown = Shown(
            rows: rows, width: width, placement: placement, outsidePress: outsidePress,
            parent: window, oldResponder: window.firstResponder, onChoose: onChoose,
            onField: onField, onClose: onClose)
        self.shown = shown
        let metrics = look.metrics
        let root = makePanel(path: [], rows: rows, metrics: metrics)
        root.takesKeys = true
        let size = Self.size(of: rows, width: width, metrics: metrics)
        let origin = Self.origin(
            size, at: placement, gap: metrics.points(M.belowGap),
            in: visibleFrame(placement.anchor))
        root.setFrame(NSRect(origin: origin, size: size), display: false)
        root.list.layoutSubtreeIfNeeded()
        shown.panels = [root]
        watch(window, root: root, shown)
        (window as? BifrostWindow)?.openMenu = self
        // The parent stays the key window: the panel only orders in.
        if window.isVisible {
            window.addChildWindow(root, ordered: .above)
            root.orderFront(nil)
        }
        _ = root.makeFirstResponder(root.list)
        NSAccessibility.post(element: root.list, notification: Self.menuOpened)
    }

    // New rows for the open menu, for example after a check box changed or a field saved. The
    // highlight and the open submenus stay while their rows are still there.
    package func update(_ rows: [MenuRow]) {
        guard let shown else { return }
        shown.navigation.setRows(rows)
        for (index, panel) in shown.panels.enumerated() {
            guard let level = rows.level(panel.list.path) else { continue }
            panel.list.setRows(level)
            attachTips(panel.list)
            // A level with other rows keeps its top edge and its left edge.
            let size = Self.size(
                of: level, width: index == 0 ? shown.width : nil, metrics: panel.list.state.metrics)
            if size != panel.frame.size {
                let top = panel.frame.maxY
                panel.setFrame(
                    NSRect(x: panel.frame.minX, y: top - size.height, width: size.width,
                        height: size.height), display: false)
            }
        }
        sync(shown, highlightChanged: true)
        run(shown.navigation.takeEffects())
    }

    // Close the menu. Nothing happens when no menu shows.
    package func close() {
        guard let shown else { return }
        tearDown(shown)
        restoreFocus(shown)
        shown.onClose()
    }

    private func tearDown(_ shown: Shown) {
        self.shown = nil
        submenuTimer.stop()
        for monitor in [shown.pressMonitor, shown.otherAppsMonitor].compactMap(\.self) {
            NSEvent.removeMonitor(monitor)
        }
        shown.pressMonitor = nil
        shown.otherAppsMonitor = nil
        for watch in shown.watches { watch.cancel() }
        shown.watches = []
        if let parent = shown.parent as? BifrostWindow, parent.openMenu === self {
            parent.openMenu = nil
        }
        for panel in shown.panels.reversed() { dismantle(panel) }
    }

    // MARK: - The panels

    private func makePanel(path: [Int], rows: [MenuRow], metrics: CanvasMetrics) -> MenuPanel {
        let list = MenuListView(path: path, rows: rows, metrics: metrics)
        list.owner = self
        let panel = MenuPanel(list: list)
        panel.owner = self
        attachTips(list)
        return panel
    }

    // A disabled row with a reason shows the reason in a tooltip at its right. The panel is small,
    // so the tooltip takes its width and its edges from the screen.
    private func attachTips(_ list: MenuListView) {
        for view in list.rowViews {
            if let spec = view.row.spec, !spec.enabled, let reason = spec.reason {
                tooltips.attach(reason, to: view, side: .right, area: .screen)
            } else {
                tooltips.detach(from: view)
            }
        }
    }

    private func dismantle(_ panel: MenuPanel) {
        NSAccessibility.post(element: panel.list, notification: Self.menuClosed)
        for view in panel.list.rowViews { tooltips.detach(from: view) }
        panel.takesKeys = false
        panel.owner = nil
        panel.list.owner = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    // The old first responder of the parent gets the focus back. The parent stays the key window,
    // so it takes the key focus back only after a field edit, and only when the app is active and
    // no window has the key focus: a close on the loss of the key focus never takes it back.
    private func restoreFocus(_ shown: Shown) {
        guard let parent = shown.parent else { return }
        let app = NSApplication.shared
        if shown.fieldEdited, app.isActive, app.keyWindow == nil, parent.isVisible {
            parent.makeKey()
        }
        guard let old = shown.oldResponder, parent.firstResponder !== old else { return }
        if old === parent || (old as? NSView)?.window === parent {
            parent.makeFirstResponder(old)
        }
    }

    // The watches of an open menu. A press outside the menu, in the app or in another app, closes
    // it. So do the loss of the key focus by the parent or by the root panel (but not to a window
    // of the menu, for a field edit), the deactivation of the app, a menu of the menu bar, an item
    // of the menu bar that acts and a close of the parent. Each watch acts only for its own menu:
    // a later menu has its own watches.
    private func watch(_ window: NSWindow, root: MenuPanel, _ shown: Shown) {
        let presses: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = presses.union([
            .leftMouseDragged, .rightMouseDragged, .leftMouseUp, .rightMouseUp,
        ])
        shown.pressMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            return self.handleMouse(event)
        }
        shown.otherAppsMonitor = NSEvent.addGlobalMonitorForEvents(matching: presses) {
            [weak self, weak shown] _ in
            guard let self, let shown, self.shown === shown else { return }
            self.close()
        }
        let center = NotificationCenter.default
        let closes = center.notifications(named: NSWindow.willCloseNotification, object: window)
        let resigns = center.notifications(named: NSWindow.didResignKeyNotification, object: window)
        let rootResigns = center.notifications(
            named: NSWindow.didResignKeyNotification, object: root)
        let app = appNotifications
        let inactive = app.notifications(
            named: NSApplication.didResignActiveNotification, object: nil)
        let menuBar = app.notifications(named: NSMenu.didBeginTrackingNotification, object: nil)
        let menuBarActs = app.notifications(named: NSMenu.didSendActionNotification, object: nil)
        shown.watches = [
            Task { [weak self, weak shown] in
                for await _ in closes { self?.close(shown) }
            },
            Task { [weak self, weak shown] in
                for await _ in resigns { self?.keyFocusLeft(shown) }
            },
            Task { [weak self, weak shown] in
                for await _ in rootResigns { self?.keyFocusLeft(shown) }
            },
            Task { [weak self, weak shown] in
                for await _ in inactive { self?.close(shown) }
            },
            Task { [weak self, weak shown] in
                for await _ in menuBar { self?.close(shown) }
            },
            Task { [weak self, weak shown] in
                for await notification in menuBarActs {
                    let item = notification.userInfo?["MenuItem"] as? NSMenuItem
                    self?.menuBarActed(item, shown)
                }
            },
        ]
    }

    // Close the menu when it is still the open menu.
    private func close(_ owner: Shown?) {
        guard let owner, shown === owner else { return }
        close()
    }

    // The parent or the root panel lost the key focus. The menu stays when the parent has it or a
    // panel of the menu took it (a field edit), else it closes: for example a sheet or an alert
    // took the key focus.
    func keyFocusLeft() {
        guard let shown else { return }
        keyFocusLeft(shown)
    }

    private func keyFocusLeft(_ owner: Shown?) {
        guard let owner, shown === owner else { return }
        let key = NSApplication.shared.keyWindow
        if let key, key === owner.parent || owner.panels.contains(where: { $0 === key }) { return }
        close()
    }

    // An item of the menu bar acted, for example Close Panel, Paste or Zoom. The menu closes, so
    // it does not stay open over the result. An edit of the text field of the menu keeps it open.
    private func menuBarActed(_ item: NSMenuItem?, _ owner: Shown?) {
        guard let owner, shown === owner else { return }
        if let item, let action = item.action, let root = owner.panels.first, root.isKeyWindow,
            root.list.focusedField != nil
        {
            let target = NSApplication.shared.target(forAction: action, to: item.target, from: item)
            let editor = root.firstResponder as? NSText
            if Self.editsField(
                action: action, target: target as AnyObject?, editor: editor, panel: root)
            {
                return
            }
        }
        close()
    }

    // The actions of Undo and Redo, which a window gives to its undo manager, and of the Emoji &
    // Symbols palette and Dictation, which the app runs and which type into the key window.
    static let undoAction = Selector(("undo:"))
    static let redoAction = Selector(("redo:"))
    static let emojiAction = #selector(NSApplication.orderFrontCharacterPalette(_:))
    static let dictationAction = Selector(("startDictation:"))
    private static let undoActions: Set<Selector> = [undoAction, redoAction]
    private static let typingActions: Set<Selector> = [emojiAction, dictationAction]

    // True when an action of the menu bar is an edit of the text field that edits in the root
    // panel: its target is the field editor (Paste, Cut, Select All), it is Undo or Redo of the
    // root panel, or it types into the field (Emoji & Symbols, Dictation).
    static func editsField(
        action: Selector, target: AnyObject?, editor: AnyObject?, panel: AnyObject
    ) -> Bool {
        if let editor, target === editor { return true }
        if undoActions.contains(action) && target === panel { return true }
        return typingActions.contains(action)
    }

    // MARK: - The events of the panels

    // A press, a drag or a release in the app. An event in a panel of the menu goes on to the
    // rows. A press outside closes the menu. With OutsidePress.closesOnly it goes no further.
    // With OutsidePress.goesOn it goes on to its view, except a press on the button of a menu
    // below a button: that press only closes the menu, so the button does not open it again. A
    // drag and a release outside come from the press that opened the menu (for example on its
    // button): they move the highlight, and a release on a row chooses the row.
    func handleMouse(_ event: NSEvent) -> NSEvent? {
        guard let shown else { return event }
        if let window = event.window, shown.panels.contains(where: { $0 === window }) {
            return event
        }
        let point = event.window?.convertPoint(toScreen: event.locationInWindow)
            ?? event.locationInWindow
        switch event.type {
        case .leftMouseDragged, .rightMouseDragged:
            dragged(to: point)
            return event
        case .leftMouseUp, .rightMouseUp:
            released(at: point)
            return event
        default:
            var stops = shown.outsidePress == .closesOnly
            if case .below(let button, _) = shown.placement, button.contains(point) {
                stops = true
            }
            close()
            return stops ? nil : event
        }
    }

    // A key down from the parent window (BifrostWindow), or from the root panel while a field
    // edits. True when the menu took the key. The keys that edit text go to a field that has the
    // focus, and a key with Command or Control goes on (the menu bar had it first). Each other key
    // stays in the menu.
    func handleKey(_ event: NSEvent) -> Bool {
        guard let shown, let root = shown.panels.first else { return false }
        let input = root.firstResponder as? any NSTextInputClient
        if input?.hasMarkedText() == true { return false }
        guard let keyEvent = KeyEvent(event, isComposing: false) else { return false }
        if !keyEvent.modifiers.isDisjoint(with: [.command, .control]) { return false }
        // Tab does nothing in a menu, also in a field.
        if keyEvent.key == .named(.tab) { return true }
        guard let key = Self.menuKey(keyEvent) else { return root.list.focusedField == nil }
        guard shown.navigation.usesKey(key) else { return false }
        // A held Return or Space chooses one time: its repeats do nothing.
        if keyEvent.isRepeat && (key == .enter || key == .space) { return true }
        shown.navigation.key(key, now: timeline.now())
        run(shown.navigation.takeEffects(), fromKeys: true)
        return true
    }

    // The key of the menu for a key event, or nil for a key that the menu does not use.
    static func menuKey(_ event: KeyEvent) -> MenuKey? {
        switch event.key {
        case .named(.arrowUp): .up
        case .named(.arrowDown): .down
        case .named(.arrowLeft): .left
        case .named(.arrowRight): .right
        case .named(.home): .home
        case .named(.end): .end
        case .named(.enter): .enter
        case .named(.space): .space
        case .named(.escape): .escape
        // The Enter key of the keypad.
        case .text("\r"), .text("\u{3}"): .enter
        case .text(let text) where isTyped(text): .text(text)
        default: nil
        }
    }

    // True for a text that a key types: no control character, and no character of a function key
    // (U+F700 to U+F8FF).
    private static func isTyped(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return value >= 0x20 && value != 0x7F && !(0xF700...0xF8FF).contains(value)
        }
    }

    // The pointer is over a row.
    func pointerMoved(to path: [Int]) {
        guard let shown else { return }
        shown.navigation.hover(path, now: timeline.now())
        run(shown.navigation.takeEffects())
    }

    // The pointer left a row. It clears the highlight only when the row has it: the pointer can
    // come to the next row before it leaves this one.
    func pointerLeft(_ path: [Int]) {
        guard let shown, shown.navigation.highlighted == path else { return }
        shown.navigation.hover(nil, now: timeline.now())
        run(shown.navigation.takeEffects())
    }

    // A press on a row highlights it, and an enabled item row shows the press tint.
    func pressed(_ path: [Int]) {
        guard let shown, let row = shown.navigation.rows.row(at: path) else { return }
        pointerMoved(to: path)
        if let spec = row.spec, spec.enabled, let list = list(of: path) {
            list.state.pressed = path.last
        }
    }

    // A drag of a press: the row under the pointer gets the highlight, and the press tint goes.
    func dragged(to point: NSPoint) {
        guard let shown else { return }
        for panel in shown.panels where panel.list.state.pressed != nil {
            panel.list.state.pressed = nil
        }
        if let path = rowPath(at: point) {
            pointerMoved(to: path)
        } else if let path = shown.navigation.highlighted {
            pointerLeft(path)
        }
    }

    // The release of a press: on a row, it is a click of that row.
    func released(at point: NSPoint) {
        guard let shown else { return }
        for panel in shown.panels { panel.list.state.pressed = nil }
        guard let path = rowPath(at: point) else { return }
        shown.navigation.click(path)
        run(shown.navigation.takeEffects())
    }

    // A click of a row, for example from VoiceOver.
    func clicked(_ path: [Int]) {
        guard let shown else { return }
        for panel in shown.panels { panel.list.state.pressed = nil }
        shown.navigation.click(path)
        run(shown.navigation.takeEffects())
    }

    // The path of the row under a point of the screen, in the inner open submenu first, or nil.
    func rowPath(at point: NSPoint) -> [Int]? {
        for panel in panels.reversed() where panel.frame.contains(point) {
            let local = panel.list.convert(panel.convertPoint(fromScreen: point), from: nil)
            return panel.list.rowViews.first { $0.frame.contains(local) }?.path
        }
        return nil
    }

    // The field of a field row took the focus.
    func fieldFocused(_ path: [Int]) {
        guard let shown else { return }
        shown.navigation.focusField(path)
        run(shown.navigation.takeEffects())
    }

    // MARK: - The effects

    // fromKeys is true for the effects of a key: a disabled row that the keys highlight shows its
    // reason at once, as a focused control shows its tooltip.
    private func run(_ effects: [MenuEffect], fromKeys: Bool = false) {
        guard let shown else { return }
        if !effects.isEmpty {
            let highlightChanged = effects.contains { effect in
                if case .highlight = effect { true } else { false }
            }
            sync(shown, highlightChanged: highlightChanged)
            if highlightChanged { syncKeyTip(shown, fromKeys: fromKeys) }
        }
        var chosen: [Int]?
        var dismiss = false
        for effect in effects {
            switch effect {
            case .choose(let path): chosen = path
            case .dismiss: dismiss = true
            case .highlight, .openSubmenu, .closeSubmenu: break
            }
        }
        let row = chosen.flatMap { shown.navigation.rows.row(at: $0) }
        if dismiss { close() }
        if let chosen, let row { act(row, at: chosen, in: shown) }
        scheduleSubmenuTimer()
    }

    // A chosen row acts. A field saves its text, and then shows the text of its row again: the
    // owner gives the saved text with update(_:) during onField.
    private func act(_ row: MenuRow, at path: [Int], in shown: Shown) {
        switch row {
        case .field(let id, _, _, _):
            guard let field = list(of: path)?.rowViews[path[path.count - 1]].field else { return }
            shown.onField(id, field.stringValue)
            if self.shown === shown,
                case .field(_, _, let saved, _) = shown.navigation.rows.row(at: path)
            {
                field.show(saved)
            }
        case .separator:
            return
        case .item(let spec), .checkbox(let spec, _), .check(let spec, _), .radio(let spec, _),
            .submenu(let spec, _):
            shown.onChoose(spec.id)
        }
    }

    // The panels, the highlight and the focus follow the navigation. A new highlight tells
    // VoiceOver which menu item has it, in each level.
    private func sync(_ shown: Shown, highlightChanged: Bool) {
        syncSubmenus(shown)
        refresh(shown)
        syncFieldFocus(shown)
        if highlightChanged, let view = highlightedRow(shown) {
            NSAccessibility.post(element: view, notification: Self.itemSelected)
        }
    }

    // The view of the highlighted row, or nil.
    private func highlightedRow(_ shown: Shown) -> MenuRowView? {
        guard let path = shown.navigation.highlighted, let index = path.last,
            let list = list(of: path), list.rowViews.indices.contains(index)
        else { return nil }
        return list.rowViews[index]
    }

    // The tooltip of the reason of a disabled row that the keys highlight. A pointer shows it
    // after the delay of the tooltips, and the keys show it at once. It closes when the highlight
    // moves on.
    private func syncKeyTip(_ shown: Shown, fromKeys: Bool) {
        let view = highlightedRow(shown)
        if let tip = shown.keyTip, tip !== view {
            tooltips.unfocused(tip)
            shown.keyTip = nil
        }
        guard fromKeys, let view, shown.keyTip == nil, let spec = view.row.spec, !spec.enabled,
            spec.reason != nil
        else { return }
        tooltips.focused(view)
        shown.keyTip = view
    }

    // The list of the level that holds the row of the path, or nil.
    private func list(of path: [Int]) -> MenuListView? {
        let parent = [Int](path.dropLast())
        return shown?.panels.first { $0.list.path == parent }?.list
    }

    // The panels follow the open submenus of the navigation.
    private func syncSubmenus(_ shown: Shown) {
        let wanted = shown.navigation.open
        var keep = 1
        while keep < shown.panels.count, keep - 1 < wanted.count,
            shown.panels[keep].list.path == wanted[keep - 1]
        {
            keep += 1
        }
        for panel in shown.panels[keep...].reversed() { dismantle(panel) }
        shown.panels.removeSubrange(keep...)
        for path in wanted.dropFirst(keep - 1) { openSubmenu(path, in: shown) }
    }

    // A submenu opens at the right of its row, submenuRise higher than the row. At the edge of
    // the screen it opens at the left of the row.
    private func openSubmenu(_ path: [Int], in shown: Shown) {
        guard let rows = shown.navigation.rows.level(path), let owner = shown.panels.last,
            let index = path.last, owner.list.rowViews.indices.contains(index)
        else { return }
        let rowView = owner.list.rowViews[index]
        let metrics = look.metrics
        let panel = makePanel(path: path, rows: rows, metrics: metrics)
        let size = Self.size(of: rows, width: nil, metrics: metrics)
        let rowRect = owner.convertToScreen(rowView.convert(rowView.bounds, to: nil))
        let origin = Self.submenuOrigin(
            size, row: rowRect, rise: metrics.points(M.submenuRise),
            in: visibleFrame(NSPoint(x: rowRect.midX, y: rowRect.midY)))
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        panel.list.layoutSubtreeIfNeeded()
        shown.panels.append(panel)
        rowView.submenuList = panel.list
        if owner.isVisible {
            owner.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
        }
        NSAccessibility.post(element: panel.list, notification: Self.menuOpened)
    }

    // Each level shows the highlight and the row of its open submenu.
    private func refresh(_ shown: Shown) {
        let highlighted = shown.navigation.highlighted ?? []
        let open = shown.navigation.open
        for panel in shown.panels {
            let path = panel.list.path
            let state = panel.list.state
            let inLevel = highlighted.count == path.count + 1 && highlighted.starts(with: path)
            let row = inLevel ? highlighted.last : nil
            let openRow = open.first { $0.count == path.count + 1 && $0.starts(with: path) }?.last
            // Each set of an observed value draws the rows again, so only a change sets it.
            if state.highlighted != row { state.highlighted = row }
            if state.openRow != openRow { state.openRow = openRow }
            panel.list.stateChanged()
        }
    }

    // A field row of the root menu has the focus while it has the highlight. The root panel then
    // takes the key focus, so the field gets the typed text, and it gives the key focus back to the
    // parent when the highlight leaves the field. Only the root panel takes the key focus, so a
    // field row works only in the root menu.
    private func syncFieldFocus(_ shown: Shown) {
        guard let root = shown.panels.first else { return }
        if let path = shown.navigation.highlighted, path.count == 1,
            root.list.rowViews.indices.contains(path[0]),
            let field = root.list.rowViews[path[0]].field
        {
            shown.fieldEdited = true
            if root.isVisible && !root.isKeyWindow { root.makeKey() }
            if !field.hasFocus { _ = root.makeFirstResponder(field) }
        } else if root.list.focusedField != nil {
            _ = root.makeFirstResponder(root.list)
            if root.isKeyWindow, let parent = shown.parent, parent.isVisible { parent.makeKey() }
        }
    }

    // The timer of the submenu delay runs while a submenu row waits to open.
    private func scheduleSubmenuTimer() {
        guard let shown, let due = shown.navigation.openDue else {
            submenuTimer.stop()
            shown?.timerDue = nil
            return
        }
        guard shown.timerDue != due else { return }
        shown.timerDue = due
        let wait = max(.zero, due - timeline.now())
        submenuTimer.start(after: wait) { [weak self] in self?.submenuTimerFired() }
    }

    private func submenuTimerFired() {
        guard let shown else { return }
        shown.timerDue = nil
        shown.navigation.timerFired(now: timeline.now())
        run(shown.navigation.takeEffects())
    }

    // MARK: - The size and the place

    // The size of a menu in points: the rows with the border and the space above and below them.
    // A width in layout units is the width of the menu, else the menu is as wide as its widest
    // row, and at least minWidth.
    static func size(of rows: [MenuRow], width: Double?, metrics: CanvasMetrics) -> NSSize {
        let height = metrics.points(
            2 * M.border + 2 * M.paddingY + rows.reduce(0) { $0 + $1.height })
        let least = metrics.points(M.minWidth)
        if let width { return NSSize(width: max(metrics.points(width), least), height: height) }
        let widest = rows.map { contentWidth($0, metrics: metrics) }.max() ?? 0
        let border = metrics.points(M.border)
        return NSSize(width: max(least, (widest + 2 * border).rounded(.up)), height: height)
    }

    // The width in points of the parts of a row.
    private static func contentWidth(_ row: MenuRow, metrics: CanvasMetrics) -> CGFloat {
        let font = Fonts.ui(metrics.points(M.textSize), weight: .regular)
        func text(_ string: String) -> CGFloat {
            (string as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        }
        switch row {
        case .separator:
            return 0
        case .field(_, let label, _, _):
            return text(label) + metrics.points(2 * M.fieldPaddingX)
        case .item(let spec), .checkbox(let spec, _), .check(let spec, _), .radio(let spec, _),
            .submenu(let spec, _):
            var units = M.rowPaddingX
            switch row {
            case .checkbox: units += CheckSquare.size + M.rowGap
            case .check, .radio: units += M.checkColumn + M.rowGap
            default: break
            }
            if spec.hasSwatchColumn { units += M.swatchSize + M.rowGap }
            if case .submenu = row {
                units += M.rowGap + M.chevronSize + M.submenuPaddingRight
            } else {
                units += M.rowPaddingX
            }
            return text(spec.label) + metrics.points(units)
        }
    }

    // The origin of a menu of the size in the visible frame (screen coordinates, y up). At a
    // point, the menu opens below and at the right of it, and flips to the other side of the
    // point at an edge. Below a button, it flips above the button at the bottom edge. A menu that
    // fits on neither side moves inside the frame.
    static func origin(
        _ size: NSSize, at placement: Placement, gap: CGFloat, in screen: NSRect
    ) -> NSPoint {
        var x: CGFloat
        var y: CGFloat
        switch placement {
        case .point(let point):
            x = point.x + size.width <= screen.maxX ? point.x : point.x - size.width
            y = point.y - size.height
            if y < screen.minY && point.y + size.height <= screen.maxY { y = point.y }
        case .below(let button, let rightEdge):
            x = rightEdge ? button.maxX - size.width : button.minX
            y = button.minY - gap - size.height
            if y < screen.minY && button.maxY + gap + size.height <= screen.maxY {
                y = button.maxY + gap
            }
        }
        return NSPoint(
            x: clamp(x, screen.minX, screen.maxX - size.width),
            y: clamp(y, screen.minY, screen.maxY - size.height))
    }

    // The origin of a submenu of the size next to the rect of its row (screen coordinates).
    static func submenuOrigin(
        _ size: NSSize, row: NSRect, rise: CGFloat, in screen: NSRect
    ) -> NSPoint {
        let x = row.maxX + size.width <= screen.maxX ? row.maxX : row.minX - size.width
        let y = row.maxY + rise - size.height
        return NSPoint(
            x: clamp(x, screen.minX, screen.maxX - size.width),
            y: clamp(y, screen.minY, screen.maxY - size.height))
    }

    // A value inside low to high. When high is below low, the result is low.
    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        max(low, min(value, high))
    }
}

// The open menu: the navigation, the panels and the callbacks of the owner.
@MainActor
private final class Shown {
    var navigation: MenuNavigation
    // The width of the root menu in layout units, or nil for the width of its rows.
    let width: Double?
    let placement: BifrostMenu.Placement
    let outsidePress: BifrostMenu.OutsidePress
    weak var parent: NSWindow?
    // The first responder of the parent window when the menu opened.
    weak var oldResponder: NSResponder?
    let onChoose: (String) -> Void
    let onField: (String, String) -> Void
    let onClose: () -> Void
    var panels: [MenuPanel] = []
    // The monitors of the presses in the app and in the other apps.
    var pressMonitor: Any?
    var otherAppsMonitor: Any?
    // The tasks that follow the notifications that close the menu.
    var watches: [Task<Void, Never>] = []
    // True after the text field of a field row had the focus.
    var fieldEdited = false
    // The disabled row whose reason the keys showed, or nil.
    weak var keyTip: MenuRowView?
    // The time of the submenu delay that the timer waits for.
    var timerDue: Duration?

    init(
        rows: [MenuRow], width: Double?, placement: BifrostMenu.Placement,
        outsidePress: BifrostMenu.OutsidePress, parent: NSWindow, oldResponder: NSResponder?,
        onChoose: @escaping (String) -> Void, onField: @escaping (String, String) -> Void,
        onClose: @escaping () -> Void
    ) {
        navigation = MenuNavigation(rows: rows)
        self.width = width
        self.placement = placement
        self.outsidePress = outsidePress
        self.parent = parent
        self.oldResponder = oldResponder
        self.onChoose = onChoose
        self.onField = onField
        self.onClose = onClose
    }
}
