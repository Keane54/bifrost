// A chord: a key and its modifiers. The settings file keeps a chord as a binding text with Mod in
// place of Cmd, for example "Mod+Shift+M". The app parses the text once, at the settings edge, and
// keeps the chord after that. text gives the stored form back. The behaviour list is in
// docs/behaviour/keys.md.

package struct Chord: Hashable, Sendable, CustomStringConvertible {
    // The key of a chord: a named key, or the character of a letter, a digit or a punctuation key
    // of a US keyboard. A letter is upper case.
    package enum Key: Hashable, Sendable {
        case named(KeyName)
        case character(Character)
    }

    package var modifiers: KeyEvent.Modifiers
    package var key: Key

    package init(_ modifiers: KeyEvent.Modifiers = [], key: Key) {
        self.modifiers = modifiers
        self.key = key
    }

    // Read a binding text. The parts have the separator "+": the modifiers in any order and in
    // any case (Mod, Cmd, Command and Meta are Command), and one key. Give nil when the text is
    // not a binding: no key, two keys, a modifier two times or an unknown part.
    package init?(_ text: String) {
        var modifiers: KeyEvent.Modifiers = []
        var key: Key?
        for part in text.split(separator: "+", omittingEmptySubsequences: false) {
            if let modifier = Self.modifierNames[asciiLowercased(part)] {
                guard !modifiers.contains(modifier) else { return nil }
                modifiers.insert(modifier)
                continue
            }
            guard key == nil, let parsed = Key(part) else { return nil }
            key = parsed
        }
        guard let key else { return nil }
        self.init(modifiers, key: key)
    }

    // The chord of a key event as the key rules read it, for the key recorder. The chord has the
    // modifiers of the event, and its key comes from the first rule that applies:
    // - A named key gives its name. So the space bar gives Space, and the Enter key of the keypad
    //   gives Enter.
    // - The typed key, when it is a letter, a digit or a punctuation mark of a binding and the
    //   chord of that key matches the event by its key, not only by position. The chord has the
    //   modifiers of the event, so the match is direct, or for a digit or a punctuation mark the
    //   score of an implicit Shift (Match.swift gives that score to such a key with no Shift in
    //   the chord). So Cmd+Z on a QWERTZ keyboard gives Mod+Z, and Cmd+A on an AZERTY keyboard
    //   gives Mod+A.
    // - The key of a US keyboard at the place of the key (init(placeOf:)), when the match by
    //   position reads the event as that key. So Option+O gives Alt+O, Shift+1 gives Shift+1, and
    //   a dead key or a letter of another script gives the US key at its place.
    // A modifier key alone, a key with no name and no US character (a keypad digit, F13, the key
    // left of 1 on an ISO keyboard) and a key that no chord matches give nil. So each chord of
    // this init matches its key event.
    package init?(event: KeyEvent) {
        guard let place = Chord(placeOf: event) else { return nil }
        if case .named = place.key {
            self = place
            return
        }
        if case .text(let text) = event.key, text.count == 1, let typed = Key(Substring(text)) {
            let chord = Chord(event.modifiers, key: typed)
            if let score = chord.match(event), score > .position {
                self = chord
                return
            }
        }
        guard place.match(event) != nil else { return nil }
        self = place
    }

    // The chord of the place of a key: the modifiers of the event, and the name of the key or
    // the character of a US keyboard at its place. The chat input reads the dictation key by its
    // place, so the key recorder of the dictation slot uses this chord. A modifier key alone and
    // a key with no name and no US character give nil.
    package init?(placeOf event: KeyEvent) {
        if let name = event.keyCode.name {
            self.init(event.modifiers, key: .named(name))
        } else if let character = event.keyCode.usCharacter {
            self.init(event.modifiers, key: .character(character))
        } else {
            return nil
        }
    }

    // The stored form, in the standard order: Mod, Control, Alt, Shift, then the key.
    package var text: String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("Mod") }
        if modifiers.contains(.control) { parts.append("Control") }
        if modifiers.contains(.option) { parts.append("Alt") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        parts.append(key.name)
        return parts.joined(separator: "+")
    }

    package var description: String { text }

    package var isPlain: Bool { modifiers.isEmpty }

    // The key of a chord with no modifier, for the dictation key: the space bar, or the key of a
    // US keyboard that types the character. Else nil.
    package var physicalKey: KeyCode? {
        guard isPlain else { return nil }
        switch key {
        case .named(.space): return KeyCode(.space)
        case .named: return nil
        case .character(let character): return KeyCode(us: character)
        }
    }

    // The key text of the key equivalent of a menu item. A letter is lower case, and Shift is a
    // flag of the item. A named key has the character that AppKit uses for it.
    package var keyEquivalent: String {
        switch key {
        case .named(let name): name.keyEquivalent
        case .character(let character): character.lowercased()
        }
    }

    private static let modifierNames: [String: KeyEvent.Modifiers] = [
        "alt": .option, "cmd": .command, "command": .command, "control": .control,
        "ctrl": .control, "meta": .command, "mod": .command, "option": .option, "shift": .shift,
    ]
}

extension Chord.Key {
    // The punctuation keys of a binding.
    package static let punctuation: Set<Character> = [
        "/", ".", ",", "[", "]", ";", "'", "`", "-", "=", "\\",
    ]

    // The key of one part of a binding text, or nil. A named key has any case and some other
    // names (Esc, Return, Up, Down, Left, Right). A letter, a digit and a punctuation mark are one
    // ASCII character.
    fileprivate init?(_ part: Substring) {
        if part.count == 1, let character = part.first {
            guard character.isASCII else { return nil }
            if character.isLetter {
                self = .character(Character(character.uppercased()))
            } else if character.isNumber || Self.punctuation.contains(character) {
                self = .character(character)
            } else {
                return nil
            }
            return
        }
        guard let name = Self.names[asciiLowercased(part)] else { return nil }
        self = .named(name)
    }

    // The name of the key in a binding text, for example "ArrowUp" or "M".
    package var name: String {
        switch self {
        case .named(let name): name.rawValue
        case .character(let character): String(character)
        }
    }

    // True for a key that types a character when it is not held: Space, a letter, a digit or a
    // punctuation key. The dictation key must be one.
    package var typesCharacter: Bool {
        switch self {
        case .named(let name): name == .space
        case .character: true
        }
    }

    // True for a letter or a digit. A hold key must be one.
    package var isLetterOrDigit: Bool {
        guard case .character(let character) = self else { return false }
        return character.isLetter || character.isNumber
    }

    // The named keys by their lower-case name, with their other names.
    private static let names: [String: KeyName] = {
        var map = Dictionary(
            uniqueKeysWithValues: KeyName.allCases.map { ($0.rawValue.lowercased(), $0) })
        map["esc"] = .escape
        map["return"] = .enter
        map["up"] = .arrowUp
        map["down"] = .arrowDown
        map["left"] = .arrowLeft
        map["right"] = .arrowRight
        return map
    }()
}

extension KeyName {
    // The key text of a key equivalent. The arrow keys, Delete, Home, End, the page keys and the
    // function keys use the function key characters of AppKit (U+F700 and up). Backspace is the
    // backspace character (U+0008).
    fileprivate var keyEquivalent: String {
        switch self {
        case .arrowUp: "\u{F700}"
        case .arrowDown: "\u{F701}"
        case .arrowLeft: "\u{F702}"
        case .arrowRight: "\u{F703}"
        case .enter: "\r"
        case .escape: "\u{1B}"
        case .tab: "\t"
        case .backspace: "\u{8}"
        case .delete: "\u{F728}"
        case .space: " "
        case .home: "\u{F729}"
        case .end: "\u{F72B}"
        case .pageUp: "\u{F72C}"
        case .pageDown: "\u{F72D}"
        case .f1: "\u{F704}"
        case .f2: "\u{F705}"
        case .f3: "\u{F706}"
        case .f4: "\u{F707}"
        case .f5: "\u{F708}"
        case .f6: "\u{F709}"
        case .f7: "\u{F70A}"
        case .f8: "\u{F70B}"
        case .f9: "\u{F70C}"
        case .f10: "\u{F70D}"
        case .f11: "\u{F70E}"
        case .f12: "\u{F70F}"
        }
    }
}

// The lower case of a part of a binding text. Only an ASCII part can be a name, so another part
// gives an empty text, which is no name.
private func asciiLowercased(_ part: Substring) -> String {
    part.allSatisfy(\.isASCII) ? part.lowercased() : ""
}
