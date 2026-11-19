// The text rules of the data that a chat writes to its pseudo-terminal: the cursor keys and the
// typed tail. The tables of ChatKeyRuleTableTests.swift have more cases.
import Testing

@testable import BifrostDictation

@Suite("cursor keys and the typed tail")
struct PTYTextTests {
    @Test("cursor keys are found, also from a mouse wheel without tracking")
    func cursorKeys() {
        for data in [
            "\u{1b}[A", "\u{1b}[B", "\u{1b}[C", "\u{1b}[D",
            // The cursor keys in the application mode of the terminal.
            "\u{1b}OA", "\u{1b}OB", "\u{1b}OC", "\u{1b}OD",
            // With a modifier, for example Ctrl+Right.
            "\u{1b}[1;5C", "\u{1b}[A\u{1b}[A\u{1b}[A",
        ] {
            #expect(PTYText.movesCursor(data), "\(data.debugDescription)")
        }
    }

    @Test
    func notCursorKeys() {
        for data in [
            "a", "ABCD", "[A", "\r",
            // Focus reports, a cursor position report and a device attributes reply.
            "\u{1b}[I", "\u{1b}[O", "\u{1b}[12;5R", "\u{1b}[?1;2c",
            // A mouse report.
            "\u{1b}[<0;10;5M",
        ] {
            #expect(!PTYText.movesCursor(data), "\(data.debugDescription)")
        }
    }

    private func tail(_ chunks: String...) -> String {
        chunks.reduce("", PTYText.typedTail)
    }

    @Test("the typed tail keeps typed text")
    func keeps() {
        #expect(tail("he", "llo") == "hello")
    }

    @Test("the typed tail removes escape sequences")
    func removesEscapes() {
        #expect(tail("hi", "\u{1b}[A", "\u{1b}OB", "\u{1b}[I", "\u{1b}[O") == "hi")
        let osc = "\u{1b}]11;rgb:0000/0000/0000\u{1b}\\"
        #expect(tail("ok", "\u{1b}[<0;10;5M", osc, "\u{1b}[?1;2c") == "ok")
        #expect(tail("a", "\u{1b}b") == "a")
    }

    @Test("the typed tail keeps pasted text")
    func paste() {
        #expect(tail("x", "\u{1b}[200~pasted\u{1b}[201~") == "xpasted")
    }

    @Test("each delete removes one grapheme from the tail")
    func deletes() {
        #expect(tail("café 👍🏽", "\u{7f}") == "café ")
        #expect(tail("café", "\u{7f}") == "caf")
        #expect(tail("ab", "\u{7f}\u{7f}\u{7f}") == "")
    }

    @Test("Enter and Shift+Enter end the tail with a new line")
    func newLines() {
        #expect(tail("hello", "\r") == "hello\n")
        #expect(tail("hello", "\u{1b}\r") == "hello\n")
    }

    @Test("Ctrl+C and Ctrl+U clear the tail and other controls drop out")
    func controls() {
        #expect(tail("hello", "\u{03}") == "")
        #expect(tail("hello", "\u{15}") == "")
        #expect(tail("hel", "\t", "\u{01}", "lo") == "hello")
    }

    @Test("a long tail keeps only its end")
    func long() {
        let long = tail(String(repeating: "a", count: 5000), "b")
        #expect(long.count == 1000)
        #expect(long.hasSuffix("ab"))
    }

    // The tail keeps the last 1,000 Characters, so an emoji or a letter with a mark at the cut
    // stays whole.
    @Test(arguments: ["👍", "👍🏽", "🇰🇷", "e\u{301}"])
    func theTypedTailKeepsWholeCharacters(_ first: String) {
        let text = first + String(repeating: "a", count: 999)
        let kept = PTYText.typedTail("", "b" + text)
        #expect(Array(kept.unicodeScalars) == Array(text.unicodeScalars))
        #expect(kept.count == 1000)
    }

    // ESC and one character take the whole emoji, not the first half of its pair.
    @Test func anEscapeTakesAWholeEmoji() {
        #expect(Array(PTYText.typedTail("", "\u{1b}👍x").unicodeScalars) == ["x"])
    }
}
