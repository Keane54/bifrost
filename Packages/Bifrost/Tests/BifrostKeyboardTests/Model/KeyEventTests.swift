// The typed key event and the key code tables. The window filter makes each KeyEvent from the
// values of an NSEvent. The UI package tests that edge with real NSEvents (KeyEventsTests).
import Testing

@testable import BifrostKeyboard

@Suite("The key codes of a Mac keyboard")
struct KeyCodeTests {
    // The kVK_ constants of Carbon for the keys that type a character on a US keyboard.
    @Test(
        "a US character has its key code and the key code gives the character back",
        arguments: [
            ("A", 0), ("S", 1), ("Z", 6), ("C", 8), ("Q", 12), ("O", 31), ("I", 34), ("K", 40),
            ("M", 46), ("1", 18), ("5", 23), ("6", 22), ("0", 29), ("=", 24), ("-", 27),
            ("]", 30), ("[", 33), ("'", 39), (";", 41), ("\\", 42), (",", 43), ("/", 44),
            (".", 47), ("`", 50),
        ] as [(Character, UInt16)])
    func usCharacter(_ character: Character, _ code: UInt16) {
        #expect(KeyCode(us: character) == KeyCode(rawValue: code))
        #expect(KeyCode(rawValue: code).usCharacter == character)
    }

    @Test("a letter has one key for both cases, and other characters have no US key")
    func otherCharacters() {
        #expect(KeyCode(us: "o") == KeyCode(us: "O"))
        for character: Character in [" ", "!", "?", "ø", "ß", "ı", "\r"] {
            #expect(KeyCode(us: character) == nil, "\(character)")
        }
    }

    @Test("the US keyboard has each letter, digit and punctuation key of a binding")
    func fullTable() {
        let characters = Set((0...127).compactMap { KeyCode(rawValue: $0).usCharacter })
        for letter in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" { #expect(characters.contains(letter)) }
        for digit in "0123456789" { #expect(characters.contains(digit)) }
        for mark in Chord.Key.punctuation { #expect(characters.contains(mark)) }
        #expect(characters.count == 26 + 10 + Chord.Key.punctuation.count)
    }

    @Test(
        "a named key has its key code, and both Enter keys are Enter",
        arguments: [
            (KeyName.enter, 36), (.tab, 48), (.space, 49), (.backspace, 51), (.escape, 53),
            (.delete, 117), (.home, 115), (.end, 119), (.pageUp, 116), (.pageDown, 121),
            (.arrowLeft, 123), (.arrowRight, 124), (.arrowDown, 125), (.arrowUp, 126),
            (.f1, 122), (.f2, 120), (.f3, 99), (.f4, 118), (.f5, 96), (.f6, 97), (.f7, 98),
            (.f8, 100), (.f9, 101), (.f10, 109), (.f11, 103), (.f12, 111),
        ] as [(KeyName, UInt16)])
    func named(_ name: KeyName, _ code: UInt16) {
        #expect(KeyCode(name) == KeyCode(rawValue: code))
        #expect(KeyCode(rawValue: code).name == name)
    }

    @Test("the Enter key of the keypad is Enter, and F13 and the keypad digits have no name")
    func otherNames() {
        #expect(KeyCode(rawValue: 76).name == .enter)
        #expect(KeyName.allCases.count == 26)
        for code: UInt16 in [105, 82, 87, 10, 114, 71] {
            #expect(KeyCode(rawValue: code).name == nil, "\(code)")
        }
    }

    @Test(
        "each modifier key has its modifier, on the left and on the right",
        arguments: [
            (55, ModifierKey.command), (54, .command), (56, .shift), (60, .shift),
            (58, .option), (61, .option), (59, .control), (62, .control), (57, .capsLock),
            (63, .function),
        ] as [(UInt16, ModifierKey)])
    func modifierKeys(_ code: UInt16, _ key: ModifierKey) {
        #expect(KeyCode(rawValue: code).modifierKey == key)
        #expect(KeyCode(key).modifierKey == key)
    }

    @Test("Caps Lock and fn are not a modifier of a binding")
    func modifierFlags() {
        #expect(ModifierKey.command.flag == .command)
        #expect(ModifierKey.shift.flag == .shift)
        #expect(ModifierKey.option.flag == .option)
        #expect(ModifierKey.control.flag == .control)
        #expect(ModifierKey.capsLock.flag == nil)
        #expect(ModifierKey.function.flag == nil)
        #expect(KeyCode(us: "A")?.modifierKey == nil)
    }

    @Test(
        "a plain Space, letter, digit or punctuation binding has a physical key",
        arguments: [
            ("Space", 49), ("space", 49), ("O", 31), ("k", 40), ("1", 18), ("0", 29), ("/", 44),
            (".", 47), (",", 43), ("[", 33), ("]", 30), ("\\", 42), ("`", 50), ("'", 39),
            (";", 41), ("-", 27), ("=", 24),
        ] as [(String, UInt16)])
    func physical(_ binding: String, _ code: UInt16) {
        #expect(Chord(binding)?.physicalKey == KeyCode(rawValue: code))
    }

    @Test(
        "a modifier, a named key or bad text has no physical key",
        arguments: ["Mod+N", "Shift+O", "Shift+K", "Enter", "Tab", "ArrowUp", "F5", "bad", ""])
    func noPhysical(_ binding: String) {
        #expect(Chord(binding)?.physicalKey == nil)
    }
}

// The key recorder makes a chord from a key event, as the key rules read the key: the typed key
// when it names a key of a binding and matches directly, else the US key at its place.
@Suite("The chord of a key event")
struct ChordOfEventTests {
    @Test(
        "a key event gives the chord that the key rules read",
        arguments: [
            (46, "M", [.command, .shift], "Mod+Shift+M"), (31, "ø", .option, "Alt+O"),
            (18, "!", .shift, "Shift+1"), (14, "", .option, "Alt+E"),
            (33, "[", .command, "Mod+["), (44, "?", [.command, .shift], "Mod+Shift+/"),
            (49, " ", [], "Space"), (76, "\u{3}", .command, "Mod+Enter"), (96, "", [], "F5"),
            (0, "q", .control, "Control+Q"),
        ] as [(UInt16, String, KeyEvent.Modifiers, String)])
    func chord(_ code: UInt16, _ text: String, _ modifiers: KeyEvent.Modifiers, _ binding: String) {
        let event = KeyEvent(
            keyCode: KeyCode(rawValue: code), characters: text, modifiers: modifiers)
        let chord = Chord(event: event)
        #expect(chord?.text == binding)
        // The chord is in the standard form, so its text gives the same chord.
        #expect(chord.flatMap { Chord($0.text) } == chord)
    }

    // A modifier key alone, a digit of the keypad, F13 and the key left of 1 on an ISO keyboard.
    @Test(
        "a key that cannot be a chord gives no chord", arguments: [55, 56, 87, 105, 10] as [UInt16])
    func noChord(_ code: UInt16) {
        #expect(Chord(event: KeyEvent(keyCode: KeyCode(rawValue: code), characters: "5")) == nil)
    }

    // Key events of five layouts: the key code, the typed text, the text with no modifier but
    // Shift, the modifiers, and the chord of the key.
    static let layoutSamples: [(UInt16, String, String, KeyEvent.Modifiers, String)] = [
        // US
        (0, "a", "a", [], "A"), (0, "a", "a", .command, "Mod+A"),
        (0, "A", "A", [.command, .shift], "Mod+Shift+A"), (31, "ø", "o", .option, "Alt+O"),
        (18, "!", "!", .shift, "Shift+1"), (24, "+", "+", [.command, .shift], "Mod+Shift+="),
        (8, "\u{3}", "c", .control, "Control+C"), (14, "", "e", .option, "Alt+E"),
        (14, "", "e", [.option, .command], "Mod+Alt+E"), (47, ".", ".", .command, "Mod+."),
        (50, "`", "`", [], "`"),
        // AZERTY: A is at the place of the US Q, the digits need Shift.
        (12, "a", "a", .command, "Mod+A"), (0, "q", "q", .control, "Control+Q"),
        (13, "z", "z", [], "Z"), (41, "m", "m", .command, "Mod+M"),
        (46, ",", ",", .command, "Mod+,"),
        (18, "&", "&", [], "1"), (18, "1", "1", .shift, "Shift+1"), (19, "é", "é", [], "2"),
        (19, "é", "é", .command, "Mod+2"),
        // QWERTZ: Z and Y change places.
        (16, "z", "z", .command, "Mod+Z"), (6, "y", "y", .command, "Mod+Y"),
        (16, "Z", "Z", [.command, .shift], "Mod+Shift+Z"), (41, "ö", "ö", .command, "Mod+;"),
        (44, "-", "-", .command, "Mod+-"), (41, "Ö", "ö", .option, "Alt+;"),
        (6, "Y", "Y", [.command, .shift], "Mod+Shift+Y"),
        // QWERTZ: a symbol of a binding that Shift or Option types gives that symbol.
        (26, "/", "/", .shift, "Shift+/"), (23, "[", "5", .option, "Alt+["),
        // Dvorak
        (12, "'", "'", [], "'"), (13, ",", ",", .command, "Mod+,"),
        (15, "p", "p", .command, "Mod+P"),
        (1, "o", "o", [], "O"), (27, "[", "[", .command, "Mod+["), (33, "/", "/", [], "/"),
        // Dvorak: a letter that Option changes gives the US key at its place.
        (1, "ø", "o", .option, "Alt+S"),
        // Russian: the letters of another script give the US key at their place.
        (3, "а", "а", [], "F"), (3, "а", "а", .command, "Mod+F"),
        (17, "Е", "Е", [.command, .shift], "Mod+Shift+T"), (41, "ж", "ж", [], ";"),
        // Russian: Shift+4 types a semicolon, a symbol of a binding.
        (21, ";", ";", .shift, "Shift+;"),
    ]

    // The chord of each sample matches its own key event, so the recorded key runs its slot.
    @Test(arguments: layoutSamples)
    func theChordOfAKeyMatchesItsOwnKeyOnEachLayout(
        _ code: UInt16, _ text: String, _ ignoring: String, _ modifiers: KeyEvent.Modifiers,
        _ binding: String
    ) throws {
        let event = KeyEvent(
            keyCode: KeyCode(rawValue: code), characters: text,
            charactersIgnoringModifiers: ignoring, modifiers: modifiers)
        let chord = try #require(Chord(event: event))
        #expect(chord.text == binding)
        #expect(chord.match(event) != nil)
    }

    // A key whose typed key no binding names and whose place does not stand in gives no chord:
    // the key rules cannot read it as any binding. The QWERTZ Ö and + keys with no modifier, and
    // QWERTZ Option+L, which types @.
    @Test func aKeyThatNoChordMatchesGivesNoChord() {
        let samples: [(UInt16, String, String, KeyEvent.Modifiers)] = [
            (41, "ö", "ö", []), (30, "+", "+", []), (37, "@", "l", .option),
        ]
        for (code, text, ignoring, modifiers) in samples {
            let event = KeyEvent(
                keyCode: KeyCode(rawValue: code), characters: text,
                charactersIgnoringModifiers: ignoring, modifiers: modifiers)
            #expect(Chord(event: event) == nil, "\(text)")
        }
    }

    // The chord of the place of a key: the name or the US character at its place, whatever the
    // layout types there.
    @Test func theChordOfThePlaceIsTheUSKeyAtThePlace() {
        let azertyA = KeyEvent(keyCode: KeyCode(rawValue: 12), characters: "a")
        #expect(Chord(placeOf: azertyA)?.text == "Q")
        let umlaut = KeyEvent(keyCode: KeyCode(rawValue: 41), characters: "ö")
        #expect(Chord(placeOf: umlaut)?.text == ";")
        let space = KeyEvent(keyCode: KeyCode(rawValue: 49), characters: " ")
        #expect(Chord(placeOf: space)?.text == "Space")
        #expect(Chord(placeOf: KeyEvent(keyCode: KeyCode(rawValue: 87), characters: "5")) == nil)
    }
}

@Suite("The key of a key event")
struct KeyEventKeyTests {
    private func key(
        _ code: UInt16, _ characters: String, _ ignoring: String,
        _ modifiers: KeyEvent.Modifiers = []
    ) -> KeyEvent.Key {
        KeyEvent(
            keyCode: KeyCode(rawValue: code), characters: characters,
            charactersIgnoringModifiers: ignoring, modifiers: modifiers
        ).key
    }

    @Test("a key that types a character gives its text, with Shift and Option")
    func text() {
        #expect(key(31, "o", "o") == .text("o"))
        #expect(key(31, "O", "O", .shift) == .text("O"))
        #expect(key(31, "ø", "o", .option) == .text("ø"))
        #expect(key(18, "!", "!", .shift) == .text("!"))
    }

    @Test("with Control or Command the key is the text without those modifiers")
    func commandText() {
        #expect(key(8, "\u{3}", "c", .control) == .text("c"))
        #expect(key(46, "M", "M", [.command, .shift]) == .text("M"))
        #expect(key(1, "ß", "s", [.command, .option]) == .text("s"))
        // An empty text without modifiers keeps the typed text.
        #expect(key(1, "s", "", .command) == .text("s"))
    }

    @Test("a key with no text is a dead key")
    func dead() {
        #expect(key(14, "", "e", .option) == .dead)
        #expect(key(14, "", "e", [.option, .command]) == .dead)
    }

    @Test("a named key gives its name, whatever its text is")
    func named() {
        #expect(key(49, " ", " ") == .named(.space))
        #expect(key(49, "\u{A0}", " ", .option) == .named(.space))
        #expect(key(36, "\r", "\r", .shift) == .named(.enter))
        #expect(key(76, "\u{3}", "\u{3}") == .named(.enter))
        #expect(key(48, "\u{19}", "\u{19}", .shift) == .named(.tab))
        #expect(key(126, "\u{F700}", "\u{F700}", .command) == .named(.arrowUp))
        #expect(key(53, "\u{1b}", "\u{1b}") == .named(.escape))
    }

    @Test("a modifier key gives its modifier")
    func modifier() {
        #expect(key(55, "", "", .command) == .modifier(.command))
        #expect(key(60, "", "") == .modifier(.shift))
        #expect(key(57, "", "") == .modifier(.capsLock))
    }

    @Test("an event keeps its edge, its repeat, its composition and its modifiers")
    func fields() {
        let event = KeyEvent(
            keyCode: KeyCode(rawValue: 46), characters: "M",
            modifiers: [.command, .shift], isDown: false, isRepeat: true, isComposing: true)
        #expect(event.charactersIgnoringModifiers == "M")
        #expect(!event.isDown)
        #expect(event.isRepeat)
        #expect(event.isComposing)
        #expect(event.modifiers == [.shift, .command])
        let binding = Chord([.command, .shift], key: .character("M"))
        #expect(binding.match(event) == nil)
        let shown = KeyEvent(keyCode: event.keyCode, characters: "M", modifiers: [.command, .shift])
        #expect(binding.match(shown) == .direct)
    }
}
