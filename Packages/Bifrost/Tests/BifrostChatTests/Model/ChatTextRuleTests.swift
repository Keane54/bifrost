import BifrostTestSupport
import Testing

@testable import BifrostChat

// The text rules (TextRules.swift of BifrostFoundation) in the screen rows and the links of a
// chat: white space is Character.isWhitespace, and the link limit counts Characters.
@Suite("the text rules of the chat")
struct ChatTextRuleTests {
    @Test("a blank row reads white space as Character.isWhitespace", arguments: spaceCases)
    func whiteSpace(_ item: SpaceCase) {
        #expect(ScreenRow(text: item.text, wrapped: false).isBlank == item.isSpace)
    }

    @Test("the link limit counts Characters", arguments: limitUnits)
    func limits(_ unit: String) {
        func text(_ count: Int) -> String { String(repeating: unit, count: count) }
        let start = "https://example.com/"
        let link = start + text(LinkRules.maxLength - start.count)
        #expect(LinkRules.target(link, localHost: "mac") != nil)
        #expect(LinkRules.target(link + unit, localHost: "mac") == nil)
    }
}
