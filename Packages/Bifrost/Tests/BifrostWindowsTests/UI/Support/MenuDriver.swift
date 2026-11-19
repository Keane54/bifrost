import AppKit
import BifrostKeyboard
import BifrostTestSupport
import Testing

@testable import BifrostLook
@testable import BifrostWindows

// The driver of the tests of the Bifrost menu: a menu with a manual clock, its own tooltips and a
// fixed screen, and the keys and the clicks of a user. The tests never show a window, so the
// panels of the menu never show on the screen. The driver gives each key to the window of the
// menu as NSApplication does (sendEvent): the parent window, or the root panel while a field
// edits. It gives each click to the view of the row as AppKit does for a press and its release.
// The menu gets the notifications of the app from the center of the driver (appCenter): a test
// that sends a key to a menu bar posts that an item acted, and that must not close the menu of
// a test that runs at the same time.
@MainActor
final class MenuDriver {
    // The visible frame of the screen of the tests, in screen coordinates.
    static let screen = NSRect(x: 0, y: 0, width: 1200, height: 800)

    let clock = ManualClock()
    let tooltips: TooltipController
    let look = PanelLook()
    let menu: BifrostMenu
    // The center of the notifications of the app for the menu.
    let appCenter = NotificationCenter()
    // The IDs that onChoose got, the IDs and texts that onField got, and the count of onClose.
    private(set) var chosen: [String] = []
    private(set) var saved: [(id: String, text: String)] = []
    private(set) var closes = 0

    init(menu given: BifrostMenu? = nil) {
        UITestApp.prepare()
        tooltips = TooltipController(clock: clock)
        menu = given ?? BifrostMenu(look: look, tooltips: tooltips, clock: clock)
        menu.visibleFrame = { _ in Self.screen }
        menu.appNotifications = appCenter
    }

    // A window that is never ordered front, at the origin of the screen, so its coordinates are
    // screen coordinates. It gives each key down to an open menu, as the main window does.
    static func window() -> BifrostWindow {
        let window = BifrostWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    func show(
        _ rows: [MenuRow], width: Double? = nil,
        at placement: BifrostMenu.Placement = .point(NSPoint(x: 100, y: 700)),
        in window: NSWindow, outsidePress: BifrostMenu.OutsidePress = .goesOn
    ) {
        menu.show(
            rows, width: width, at: placement, in: window, outsidePress: outsidePress,
            onChoose: { [weak self] in self?.chosen.append($0) },
            onField: { [weak self] in self?.saved.append(($0, $1)) },
            onClose: { [weak self] in self?.closes += 1 })
    }

    // The root panel of the open menu.
    var root: MenuPanel {
        get throws { try #require(menu.panels.first) }
    }

    // The view of a row of a level: 0 is the root menu, 1 its open submenu.
    func row(_ index: Int, level: Int = 0) throws -> MenuRowView {
        let panels = menu.panels
        try #require(panels.indices.contains(level))
        let views = panels[level].list.rowViews
        try #require(views.indices.contains(index))
        return views[index]
    }

    // The key codes and texts of the keys of the menu tests.
    private static let keys: [String: (code: UInt16, text: String)] = [
        "Down": (125, "\u{F701}"), "Up": (126, "\u{F700}"), "Left": (123, "\u{F702}"),
        "Right": (124, "\u{F703}"), "Return": (36, "\r"), "Escape": (53, "\u{1b}"),
        "Space": (49, " "), "Home": (115, "\u{F729}"), "End": (119, "\u{F72B}"),
        "F5": (96, "\u{F708}"),
    ]

    // A key down of a named key, or of a letter of a US keyboard, in a window: the parent window of
    // the menu by default.
    func key(
        _ name: String, command: Bool = false, isRepeat: Bool = false, in window: NSWindow? = nil
    ) throws {
        let target = try #require(window ?? menu.parentWindow)
        let code: UInt16
        let text: String
        if let key = Self.keys[name] {
            (code, text) = key
        } else {
            let us = try #require(name.first.flatMap { KeyCode(us: $0) })
            (code, text) = (us.rawValue, name)
        }
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: command ? [.command] : [],
                timestamp: 0, windowNumber: target.windowNumber, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: isRepeat, keyCode: code))
        target.sendEvent(event)
    }

    // A press and its release in the centre of a row.
    func click(_ view: MenuRowView) throws {
        let window = try #require(view.window)
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 1))
            if type == .leftMouseDown {
                view.mouseDown(with: event)
            } else {
                view.mouseUp(with: event)
            }
        }
    }

    // A press of the left button at a point of a window, in the coordinates of the window.
    static func press(at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try mouse(.leftMouseDown, at: point, in: window)
    }

    // A mouse event at a point of a window, in the coordinates of the window.
    static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws
        -> NSEvent
    {
        try #require(
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 1))
    }

    // The centre of a row in screen coordinates.
    func screenCentre(of view: MenuRowView) throws -> NSPoint {
        let window = try #require(view.window)
        let centre = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        return window.convertPoint(toScreen: centre)
    }
}
