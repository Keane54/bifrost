import BifrostKeyboard
import Testing

// The key events of the tests of the key rules and of the chat input.

package struct Mods {
    package var shift = false
    package var alt = false
    package var ctrl = false
    package var meta = false
    package var isRepeat = false
    package var isComposing = false

    package init(
        shift: Bool = false, alt: Bool = false, ctrl: Bool = false, meta: Bool = false,
        isRepeat: Bool = false, isComposing: Bool = false
    ) {
        self.shift = shift
        self.alt = alt
        self.ctrl = ctrl
        self.meta = meta
        self.isRepeat = isRepeat
        self.isComposing = isComposing
    }

    package var modifiers: KeyEvent.Modifiers {
        var modifiers: KeyEvent.Modifiers = []
        if shift { modifiers.insert(.shift) }
        if ctrl { modifiers.insert(.control) }
        if alt { modifiers.insert(.option) }
        if meta { modifiers.insert(.command) }
        return modifiers
    }
}

// The edge of a key event of a test.
package enum Edge {
    case keydown, keyup
}

// The modifier key of each spelling of the tests.
private let modifierSpellings: [String: ModifierKey] = [
    "Shift": .shift, "Control": .control, "Alt": .option, "Meta": .command,
    "CapsLock": .capsLock, "Fn": .function,
]

// A key event of a US keyboard. The spelling is the text of the key (" " is the space bar, and a
// letter in either case is its letter key), the name of a named key of a binding ("Enter"), or a
// modifier key ("Shift", "Control", "Alt", "Meta", "CapsLock", "Fn"). "Process" is the space bar
// with no text, as a key of a composition gives it.
package func ev(_ edge: Edge, _ key: String, _ mods: Mods = Mods()) -> KeyEvent {
    var code = KeyCode(.space)
    var text = ""
    if key == " " {
        text = " "
    } else if let modifier = modifierSpellings[key] {
        code = KeyCode(modifier)
    } else if let name = KeyName(rawValue: key) {
        code = KeyCode(name)
    } else if let character = key.first, key.count == 1, let us = KeyCode(us: character) {
        code = us
        text = key
    } else if key != "Process" {
        Issue.record("no US key for \(key)")
    }
    return KeyEvent(
        keyCode: code, characters: text, modifiers: mods.modifiers, isDown: edge == .keydown,
        isRepeat: mods.isRepeat, isComposing: mods.isComposing)
}

// The slot of a stored ID. An ID that no slot has records an issue and gives the dictation slot.
package func keySlot(_ id: String, sourceLocation: SourceLocation = #_sourceLocation) -> KeySlot {
    guard let slot = KeySlot(id) else {
        Issue.record("no slot \(id)", sourceLocation: sourceLocation)
        return .dictation
    }
    return slot
}

// The chord of a binding text. A text that is not a binding records an issue and gives Space.
package func chord(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) -> Chord {
    guard let chord = Chord(text) else {
        Issue.record("no binding \(text)", sourceLocation: sourceLocation)
        return Chord(key: .named(.space))
    }
    return chord
}

// The key changes of stored IDs and binding texts. nil is Off. The changes are not checked, so
// a test can give a key that a slot refuses.
package func keyChanges(
    _ pairs: [String: String?], sourceLocation: SourceLocation = #_sourceLocation
) -> KeyChanges {
    KeyChanges(
        Dictionary(
            uniqueKeysWithValues: pairs.map { id, text in
                let slot = keySlot(id, sourceLocation: sourceLocation)
                let parsed = text.map { chord($0, sourceLocation: sourceLocation) }
                return (slot, parsed.map(KeyBinding.chord) ?? .off)
            }))
}
