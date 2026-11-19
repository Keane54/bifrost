import BifrostTestSupport
import Testing

@testable import BifrostFoundation

// The text rules of the app (TextRules.swift): white space is Character.isWhitespace, and each
// length limit counts Characters. The tests of each module check that its rules give the same
// result for the same Character, with the cases of TextCases.swift (BifrostTestSupport).

@Suite("the text rules")
struct TextRuleTests {
    @Test("the trim reads white space as Character.isWhitespace", arguments: spaceCases)
    func whiteSpace(_ item: SpaceCase) {
        let c = item.text
        let kept = item.isSpace ? "ab" : "\(c)ab\(c)"
        #expect(Character(c).isWhitespace == item.isSpace)
        #expect(Array("\(c)ab\(c)".trimmed().unicodeScalars) == Array(kept.unicodeScalars))
    }

    // A combining mark after a white space is a part of the same Character, so the trim removes
    // it with the white space. A mark after a line break is a
    // Character alone with no base, so it stays.
    @Test func theTrimRemovesAMarkWithItsWhiteSpace() {
        #expect(Array(" \u{301}Work".trimmed().unicodeScalars) == Array("Work".unicodeScalars))
        #expect(Array("Work \u{301}".trimmed().unicodeScalars) == Array("Work".unicodeScalars))
        #expect(
            Array("\n\u{301}Work".trimmed().unicodeScalars)
                == Array("\u{301}Work".unicodeScalars))
    }
}
