// The main window of the app. Its sendEvent runs the Bifrost key filter before the views get the
// event: the keyDown of SwiftTerm is not open, so the keys of Bifrost must act before the views
// (the section "How state flows" of the architecture design). The filter is WindowKeyFilter. With
// no filter, each event goes to the views as in a plain window.
//
// While a Bifrost menu shows over the window, the window stays the key window, and each key down
// goes to the menu. The key equivalents of the menu bar act before sendEvent, so only they act
// while the menu shows (docs/behaviour/menu.md, "The panel"). A menu that opens ends a recording
// of the key recorder of Settings, so a key at the menu never becomes a key binding.
import AppKit
import BifrostKeyboard
import BifrostSettings

// The key filter of the window. Each method is a hook of the window.
@MainActor
package protocol WindowEventFilter: AnyObject {
    // True when the event acted, so the views must not get it.
    func filter(_ event: NSEvent) -> Bool
    // A key equivalent, before the views and the main menu get it. True when the filter took it.
    func keyEquivalent(_ event: NSEvent) -> Bool
    // The window gave the event to the views.
    func dispatchEnded(_ event: NSEvent)
    // A key down that no view took: the end of the responder chain. True when the filter used
    // the key, so AppKit must not get it.
    func endOfChain(_ event: NSEvent) -> Bool
    // The first responder changed.
    func focusChanged(from: NSResponder?, to: NSResponder?)
    // The window became the key window (true) or stopped being it (false).
    func keyWindowChanged(_ isKey: Bool)
    // An open Bifrost menu took a key down. Its repeats and its release must not reach a view.
    func menuTookKey(_ event: NSEvent)
}

extension WindowEventFilter {
    func menuTookKey(_ event: NSEvent) {}
}

// The class is not final: a test subclass counts the calls of cancelOperation(_:).
public class BifrostWindow: NSWindow {
    package weak var filter: (any WindowEventFilter)?
    // The Bifrost menu that shows over the window, or nil. BifrostMenu sets it after it read the
    // first responder of the window. A menu that opens ends a recording of the key recorder: the
    // menu has the key downs now, and the key equivalents must go to the menu bar, not to the
    // recorder.
    package weak var openMenu: BifrostMenu? {
        didSet {
            guard openMenu != nil, let recorder = firstResponder as? KeyRecorderView else { return }
            recorder.cancel()
        }
    }

    // True while a Bifrost menu shows over the window.
    package var menuIsOpen: Bool { openMenu?.isOpen ?? false }

    // The layer of the dialog that shows over the canvas of the window, or nil. DialogHost sets it
    // while a dialog shows. Then the focus stays in the layer (makeFirstResponder), and the key
    // filter puts each key in the modal zone.
    package weak var openDialog: DialogLayerView?

    // True while a dialog shows over the canvas of the window.
    package var dialogIsOpen: Bool { openDialog != nil }

    #if DEBUG
    // The hook of a test and of a test home: the window acts as the key window, also when the app
    // is not active. A test window is never ordered front, and an input method context is active
    // only in a key window. A Release build does not have it.
    package var actsAsKey = false

    // Only with a test home in a Debug build (WindowShow.actsAsKey). Then the test port can type
    // into the window while another app has the focus.
    public func actAsKeyForTestHome() {
        actsAsKey = true
    }

    override public var isKeyWindow: Bool { actsAsKey || super.isKeyWindow }
    #endif

    // A borderless window can be the key window too (the Borderless mode).
    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { true }

    override public func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let openMenu, openMenu.isOpen {
            filter?.menuTookKey(event)
            _ = openMenu.handleKey(event)
            return
        }
        if let filter, filter.filter(event) { return }
        super.sendEvent(event)
        filter?.dispatchEnded(event)
    }

    // AppKit offers a key equivalent to the key window, which gives it to its views, before the
    // main menu gets it. The filter gets it first, so the key recorder takes each key while it
    // records, also when another view has the same key equivalent.
    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        if filter?.keyEquivalent(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    // A key down that no view took gets here: the end of the responder chain. A waiting Esc acts
    // here. An Esc or a Tab that the filter did not use goes to AppKit: Esc ends the full screen
    // (cancelOperation:) and Tab moves the focus in the key-view loop. Any other key does nothing
    // (no beep).
    override public func keyDown(with event: NSEvent) {
        if filter?.endOfChain(event) == true { return }
        let key = KeyCode(rawValue: event.keyCode)
        if key == KeyCode(.escape) || key == KeyCode(.tab) {
            super.keyDown(with: event)
        }
    }

    override public func keyUp(with event: NSEvent) {}

    // Each change of the first responder goes to the filter. While a dialog shows, a responder
    // outside its layer, the window itself and nil give the focus to the layer: for example a
    // field of the dialog that a busy save turns off gives up the focus to the window.
    override public func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let before = firstResponder
        let target = openDialog.map { $0.keeps(responder) ? responder : $0 } ?? responder
        let done = super.makeFirstResponder(target)
        if done, firstResponder !== before {
            filter?.focusChanged(from: before, to: firstResponder)
        }
        return done
    }

    override public func becomeKey() {
        super.becomeKey()
        filter?.keyWindowChanged(true)
    }

    override public func resignKey() {
        super.resignKey()
        filter?.keyWindowChanged(false)
    }
}
