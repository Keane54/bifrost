// The pure key rules of the chat input: the dictation key and the modifier keys. The chat input
// itself (the hold key and its timer) is ChatInput, with its tests in ChatInputTests.swift. The
// text rules are in PTYTextTests.swift.
import BifrostKeyboard
import BifrostTestSupport
import Testing

@testable import BifrostDictation

// The modifier rule of the chat input for a spelling of ev.
private func isModifierKey(_ key: String) -> Bool {
    ev(.keydown, key).isModifierKey
}

// The key code of the space bar, the default dictation key.
private let space: KeyCode? = KeyCode(.space)

@Suite("the dictation key")
struct DictationKeyTests {
    // The dictation key with no modifier, outside a composition, starts a hold. The key with a
    // modifier, a key of a composition, another key and a key that types no character are
    // normal keys. With the key Off (no code), no key starts a hold.
    @Test(
        arguments: [
            (ev(.keydown, " "), space, true), (ev(.keydown, "/"), KeyCode(us: "/"), true),
            (ev(.keydown, " ", Mods(shift: true)), space, false),
            (ev(.keydown, " ", Mods(alt: true)), space, false),
            (ev(.keydown, " ", Mods(ctrl: true)), space, false),
            (ev(.keydown, " ", Mods(meta: true)), space, false),
            (ev(.keydown, " ", Mods(isComposing: true)), space, false),
            (ev(.keydown, "Process", Mods(isComposing: true)), space, false),
            (ev(.keydown, "a"), space, false), (ev(.keydown, " "), nil, false),
            (KeyEvent(keyCode: KeyCode(.space)), space, false),
        ])
    func onlyThePlainDictationKeyStartsAHold(_ event: KeyEvent, _ code: KeyCode?, _ starts: Bool) {
        #expect(event.isDictationKey(code: code) == starts)
    }
}

@Suite("modifier keys")
struct ModifierKeyTests {
    @Test("keys that type nothing alone are modifier keys")
    func modifiers() {
        for key in ["Shift", "Control", "Alt", "Meta", "CapsLock", "Fn"] {
            #expect(isModifierKey(key))
        }
        for key in [" ", "a", "Enter", "Backspace"] { #expect(!isModifierKey(key)) }
    }
}
