// The Esc rule (user decision, 2026-11-06).
//
// In the send box, Esc leaves the send box. Else it closes Settings when Settings is the active
// panel of the top frame. Else it opens Settings and brings it to the front. Esc does nothing
// when another handler took it, for example a popover or a drag. A chat window, a text field, a
// dialog, a menu and the key recorder keep their own Esc. Esc never clears the selection. A key
// repeat of a held Esc does not toggle Settings again.

package enum EscapeIntent: Sendable, Equatable {
    case none
    case leaveSendBox
    case openSettings
    case closeSettings

    package init(
        zone: FocusZone, escapeHandled: Bool = false, isRepeat: Bool = false, settingsOnTop: Bool
    ) {
        if zone == .sendBox {
            self = .leaveSendBox
        } else if escapeHandled || isRepeat || (zone != .other && zone != .control) {
            self = .none
        } else {
            self = settingsOnTop ? .closeSettings : .openSettings
        }
    }
}
