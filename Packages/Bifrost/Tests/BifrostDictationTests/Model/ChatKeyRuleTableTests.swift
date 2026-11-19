// Tables of the rules of the chat input (DictationKeys.swift): the text that the typed tail keeps,
// the data that moves the cursor, the modifier keys, and the keys that the chat input takes. Each
// case has its own name in the report.
import BifrostKeyboard
import BifrostTestSupport
import Testing

@testable import BifrostDictation

private let esc = "\u{1b}"

// MARK: - The text rules of the chat input

private struct TailCase: Sendable, CustomTestStringConvertible {
    let name: String
    // The chunks that the user types, and the tail after each chunk.
    let chunks: [String]
    let tails: [String]
    var testDescription: String { name }
}

private let tailCases: [TailCase] = [
    TailCase(
        name: "text stays, and an arrow key and a reply of the terminal go",
        chunks: [
            "hecafé\(esc)[A", "caféllo\u{85}", "\u{8}\(esc)]unterminated", "\(esc)[I", "\(esc)b",
        ],
        tails: ["hecafé", "hecafécaféllo", "hecafécaféll", "hecafécaféll", "hecafécaféll"]),
    TailCase(
        name: "a tab goes, and Ctrl+U and Ctrl+C clear the tail",
        chunks: ["\the\u{15}", "llo", "\u{3}", "\(esc)]0;title\u{7}\(esc)P"],
        tails: ["", "llo", "", ""]),
    TailCase(
        name: "Enter and Shift+Enter end the tail with a new line",
        chunks: ["\u{85}\(esc)\r\(esc)b", "\(esc)[<0;10;5M\(esc)b\r"], tails: ["\n", "\n\n"]),
    TailCase(
        name: "a title and a space and Enter",
        chunks: ["\(esc)]0;title\u{7}\(esc)OB", " \r"], tails: ["", " \n"]),
    TailCase(
        name: "DEL removes one character", chunks: ["\t", "he", "\u{7f}"], tails: ["", "he", "h"]),
    TailCase(
        name: "a mouse report goes, and the text after it stays",
        chunks: ["\(esc)[<0;10;5M", "\(esc)[\r\(esc)]0;title\u{7}", "hehe"],
        tails: ["", "", "hehe"]),
    TailCase(
        name: "an emoji with a skin tone stays whole", chunks: ["👍🏽", "\t\(esc)\r"],
        tails: ["👍🏽", "👍🏽\n"]),
    TailCase(
        name: "a bracketed paste keeps its text",
        chunks: [
            "\(esc)[👍🏽é", "\r\(esc)\r", " \u{85}",
            "\(esc)[200~pasted\(esc)[201~llo\(esc)[200~pasted\(esc)[201~", "\u{1}",
        ],
        tails: ["🏽é", "🏽é\n\n", "🏽é\n\n ", "🏽é\n\n pastedllopasted", "🏽é\n\n pastedllopasted"]),
    TailCase(
        name: "an escape and a title with an emoji",
        chunks: [
            "\(esc)]0;title\u{7}", "\u{3}\r\(esc)]0;title\u{7}", "\(esc)\(esc)",
            "\(esc)]0;title\u{7}",
            " \(esc)[👍🏽",
        ],
        tails: ["", "\n", "\n", "\n", "\n 🏽"]),
    TailCase(
        name: "a flag keeps its second letter, and DEL removes a whole emoji",
        chunks: ["\(esc)b", "\(esc)", "llo👍🏽", "\(esc)[🇰🇷", "\(esc)P\u{8}\(esc)P"],
        tails: ["", "", "llo👍🏽", "llo👍🏽🇷", "llo👍🏽🇷"]),
]

private struct CursorCase: Sendable, CustomTestStringConvertible {
    let data: String
    let moves: Bool
    var testDescription: String { "\(data.debugDescription) \(moves ? "moves" : "does not move")" }
}

private let cursorCases: [CursorCase] = [
    CursorCase(data: "\(esc)[A", moves: true), CursorCase(data: "\(esc)[B", moves: true),
    CursorCase(data: "\(esc)[C", moves: true), CursorCase(data: "\(esc)[D", moves: true),
    CursorCase(data: "\(esc)OA", moves: true), CursorCase(data: "\(esc)OB", moves: true),
    CursorCase(data: "\(esc)OC", moves: true), CursorCase(data: "\(esc)OD", moves: true),
    CursorCase(data: "\(esc)[1;5C", moves: true),
    CursorCase(data: "\(esc)[A\(esc)[A\(esc)[A", moves: true),
    CursorCase(data: "x\(esc)[3;4Dy", moves: true), CursorCase(data: "\(esc)[;D", moves: true),
    CursorCase(data: "\(esc)\(esc)[A", moves: true),
    CursorCase(data: "a", moves: false), CursorCase(data: "ABCD", moves: false),
    CursorCase(data: "[A", moves: false), CursorCase(data: "\r", moves: false),
    CursorCase(data: "\(esc)[I", moves: false), CursorCase(data: "\(esc)[O", moves: false),
    CursorCase(data: "\(esc)[12;5R", moves: false), CursorCase(data: "\(esc)[?1;2c", moves: false),
    CursorCase(data: "\(esc)[<0;10;5M", moves: false), CursorCase(data: esc, moves: false),
    CursorCase(data: "\(esc)[", moves: false), CursorCase(data: "\(esc)O", moves: false),
    CursorCase(data: "\(esc)O1A", moves: false), CursorCase(data: "\(esc)[1;2E", moves: false),
]

@Suite("The text rules of the chat input")
struct ChatTextTests {
    @Test("the typed tail follows the text that the user types", arguments: tailCases)
    fileprivate func tail(_ item: TailCase) {
        var tail = ""
        #expect(item.chunks.count == item.tails.count)
        for (chunk, expected) in zip(item.chunks, item.tails) {
            tail = PTYText.typedTail(tail, chunk)
            #expect(
                Array(tail.unicodeScalars) == Array(expected.unicodeScalars),
                "\(chunk.debugDescription)")
        }
    }

    @Test("data moves the cursor or it does not", arguments: cursorCases)
    fileprivate func cursor(_ item: CursorCase) {
        #expect(PTYText.movesCursor(item.data) == item.moves)
    }

    @Test(
        "a modifier key alone types nothing, on the left and on the right",
        arguments: Array(54...63) as [UInt16])
    func modifierKey(_ code: UInt16) {
        #expect(KeyEvent(keyCode: KeyCode(rawValue: code), isDown: true).isModifierKey)
        #expect(KeyEvent(keyCode: KeyCode(rawValue: code), isDown: false).isModifierKey)
    }

    // The space bar, a letter, Enter, Backspace, F13, the keypad 5 and the Help key.
    @Test(
        "another key is not a modifier key",
        arguments: [
            (49, " "), (0, "a"), (36, "\r"), (51, "\u{7f}"), (105, "\u{F710}"), (87, "5"),
            (114, "\u{F746}"),
        ] as [(UInt16, String)])
    func otherKey(_ code: UInt16, _ text: String) {
        #expect(!KeyEvent(keyCode: KeyCode(rawValue: code), characters: text).isModifierKey)
    }
}

// MARK: - The keys of the chat input

private struct ChatKeyCase: Sendable, CustomTestStringConvertible {
    let key: String
    let mods: String
    let type: Edge
    // The action when no text types, and when a final text types.
    let idle: ChatKeyAction
    let typing: ChatKeyAction
    var testDescription: String {
        "\(type) \(key.debugDescription) with \(mods.isEmpty ? "no modifier" : mods)"
    }

    var event: KeyEvent {
        let mods = Mods(
            shift: mods.contains("S"), alt: mods.contains("A"), ctrl: mods.contains("C"),
            meta: mods.contains("M"))
        return ev(type, key, mods)
    }
}

private func chatKeys() -> [ChatKeyCase] {
    var cases: [ChatKeyCase] = []
    let none = ChatKeyAction()
    let interrupt = ChatKeyAction(stop: .interrupt)
    let block = ChatKeyAction(stop: .block)
    // A key that is not Escape stops a dictation. A final text that types does not stop.
    for key in ["a", "ArrowUp", "Enter"] {
        for mods in ["", "S", "A", "C", "M", "SC"] where !(key == "Enter" && mods == "S") {
            cases.append(
                ChatKeyCase(key: key, mods: mods, type: .keydown, idle: interrupt, typing: none))
            cases.append(ChatKeyCase(key: key, mods: mods, type: .keyup, idle: none, typing: none))
        }
    }
    // Shift+Enter sends ESC CR, takes the key down and the key up, and stops a dictation.
    let newLine = KeyRoute.send(KeyRoute.newLineText)
    cases.append(
        ChatKeyCase(
            key: "Enter", mods: "S", type: .keydown,
            idle: ChatKeyAction(stop: .interrupt, route: newLine),
            typing: ChatKeyAction(route: newLine)))
    cases.append(
        ChatKeyCase(
            key: "Enter", mods: "S", type: .keyup, idle: ChatKeyAction(route: .swallow),
            typing: ChatKeyAction(route: .swallow)))
    // A key with Space and a modifier is another key.
    for mods in ["S", "A", "C", "M"] {
        cases.append(
            ChatKeyCase(key: " ", mods: mods, type: .keydown, idle: interrupt, typing: none))
    }
    // Escape and Ctrl+C stop every typer, also a final text.
    for mods in ["", "S", "A", "C", "M"] {
        cases.append(
            ChatKeyCase(key: "Escape", mods: mods, type: .keydown, idle: block, typing: block))
        cases.append(
            ChatKeyCase(key: "Escape", mods: mods, type: .keyup, idle: none, typing: none))
    }
    cases.append(ChatKeyCase(key: "c", mods: "C", type: .keydown, idle: block, typing: block))
    // A modifier key alone stops nothing.
    for key in ["Shift", "Meta", "Alt", "Control", "CapsLock"] {
        cases.append(ChatKeyCase(key: key, mods: "", type: .keydown, idle: none, typing: none))
        cases.append(ChatKeyCase(key: key, mods: "S", type: .keyup, idle: none, typing: none))
    }
    return cases
}

@Suite("The keys of the chat input")
struct ChatKeyTableTests {
    @Test("a key gives its action when no text types", arguments: chatKeys())
    fileprivate func idle(_ item: ChatKeyCase) {
        #expect(ChatKeyAction(item.event, waits: false) == item.idle)
    }

    @Test("a key gives its action while a final text types", arguments: chatKeys())
    fileprivate func typing(_ item: ChatKeyCase) {
        #expect(ChatKeyAction(item.event, waits: true) == item.typing)
    }

    // During a composition, Shift+Enter goes to the input method with no ESC CR (accepted
    // change, docs/behaviour/keys.md). The key down still stops a dictation.
    @Test func shiftEnterDuringACompositionGoesToTheInputMethod() {
        let down = ev(.keydown, "Enter", Mods(shift: true, isComposing: true))
        #expect(ChatKeyAction(down, waits: false) == ChatKeyAction(stop: .interrupt))
        var up = down
        up.isDown = false
        #expect(ChatKeyAction(up, waits: false) == ChatKeyAction())
    }
}
