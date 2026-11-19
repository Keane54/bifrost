import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostDictation

// The text rules (TextRules.swift of BifrostFoundation) in the vim mode and the typing rules:
// white space is Character.isWhitespace.
@Suite("the text rules of the dictation")
struct DictationTextRuleTests {
    @Test("each rule reads white space as Character.isWhitespace", arguments: spaceCases)
    func whiteSpace(_ item: SpaceCase) throws {
        let c = item.text
        let settings = try JSONEncoder().encode(["editorMode": "\(c)vim\(c)"])
        #expect(VimMode.of(settings) == item.isSpace)
        #expect(TypingRules.spaceFirst(after: "a\(c)") == !item.isSpace)
    }
}
