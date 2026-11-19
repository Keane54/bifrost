import AppKit
import BifrostFoundation
import BifrostTestSupport
import Foundation
import SwiftTerm
import SwiftUI
import Testing

@testable import BifrostChat
@testable import BifrostKeyboard
@testable import BifrostLayout
@testable import BifrostWindows

// The focus zone of the first responder, with real views in a window that is never ordered
// front. The chat is the real chat terminal view.
@Suite("focus targets", .serialized, .timeLimit(.minutes(1)), .tags(.window))
@MainActor
struct FocusTargetTests {
    // A window with a content view. The test adds the views.
    @MainActor
    final class Parts {
        let window: BifrostWindow
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))

        init() {
            UITestApp.prepare()
            window = BifrostWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.actsAsKey = true
            window.contentView = content
        }

        func add<V: NSView>(_ view: V, to parent: NSView? = nil) -> V {
            (parent ?? content).addSubview(view)
            return view
        }

        // The focus after the view becomes the first responder.
        func focus(_ responder: NSResponder?) -> KeyFocus {
            #expect(window.makeFirstResponder(responder))
            return KeyFocus(window.firstResponder, in: window)
        }

    }

    // The real terminal view of a chat, with no chat terminal behind it.
    static func chatView() -> ChatTerminalView {
        let view = ChatTerminalView(
            sessionId: "S1", font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        return view
    }

    @Test func theChatTerminalViewIsTheChatOfItsSession() {
        let p = Parts()
        let chat = p.add(Self.chatView())
        let focus = p.focus(chat)
        #expect(focus.zone == .chat)
        #expect(focus.target?.chatSession == "S1")
        #expect(focus.chat === chat)
        // A view inside the chat terminal is in the chat too.
        let inner = p.add(
            FocusableView(frame: NSRect(x: 0, y: 0, width: 10, height: 10)), to: chat)
        #expect(p.focus(inner).chat === chat)
        #expect(p.focus(inner).zone == .chat)
    }

    @Test func theFieldEditorOfATextFieldAndATextViewAreText() {
        let p = Parts()
        let field = p.add(NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24)))
        let editor = p.focus(field)
        #expect(p.window.firstResponder is NSText)
        #expect(editor.zone == .text)
        let textView = p.add(NSTextView(frame: NSRect(x: 0, y: 40, width: 200, height: 100)))
        #expect(p.focus(textView).zone == .text)
    }

    @Test func aControlIsTheControlZone() {
        let p = Parts()
        let button = p.add(FocusableButton(frame: NSRect(x: 0, y: 0, width: 80, height: 30)))
        #expect(p.focus(button).zone == .control)
        let popUp = p.add(FocusablePopUp(frame: NSRect(x: 0, y: 40, width: 120, height: 30)))
        #expect(p.focus(popUp).zone == .control)
    }

    // A tab of a frame has the accessibility role of a radio button, so it is a control: Return,
    // Space, Tab and the arrow keys stay with it.
    @Test func aTabOfAFrameIsAControl() throws {
        let p = Parts()
        let stack = try Self.stackedCanvas(in: p)
        let tab = try #require(stack.tabs.first)
        // The tab is a plain view (not an NSControl): only its role makes it a control.
        #expect(tab.accessibilityRole() == .radioButton)
        let focus = p.focus(tab)
        #expect(focus.zone == .control)
    }

    // A focused SwiftUI button of the side bar makes its host the first responder. The host has
    // the control mark, so the side bar is a control, as its buttons are.
    @Test func theSideBarHostIsAControl() async throws {
        let p = Parts()
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let store = await UIStateStore.open(
            file: dir.appending(path: "ui-state.json"), clock: ManualClock(),
            log: Recorder<StoreEvent>())
        let layout = WindowLayoutModel(layout: WindowLayout(bounds: LayoutSize(w: 800, h: 600)))
        let host = p.add(
            SideBarView.host(
                model: SideBarModel(layout: layout, store: store), bodies: FakeBodies()))
        host.frame = NSRect(x: 0, y: 0, width: 40, height: 400)
        #expect(host.identifier == FocusMark.control)
        #expect(host.sizingOptions == [])
        let focus = p.focus(host)
        #expect(p.window.firstResponder === host)
        #expect(focus.zone == .control)
    }

    // A canvas with a stack of two panels in the window of the parts.
    // TabView is the tab of a frame, not the TabView of SwiftUI.
    static func stackedCanvas(
        in p: Parts
    ) throws -> (canvas: CanvasView, tabs: [BifrostWindows.TabView]) {
        let model = WindowLayoutModel(layout: WindowLayout(bounds: LayoutSize(w: 1, h: 1)))
        let canvas = CanvasView(model: model, bodies: FakeBodies(), settings: CanvasSettings())
        model.onChange = { [weak canvas] in canvas?.modelChanged($0) }
        canvas.frame = p.content.bounds
        p.content.addSubview(canvas)
        model.apply(.open(panel("watchlist")))
        model.apply(.open(panel("settings")))
        let frames = model.layout.frames.map(\.id)
        try #require(frames.count == 2)
        model.apply(.stack(frames[1], onto: frames[0]))
        let view = try #require(canvas.frameView(frames[0]))
        return (canvas, view.titleBar.tabViews)
    }

    // A dialog in the window, the key recorder, and a view of another window (a sheet, an alert
    // or a popover) are the modal zone. The key recorder also clears the hold gate.
    @Test func aDialogTheKeyRecorderAndAnotherWindowAreModal() {
        let p = Parts()
        let dialog = p.add(FocusableView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)))
        dialog.identifier = FocusMark.modal
        let button = p.add(
            FocusableButton(frame: NSRect(x: 0, y: 0, width: 80, height: 30)), to: dialog)
        #expect(p.focus(button).zone == .modal)
        let recorder = p.add(FocusableView(frame: NSRect(x: 200, y: 0, width: 100, height: 100)))
        recorder.identifier = FocusMark.keyRecorder
        let focus = p.focus(recorder)
        #expect(focus.zone == .modal)
        #expect(focus.target?.inKeyRecorder == true)
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
            backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        let inSheet = FocusableView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        sheet.contentView?.addSubview(inSheet)
        #expect(KeyFocus(inSheet, in: p.window).zone == .modal)
        sheet.close()
    }

    // A sheet of the window or an app-modal window (an alert) makes the chat modal, so the
    // Bifrost keys and the chat input stop. A test never shows a
    // sheet or runs a modal session, because both show a window: the window of the test gives
    // its sheet, and the seam of KeyFocus gives the modal window of the app.
    @Test func aSheetAndAnAppModalWindowMakeTheChatModal() throws {
        UITestApp.prepare()
        let window = SheetWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = content
        let chat = Self.chatView()
        content.addSubview(chat)
        #expect(window.makeFirstResponder(chat))
        #expect(KeyFocus(window.firstResponder, in: window).zone == .chat)
        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
            backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        window.fakeSheet = other
        let inSheet = KeyFocus(window.firstResponder, in: window)
        #expect(inSheet.zone == .modal)
        #expect(inSheet.chat === chat)
        window.fakeSheet = nil
        #expect(KeyFocus(window.firstResponder, in: window).zone == .chat)
        let original = KeyFocus.appModalWindow
        defer { KeyFocus.appModalWindow = original }
        KeyFocus.appModalWindow = { other }
        #expect(KeyFocus(window.firstResponder, in: window).zone == .modal)
        KeyFocus.appModalWindow = original
        #expect(KeyFocus(window.firstResponder, in: window).zone == .chat)
        other.close()
        window.close()
    }

    @Test func theSendBoxIsItsOwnZone() {
        let p = Parts()
        let box = p.add(NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)))
        box.identifier = FocusMark.sendBox
        let text = p.add(NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)), to: box)
        #expect(p.focus(text).zone == .sendBox)
    }

    // A plain view, the rows of an Overview and the window itself are the other zone.
    @Test func anyOtherViewAndTheWindowAreTheOtherZone() {
        let p = Parts()
        let rows = p.add(FocusableView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)))
        rows.identifier = FocusMark.overviewRows(panel("overview:2"))
        let focus = p.focus(rows)
        #expect(focus.zone == .other)
        #expect(focus.target?.overviewRows == "overview:2")
        #expect(focus.chat == nil)
        let window = p.focus(nil)
        #expect(p.window.firstResponder === p.window)
        #expect(window.zone == .other)
    }

    // A key of a composition in a text view matches no Bifrost key: the focus gives the marked
    // text of the first responder.
    @Test func theMarkedTextOfTheFirstResponderIsAComposition() {
        let p = Parts()
        let textView = p.add(NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)))
        #expect(!p.focus(textView).isComposing)
        textView.setMarkedText(
            "か", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(KeyFocus(p.window.firstResponder, in: p.window).isComposing)
        let chat = p.add(Self.chatView())
        #expect(!p.focus(chat).isComposing)
        chat.setMarkedText(
            "か", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(KeyFocus(p.window.firstResponder, in: p.window).isComposing)
    }
}

// A window that says that a sheet shows, with no sheet on the screen.
final class SheetWindow: NSWindow {
    var fakeSheet: NSWindow?
    override var attachedSheet: NSWindow? { fakeSheet }
}

// The test views that can be the first responder, also with Full Keyboard Access off.
final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

final class FocusableButton: NSButton {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
}

@MainActor
final class FocusablePopUp: NSPopUpButton {
    override var acceptsFirstResponder: Bool { true }
}
