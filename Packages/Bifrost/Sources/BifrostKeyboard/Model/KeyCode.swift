// The keys of a Mac keyboard. A key code is the virtual key code of an NSEvent (the kVK_
// constants of Carbon). It names a place on the keyboard, not the character that the layout types
// there. This file has the one table of the keys:
// - the named keys of a binding (KeyName), for example Enter and the arrow keys;
// - the modifier keys (ModifierKey);
// - the character of each key on a US keyboard. A binding names a letter, a digit or a punctuation
//   mark of a US keyboard. The key rules use the place of the key when the typed character cannot
//   name a shortcut (Match.swift), and the hold keys use the place of a letter or a digit.

package struct KeyCode: RawRepresentable, Hashable, Sendable {
    package let rawValue: UInt16

    package init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    // The key of a named key. Enter is the Return key, not the Enter key of the keypad.
    package init(_ name: KeyName) {
        rawValue = name.keyCode
    }

    // The left key of a modifier.
    package init(_ modifier: ModifierKey) {
        rawValue = modifier.keyCode
    }

    // The key that types this character on a US keyboard with no modifier: a letter (in either
    // case), a digit of the digit row or a punctuation mark. Else nil.
    package init?(us character: Character) {
        let upper = character.isASCII ? Character(character.uppercased()) : character
        guard let code = keyCodeOfCharacter[upper] else { return nil }
        rawValue = code
    }

    // The named key, or nil. The Enter key of the keypad is Enter too.
    package var name: KeyName? {
        keyNameOfCode[rawValue]
    }

    // The modifier of a modifier key, or nil for another key.
    package var modifierKey: ModifierKey? {
        switch rawValue {
        case 54, 55: .command
        case 56, 60: .shift
        case 58, 61: .option
        case 59, 62: .control
        case 57: .capsLock
        case 63: .function
        default: nil
        }
    }

    // The character of the key on a US keyboard: an upper-case letter, a digit of the digit row
    // or a punctuation mark. Nil for the other keys, for example the keypad and the named keys.
    package var usCharacter: Character? {
        usCharacters[rawValue]
    }

    // True for a letter key.
    var isLetter: Bool {
        usCharacter?.isLetter == true
    }

    // True for a key of the digit row. The digits of the keypad are not in the row.
    var isDigitRow: Bool {
        usCharacter?.isNumber == true
    }

    // The key at this place on a US keyboard, for the match by position: the US character, or
    // the digit or the symbol of a key of the keypad.
    var positionKey: String? {
        usCharacter.map(String.init) ?? keypadKeys[rawValue]
    }
}

// The named keys of a binding. The raw value is the name in the binding text, for example
// "ArrowUp" in "Mod+ArrowUp".
package enum KeyName: String, Sendable, CaseIterable {
    case arrowUp = "ArrowUp", arrowDown = "ArrowDown", arrowLeft = "ArrowLeft"
    case arrowRight = "ArrowRight", enter = "Enter", escape = "Escape", tab = "Tab"
    case backspace = "Backspace", delete = "Delete", space = "Space", home = "Home", end = "End"
    case pageUp = "PageUp", pageDown = "PageDown"
    case f1 = "F1", f2 = "F2", f3 = "F3", f4 = "F4", f5 = "F5", f6 = "F6", f7 = "F7", f8 = "F8"
    case f9 = "F9", f10 = "F10", f11 = "F11", f12 = "F12"

    fileprivate var keyCode: UInt16 {
        switch self {
        case .arrowUp: 126
        case .arrowDown: 125
        case .arrowLeft: 123
        case .arrowRight: 124
        case .enter: 36
        case .escape: 53
        case .tab: 48
        case .backspace: 51
        case .delete: 117
        case .space: 49
        case .home: 115
        case .end: 119
        case .pageUp: 116
        case .pageDown: 121
        case .f1: 122
        case .f2: 120
        case .f3: 99
        case .f4: 118
        case .f5: 96
        case .f6: 97
        case .f7: 98
        case .f8: 100
        case .f9: 101
        case .f10: 109
        case .f11: 103
        case .f12: 111
        }
    }
}

// The modifier keys. A flags-changed event names one of them.
package enum ModifierKey: Sendable, CaseIterable {
    case command, shift, option, control, capsLock, function

    // The modifier of a binding that the key holds down. Caps Lock and fn are not modifiers of
    // a binding.
    package var flag: KeyEvent.Modifiers? {
        switch self {
        case .command: .command
        case .shift: .shift
        case .option: .option
        case .control: .control
        case .capsLock, .function: nil
        }
    }

    fileprivate var keyCode: UInt16 {
        switch self {
        case .command: 55
        case .shift: 56
        case .option: 58
        case .control: 59
        case .capsLock: 57
        case .function: 63
        }
    }
}

// The character of each key of a US keyboard that types one with no modifier.
private let usCharacters: [UInt16: Character] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
    12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4",
    22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
    32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
    43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
]

// The inverse of usCharacters. Each character is on one key only.
private let keyCodeOfCharacter: [Character: UInt16] = Dictionary(
    uniqueKeysWithValues: usCharacters.map { ($0.value, $0.key) })

// The digits and the symbols of the keypad. The Enter key of the keypad is a named key, and the
// keypad equal sign has no place in the match.
private let keypadKeys: [UInt16: String] = [
    65: ".", 67: "*", 69: "+", 75: "/", 78: "-", 82: "0", 83: "1", 84: "2", 85: "3", 86: "4",
    87: "5", 88: "6", 89: "7", 91: "8", 92: "9",
]

private let keyNameOfCode: [UInt16: KeyName] = {
    var map = Dictionary(uniqueKeysWithValues: KeyName.allCases.map { ($0.keyCode, $0) })
    map[76] = .enter
    return map
}()
