// The typer of a dictation: the edits, the corrections, the leading space, the clean of the text
// and the cut of a write. TyperDriver writes one part at once and the next part at each step,
// as the chat does at the end of each gap. The times of the gaps are in ChatDictationTests.
import Testing

@testable import BifrostDictation

private let del = TypingRules.del
private let family = "👨\u{200D}👩\u{200D}👧"
private let mixed =
    "Fix the café bug ❤\u{FE0F} 👍🏽 in 中文 🇬🇧 now 👨\u{200D}👩\u{200D}👧 ok, all done."

private func dels(_ count: Int) -> String { String(repeating: del, count: count) }

private func rules(_ t: TyperDriver, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(t.problems.isEmpty, "\(t.problems)", sourceLocation: sourceLocation)
}

private func partsOf(_ data: [String]) -> [String] {
    data.map { let p = parts($0); return "\(p.deletes) \(p.text)" }
}

@Suite("the typer of a dictation", .timeLimit(.minutes(1)))
@MainActor
struct DictationTyperTests {
    @Test func eachWriteGoesFromTheTypedTextToTheNewestText() {
        var t = TyperDriver()
        t.update("", "Add a")
        t.update("", "Add a test")
        t.update("", "Add a text")
        t.runAll()
        #expect(t.data.exact == ["Add a", " text"].exact)
        t.update("", "Add a test")
        t.runAll()
        #expect(t.data.exact == ["Add a", " text", "\(dels(2))st"].exact)
        #expect(t.prompt.exact == "Add a test".exact)
        rules(t)
    }

    @Test func anUpdateNeverRemovesFinalText() {
        var t = TyperDriver()
        t.update("Fix the bug.", "")
        t.update("Fix the bug.", " Then ran")
        t.update("Fix the bug. Then run", "")
        t.runAll()
        #expect(t.prompt.exact == "Fix the bug. Then run".exact)
        let before = t.data.count
        t.update("Fix the", " bag")
        t.update("", "Fix")
        t.runAll()
        #expect(t.data.count == before)
        t.update("Fix the bug. Then run", " the tests")
        t.runAll()
        #expect(t.prompt.exact == "Fix the bug. Then run the tests".exact)
        rules(t)
    }

    // The end is the text of the recognizer: it adds words, drops a guessed word, changes a final
    // word, or comes with no final part before it.
    @Test(arguments: [
        ([("Add a test", " that")], "Add a test that checks it."),
        ([("Add a test", " that um")], "Add a test that"),
        ([("Add a tent.", "")], "Add a test."),
        ([("", "Add a"), ("", "And a test")], "Add a test."),
        ([], "Add a test."),
    ])
    func thePromptEndsWithTheFinalText(updates: [(String, String)], final: String) {
        var t = TyperDriver(user: "Please ", lastSent: "Please ")
        for (text, volatile) in updates {
            t.update(text, volatile)
            t.runAll()
        }
        t.finish(final)
        t.runAll()
        #expect(t.prompt.exact == "Please \(final)".exact)
        rules(t)
    }

    @Test func anEmptyFinalTextRemovesOnlyTheTextOfTheDictation() {
        var t = TyperDriver(user: "Keep this", lastSent: "Keep this")
        t.update("", "um")
        t.runAll()
        #expect(t.prompt.exact == "Keep this um".exact)
        t.finish("")
        t.runAll()
        #expect(t.prompt.exact == "Keep this".exact)
        #expect(t.data.last?.exact == dels(3).exact)
        rules(t)
    }

    @Test func nothingTypesAfterTheEndOrAStop() {
        var t = TyperDriver()
        t.finish("Done.")
        t.runAll()
        t.update("Other", " words")
        t.finish("Other")
        t.runAll()
        #expect(t.data.exact == ["Done."].exact)
        var stopped = TyperDriver()
        stopped.update("", String(repeating: "a", count: 1000))
        stopped.typer.cancel()
        stopped.runAll()
        stopped.update("", "b")
        stopped.finish("c")
        stopped.runAll()
        #expect(stopped.prompt.exact == String(repeating: "a", count: 100).exact)
    }

    @Test func accentsEmojiAndCJKAreWholeCharacters() {
        var t = TyperDriver(user: "Note: ", lastSent: "Note: ")
        let steps: [(String, String)] = [
            ("", "Le café ❤\u{FE0F}"),
            ("", "Le cafe"),
            ("", "Le cafe\u{301} \(family) 🇬🇧"),
            ("Le cafe\u{301}", " 🇬🇧 中文 한국어"),
            ("Le cafe\u{301} 🇬🇧", " 日本語 👍🏽"),
        ]
        for (final, volatile) in steps {
            t.update(final, volatile)
            t.runAll()
            #expect(t.dictated.exact == (final + volatile).exact)
        }
        t.finish("Le cafe\u{301} 🇬🇧 日本語 👍🏽.")
        t.runAll()
        #expect(t.prompt.exact == "Note: Le cafe\u{301} 🇬🇧 日本語 👍🏽.".exact)
        // A mixed sentence of 48 Characters goes with 48 DELs.
        var m = TyperDriver(user: "Keep ", lastSent: "Keep ")
        m.update("", mixed)
        m.runAll()
        m.finish("")
        m.runAll()
        #expect(m.data.last?.exact == dels(48).exact)
        #expect(m.prompt.exact == "Keep ".exact)
        rules(t)
        rules(m)
    }

    @Test func theEndOfALongLineIsCorrected() {
        var t = TyperDriver()
        let long = String(repeating: "word ", count: 40)
        t.update("", "\(long)parcer")
        t.runAll()
        t.update("", "\(long)parser")
        t.runAll()
        #expect(t.data.last?.exact == "\(dels(3))ser".exact)
        #expect(t.prompt.exact == "\(long)parser".exact)
        rules(t)
    }

    // A space goes first unless the last sent text is empty or ends with white space. The typer
    // reads the last sent text one time: a second read would give the other answer.
    @Test(arguments: [
        ("Fix", true), ("v2", true), ("done.", true), ("caf\u{E9}", true), ("cafe\u{301}", true),
        ("中", true), ("(", true), ("Fix ", false), ("", false), ("\r", false), ("\t", false),
        ("❤\u{FE0F}", true), (del, true),
    ])
    func aSpaceGoesFirstAfterTextWithNoWhiteSpaceAtItsEnd(lastSent: String, space: Bool) {
        var t = TyperDriver(user: "", lastSent: lastSent)
        t.update("", "hello")
        t.runAll()
        t.lastSent = space ? "" : "Fix"
        t.update("", "hello there")
        t.runAll()
        #expect(t.data.exact == [space ? " hello" : "hello", " there"].exact)
        rules(t)
    }

    @Test func theLastSentTextIsReadOnceAtTheFirstTextThatIsNotEmpty() {
        var t = TyperDriver(user: "", lastSent: "Fix")
        t.lastSentFollowsWrites = true
        t.update("", "the ")
        t.runAll()
        t.update("", "the bug")
        t.runAll()
        t.finish("the bug.")
        t.runAll()
        #expect(t.data.exact == [" the ", "bug", "."].exact)
        // A first text with nothing to type reads nothing: an empty last sent text gives no space.
        var empty = TyperDriver(user: "Fix", lastSent: "")
        empty.update("", "")
        empty.lastSent = "Fix"
        empty.update("", "it")
        empty.runAll()
        empty.update("i", "t")
        empty.runAll()
        #expect(empty.data.exact == [" it"].exact)
    }

    // A menu mark (/, !, ? and #) at the start gets a space first, also on an empty prompt. @
    // gets none on an empty prompt, so the file suggestions of Claude stay open.
    @Test(arguments: ["/", "!", "?", "#", "@"])
    func aMenuMarkAtTheStartGetsASpaceFirst(mark: String) {
        var empty = TyperDriver(user: "", lastSent: "")
        empty.update("", "\(mark)help")
        #expect(empty.data.exact == [mark == "@" ? "@help" : " \(mark)help"].exact)
        var after = TyperDriver(user: "Fix", lastSent: "Fix")
        after.update("", "\(mark)help")
        #expect(after.data.exact == [" \(mark)help"].exact)
        // A text that starts with white space gets no other space.
        var spaced = TyperDriver(user: "Fix", lastSent: "Fix")
        spaced.update("", " the bug")
        #expect(spaced.data.exact == [" the bug"].exact)
    }

    @Test func aCorrectionToASlashGetsTheSpaceToo() {
        var t = TyperDriver(user: "", lastSent: "")
        t.update("", "slash help")
        t.runAll()
        t.update("", "/help")
        t.runAll()
        #expect(t.prompt.exact == " /help".exact)
        t.finish("/help me")
        t.runAll()
        #expect(t.prompt.exact == " /help me".exact)
        rules(t)
    }

    @Test func lineBreaksBecomeSpacesAndControlAndFormatCharactersGo() {
        var t = TyperDriver()
        t.update("", "one\ntwo\r\nthree\tfour\rfive")
        t.runAll()
        #expect(t.prompt.exact == "one two three four five".exact)
        t.finish("ab\u{1B}[2Jc\u{7F}d\u{8}e\u{9B}f\u{0}g")
        t.runAll()
        #expect(t.prompt.exact == "ab[2Jcdefg".exact)
        var f = TyperDriver()
        f.update("", "a\u{200B}b\u{FEFF}c\u{AD}d\u{200E}e\u{202E}f")
        f.runAll()
        #expect(f.prompt.exact == "abcdef".exact)
        // The joiners of an emoji stay.
        f.finish("ok \(family)")
        f.runAll()
        #expect(f.prompt.exact == "ok \(family)".exact)
        rules(t)
        rules(f)
    }

    @Test func marksAtTheStartNeverJoinTheTextOfTheUser() {
        var t = TyperDriver(user: "Fix the ", lastSent: "Fix the ")
        t.update("", "\u{301}\u{200D}bug")
        t.runAll()
        #expect(t.prompt.exact == "Fix the bug".exact)
        t.finish("")
        t.runAll()
        #expect(t.prompt.exact == "Fix the ".exact)
        rules(t)
    }

    @Test func aLongTextGoesInPartsOf100UnitsAtCharacterBoundaries() {
        let words = String(repeating: "word ", count: 100)
        var w = TyperDriver()
        w.update("", words)
        w.runAll()
        #expect(w.data.map(\.utf16.count) == [100, 100, 100, 100, 100])
        #expect(w.prompt.exact == words.exact)
        let accents = "x" + String(repeating: "e\u{301}", count: 300)
        var a = TyperDriver()
        a.update("", accents)
        #expect(a.data.map(\.utf16.count) == [99])
        a.runAll()
        #expect(a.data.map(\.utf16.count) == [99, 100, 100, 100, 100, 100, 2])
        #expect(!a.data.contains { $0.unicodeScalars.first == "\u{301}" })
        #expect(a.prompt.exact == accents.exact)
        let families = String(repeating: family, count: 120)
        var b = TyperDriver()
        b.update("", families)
        b.runAll()
        #expect(b.data.map(\.utf16.count) == Array(repeating: 96, count: 10))
        #expect(b.prompt.exact == families.exact)
        rules(w)
        rules(a)
        rules(b)
    }

    @Test func aLongDELRunGoesIn1000DELsAndThenTheRest() {
        var t = TyperDriver(user: "Keep ", lastSent: "Keep ")
        t.update("", String(repeating: "a", count: 1500))
        t.runAll()
        let before = t.data.count
        t.finish("b")
        t.runAll()
        #expect(partsOf(Array(t.data.dropFirst(before))) == ["1000 ", "500 b"])
        #expect(t.prompt.exact == "Keep b".exact)
        rules(t)
    }

    // A new text during a long edit plans the rest of the edit again: after a part of a DEL run,
    // and after a part of a long text.
    @Test(arguments: [false, true])
    func aNewTextDuringALongEditPlansTheRestAgain(end: Bool) {
        var t = TyperDriver(user: "Keep ", lastSent: "Keep ")
        t.update("", String(repeating: "a", count: 1500))
        t.runAll()
        let before = t.data.count
        t.update("", "b")
        #expect(Array(t.data.dropFirst(before)).exact == [dels(1000)].exact)
        let next = String(repeating: "a", count: 300) + "c"
        if end { t.finish(next) } else { t.update("", next) }
        t.runAll()
        #expect(partsOf(Array(t.data.dropFirst(before))) == ["1000 ", "200 c"])
        #expect(t.prompt.exact == "Keep \(next)".exact)
        for (next, rest) in [
            (String(repeating: "a", count: 50) + "b", "\(dels(50))b"),
            (String(repeating: "a", count: 180) + "b", String(repeating: "a", count: 80) + "b"),
        ] {
            var s = TyperDriver()
            s.update("", String(repeating: "a", count: 250))
            if end { s.finish(next) } else { s.update("", next) }
            s.runAll()
            #expect(s.data.exact == [String(repeating: "a", count: 100), rest].exact)
            #expect(s.prompt.exact == next.exact)
            rules(s)
        }
        rules(t)
    }

    // Before its turn, only the newest text of the dictation waits. At its turn, the typer reads
    // the last sent text, which has the text that typed before it.
    @Test func beforeItsTurnOnlyTheNewestTextWaits() {
        let typer = DictationTyper()
        typer.give(final: "", volatile: "One", end: false, lastSent: "")
        typer.give(final: "", volatile: "Two", end: false, lastSent: "")
        #expect(typer.waitsForTurn)
        #expect(typer.nextWrite() == nil)
        typer.start(lastSent: "older text")
        #expect(!typer.waitsForTurn)
        #expect(typer.nextWrite()?.data.exact == " Two".exact)
        #expect(typer.nextWrite() == nil)
        // A stop drops the text that waits.
        let stopped = DictationTyper()
        stopped.give(final: "Three", volatile: "", end: true, lastSent: "")
        stopped.cancel()
        #expect(!stopped.waitsForTurn)
        stopped.start(lastSent: "")
        #expect(stopped.nextWrite() == nil)
    }

    // The pieces of the random recognizer texts: letters, spaces, line breaks, tabs, ESC and
    // escape sequences, the C0 and C1 controls, DEL, format characters, joiners, marks, skin
    // tones, tags, emoji and the menu characters.
    static let pieces: [String] = [
        "a", "b", "Fix", " ", "  ", "é", "e\u{301}", "\n", "\r", "\r\n", "\n\r", "\t", "\u{B}",
        "\u{C}", "\u{1B}", "\u{1B}[2J", "\u{1B}[A", "\u{1B}OD", "\u{1B}\r", "\u{7F}", "\u{8}",
        "\u{0}", "\u{3}", "\u{4}", "\u{1A}", "\u{1F}", "\u{85}", "\u{9B}", "\u{9F}", "\u{2028}",
        "\u{2029}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{AD}", "\u{200E}",
        "\u{202E}", "\u{2066}", "\u{E0001}", "\u{E0041}", "\u{301}", "\u{20DD}", "\u{1F3FD}",
        "👍", "👍🏽", "👨\u{200D}👩\u{200D}👧", "🇬🇧", "中文", "/", "!", "?", "#", "@",
    ]

    static func text(_ random: inout SeededRandom) -> String {
        (0..<random.int(0...12)).map { _ in random.pick(pieces) }.joined()
    }

    // The scalars that must never reach Claude's prompt in the text of a write: a control
    // character (Enter, a line break, a tab, ESC, DEL), a line or paragraph separator, and a
    // format character other than ZWJ, ZWNJ and the tags.
    static func forbidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: return true
        case .format:
            return !(scalar.value == 0x200C || scalar.value == 0x200D
                || (0xE0020...0xE007F).contains(scalar.value))
        default: return false
        }
    }

    // True when the text of a write, after its DELs, has a forbidden scalar.
    static func hasForbidden(_ write: String) -> Bool {
        parts(write).text.unicodeScalars.contains(where: forbidden)
    }

    // 2,000 seeded random recognizer texts. No write has Enter, a line break, a tab, ESC or
    // another control character after its DELs.
    @Test func theTyperNeverSendsEnterTabOrEscape() {
        var random = SeededRandom(seed: 20_261_116)
        var failures: [String] = []
        var controls = 0
        for n in 0..<2000 {
            let texts = (0..<random.int(1...4)).map { _ in Self.text(&random) }
            let last = Self.text(&random)
            controls += (texts + [last]).joined().unicodeScalars.filter(Self.forbidden).count
            var t = TyperDriver(user: "", lastSent: random.pick(["", "Fix", "Fix ", "\r"]))
            var final = ""
            for text in texts {
                if random.chance(0.4) { final += text }
                t.update(final, random.chance(0.5) ? text : "")
                if random.chance(0.5) { t.runAll() }
            }
            t.finish(last)
            t.runAll()
            for write in t.data where Self.hasForbidden(write) {
                failures.append("case \(n): \(write.debugDescription)")
            }
            if !t.problems.isEmpty { failures.append("case \(n): \(t.problems)") }
        }
        #expect(failures.isEmpty, "\(failures.count) writes: \(failures.prefix(3))")
        // The texts must hold many forbidden characters, or the test would test nothing.
        #expect(controls > 5000)
    }

    // The pieces of the texts of the cut test: Characters of many scalars and many UTF-16 units.
    private static let longPieces: [String] = [
        "x", "a", " ", "e\u{301}", "e\u{301}\u{302}\u{303}", "👨\u{200D}👩\u{200D}👧", "🇬🇧",
        "👍🏽", "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}", "क्ष", "한",
        "中", "e" + String(repeating: "\u{301}", count: 60),
        "e" + String(repeating: "\u{301}", count: 120),
    ]

    // Seeded random texts with long Characters, with corrections. Each write keeps whole
    // Characters: the prompt as a list of the Characters of each write is the same as the
    // Characters of the prompt text. So a cut never puts a part of a Character in one write and
    // the rest in the next.
    @Test func aWriteNeverSplitsACharacter() async {
        var random = SeededRandom(seed: 7_301)
        var failures: [String] = []
        var cuts = 0
        for n in 0..<1000 {
            // The typer runs on the main actor, and the 1,000 cases take seconds in a debug
            // build. Each tenth case first lets the other jobs of the main actor run, so the
            // test holds the main actor for 10 cases at a time (some milliseconds).
            if n.isMultiple(of: 10) { await Task.yield() }
            var t = TyperDriver()
            var words: [String] = []
            for _ in 0..<random.int(1...5) {
                // Add pieces, and sometimes change the last pieces (a correction).
                if random.chance(0.3), !words.isEmpty {
                    words.removeLast(random.int(1...words.count))
                }
                words += (0..<random.int(1...30)).map { _ in random.pick(Self.longPieces) }
                t.update("", words.joined())
                if random.chance(0.5) { t.runAll() }
            }
            t.finish(words.joined())
            t.runAll()
            var model: [Character] = []
            for write in t.data {
                let (deletes, text) = parts(write)
                model.removeLast(min(deletes, model.count))
                model += Array(text)
                let joined = Array(String(model))
                let same =
                    joined.count == model.count
                    && zip(joined, model).allSatisfy {
                        $0.unicodeScalars.elementsEqual($1.unicodeScalars)
                    }
                if !same { failures.append("case \(n): a write split a Character") }
            }
            cuts += max(0, t.data.count - 1)
            if !t.prompt.utf8.elementsEqual(words.joined().utf8) {
                failures.append("case \(n): the prompt is not the text")
            }
            if !t.problems.isEmpty { failures.append("case \(n): \(t.problems)") }
        }
        #expect(failures.isEmpty, "\(failures.count) failures: \(failures.prefix(3))")
        #expect(cuts > 2000)
    }
}
