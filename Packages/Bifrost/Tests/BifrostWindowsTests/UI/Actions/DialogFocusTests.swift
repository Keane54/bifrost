// The focus of the dialogs over a canvas (docs/behaviour/actions.md, "The dialogs"): while a
// dialog shows, the focus stays in its layer, also when a save or the checks of a start turn the
// fields off, and each key is in the dialog zone. After a failed save of Rename the name field
// has the focus again, and after a failed start of New session the folder field has it again. At
// the close, the old first responder gets the focus back. A dialog that opens closes a Bifrost
// menu of the window first.
import AppKit
import BifrostKeyboard
import BifrostSessions
import BifrostTestSupport
import Testing

@testable import BifrostLayout
@testable import BifrostWindows

// The harness of the actions, with its dialog layer over the canvas of a window that is never
// ordered front, and the body of a Settings frame as the first responder before a dialog.
@MainActor
private final class Parts {
    let h: ActionsHarness
    let fixture = CanvasFixture(bifrostWindow: true)
    let body: NSView

    init(active: [AgentEntry]) async throws {
        h = try await ActionsHarness(active: active)
        let window = try #require(fixture.window as? BifrostWindow)
        window.actsAsKey = true
        fixture.canvas.dialogLayer = h.dialogs.view
        _ = fixture.open("settings", at: rect(100, 100, 400, 300))
        body = try #require(fixture.bodies.views[panel("settings")])
        #expect(window.makeFirstResponder(body))
    }

    var window: BifrostWindow { fixture.window as! BifrostWindow }

    // True when the first responder of the window is in the dialog layer.
    var focusInDialog: Bool { h.dialogs.view.holdsFocus(of: window) }

    // True when a field of the dialog has the focus: its field editor is the first responder.
    // With a text, only the field that shows this text counts.
    func fieldHasFocus(text: String? = nil) -> Bool {
        guard let editor = window.firstResponder as? NSText, focusInDialog else { return false }
        return text.map { editor.string == $0 } ?? true
    }

    // True when the layer holds the focus and no field has it.
    var layerHasFocus: Bool { focusInDialog && !(window.firstResponder is NSText) }

    var zone: FocusZone { KeyFocus(window.firstResponder, in: window).zone }

    func close() { fixture.close() }
}

// The fields of the dialogs are SwiftUI text fields, so the suite takes its turn with the other
// tests of SwiftUI text fields (SharedFieldEditor).
@Suite(
    "the focus of the dialogs", .serialized, .sharedFieldEditor, .testTimeLimit,
    .tags(.window))
@MainActor
struct DialogFocusTests {
    // The checks of a start (here a slow git run of the folder check) keep the dialog open with
    // its fields off. When the checks pass, the dialog closes.
    @Test func theFocusStaysInADialogWhileTheChecksOfItsStartRun() async throws {
        let p = try await Parts(active: [])
        defer { p.close() }
        let gate = TestGate()
        defer { gate.openAll() }
        p.h.calls.holdGit(gate)
        p.h.runner.runGlobal(.newSession)
        let model = try p.h.newSessionDialog()
        #expect(p.window.dialogIsOpen)
        #expect(p.focusInDialog)
        model.apply(.cwd("/p"))
        let start = Task { await model.submit() }
        await gate.waitUntilHolding()
        #expect(model.busy)
        #expect(p.focusInDialog)
        #expect(p.zone == .modal)
        // A field that the start turns off gives the focus to the window: the layer keeps it.
        _ = p.window.makeFirstResponder(p.window)
        #expect(p.focusInDialog)
        _ = p.window.makeFirstResponder(p.body)
        #expect(p.focusInDialog)
        #expect(p.zone == .modal)
        gate.openAll()
        await p.h.finish(start)
        #expect(!p.window.dialogIsOpen)
        // The old first responder has the focus again.
        #expect(p.window.firstResponder === p.body)
        #expect(p.zone != .modal)
        await p.h.settle()
    }

    // The name field has the focus before the save, as after the open. The save turns the field
    // off, and the layer holds the focus. After the failed save the field has the focus again.
    @Test func aFailedRenameSaveGivesTheFocusToTheNameField() async throws {
        let p = try await Parts(active: [Entry.running(s1)])
        defer { p.close() }
        let gate = TestGate()
        defer { gate.openAll() }
        p.h.runner.run(.rename, s1)
        let model = try p.h.renameDialog()
        model.alsoClaude = true
        await waitUntil { p.fieldHasFocus() }
        // The send of /rename waits at its spawn, then fails.
        p.h.spawner.holdNext(gate)
        p.h.spawner.failNext(PTYError(message: "The spawn failed."))
        let save = Task { await model.submit() }
        await gate.waitUntilHolding()
        #expect(model.busy)
        // The focus is in the layer during the save, not in the field.
        await waitUntil { p.layerHasFocus }
        // A click on the box during the save gives the focus to the layer.
        #expect(p.window.makeFirstResponder(p.h.dialogs.view))
        gate.openAll()
        await p.h.finish(save)
        #expect(model.reason != nil)
        #expect(!model.busy)
        // The failure asks for the focus with a count that only rises, so SwiftUI sees it also
        // when it never saw busy as true.
        #expect(model.focusReturns == 1)
        await waitUntil { p.fieldHasFocus() }
        // The field writes its text again when it gets the focus. The same text keeps the reason.
        #expect(model.reason != nil)
        model.cancel()
        #expect(p.window.firstResponder === p.body)
    }

    // The same for New session: the folder field has the focus before the start. After a failed
    // check of the start, the folder field has the focus again, and the reason still shows.
    @Test func aFailedStartGivesTheFocusToTheFolderField() async throws {
        let p = try await Parts(active: [])
        defer { p.close() }
        let gate = TestGate()
        defer { gate.openAll() }
        p.h.runner.runGlobal(.newSession)
        let model = try p.h.newSessionDialog()
        model.apply(.cwd("/p"))
        await waitUntil { p.fieldHasFocus(text: "/p") }
        // The folder check of the start waits at its git run. Then the check of claude fails.
        p.h.calls.holdGit(gate)
        let start = Task { await model.submit() }
        await gate.waitUntilHolding()
        #expect(model.busy)
        await waitUntil { p.layerHasFocus }
        p.h.deps.claudeFound = false
        gate.openAll()
        await p.h.finish(start)
        #expect(!model.busy)
        #expect(model.focusReturns == 1)
        await waitUntil { p.fieldHasFocus(text: "/p") }
        // The field writes its text again when it gets the focus. The same text keeps the reason.
        #expect(model.reason == ActionRefusal.claudeNotFound.message)
        model.cancel()
        #expect(p.window.firstResponder === p.body)
    }

    // A dialog that opens while a Bifrost menu shows over the window closes the menu first: the
    // menu gives the focus back to its old first responder, the dialog takes the focus, and the
    // keys go to the dialog. At the close of the dialog, that responder has the focus again.
    @Test func aDialogClosesAnOpenMenuFirst() async throws {
        let p = try await Parts(active: [Entry.running(s1)])
        defer { p.close() }
        let driver = MenuDriver()
        driver.show([.item(MenuItemSpec(id: "alpha", label: "Alpha"))], in: p.window)
        #expect(p.window.menuIsOpen)
        p.h.runner.run(.rename, s1)
        let model = try p.h.renameDialog()
        #expect(!driver.menu.isOpen)
        #expect(!p.window.menuIsOpen)
        #expect(driver.closes == 1)
        #expect(p.focusInDialog)
        #expect(p.zone == .modal)
        model.cancel()
        #expect(p.window.firstResponder === p.body)
    }

    // The close gives the focus back also when the window itself has it.
    @Test func theCloseGivesTheFocusBackFromTheWindow() async throws {
        let p = try await Parts(active: [Entry.running(s1)])
        defer { p.close() }
        p.h.runner.run(.rename, s1)
        let model = try p.h.renameDialog()
        p.window.openDialog = nil
        _ = p.window.makeFirstResponder(p.window)
        p.window.openDialog = p.h.dialogs.view
        model.cancel()
        #expect(p.window.firstResponder === p.body)
    }
}
