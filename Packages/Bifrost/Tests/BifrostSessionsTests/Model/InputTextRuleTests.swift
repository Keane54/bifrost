import BifrostTestSupport
import Testing

@testable import BifrostSessions

// The text rules (TextRules.swift of BifrostFoundation) in the rename, the local name and the
// text of the session input: white space is Character.isWhitespace, and each limit counts
// Characters, also of emoji and combined letters.
@Suite("the text rules of the session input")
struct InputTextRuleTests {
    @Test("each rule reads white space as Character.isWhitespace", arguments: spaceCases)
    func whiteSpace(_ item: SpaceCase) {
        let c = item.text
        let kept = item.isSpace ? "ab" : "\(c)ab\(c)"
        #expect(InputPlan.rename("\(c)ab\(c)") == .success("/rename \(kept)"))
        let hidden = ["\u{FEFF}", "\u{200B}"].contains(c)
        #expect((try? cleanAlias("\(c)ab\(c)")) == (hidden ? nil : kept))
    }

    // A combining mark after a white space goes with the white space (TextRuleTests).
    @Test func theRenameRemovesAMarkWithItsWhiteSpace() {
        #expect(InputPlan.rename(" \u{301}Work") == .success("/rename Work"))
    }

    @Test("each limit counts Characters", arguments: limitUnits)
    func limits(_ unit: String) throws {
        func text(_ count: Int) -> String { String(repeating: unit, count: count) }
        #expect(try cleanAlias(text(maxAliasLength)) == text(maxAliasLength))
        #expect(throws: AliasRefusal.tooLong) { try cleanAlias(text(maxAliasLength + 1)) }

        let rename = InputPlan.maxRename
        #expect(InputPlan.rename(text(rename)) == .success("/rename \(text(rename))"))
        let long = InputRefusal.nameTooLong
        #expect(InputPlan.rename(text(rename + 1)) == .failure(long))
        #expect(InputPlan.plan(text(InputPlan.maxText)) != .refused(.tooLong))
        #expect(InputPlan.plan(text(InputPlan.maxText + 1)) == .refused(.tooLong))
    }
}
