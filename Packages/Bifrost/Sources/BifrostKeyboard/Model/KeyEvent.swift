// A key down or a key up, in the values of an AppKit NSEvent: the key code, the two texts, the
// modifier flags and the edge. The window filter makes it from the NSEvent (KeyEvents.swift in the
// UI of the keyboard). This file does not import AppKit, so the key rules stay pure, and the tests
// make events with no window.
package struct KeyEvent: Sendable, Equatable {
    // The modifiers that a binding can name. Caps Lock and fn are not modifiers of a binding.
    package struct Modifiers: OptionSet, Sendable, Hashable {
        package let rawValue: UInt8

        package init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        package static let shift = Modifiers(rawValue: 1 << 0)
        package static let control = Modifiers(rawValue: 1 << 1)
        package static let option = Modifiers(rawValue: 1 << 2)
        package static let command = Modifiers(rawValue: 1 << 3)
    }

    // The key of an event, as the key rules read it.
    package enum Key: Hashable, Sendable {
        // A key with a name in a binding, for example Enter or an arrow key.
        case named(KeyName)
        // A modifier key alone: a flags-changed event.
        case modifier(ModifierKey)
        // A dead key: it types nothing alone, for example Option+E.
        case dead
        // The text that the key types.
        case text(String)
    }

    package var keyCode: KeyCode
    // The text of the key with its modifiers (NSEvent.characters).
    package var characters: String
    // The text of the key with no modifier except Shift (NSEvent.charactersIgnoringModifiers).
    package var charactersIgnoringModifiers: String
    package var modifiers: Modifiers
    // True for a key down, false for a key up.
    package var isDown: Bool
    package var isRepeat: Bool
    // True while an input method composes text: the first responder has marked text. Each key of
    // a composition has it, so the chat rules see the composition.
    package var isComposing: Bool

    // With no charactersIgnoringModifiers, the event uses the characters for both texts.
    package init(
        keyCode: KeyCode, characters: String = "", charactersIgnoringModifiers: String? = nil,
        modifiers: Modifiers = [], isDown: Bool = true, isRepeat: Bool = false,
        isComposing: Bool = false
    ) {
        self.keyCode = keyCode
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers ?? characters
        self.modifiers = modifiers
        self.isDown = isDown
        self.isRepeat = isRepeat
        self.isComposing = isComposing
    }

    // The key of the event:
    // - A modifier key and a named key give their key. Their text does not change it.
    // - A key with no text is a dead key, for example Option+E.
    // - With Control or Command, the key is the text with no modifier except Shift. Control+C
    //   gives "c", and Command+Shift+M gives "M". So a control character or an Option character
    //   does not hide the key of a shortcut.
    // - Else the key is the typed text, with Shift and Option.
    package var key: Key {
        if let modifier = keyCode.modifierKey { return .modifier(modifier) }
        if let name = keyCode.name { return .named(name) }
        if characters.isEmpty { return .dead }
        if !modifiers.isDisjoint(with: [.command, .control]), !charactersIgnoringModifiers.isEmpty {
            return .text(charactersIgnoringModifiers)
        }
        return .text(characters)
    }
}
