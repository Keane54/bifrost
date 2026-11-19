// The texts and the names of Hand over (docs/behaviour/actions.md, "Hand over"): the request
// prompt, the first prompt of the new session, the name of the new session and the name of the
// note file.
import BifrostFoundation
import Foundation
import Testing

@testable import BifrostSessions

// A Gregorian calendar in a fixed time zone, so the file name of a test never depends on the
// zone of the Mac.
private func calendar(_ zone: String) throws -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: zone))
    return calendar
}

@Suite("the texts of Hand over")
struct HandOverTextTests {
    @Test func theNewNameTakesTheNextFreeNumber() {
        #expect(HandOverText.newName("x", taken: []) == "x (2)")
        #expect(HandOverText.newName("x (2)", taken: []) == "x (3)")
        // Each taken name is skipped.
        #expect(HandOverText.newName("x (2)", taken: ["x (3)"]) == "x (4)")
        #expect(HandOverText.newName("x", taken: ["x (2)", "x (3)"]) == "x (4)")
        // Only " (n)" at the end is a number.
        #expect(HandOverText.newName("x (2) y", taken: []) == "x (2) y (2)")
        #expect(HandOverText.newName("x(2)", taken: []) == "x(2) (2)")
        #expect(HandOverText.newName("x ()", taken: []) == "x () (2)")
        #expect(HandOverText.newName("x (\u{0663})", taken: []) == "x (\u{0663}) (2)")
        // A number that is too large for a count is no number.
        let huge = "x (\(Int.max))"
        #expect(HandOverText.newName(huge, taken: []) == "\(huge) (2)")
    }

    // The base is cut so that the name has 64 Characters or less, and a space at the end of the
    // cut goes. An emoji counts as one Character.
    @Test func aLongNameIsCutBeforeItsNumber() {
        let long = String(repeating: "a", count: 64)
        let name = HandOverText.newName(long, taken: [])
        #expect(name == String(repeating: "a", count: 60) + " (2)")
        #expect(name.count == NewSessionSpec.maxName)
        let spaced = String(repeating: "b", count: 59) + " cdef"
        #expect(
            HandOverText.newName(spaced, taken: []) == String(repeating: "b", count: 59) + " (2)")
        let emoji = String(repeating: "\u{1F680}", count: 64)
        #expect(
            HandOverText.newName(emoji + " (9)", taken: [])
                == String(repeating: "\u{1F680}", count: 59) + " (10)")
    }

    // Each run of characters other than ASCII letters, digits, ".", "_" and "-" becomes one "-".
    // A "-" at the ends goes, the name part has 64 characters or less, and an empty name gives
    // "session". The date and the time are local, in the time zone of the calendar.
    @Test func theNoteFileNameHasOnlySafeCharacters() throws {
        let at = Date(timeIntervalSince1970: 1_795_000_000)  // 2026-11-18 11:06:40 UTC
        let london = try calendar("Europe/London")
        #expect(
            HandOverText.noteFileName("my session/../\u{E9} x", at: at, calendar: london)
                == "my-session-..-x-20261118-110640.md")
        let tokyo = try calendar("Asia/Tokyo")
        #expect(
            HandOverText.noteFileName("bifrost-test-s", at: at, calendar: tokyo)
                == "bifrost-test-s-20261118-200640.md")
        #expect(
            HandOverText.noteFileName(" -x- ", at: at, calendar: london)
                == "x-20261118-110640.md")
        for empty in ["\u{1F680}", "", "---"] {
            #expect(
                HandOverText.noteFileName(empty, at: at, calendar: london)
                    == "session-20261118-110640.md")
        }
        // The cut can leave a "-" at the end, and that "-" goes too.
        let long = String(repeating: "a", count: 63) + " b"
        #expect(
            HandOverText.noteFileName(long, at: at, calendar: london)
                == String(repeating: "a", count: 63) + "-20261118-110640.md")
        let file = HandOverText.noteFileName("a\0/b\u{202E}c", at: at, calendar: london)
        #expect(file == "a-b-c-20261118-110640.md")
    }

    // The rules text keeps its own line breaks, and one line break at its end is not there two
    // times. The request line comes first, and each marker is on a line of its own.
    @Test func thePromptHoldsTheRulesUnchanged() {
        let rules = "# Rules\n\n- Keep the user's words: \"$HOME\" and `code`.\n  Indented.\n"
        let prompt = HandOverText.prompt(rules: rules, requestID: "ab12cd34")
        let lines = prompt.components(separatedBy: "\n")
        #expect(lines.first == "Bifrost hand-over request ab12cd34")
        #expect(HandOverText.requestLine("ab12cd34") == "Bifrost hand-over request ab12cd34")
        let body = String(rules.dropLast())
        #expect(prompt.contains("\n\n" + body + "\n\nPut the note in your reply"))
        #expect(!prompt.contains("Indented.\n\n\n"))
        #expect(
            lines.suffix(3) == [HandOverText.noteStart, "<the note>", HandOverText.noteEnd])
        #expect(
            lines[2]
                == "Write a hand-over note for this session now. Use no tool, write no file, and "
                + "change nothing. A new session continues the work from the note. The rules for "
                + "the note follow.")
        #expect(HandOverText.noteStart == "[[BIFROST-HAND-OVER-NOTE-START]]")
        #expect(HandOverText.noteEnd == "[[BIFROST-HAND-OVER-NOTE-END]]")
        // A rules text with no line break at its end stays as it is.
        #expect(HandOverText.prompt(rules: "R", requestID: "x").contains("\n\nR\n\n"))
    }

    @Test func theContinuePromptGivesThePathAndEndsWithTheNote() {
        let prompt = HandOverText.continuePrompt(note: "# Note\nNext.", notePath: "/h/n.md")
        #expect(
            prompt
                == "Continue the work of an earlier session. Its hand-over note follows. The note "
                + "is also saved at /h/n.md. Read the note first, then continue with its next "
                + "steps. Ask the user when something is not clear.\n\n# Note\nNext.")
    }
}
