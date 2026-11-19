// The focus zone of the first responder (docs/behaviour/keys.md, "Where a shortcut can act"). The
// window reads it from the first responder of the window and its superviews:
// - A view that is a ChatKeyTarget, or is inside one, is the chat of its session.
// - The field editor of a text field and the other NSText views are text.
// - An NSControl is a control. So is a view with the accessibility role of a control, or inside one
//   (a button, a menu button, a radio button, a check box or a menu item), for example a tab of a
//   frame. So is a view with the control mark, or inside one: a SwiftUI control in an NSHostingView
//   makes the host the first responder.
// - A sheet or an alert of the app is a dialog (modal). So is a view inside a view with the modal
//   mark or the key recorder mark.
// - Each other view, and the window itself, is the other zone.
// FocusZone(_:) of the key model keeps the order of the checks (row K7).
import AppKit
import BifrostLayout

// A chat terminal: the view that is the first responder of a chat window. ChatTerminalView is
// one, and so is the ChatTerminal that owns it. Each chat owns its chat input, so the filter owns
// no chat state.
@MainActor
package protocol ChatKeyTarget: AnyObject {
    // The session of the chat.
    var sessionId: String { get }
    // True while the input method has marked text in the chat.
    var isComposing: Bool { get }
    // A key down, a key up or a modifier key of the chat, after the Bifrost keys. dictationKey
    // is the physical key of the dictation key, or nil when the key is Off. True when the chat
    // input takes the event: the terminal must not get it.
    func chatKey(_ event: KeyEvent, dictationKey: KeyCode?) -> Bool
    // The chat got the key focus (true), or lost it (false): the first responder changed, or
    // the window became the key window or stopped being it. dictationKey is the physical key of
    // the dictation key, or nil when the key is Off: a focused chat warms the speech engine only
    // with a key.
    func chatFocus(_ focused: Bool, dictationKey: KeyCode?)
}

// The marks of the views that the focus zone needs and that no AppKit class tells. A view gets a
// mark as its identifier. A view inside a marked view has the mark too.
@MainActor
package enum FocusMark {
    // The send box of the Selected Item panel (phase 4).
    package static let sendBox = NSUserInterfaceItemIdentifier("bifrost.send-box")
    // The key recorder of Settings > Keys (phase 4). Bifrost keys pause while it records (C4).
    package static let keyRecorder = NSUserInterfaceItemIdentifier("bifrost.key-recorder")
    // A dialog, a menu or a list box inside the window.
    package static let modal = NSUserInterfaceItemIdentifier("bifrost.modal")
    // A host of SwiftUI controls, for example the side bar. Each part of it that takes the focus
    // is a control.
    package static let control = NSUserInterfaceItemIdentifier("bifrost.control")
    // The rows of an Overview: the prefix, then the panel ID of the Overview.
    package static let overviewRowsPrefix = "bifrost.overview-rows:"

    package static func overviewRows(_ panel: PanelID) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(overviewRowsPrefix + panel.text)
    }
}

// The focus of a first responder: the target of the key rules, the zone and the chat.
@MainActor
package struct KeyFocus {
    package var target: FocusTarget?
    package var chat: (any ChatKeyTarget)?
    // True while the input method has marked text in the first responder. A key of a
    // composition matches no binding.
    package var isComposing = false

    package var zone: FocusZone { FocusZone(target) }

    // The focus of the responder in the window.
    package init(_ responder: NSResponder?, in window: NSWindow?) {
        let modal = Self.dialogShows(for: window)
        guard let view = responder as? NSView else {
            target = modal ? FocusTarget(inModal: true) : nil
            return
        }
        var found = FocusTarget(inModal: modal)
        var control = view is NSControl
        var current: NSView? = view
        // The nearest marks win: the walk goes from the view up through its superviews.
        while let item = current {
            if chat == nil, let chatView = item as? any ChatKeyTarget {
                chat = chatView
                found.chatSession = chatView.sessionId
            }
            Self.read(item.identifier, into: &found)
            if item.identifier == FocusMark.control { control = true }
            if let role = item.accessibilityRole(), Self.controlRoles.contains(role) {
                control = true
            }
            current = item.superview
        }
        // A text view comes first, before the control roles.
        found.kind = view is NSText ? .text : control ? .control : .other
        // A view of another window (a popover or a sheet) is not in this window.
        if let other = view.window, let window, other !== window { found.inModal = true }
        target = found
        let client = view as? any NSTextInputClient
        isComposing = chat?.isComposing ?? client?.hasMarkedText() ?? false
    }

    // The accessibility roles of a control. A tab is a radio button of a tab group, and a switch
    // is a check box.
    private static let controlRoles: Set<NSAccessibility.Role> = [
        .button, .menuButton, .radioButton, .checkBox, .menuItem,
    ]

    // The modal window of the app. A test gives another window here, because a test never runs
    // a modal session: a modal session shows its window.
    static var appModalWindow: () -> NSWindow? = { NSApplication.shared.modalWindow }

    // A sheet of the window or an alert of the app shows.
    private static func dialogShows(for window: NSWindow?) -> Bool {
        window?.attachedSheet != nil || appModalWindow() != nil
    }

    private static func read(
        _ mark: NSUserInterfaceItemIdentifier?, into target: inout FocusTarget
    ) {
        guard let mark else { return }
        if mark == FocusMark.sendBox { target.inSendBox = true }
        if mark == FocusMark.keyRecorder { target.inKeyRecorder = true }
        if mark == FocusMark.modal { target.inModal = true }
        let prefix = FocusMark.overviewRowsPrefix
        if target.overviewRows == nil, mark.rawValue.hasPrefix(prefix) {
            target.overviewRows = String(mark.rawValue.dropFirst(prefix.count))
        }
    }
}
