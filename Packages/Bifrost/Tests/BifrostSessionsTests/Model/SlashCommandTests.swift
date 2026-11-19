import BifrostSessions
import Testing

// The form of a slash command that the settings and the dialog history keep. The texts of the
// refusals are in the settings (SettingsTextRuleTests).

@Suite("slash command")
struct SlashCommandTests {
    @Test func aCommandIsTrimmedAndKept() throws {
        #expect(try SlashCommand.clean("  /compact  ") == "/compact")
        #expect(try SlashCommand.clean("/a b") == "/a b")
        let longest = "/" + String(repeating: "😀", count: SlashCommand.maxLength - 1)
        #expect(try SlashCommand.clean(longest) == longest)
    }

    @Test(
        "a text that does not start with a slash and a character is refused",
        arguments: ["", "  ", "a", "/", "/ a", "/\u{85}a", " / a"])
    func start(text: String) {
        #expect(throws: SlashCommand.Refusal.start) { try SlashCommand.clean(text) }
    }

    @Test(arguments: ["/a\nb", "/a\rb", "/a\r\nb"])
    func aLineBreakIsRefused(text: String) {
        #expect(throws: SlashCommand.Refusal.lines) { try SlashCommand.clean(text) }
    }

    @Test func aCommandOfMoreThan200CharactersIsRefused() {
        #expect(SlashCommand.maxLength == 200)
        let text = "/" + String(repeating: "😀", count: SlashCommand.maxLength)
        #expect(throws: SlashCommand.Refusal.tooLong) { try SlashCommand.clean(text) }
    }
}
