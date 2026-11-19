import BifrostTestSupport
import Testing

@testable import BifrostSettings

// The text rules (TextRules.swift of BifrostFoundation) in the checks of the settings texts:
// white space is Character.isWhitespace, and each limit counts Characters.
@Suite("the text rules of the settings")
struct SettingsTextRuleTests {
    @Test("the font family reads white space as Character.isWhitespace", arguments: spaceCases)
    func whiteSpace(_ item: SpaceCase) throws {
        let c = item.text
        let kept = item.isSpace ? "ab" : "\(c)ab\(c)"
        #expect(try SettingsText.checkFontFamily("\(c)ab\(c)") == kept)
    }

    @Test("each limit counts Characters", arguments: limitUnits)
    func limits(_ unit: String) throws {
        func text(_ count: Int) -> String { String(repeating: unit, count: count) }
        let slash = SettingsText.maxSlashLength - 1
        #expect(try SettingsText.checkSlashCommand("/" + text(slash)) == "/" + text(slash))
        #expect(throws: SettingsRefusal.slashTooLong) {
            try SettingsText.checkSlashCommand("/" + text(slash + 1))
        }
        let family = SettingsText.maxFontFamily
        #expect(try SettingsText.checkFontFamily(text(family)) == text(family))
        #expect(throws: SettingsRefusal.fontFamily) {
            try SettingsText.checkFontFamily(text(family + 1))
        }
    }
}
