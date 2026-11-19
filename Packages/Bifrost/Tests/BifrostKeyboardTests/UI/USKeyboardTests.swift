import AppKit
import BifrostTestSupport
import Testing

@testable import BifrostKeyboard

// The keys of the text of a type request of the debug test port: each printable ASCII
// character has a key of the US keyboard, and that key with its modifiers types the character.
@Suite("US keyboard", .tags(.window))
@MainActor
struct USKeyboardTests {
    @Test func eachPrintableASCIICharacterHasAKeyThatTypesIt() throws {
        for value in 0x20...0x7e {
            let character = Character(try #require(Unicode.Scalar(value)))
            let stroke = try #require(USKeyboard.keystroke(for: character), "\(value)")
            #expect(USKeyboard.keyCodes[stroke.id] != nil, "\(value)")
            #expect(stroke.mods.isSubset(of: [.shift]), "\(value)")
            #expect(USKeyboard.characters(stroke.id, stroke.mods).0 == String(character))
        }
        #expect(USKeyboard.keystroke(for: "a")?.mods == [])
        #expect(USKeyboard.keystroke(for: "A")?.mods == [.shift])
        #expect(USKeyboard.keystroke(for: " ")?.id == "Space")
    }

    // A character that a US keyboard does not type with Shift alone has no key.
    @Test func anotherCharacterHasNoKey() {
        for character: Character in ["é", "\n", "\u{1b}", "\t", "😀", "\u{7f}"] {
            #expect(USKeyboard.keystroke(for: character) == nil)
        }
    }
}
