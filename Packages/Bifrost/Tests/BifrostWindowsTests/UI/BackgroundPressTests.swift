import AppKit
import BifrostSessions
import BifrostTestSupport
import Testing

@testable import BifrostLayout
@testable import BifrostLook
@testable import BifrostWindows

// A press on the background of the canvas (docs/behaviour/windows.md, "Frames and panels"). The
// press takes the key focus from every panel, and the top frame loses the focus look, as at each
// other loss of the focus. The first click on a window that is not the key window does this too. A
// press on a frame gives the focus back. A press on a frame that goes up the responder chain to
// the canvas and a press while a dialog shows or opens change nothing. A press outside the Panel
// menu closes the menu first. Each test has its own window, which is never ordered front.
// MouseDriver gives the mouse events (MouseEvents.swift).
@MainActor
@Suite("a press on the background", .serialized, .testTimeLimit, .tags(.window))
struct BackgroundPressTests {
    // A point of the canvas where no frame is.
    private static let background = CGPoint(x: 1000, y: 600)

    // Each mouse button. The body of the top frame has the focus before each press.
    @Test func aPressOnTheBackgroundTakesTheFocusFromThePanels() throws {
        let f = CanvasFixture()
        defer { f.close() }
        let a = f.open("settings", at: rect(100, 100, 400, 300))
        let b = f.open("watchlist", at: rect(600, 100, 300, 300))
        let body = try #require(f.bodies.views[panel("watchlist")])
        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            #expect(f.window.makeFirstResponder(body))
            #expect(f.view(b).isTop)
            let hit = f.mouse.down(at: Self.background, in: f.canvas, type: type)
            #expect(hit === f.canvas)
            #expect(f.window.firstResponder === f.window)
            #expect(f.model.layout.focusedFrame == nil)
            #expect(f.model.layout.topFrame?.id == b)
            // The top frame loses the focus look in 250 ms, as when another frame comes to the
            // front.
            #expect(!f.view(b).isTop)
            #expect(!f.view(a).isTop)
            #expect(f.view(b).look.fill == ThemeTokens.panel(transparency: 15).cgColor)
            let fill = try #require(f.view(b).fillLayer.animation(forKey: "backgroundColor"))
            #expect(fill.duration == 0.25)
            // A press on the frame that was on top gives it the focus again.
            f.mouse.down(at: CGPoint(x: 750, y: 250), in: f.canvas)
            #expect(f.model.layout.focusedFrame?.id == b)
            #expect(f.view(b).isTop)
        }
    }

    // The click that brings Bifrost to the front from another app: the window is not the key
    // window. The canvas takes this first click, so a click on the background takes the focus at
    // once. A click on a frame keeps the rule of macOS: no view of the frame takes the first
    // click, so the click only makes the window key, and the focus stays.
    @Test func theFirstClickOnTheBackgroundAlsoTakesTheFocus() throws {
        let f = CanvasFixture()
        defer { f.close() }
        #expect(!f.window.isKeyWindow)
        let a = f.open("settings", at: rect(100, 100, 400, 300))
        let b = f.open("watchlist", at: rect(600, 100, 300, 300))
        let body = try #require(f.bodies.views[panel("watchlist")])
        #expect(f.window.makeFirstResponder(body))
        // The body, the title bar and the left edge of a, and the body of b.
        let onFrames = [
            CGPoint(x: 300, y: 250), CGPoint(x: 300, y: 110), CGPoint(x: 102, y: 250),
            CGPoint(x: 750, y: 250),
        ]
        for point in onFrames {
            #expect(f.mouse.hitView(at: point, in: f.canvas)?.isDescendant(of: f.canvas) == true)
            #expect(f.mouse.firstDown(at: point, in: f.canvas) == nil)
        }
        #expect(f.model.layout.focusedFrame?.id == b)
        #expect(f.window.firstResponder === body)
        #expect(f.mouse.firstDown(at: Self.background, in: f.canvas) === f.canvas)
        #expect(f.window.firstResponder === f.window)
        #expect(f.model.layout.focusedFrame == nil)
        #expect(!f.view(a).isTop && !f.view(b).isTop)
    }

    // The frame view gives a right press and a press of another button to the next responder, the
    // canvas. Such a press is on the frame, so the frame comes to the front and keeps the focus.
    @Test func aPressOnAFrameThatGoesUpToTheCanvasKeepsTheFocus() throws {
        let f = CanvasFixture()
        defer { f.close() }
        let a = f.open("settings", at: rect(100, 100, 400, 300))
        _ = f.open("watchlist", at: rect(600, 100, 300, 300))
        let body = try #require(f.bodies.views[panel("watchlist")])
        // The left edge of a: the frame view itself gets the press.
        let edge = CGPoint(x: 102, y: 250)
        for type in [NSEvent.EventType.rightMouseDown, .otherMouseDown] {
            #expect(f.window.makeFirstResponder(body))
            let hit = f.mouse.down(at: edge, in: f.canvas, type: type)
            #expect(hit === f.view(a))
            #expect(f.model.layout.focusedFrame?.id == a)
            #expect(f.view(a).isTop)
            #expect(f.window.firstResponder === body)
        }
    }

    // While a dialog shows, it has the keys. Its overlay covers the canvas, and a press that the
    // overlay gives to the next responder reaches the canvas. The hit view of the press is the
    // overlay, not the canvas, so the press changes nothing: the dialog keeps the focus, and the
    // frames keep theirs.
    @Test func aPressWhileADialogShowsChangesNothing() async throws {
        let f = CanvasFixture(bifrostWindow: true)
        defer { f.close() }
        let window = try #require(f.window as? BifrostWindow)
        let host = DialogHost(look: PanelLook(), clock: ManualClock())
        f.canvas.dialogLayer = host.view
        let a = f.open("settings", at: rect(100, 100, 400, 300))
        let body = try #require(f.bodies.views[panel("settings")])
        #expect(window.makeFirstResponder(body))
        let ask = Task {
            await host.confirm(
                ConfirmText(title: "Stop session", body: "b", confirm: "Stop"), openFolder: nil,
                onBusy: {})
        }
        await waitUntil { host.isOpen }
        #expect(host.view.holdsFocus(of: window))
        let press = try MenuDriver.press(at: f.canvas.convert(Self.background, to: nil), in: window)
        f.canvas.mouseDown(with: press)
        #expect(host.isOpen)
        #expect(host.view.holdsFocus(of: window))
        #expect(f.model.layout.focusedFrame?.id == a)
        #expect(f.view(a).isTop)
        host.escape()
        #expect(await ask.value == false)
        #expect(window.firstResponder === body)
    }

    // A dialog that opens shows its overlay, but SwiftUI draws the backdrop only at its next
    // update, so a press before that update can have the canvas as its hit view. The test hides
    // the overlay to give that hit view. The press changes nothing, so at the close the old first
    // responder gets the focus again with the focus look of its frame.
    @Test func aPressBeforeTheDialogDrawsChangesNothing() async throws {
        let f = CanvasFixture(bifrostWindow: true)
        defer { f.close() }
        let window = try #require(f.window as? BifrostWindow)
        let host = DialogHost(look: PanelLook(), clock: ManualClock())
        f.canvas.dialogLayer = host.view
        let a = f.open("settings", at: rect(100, 100, 400, 300))
        let body = try #require(f.bodies.views[panel("settings")])
        #expect(window.makeFirstResponder(body))
        let ask = Task {
            await host.confirm(
                ConfirmText(title: "Stop session", body: "b", confirm: "Stop"), openFolder: nil,
                onBusy: {})
        }
        await waitUntil { host.isOpen }
        host.view.isHidden = true
        #expect(f.mouse.down(at: Self.background, in: f.canvas) === f.canvas)
        #expect(host.view.holdsFocus(of: window))
        #expect(f.model.layout.focusedFrame?.id == a)
        host.escape()
        #expect(await ask.value == false)
        #expect(window.firstResponder === body)
        #expect(f.view(a).isTop)
    }

    // A press outside a Bifrost menu goes first to the press monitor of the menu, which closes the
    // menu and gives the focus back to the old first responder. The press outside the Panel menu
    // then goes on to the canvas, and on the background it takes the focus. (The press outside a
    // context menu stops at the close: BifrostMenuTests.)
    @Test func aPressOutsideThePanelMenuClosesItThenTakesTheFocus() throws {
        let f = CanvasFixture(bifrostWindow: true)
        defer { f.close() }
        let window = try #require(f.window as? BifrostWindow)
        let a = f.open("settings", at: rect(100, 100, 400, 300))
        let body = try #require(f.bodies.views[panel("settings")])
        #expect(window.makeFirstResponder(body))
        f.view(a).titleBar.menuButton.performClick(nil)
        let menu = f.canvas.bifrostMenu
        #expect(menu.isOpen)
        let press = try MenuDriver.press(at: f.canvas.convert(Self.background, to: nil), in: window)
        #expect(menu.handleMouse(press) === press)
        #expect(!menu.isOpen)
        #expect(window.firstResponder === body)
        #expect(f.mouse.down(at: Self.background, in: f.canvas) === f.canvas)
        #expect(window.firstResponder === window)
        #expect(f.model.layout.focusedFrame == nil)
    }
}
