// The focus zone (docs/behaviour/keys.md, "Where a shortcut can act") and the zones where the key
// of a slot acts. The window reads the zone from its first responder: the UI of the keyboard
// describes the first responder with a FocusTarget (FocusTargets.swift). Row K7 of docs/ports/keys
// gives the order of the checks.

// The place of the focus.
package enum FocusZone: Hashable, Sendable, CaseIterable {
    case chat, sendBox, text, control, modal, other

    // The zone of a target. No target is the other zone.
    package init(_ target: FocusTarget?) {
        guard let target else {
            self = .other
            return
        }
        if target.inModal || target.inKeyRecorder {
            self = .modal
        } else if target.chatSession != nil {
            self = .chat
        } else if target.inSendBox {
            self = .sendBox
        } else {
            switch target.kind {
            case .text: self = .text
            case .control: self = .control
            case .other: self = .other
            }
        }
    }
}

package struct FocusTarget: Sendable, Equatable {
    package enum Kind: Sendable, Equatable {
        // A view that takes text: a text view or the field editor of a text field.
        case text
        // A control: a button, a tab, a check box, a pop-up button or a segmented control.
        case control
        // Any other view, or the window itself.
        case other
    }

    // True inside a dialog, a sheet, a menu or a list box.
    package var inModal: Bool
    // True inside the key recorder of Settings > Keys. Bifrost keys pause while it records (C4).
    package var inKeyRecorder: Bool
    // The session ID of the chat terminal that holds the view, or nil outside a chat terminal.
    package var chatSession: String?
    // True inside the send box.
    package var inSendBox: Bool
    // The panel ID of the Overview whose rows hold the view, or nil. A dialog that opens from the
    // rows gives the focus back to them when it closes (phase 4).
    package var overviewRows: String?
    package var kind: Kind

    package init(
        kind: Kind = .other, inModal: Bool = false, inKeyRecorder: Bool = false,
        chatSession: String? = nil, inSendBox: Bool = false, overviewRows: String? = nil
    ) {
        self.kind = kind
        self.inModal = inModal
        self.inKeyRecorder = inKeyRecorder
        self.chatSession = chatSession
        self.inSendBox = inSendBox
        self.overviewRows = overviewRows
    }
}

// What a new focus changes, apart from the keys.
package struct FocusChange: Sendable, Equatable {
    // The session to select, or nil for no change.
    package var select: String?
    // True when the hold gate must forget all keys.
    package var clearGate: Bool

    package init(select: String?, clearGate: Bool) {
        self.select = select
        self.clearGate = clearGate
    }

    // A focus in a chat window selects its session. So the Selected Item panel shows that
    // session, and each session key acts on it (final review Important 1). Only a known session
    // that is not selected now changes the selection. A focus on the key recorder clears the
    // gate (final review Minor 4).
    package init(_ target: FocusTarget?, selectedId: String?, rows: [String]) {
        guard let target else {
            self.init(select: nil, clearGate: false)
            return
        }
        let sessionId = target.chatSession
        let known = sessionId.map { rows.contains($0) } ?? false
        self.init(
            select: known && sessionId != selectedId ? sessionId : nil,
            clearGate: target.inKeyRecorder)
    }
}

extension KeySlot {
    // The keys that a control keeps: Enter, Space and Tab (D27), and the keys that move in a tab
    // list, a radio group, a pop-up button or a menu.
    private static let controlKeys: Set<Chord.Key> = [
        .named(.enter), .named(.space), .named(.tab), .named(.arrowUp), .named(.arrowDown),
        .named(.arrowLeft), .named(.arrowRight), .named(.home), .named(.end),
    ]

    // True when the key of the slot may act while the focus is in this zone.
    package func acts(_ chord: Chord, in zone: FocusZone) -> Bool {
        if zone == .modal { return false }
        switch group {
        // The dictation key acts only in a chat window.
        case .dictation: return zone == .chat
        // A hold key acts only in the other zone.
        case .hold: return zone == .other
        case .always, .single: break
        }
        if chord.modifiers.contains(.command) { return true }
        if command == .escape { return zone == .other || zone == .control || zone == .sendBox }
        if chord.modifiers.contains(.control) { return zone != .chat }
        if zone == .other { return true }
        // Enter, Space, Tab, the arrow keys, Home and End stay with a control (D27).
        return zone == .control && !Self.controlKeys.contains(chord.key)
    }
}
