// Make the NSEvents of a US keyboard, as AppKit gives them. The key scenarios of the window key
// filter and the debug test port use them.
//
// Only a Debug build has this code (#if DEBUG), as the test port that types with it. The tests
// build in Debug.
#if DEBUG
import AppKit

@MainActor
public enum USKeyboard {
    // A modifier key that is down. The raw values are the names of the scenarios.
    @MainActor
    public enum Mod: String, Codable, Sendable, CaseIterable {
        case shift, ctrl, alt, meta
    }

    // The macOS virtual key code of each key ID (the kVK_ constants of Carbon).
    package static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
        "u": 32, "[": 33, "i": 34, "p": 35, "Enter": 36, "l": 37, "j": 38, "'": 39, "k": 40,
        ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "Tab": 48, "Space": 49,
        "`": 50, "Backspace": 51, "Escape": 53, "Meta": 55, "Shift": 56, "Alt": 58, "Control": 59,
        "F5": 96, "F6": 97, "F7": 98, "F3": 99, "F8": 100, "F9": 101, "F11": 103, "F10": 109,
        "F12": 111, "Home": 115, "PageUp": 116, "Delete": 117, "F4": 118, "End": 119, "F2": 120,
        "PageDown": 121, "F1": 122, "ArrowLeft": 123, "ArrowRight": 124, "ArrowDown": 125,
        "ArrowUp": 126,
    ]

    // The modifier of each modifier key ID.
    package static let modifierOf: [String: Mod] = [
        "Shift": .shift, "Control": .ctrl, "Alt": .alt, "Meta": .meta,
    ]

    private static let shifted: [String: String] = [
        "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(",
        "0": ")", "/": "?", ".": ">", ",": "<", "[": "{", "]": "}", ";": ":", "'": "\"", "`": "~",
        "-": "_", "=": "+", "\\": "|",
    ]

    // Option+key. An empty text is a dead key.
    private static let option: [String: String] = [
        "a": "å", "b": "∫", "c": "ç", "d": "∂", "e": "", "f": "ƒ", "g": "©", "h": "˙",
        "i": "", "j": "∆", "k": "˚", "l": "¬", "m": "µ", "n": "", "o": "ø", "p": "π",
        "q": "œ", "r": "®", "s": "ß", "t": "†", "u": "", "v": "√", "w": "∑", "x": "≈",
        "y": "¥", "z": "Ω", "1": "¡", "2": "™", "3": "£", "4": "¢", "5": "∞", "6": "§",
        "7": "¶", "8": "•", "9": "ª", "0": "º", "/": "÷", ".": "≥", ",": "≤", "[": "“",
        "]": "‘", ";": "…", "'": "æ", "`": "", "-": "–", "=": "≠", "\\": "«",
    ]

    private static let optionShift: [String: String] = ["o": "Ø", "a": "Å", "s": "Í", "m": "Â"]

    private static func function(_ value: Int) -> String {
        guard let scalar = Unicode.Scalar(value) else { return "" }
        return String(Character(scalar))
    }

    // The text of the named keys (NSEvent function key constants).
    private static let named: [String: String] = [
        "Enter": "\r", "Escape": "\u{1b}", "Tab": "\t", "Backspace": "\u{7f}", "Space": " ",
        "ArrowUp": function(0xF700), "ArrowDown": function(0xF701),
        "ArrowLeft": function(0xF702), "ArrowRight": function(0xF703),
        "Delete": function(0xF728), "Home": function(0xF729), "End": function(0xF72B),
        "PageUp": function(0xF72C), "PageDown": function(0xF72D),
        "F1": function(0xF704), "F2": function(0xF705), "F3": function(0xF706),
        "F4": function(0xF707), "F5": function(0xF708), "F6": function(0xF709),
        "F7": function(0xF70A), "F8": function(0xF70B), "F9": function(0xF70C),
        "F10": function(0xF70D), "F11": function(0xF70E), "F12": function(0xF70F),
    ]

    private static let arrows: Set<String> = ["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"]
    private static let functionKeys: Set<String> = ["Home", "End", "PageUp", "PageDown", "Delete"]

    // The modifier flags of the held modifiers. The arrow keys add the numeric pad and function
    // flags, and the other function keys add the function flag, as AppKit gives them.
    package static func flags(_ mods: Set<Mod>, key: String? = nil) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if mods.contains(.shift) { flags.insert(.shift) }
        if mods.contains(.ctrl) { flags.insert(.control) }
        if mods.contains(.alt) { flags.insert(.option) }
        if mods.contains(.meta) { flags.insert(.command) }
        if let key {
            if arrows.contains(key) { flags.formUnion([.numericPad, .function]) }
            if key.hasPrefix("F") && key.count > 1 || functionKeys.contains(key) {
                flags.insert(.function)
            }
        }
        return flags
    }

    // The characters and the characters without modifiers (Shift applies) of a key.
    package static func characters(_ id: String, _ mods: Set<Mod>) -> (String, String) {
        let shift = mods.contains(.shift)
        if let text = named[id] {
            if id == "Tab" && shift { return ("\u{19}", "\u{19}") }
            return (text, text)
        }
        let isLetter = id.count == 1 && id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) }
        let plain = isLetter ? (shift ? id.uppercased() : id) : (shift ? shifted[id] ?? id : id)
        if mods.contains(.ctrl), isLetter, let scalar = id.unicodeScalars.first,
            let control = Unicode.Scalar(scalar.value & 0x1F)
        {
            return (String(Character(control)), plain)
        }
        if mods.contains(.alt) && !mods.contains(.ctrl) {
            if shift, let text = optionShift[id] { return (text, plain) }
            if let text = option[id] { return (text, plain) }
        }
        return (plain, plain)
    }

    // The key ID and the modifiers that type a printable ASCII character (the space to the
    // tilde) on a US keyboard, or nil for another character. The test port types its text with
    // them.
    public static func keystroke(for character: Character) -> (id: String, mods: Set<Mod>)? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
            (0x20...0x7e).contains(scalar.value)
        else { return nil }
        let text = String(character)
        if text == " " { return ("Space", []) }
        if keyCodes[text] != nil { return (text, []) }
        let lower = text.lowercased()
        if lower != text, keyCodes[lower] != nil { return (lower, [.shift]) }
        // A shifted symbol: the key whose Shift character it is.
        let key = shifted.first { $0.value == text }?.key
        return key.map { ($0, [.shift]) }
    }

    // A key down or a key up of a key that is not a modifier, or nil for an unknown key ID.
    public static func keyEvent(
        down: Bool, id: String, mods: Set<Mod>, isRepeat: Bool, window: NSWindow
    ) -> NSEvent? {
        guard let keyCode = keyCodes[id] else { return nil }
        let (chars, ignoring) = characters(id, mods)
        return NSEvent.keyEvent(
            with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: flags(mods, key: id),
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: chars, charactersIgnoringModifiers: ignoring,
            isARepeat: isRepeat, keyCode: keyCode)
    }

    // The flags-changed event of a modifier key. mods is the set of held modifiers after the
    // change.
    public static func modifierEvent(id: String, mods: Set<Mod>, window: NSWindow) -> NSEvent? {
        guard let keyCode = keyCodes[id] else { return nil }
        return NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: flags(mods),
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
            keyCode: keyCode)
    }
}
#endif
