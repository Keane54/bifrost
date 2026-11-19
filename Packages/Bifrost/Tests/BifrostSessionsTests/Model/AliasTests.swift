// The local name of a session (docs/behaviour/actions.md, "Local names"): the tooltip of the
// name, and the control characters that the clean refuses. RuleEdgeTests has the other cases of
// the clean.
import BifrostTestSupport
import Testing

@testable import BifrostSessions

@Suite("the local name")
struct AliasTipTests {
    @Test func theTipOfALocalNameIsTheClaudeCodeName() {
        let row = SessionRow.test(name: "Work", claudeName: "alpha")
        #expect(aliasTip(row) == "Claude Code name: alpha")
    }

    // The panel can cut a long name, so the tip gives the whole name.
    @Test func theTipOfARowWithNoLocalNameIsTheNameItself() {
        #expect(aliasTip(SessionRow.test(name: "alpha")) == "alpha")
    }

    // NEL (U+0085) is in C1, and a colour escape starts with ESC.
    @Test(arguments: ["a\u{85}b", "a\u{1B}[31mb", "a\u{9B}31mb", "a\r\nb"])
    func aControlCharacterInsideTheNameRefusesIt(text: String) {
        #expect(throws: AliasRefusal.control) { try cleanAlias(text) }
    }
}
