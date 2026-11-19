// The confirmation dialog (docs/behaviour/actions.md, "Confirmations" and "The dialogs"): a
// Bifrost box in an overlay over the canvas, with the dialog mark. A dialog with confirmAgain
// needs a second click 500 ms or more after the first. Esc cancels. SwiftUI takes no synthetic
// click in a window that is never ordered front, so the tests press the buttons through the
// model of the dialog, and send Esc through the window.
import AppKit
import BifrostKeyboard
import BifrostSessions
import BifrostTestSupport
import Testing

@testable import BifrostLayout
@testable import BifrostWindows

private let deleteText = ConfirmText(
    title: "Delete fix-a", body: "This session has 1 changed file in its worktree.",
    confirm: "Delete session", confirmAgain: "Delete anyway", openFolder: "/r")

// A dialog host over the canvas of a window that is never ordered front, and a confirmation
// that runs as its own task.
@MainActor
private final class Parts {
    let clock = ManualClock()
    let fixture = CanvasFixture(bifrostWindow: true)
    let host: DialogHost
    private(set) var result: Bool?
    private(set) var task: Task<Void, Never>?

    init() {
        host = DialogHost(look: PanelLook(), clock: clock)
        fixture.canvas.dialogLayer = host.view
    }

    func ask(_ text: ConfirmText = deleteText) async throws -> ConfirmDialogModel {
        task = Task { [host] in
            let answer = await host.confirm(text, openFolder: {}, onBusy: {})
            self.result = answer
        }
        await waitUntil { host.isOpen }
        guard case .confirm(let model) = host.dialog else { throw HarnessError.noDialog }
        return model
    }

    // The answer of the confirmation, after its end.
    func answer() async -> Bool? {
        if let task { await task.value }
        return result
    }

    func close() { fixture.close() }
}

@Suite("the confirmation dialog", .serialized, .testTimeLimit, .tags(.window))
@MainActor
struct ConfirmDialogTests {
    @Test func aConfirmAgainNeedsASecondClickAfter500ms() async throws {
        let p = Parts()
        defer { p.close() }
        let model = try await p.ask()
        #expect(model.confirmLabel == "Delete session")
        model.pressConfirm()
        #expect(model.step == .again)
        #expect(model.confirmLabel == "Delete anyway")
        // A click that comes too soon changes nothing, and the wait does not start again.
        p.clock.advance(by: .milliseconds(499))
        model.pressConfirm()
        #expect(p.host.isOpen)
        p.clock.advance(by: .milliseconds(1))
        // The second half of a double click and a key repeat do not count.
        model.pressConfirm(clickCount: 2)
        model.pressConfirm(isRepeat: true)
        #expect(p.host.isOpen)
        model.pressConfirm()
        #expect(await p.answer() == true)
        #expect(!p.host.isOpen)
        #expect(p.host.view.isHidden)
        // A dialog with no confirmAgain confirms at the first click.
        let stop = try await p.ask(ConfirmText(title: "Stop session", body: "b", confirm: "Stop"))
        stop.pressConfirm()
        #expect(await p.answer() == true)
    }

    @Test func escCancels() async throws {
        let p = Parts()
        defer { p.close() }
        let window = p.fixture.window
        (window as? BifrostWindow)?.actsAsKey = true
        _ = p.fixture.open("settings", at: rect(100, 100, 400, 300))
        let body = try #require(p.fixture.bodies.views[panel("settings")])
        #expect(window.makeFirstResponder(body))
        _ = try await p.ask()
        #expect(window.firstResponder === p.host.view)
        let esc = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        window.sendEvent(esc)
        #expect(await p.answer() == false)
        #expect(!p.host.isOpen)
        // The focus goes back to the first responder from before the dialog.
        #expect(window.firstResponder === body)
        // Cancel gives false too, and a click on the backdrop does nothing.
        let model = try await p.ask()
        p.host.backdropClick()
        #expect(p.host.isOpen)
        model.cancel()
        #expect(await p.answer() == false)
    }

    // While the dialog shows, the focus is in the dialog zone, so no Bifrost key acts.
    @Test func theDialogHasTheDialogMark() async throws {
        let p = Parts()
        defer { p.close() }
        #expect(p.host.view.identifier == FocusMark.modal)
        let model = try await p.ask()
        let window = p.fixture.window
        #expect(KeyFocus(window.firstResponder, in: window).zone == .modal)
        model.cancel()
        _ = await p.answer()
        #expect(KeyFocus(window.firstResponder, in: window).zone != .modal)
    }

    // The overlay owns the cursor of its whole area, so a chat terminal under it cannot show its
    // I-beam over a dialog. A hit test over the canvas finds the overlay, not a view under it.
    @Test func theOverlayOwnsTheArrowCursorWhileADialogShows() async throws {
        let p = Parts()
        defer { p.close() }
        let canvas = p.fixture.canvas
        _ = p.fixture.open("settings", at: rect(100, 100, 400, 300))
        #expect(p.host.view.arrowRect == nil)
        let model = try await p.ask()
        #expect(p.host.view.arrowRect == p.host.view.bounds)
        let point = NSPoint(x: 200, y: 200)
        let hit = canvas.hitTest(canvas.convert(point, to: canvas.superview))
        #expect(hit === p.host.view || hit?.isDescendant(of: p.host.view) == true)
        model.cancel()
        _ = await p.answer()
        #expect(p.host.view.arrowRect == nil)
    }

    // The dialog is an overlay in the canvas of the window: no sheet, no alert and no other
    // window. The overlay covers the canvas above the frames, and it is hidden after the close.
    @Test func theDialogIsAnInWindowOverlayAndNotASheet() async throws {
        let p = Parts()
        defer { p.close() }
        let canvas = p.fixture.canvas
        _ = p.fixture.open("settings", at: rect(100, 100, 400, 300))
        let window = p.fixture.window
        #expect(p.host.view.isHidden)
        let model = try await p.ask()
        #expect(!p.host.view.isHidden)
        #expect(p.fixture.window.attachedSheet == nil)
        #expect(NSApp.modalWindow == nil)
        // No window of the app belongs to the window: no sheet, no child window. The other
        // suites make windows of their own at the same time, so the check is for this window.
        #expect(!NSApp.windows.contains { $0.sheetParent === window || $0.parent === window })
        #expect(window.childWindows?.isEmpty ?? true)
        #expect(p.host.view.window === p.fixture.window)
        #expect(p.host.view.superview === canvas)
        #expect(canvas.subviews.last === p.host.view)
        #expect(p.host.view.frame == canvas.bounds)
        // A second request while the dialog shows gives false at once, with the busy call.
        var busy = 0
        #expect(await p.host.confirm(deleteText, openFolder: nil) { busy += 1 } == false)
        #expect(busy == 1)
        // A new frame goes below the overlay.
        _ = p.fixture.open("watchlist", at: rect(200, 200, 300, 200))
        #expect(canvas.subviews.last === p.host.view)
        model.cancel()
        _ = await p.answer()
        #expect(p.host.view.isHidden)
    }
}
