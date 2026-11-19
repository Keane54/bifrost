import AppKit
import BifrostKeyboard
import BifrostTestSupport
import Testing

@testable import BifrostLook
@testable import BifrostWindows

// The Bifrost menu (BifrostMenu): the panel, the accessibility of the rows, the tooltips, the
// close and the focus, the keys and the place on the screen (docs/behaviour/menu.md). The window
// of each test is never ordered front, so the panels never show on the screen. The keys go to the
// parent window, as AppKit gives them to the key window.
@Suite("Bifrost menu", .serialized, .timeLimit(.minutes(1)), .tags(.window))
@MainActor
struct BifrostMenuTests {
    private static func spec(_ id: String, enabled: Bool = true, reason: String? = nil)
        -> MenuItemSpec
    {
        MenuItemSpec(id: id, label: id.capitalized, enabled: enabled, reason: reason)
    }

    // An item, a disabled item, a separator, a check box, a radio and a submenu.
    private static let rows: [MenuRow] = [
        .item(spec("open")), .item(spec("hand over", enabled: false, reason: "Not yet.")),
        .separator, .checkbox(spec("lock"), checked: true), .radio(spec("p1"), checked: false),
        .submenu(spec("more"), rows: [.item(spec("echo")), .item(spec("foxtrot"))]),
    ]

    @Test func theMenuIsABorderlessPanelWithTheMenuRole() throws {
        let d = MenuDriver()
        let window = MenuDriver.window()
        defer { window.close() }
        d.show(Self.rows, in: window)
        let panel = try d.root
        #expect(d.menu.isOpen)
        #expect(panel.styleMask == [.borderless])
        // The parent stays the key window. The panel can take the key focus only for a field.
        #expect(panel.becomesKeyOnlyIfNeeded)
        #expect(panel.canBecomeKey)
        #expect(!panel.isKeyWindow)
        #expect(!panel.canBecomeMain)
        #expect(window.openMenu === d.menu)
        #expect(panel.title.isEmpty)
        #expect(!panel.hasShadow)
        #expect(!panel.isOpaque)
        #expect(panel.backgroundColor == .clear)
        #expect(panel.level == .popUpMenu)
        #expect(panel.list.isAccessibilityElement())
        #expect(panel.list.accessibilityRole() == .menu)
        // A click at the centre of a row lands on the view over the row, not on the SwiftUI host.
        let row = try d.row(0)
        let centre = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        #expect(panel.contentView?.superview?.hitTest(centre) === row)
        // The list is the first responder of the panel. The test window never shows, so the
        // panel does not show either.
        #expect(panel.firstResponder === panel.list)
        #expect(!panel.isVisible)
        // The size: at least 144 wide, and 119 high: the border (2), 4 above and below the rows
        // (8), five rows of 20 and a separator of 9.
        #expect(panel.frame.width >= 144)
        #expect(panel.frame.height == 119)
        // A width gives the width.
        d.show(Self.rows, width: 208, in: window)
        #expect(try d.root.frame.width == 208)
        d.menu.close()
        #expect(!d.menu.isOpen)
        #expect(!panel.canBecomeKey)
        #expect(window.openMenu == nil)
    }

    @Test func eachRowHasTheMenuItemRole() throws {
        let d = MenuDriver()
        let window = MenuDriver.window()
        defer { window.close() }
        d.show(Self.rows, in: window)
        let list = try d.root.list
        // Each row but the separator, in its order.
        let children = try #require(list.accessibilityChildren() as? [MenuRowView])
        #expect(children.map(\.index) == [0, 1, 3, 4, 5])
        #expect(children.allSatisfy { $0.isAccessibilityElement() })
        #expect(children.allSatisfy { $0.accessibilityRole() == .menuItem })
        let labels = children.map { $0.accessibilityLabel() }
        #expect(labels == ["Open", "Hand Over", "Lock", "P1", "More"])
        #expect(!(try d.row(2)).isAccessibilityElement())
        // A checked row gives the check mark of a menu item of macOS, and another row none.
        #expect(try d.row(3).markChar == "✓")
        #expect(try d.row(4).markChar == nil)
        #expect(try d.row(0).markChar == nil)
        // A disabled row is not enabled, with its reason as its help.
        let off = try d.row(1)
        #expect(!off.isAccessibilityEnabled())
        #expect(off.accessibilityHelp() == "Not yet.")
        #expect(try d.row(0).isAccessibilityEnabled())
        #expect(try d.row(0).accessibilityHelp() == nil)
        // A submenu row tells that it has a submenu, and whether it is open.
        let more = try d.row(5)
        #expect(!more.isAccessibilityExpanded())
        let closed = try #require(more.accessibilityChildren()?.first as? NSAccessibilityElement)
        #expect(closed.accessibilityRole() == .menu)
        try d.key("End")
        #expect(more.isAccessibilitySelected())
        #expect(list.accessibilitySelectedChildren() as? [MenuRowView] == [more])
        try d.key("Right")
        #expect(more.isAccessibilityExpanded())
        let submenu = try #require(d.menu.panels.last?.list)
        #expect(more.accessibilityChildren()?.first as? MenuListView === submenu)
        #expect(submenu.accessibilityRole() == .menu)
        #expect(try d.row(0, level: 1).isAccessibilitySelected())
        // A press through accessibility chooses the row.
        #expect(try d.row(1, level: 1).accessibilityPerformPress())
        #expect(d.chosen == ["foxtrot"])
        #expect(!d.menu.isOpen)
    }

    @Test func aCheckedRowReportsItsValue() throws {
        let d = MenuDriver()
        let window = MenuDriver.window()
        defer { window.close() }
        d.show(Self.rows, in: window)
        #expect(try d.row(3).accessibilityValue() as? NSNumber == 1)
        #expect(try d.row(4).accessibilityValue() as? NSNumber == 0)
        #expect(try d.row(0).accessibilityValue() == nil)
        // A choice of the check box keeps the menu open. The owner gives the new rows.
        try d.click(d.row(3))
        #expect(d.chosen == ["lock"])
        #expect(d.menu.isOpen)
        var rows = Self.rows
        rows[3] = .checkbox(Self.spec("lock"), checked: false)
        rows[4] = .radio(Self.spec("p1"), checked: true)
        d.menu.update(rows)
        #expect(try d.row(3).accessibilityValue() as? NSNumber == 0)
        #expect(try d.row(4).accessibilityValue() as? NSNumber == 1)
        #expect(try d.root.list.state.rows == rows)
    }

    @Test func aDisabledRowShowsItsReasonAsTheTooltip() throws {
        let d = MenuDriver()
        let window = MenuDriver.window()
        defer { window.close() }
        d.show(Self.rows, in: window)
        let off = try d.row(1)
        #expect(d.tooltips.text(of: off) == "Not yet.")
        // The panel is small, so the tooltip takes its width and its edges from the screen.
        #expect(d.tooltips.area(of: off) == .screen)
        #expect(d.tooltips.text(of: try d.row(0)) == nil)
        // A click on a disabled row does nothing.
        try d.click(off)
        #expect(d.chosen.isEmpty)
        #expect(d.menu.isOpen)
        // The keys land on the disabled row and show its reason at once, as a focused control
        // shows its tooltip. Return does nothing, and the next row closes the tooltip.
        try d.key("Home")
        #expect(!d.tooltips.watchesPresses)
        try d.key("Down")
        #expect(d.menu.panels.first?.list.state.highlighted == 1)
        #expect(d.tooltips.watchesPresses)
        try d.key("Return")
        #expect(d.chosen.isEmpty)
        try d.key("Down")
        #expect(!d.tooltips.watchesPresses)
        // A row that becomes enabled loses its tooltip, and a close removes each tooltip.
        var rows = Self.rows
        rows[1] = .item(Self.spec("hand over"))
        d.menu.update(rows)
        #expect(d.tooltips.text(of: off) == nil)
        d.menu.update(Self.rows)
        #expect(d.tooltips.text(of: off) == "Not yet.")
        d.menu.close()
        #expect(d.tooltips.text(of: off) == nil)
    }

    @Test func aClickOutsideClosesTheMenu() throws {
        let d = MenuDriver()
        let window = MenuDriver.window()
        defer { window.close() }
        let button = NSRect(x: 500, y: 600, width: 24, height: 24)
        d.show(Self.rows, at: .below(button, rightEdge: true), in: window)
        #expect(d.menu.watchesPresses)
        // A press in the menu goes on to the menu.
        let inside = try MenuDriver.press(at: NSPoint(x: 10, y: 10), in: try d.root)
        #expect(d.menu.handleMouse(inside) === inside)
        #expect(d.menu.isOpen)
        // A press outside closes the menu and goes on to its view.
        let outside = try MenuDriver.press(at: NSPoint(x: 50, y: 50), in: window)
        #expect(d.menu.handleMouse(outside) === outside)
        #expect(!d.menu.isOpen)
        #expect(!d.menu.watchesPresses)
        #expect(d.closes == 1)
        // A press on the button of the menu only closes it, so the button does not open it again.
        d.show(Self.rows, at: .below(button, rightEdge: true), in: window)
        let onButton = try MenuDriver.press(at: NSPoint(x: 510, y: 610), in: window)
        #expect(d.menu.handleMouse(onButton) == nil)
        #expect(!d.menu.isOpen)
    }

    // A press outside a context menu closes it and goes no further, also a right press. A drag and
    // a release outside still go on.
    @Test func aPressOutsideAContextMenuOnlyClosesIt() throws {
        let d = MenuDriver()
        let window = MenuDriver.window()
        defer { window.close() }
        d.show(Self.rows, in: window, outsidePress: .closesOnly)
        let drag = try MenuDriver.mouse(.leftMouseDragged, at: NSPoint(x: 5, y: 5), in: window)
        #expect(d.menu.handleMouse(drag) === drag)
        let up = try MenuDriver.mouse(.leftMouseUp, at: NSPoint(x: 5, y: 5), in: window)
        #expect(d.menu.handleMouse(up) === up)
        #expect(d.menu.isOpen)
        let outside = try MenuDriver.press(at: NSPoint(x: 50, y: 50), in: window)
        #expect(d.menu.handleMouse(outside) == nil)
        #expect(!d.menu.isOpen)
        #expect(d.closes == 1)
        d.show(Self.rows, in: window, outsidePress: .closesOnly)
        let right = try MenuDriver.mouse(.rightMouseDown, at: NSPoint(x: 50, y: 50), in: window)
        #expect(d.menu.handleMouse(right) == nil)
        #expect(!d.menu.isOpen)
    }

    // The parent stays the key window while a menu shows. When it or the root panel (during a
    // field edit) loses the key focus, when the app stops being active, when a menu of the menu
    // bar opens and when an item of the menu bar acts, the menu closes.
    @Test func aLossOfTheKeyFocusClosesTheMenu() async throws {
        let d = MenuDriver()
        let window = MenuDriver.window()
        defer { window.close() }
        // The windows post to the default center. The notifications of the app come from the
        // center of the driver.
        let windows = NotificationCenter.default
        let app = d.appCenter
        let item = NSMenuItem(title: "Close Panel", action: nil, keyEquivalent: "")
        typealias Closer = (
            NotificationCenter, Notification.Name, (BifrostMenu) -> AnyObject?, [String: Any]?
        )
        let closers: [Closer] = [
            (windows, NSWindow.didResignKeyNotification, { _ in window }, nil),
            (windows, NSWindow.didResignKeyNotification, { $0.panels.first }, nil),
            (app, NSApplication.didResignActiveNotification, { _ in NSApplication.shared }, nil),
            (app, NSMenu.didBeginTrackingNotification, { _ in NSMenu() }, nil),
            (app, NSMenu.didSendActionNotification, { _ in NSMenu() }, ["MenuItem": item]),
        ]
        for (count, (center, name, object, info)) in closers.enumerated() {
            d.show(Self.rows, in: window)
            center.post(name: name, object: object(d.menu), userInfo: info)
            #expect(await waitUntil { !d.menu.isOpen }, "\(name.rawValue)")
            #expect(d.closes == count + 1)
        }

        // At a loss of the key focus by the parent, the menu stays only while a panel of the menu
        // (a field edit) or the parent has the key focus. The test app has no key window.
        d.show(Self.rows, in: window)
        d.menu.keyFocusLeft()
        #expect(!d.menu.isOpen)
        #expect(d.closes == closers.count + 1)
    }

    @Test func escReturnsTheFocusToTheOldResponder() throws {
        let d = MenuDriver()
        let window = MenuDriver.window()
        defer { window.close() }
        let old = FocusView()
        let other = FocusView()
        window.contentView?.addSubview(old)
        window.contentView?.addSubview(other)
        #expect(window.makeFirstResponder(old))
        d.show(Self.rows, in: window)
        // A press moves the focus of the window while the menu shows.
        #expect(window.makeFirstResponder(other))
        // Esc closes the open submenu first, then the menu.
        try d.key("End")
        try d.key("Right")
        #expect(d.menu.panels.count == 2)
        try d.key("Escape")
        #expect(d.menu.panels.count == 1)
        #expect(d.menu.isOpen)
        try d.key("Escape")
        #expect(!d.menu.isOpen)
        #expect(d.closes == 1)
        #expect(window.firstResponder === old)
        // A choice also gives the focus back, before the row acts.
        d.show(Self.rows, in: window)
        #expect(window.makeFirstResponder(other))
        try d.click(d.row(0))
        #expect(d.chosen == ["open"])
        #expect(window.firstResponder === old)
    }

    @Test func theMenuTakesKeysOnlyWhileOpen() throws {
        let d = MenuDriver()
        let window = MenuDriver.window()
        defer { window.close() }
        let view = KeyRecordingView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        window.contentView?.addSubview(view)
        #expect(window.makeFirstResponder(view))
        d.show(Self.rows, in: window)
        let panel = try d.root
        // The menu keeps a key that it does not use, and gives a key with Command to the key
        // equivalents of the app.
        let f5 = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: "\u{F708}",
                charactersIgnoringModifiers: "\u{F708}", isARepeat: false, keyCode: 96))
        #expect(d.menu.handleKey(f5))
        let commandC = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: "c",
                charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        #expect(!d.menu.handleKey(commandC))
        // The window gives each key down to the menu, and the first responder of the window gets
        // none: only the key equivalents of the menu bar act, and they act before sendEvent.
        window.sendEvent(commandC)
        try d.key("l")
        #expect(view.keys.isEmpty)
        // The typed letter highlighted the row that starts with it.
        #expect(panel.list.state.highlighted == 3)
        try d.key("Return")
        #expect(d.chosen == ["lock"])
        #expect(d.menu.watchesPresses)
        d.menu.close()
        // After the close, the panel cannot take the key focus, the keys go to the view again
        // and nothing watches the presses.
        #expect(!panel.canBecomeKey)
        #expect(!d.menu.handleKey(f5))
        try d.key("q", in: window)
        #expect(view.keys == ["q"])
        #expect(d.chosen == ["lock"])
        #expect(!d.menu.watchesPresses)
        #expect(panel.owner == nil)
    }

    // A held Return or Space chooses one time: a held Space on Lock changes it once, and a
    // repeat of Return chooses nothing.
    @Test func aHeldReturnOrSpaceChoosesOneTime() throws {
        let d = MenuDriver()
        let window = MenuDriver.window()
        defer { window.close() }
        d.show(Self.rows, in: window)
        // Home, then Down past the disabled row to Lock. A typed letter would start a type-ahead,
        // and Space would then add to the typed text.
        try d.key("Home")
        try d.key("Down")
        try d.key("Down")
        try d.key("Space")
        try d.key("Space", isRepeat: true)
        try d.key("Space", isRepeat: true)
        #expect(d.chosen == ["lock"])
        try d.key("Home")
        try d.key("Return", isRepeat: true)
        #expect(d.chosen == ["lock"])
        #expect(d.menu.isOpen)
        try d.key("Return")
        #expect(d.chosen == ["lock", "open"])
        #expect(!d.menu.isOpen)
    }

    // While the name field edits, an edit of the field from the menu bar keeps the menu open:
    // an action of the field editor (Paste), Undo and Redo of the root panel, and Emoji & Symbols
    // and Dictation, which type into the field. Each other action closes the menu.
    @Test func anEditOfTheFieldKeepsTheMenuOpen() {
        let editor = NSTextView()
        let panel = NSView()
        let other = NSView()
        let app = NSApplication.shared
        let paste = #selector(NSText.paste(_:))
        let undo = BifrostMenu.undoAction
        let redo = BifrostMenu.redoAction
        let emoji = BifrostMenu.emojiAction
        let dictation = BifrostMenu.dictationAction
        func edits(_ action: Selector, _ target: AnyObject?) -> Bool {
            BifrostMenu.editsField(action: action, target: target, editor: editor, panel: panel)
        }
        #expect(edits(paste, editor))
        #expect(edits(undo, panel))
        #expect(edits(redo, panel))
        #expect(edits(emoji, app))
        #expect(edits(dictation, app))
        #expect(!edits(paste, other))
        #expect(!edits(undo, other))
        #expect(!edits(#selector(NSWindow.performClose(_:)), other))
        #expect(!edits(#selector(NSWindow.performZoom(_:)), nil))
    }

    @Test func theMenuStaysInsideTheScreen() throws {
        let d = MenuDriver()
        let window = MenuDriver.window()
        defer { window.close() }
        let screen = MenuDriver.screen
        // At a point near the bottom right corner, the menu flips to the left of the point and
        // above it.
        d.show(Self.rows, at: .point(NSPoint(x: 1190, y: 20)), in: window)
        var frame = try d.root.frame
        #expect(screen.contains(frame))
        #expect(frame.maxX == 1190)
        #expect(frame.minY == 20)
        // At a point with room, the top left corner of the menu is at the point.
        d.show(Self.rows, at: .point(NSPoint(x: 100, y: 700)), in: window)
        frame = try d.root.frame
        #expect(frame.minX == 100)
        #expect(frame.maxY == 700)
        // Below a button with room, 4 under it at its right edge.
        let button = NSRect(x: 600, y: 500, width: 24, height: 24)
        d.show(Self.rows, width: 208, at: .below(button, rightEdge: true), in: window)
        frame = try d.root.frame
        #expect(frame.maxX == button.maxX)
        #expect(frame.maxY == button.minY - 4)
        // Below a button at the bottom edge, the menu flips above the button.
        let low = NSRect(x: 600, y: 10, width: 24, height: 24)
        d.show(Self.rows, width: 208, at: .below(low, rightEdge: true), in: window)
        frame = try d.root.frame
        #expect(frame.minY == low.maxY + 4)
        // Below a button at the left edge, the menu moves inside the screen.
        let left = NSRect(x: 10, y: 500, width: 24, height: 24)
        d.show(Self.rows, width: 208, at: .below(left, rightEdge: true), in: window)
        #expect(try d.root.frame.minX == screen.minX)
        // At a larger Interface scale, the sizes grow: 4 units under the button are 6 points.
        d.look.interfaceScale = 150
        d.show(Self.rows, width: 208, at: .below(button, rightEdge: true), in: window)
        frame = try d.root.frame
        #expect(frame.width == 312)
        #expect(frame.maxY == button.minY - 6)
    }

    @Test func theSubmenuFlipsToTheLeftAtTheScreenEdge() async throws {
        let d = MenuDriver()
        let window = MenuDriver.window()
        defer { window.close() }
        // With room, the submenu opens at the right of its row, 5 higher than the row, after the
        // pointer rests 100 ms on the row.
        d.show(Self.rows, at: .point(NSPoint(x: 100, y: 700)), in: window)
        d.menu.pointerMoved(to: [5])
        #expect(d.menu.panels.count == 1)
        await d.clock.waitForSleepers(1)
        d.clock.advance(by: .milliseconds(100))
        #expect(await waitUntil { d.menu.panels.count == 2 })
        let row = try d.row(5)
        var rowRect = try d.root.convertToScreen(row.convert(row.bounds, to: nil))
        var submenu = try #require(d.menu.panels.last).frame
        #expect(submenu.minX == rowRect.maxX)
        #expect(submenu.maxY == rowRect.maxY + 5)
        // At the right edge of the screen, the submenu opens at the left of its row.
        d.show(Self.rows, at: .point(NSPoint(x: 1000, y: 700)), in: window)
        try d.key("End")
        try d.key("Right")
        rowRect = try d.root.convertToScreen(d.row(5).convert(d.row(5).bounds, to: nil))
        submenu = try #require(d.menu.panels.last).frame
        #expect(d.menu.panels.count == 2)
        #expect(submenu.maxX == rowRect.minX)
        #expect(MenuDriver.screen.contains(submenu))
    }

    @Test func aChosenRowRunsOnChoose() throws {
        let d = MenuDriver()
        let window = MenuDriver.window()
        defer { window.close() }
        d.show(Self.rows, in: window)
        // A press tints an enabled row, and its release chooses the row and closes the menu.
        let open = try d.row(0)
        d.menu.pressed(open.path)
        #expect(try d.root.list.state.pressed == 0)
        #expect(try d.root.list.state.highlighted == 0)
        d.menu.released(at: try d.screenCentre(of: open))
        #expect(d.chosen == ["open"])
        #expect(!d.menu.isOpen)
        #expect(d.closes == 1)
        // A release on no row chooses nothing.
        d.show(Self.rows, in: window)
        d.menu.pressed([0])
        d.menu.released(at: NSPoint(x: 5, y: 5))
        #expect(try d.root.list.state.pressed == nil)
        #expect(d.chosen == ["open"])
        // The press left the highlight on Open, and Return chooses it.
        try d.key("Return")
        #expect(d.chosen == ["open", "open"])
        // A radio row closes the menu, and a row of a submenu runs with its ID.
        d.show(Self.rows, in: window)
        try d.click(d.row(4))
        #expect(d.chosen.last == "p1")
        #expect(!d.menu.isOpen)
        d.show(Self.rows, in: window)
        try d.click(d.row(5))
        #expect(d.menu.panels.count == 2)
        try d.click(d.row(0, level: 1))
        #expect(d.chosen.last == "echo")
        #expect(!d.menu.isOpen)
    }

    // A press on a row, a drag and a release over another row choose the row under the pointer.
    // So do a press outside the menu that opened it (for example on its button), a drag into the
    // menu and a release over a row.
    @Test func aPressADragAndAReleaseChooseTheRowUnderThePointer() throws {
        let d = MenuDriver()
        let window = MenuDriver.window()
        defer { window.close() }
        d.show(Self.rows, in: window)
        let open = try d.row(0)
        let lock = try d.row(3)
        let panel = try d.root
        let lockPoint = lock.convert(NSPoint(x: lock.bounds.midX, y: lock.bounds.midY), to: nil)
        open.mouseDown(with: try MenuDriver.mouse(.leftMouseDown, at: .zero, in: panel))
        open.mouseDragged(with: try MenuDriver.mouse(.leftMouseDragged, at: lockPoint, in: panel))
        #expect(panel.list.state.highlighted == 3)
        #expect(panel.list.state.pressed == nil)
        open.mouseUp(with: try MenuDriver.mouse(.leftMouseUp, at: lockPoint, in: panel))
        #expect(d.chosen == ["lock"])
        // The press outside: the window is at the origin of the screen, so a screen point is a
        // point of the window.
        let p1 = try d.screenCentre(of: d.row(4))
        let drag = try MenuDriver.mouse(.leftMouseDragged, at: p1, in: window)
        #expect(d.menu.handleMouse(drag) === drag)
        #expect(panel.list.state.highlighted == 4)
        _ = d.menu.handleMouse(try MenuDriver.mouse(.leftMouseUp, at: p1, in: window))
        #expect(d.chosen == ["lock", "p1"])
        #expect(!d.menu.isOpen)
        // A release outside the rows chooses nothing.
        d.show(Self.rows, in: window)
        _ = d.menu.handleMouse(
            try MenuDriver.mouse(.leftMouseUp, at: NSPoint(x: 5, y: 5), in: window))
        #expect(d.menu.isOpen)
        #expect(d.chosen == ["lock", "p1"])
    }

    @Test func aClosedParentWindowClosesTheMenu() async throws {
        let d = MenuDriver()
        let window = MenuDriver.window()
        d.show(Self.rows, in: window)
        #expect(d.menu.isOpen)
        window.close()
        #expect(await waitUntil { !d.menu.isOpen })
        #expect(d.closes == 1)
    }
}

// A view that takes the first responder.
private final class FocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
