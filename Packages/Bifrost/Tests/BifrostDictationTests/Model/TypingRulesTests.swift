// The typing rules: the edit of the typed text and the other rules. The tests of the typer are in
// DictationTyperTests.swift.
import Testing

@testable import BifrostDictation

// Exact (the text with its exact Unicode scalars) is in DictationSupport.swift.

// The 48 Characters of the mixed sentence of the spike: 55 scalars and 62 UTF-16 units.
private let mixed =
    "Fix the café bug ❤\u{FE0F} 👍🏽 in 中文 🇬🇧 now 👨\u{200D}👩\u{200D}👧 ok, all done."
private let family = "👨\u{200D}👩\u{200D}👧"

private func edit(_ typed: String, _ next: String) -> (Int, Exact) {
    let result = TypingRules.planEdit(typed: typed, next: next)
    return (result.deletes, result.insert.exact)
}

@Suite("edit plan")
struct PlanEditTests {
    @Test("only the end of the last word changes")
    func commonStart() {
        #expect(edit("Fix the parcer", "Fix the parser") == (3, "ser".exact))
    }

    @Test("a longer guess adds its end")
    func longer() {
        #expect(edit("Fix the", "Fix the bug") == (0, " bug".exact))
    }

    @Test("a shorter guess removes its end")
    func shorter() {
        #expect(edit("Fix the bug now", "Fix the bug") == (4, "".exact))
    }

    @Test
    func sameAndEmpty() {
        #expect(edit("Fix it", "Fix it") == (0, "".exact))
        #expect(edit("", "Fix it") == (0, "Fix it".exact))
        #expect(edit("Fix it", "") == (6, "".exact))
    }

    @Test
    func oneDeletePerCharacter() {
        let typed = ["abé", "ab❤\u{FE0F}", "ab\(family)", "ab🇬🇧", "abe\u{301}", "ab中"]
        for text in typed { #expect(edit(text, "ab") == (1, "".exact), "\(text.debugDescription)") }
        #expect(edit("cafe", "café") == (1, "é".exact))
    }

    @Test("a changed mark or modifier retypes the whole grapheme")
    func markChanges() {
        #expect(edit("cafe", "cafe\u{301}") == (1, "e\u{301}".exact))
        #expect(edit("caf\u{E9}", "cafe\u{301}") == (1, "e\u{301}".exact))
        #expect(edit("ab👍", "ab👍🏽") == (1, "👍🏽".exact))
    }

    @Test("48 graphemes need 48 deletes")
    func mixedSentence() {
        #expect([mixed.count, mixed.unicodeScalars.count, mixed.utf16.count] == [48, 55, 62])
        #expect(edit(mixed, "") == (48, "".exact))
    }

    @Test
    func emojiAndCJK() {
        #expect(edit("我想要咖啡 ☕\u{FE0F}", "我想要茶 🍵") == (4, "茶 🍵".exact))
    }
}

// New tests of the values and of the rules that the typer uses.
struct TypingRulesTests {
    @Test func theValuesOfTheSpike() {
        #expect(TypingRules.del == "\u{7F}")
        #expect(TypingRules.maxWriteText == 100)
        #expect(TypingRules.maxWriteDeletes == 1000)
        #expect(TypingRules.writeGap == .milliseconds(20))
    }

    @Test func theGapAddsOneMillisecondForEachTwoDeletes() {
        #expect(TypingRules.gap(afterDeletes: 0) == .milliseconds(20))
        #expect(TypingRules.gap(afterDeletes: 1) == .milliseconds(21))
        #expect(TypingRules.gap(afterDeletes: 3) == .milliseconds(22))
        #expect(TypingRules.gap(afterDeletes: 1000) == .milliseconds(520))
    }

    @Test func anEditIsEqualOnlyForTheSameBytes() {
        let composed = TypingEdit(deletes: 1, insert: "\u{E9}")
        #expect(composed != TypingEdit(deletes: 1, insert: "e\u{301}"))
        #expect(TypingEdit(deletes: 1, insert: "é") == TypingEdit(deletes: 1, insert: "é"))
        #expect(TypingEdit(deletes: 2, insert: "é") != TypingEdit(deletes: 1, insert: "é"))
    }

    @Test func theCleanChangesLineBreaksAndDropsControlAndFormatCharacters() {
        let clean = { TypingRules.clean($0, atStart: false, promptEmpty: true) }
        #expect(clean("one\ntwo\r\nthree\tfour\rfive").exact == "one two three four five".exact)
        #expect(clean("a\u{B}b\u{C}c\u{85}d\u{2028}e\u{2029}f").exact == "a b c d e f".exact)
        #expect(clean("ab\u{1B}[2Jc\u{7F}d\u{8}e\u{9B}f\u{0}g").exact == "ab[2Jcdefg".exact)
        #expect(clean("a\u{200B}b\u{FEFF}c\u{AD}d\u{200E}e\u{202E}f").exact == "abcdef".exact)
        // ZWJ, ZWNJ and the tags stay, because emoji and some languages use them.
        let flag = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}"
        #expect(clean("\(family) a\u{200C}b \(flag)").exact == "\(family) a\u{200C}b \(flag)".exact)
    }

    @Test func theStartOfADictationLosesItsJoinersAndMarks() {
        let start = "\u{301}\u{200D}\u{200C}\u{1F3FD}\u{E0041}\u{20DD}bug"
        #expect(TypingRules.clean(start, atStart: true, promptEmpty: true).exact == "bug".exact)
        // Not at the start: the marks stay.
        #expect(
            TypingRules.clean("\u{301}bug", atStart: false, promptEmpty: true).exact
                == "\u{301}bug".exact)
        // A dropped format character can show a mark at the start. The mark goes too.
        #expect(TypingRules.clean("\u{200B}\u{301}x", atStart: true, promptEmpty: true) == "x")
    }

    @Test func theStartOfADictationGetsItsSpace() {
        let clean = { (text: String, empty: Bool) in
            TypingRules.clean(text, atStart: true, promptEmpty: empty).exact
        }
        #expect(clean("hello", true) == "hello".exact)
        #expect(clean("hello", false) == " hello".exact)
        #expect(clean(" hello", false) == " hello".exact)
        #expect(clean("\nhello", false) == " hello".exact)
        for mark in ["/", "!", "?", "#"] {
            #expect(clean("\(mark)help", true) == " \(mark)help".exact)
            #expect(clean("\(mark)help", false) == " \(mark)help".exact)
        }
        #expect(clean("@help", true) == "@help".exact)
        #expect(clean("@help", false) == " @help".exact)
        // The rule reads the first scalar, as text[0] does: a slash with a mark is a slash.
        #expect(clean("/\u{301}x", true) == " /\u{301}x".exact)
        // A text that the clean empties gets no space.
        #expect(clean("\u{1B}\u{7F}", false) == "".exact)
    }

    @Test func theSpaceFirstReadsTheEndOfTheLastSentText() {
        let cases: [(String, Bool)] = [
            ("Fix", true), ("", false), ("Fix ", false), ("\r", false), ("\t", false),
            ("\u{A0}", false), ("\u{3000}", false), ("\u{FEFF}", true), ("\u{85}", false),
            (" \u{301}", false), ("\u{7F}", true),
        ]
        for (last, space) in cases {
            #expect(TypingRules.spaceFirst(after: last) == space, "\(last.debugDescription)")
        }
    }

    @Test func theFirstPartCutsAtACharacterBoundary() {
        let words = String(repeating: "word ", count: 30)
        #expect(TypingRules.firstPart(words).utf16.count == 100)
        let accents = "x" + String(repeating: "e\u{301}", count: 60)
        #expect(TypingRules.firstPart(accents).utf16.count == 99)
        #expect(TypingRules.firstPart("short").exact == "short".exact)
        // A Character longer than the limit is a part alone.
        let long = "e" + String(repeating: "\u{301}", count: 120)
        #expect(TypingRules.firstPart(long + "x").exact == long.exact)
        #expect(TypingRules.firstPart("ab" + long).exact == "ab".exact)
    }
}
