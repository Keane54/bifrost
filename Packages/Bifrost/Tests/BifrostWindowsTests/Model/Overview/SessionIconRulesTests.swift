import BifrostSessions
import BifrostWindows
import Testing

// The rules of the row icon: its project key, its project colour and its kind (the section "The
// session icon" of docs/behaviour/overview.md).

@Suite("session icon rules")
struct SessionIconRulesTests {
    @Test func theProjectKeyOfAPlainPathIsThePath() {
        #expect(SessionIconRules.projectKey("/Users/o/Developer/app") == "/Users/o/Developer/app")
    }

    @Test func theProjectKeyHasNoTrailingSlash() {
        #expect(SessionIconRules.projectKey("/Users/o/Developer/app/") == "/Users/o/Developer/app")
    }

    @Test func theProjectKeyOfAWorktreeIsItsRepository() {
        #expect(
            SessionIconRules.projectKey("/Users/o/Developer/app/.claude/worktrees/fix-bug")
                == "/Users/o/Developer/app")
        #expect(
            SessionIconRules.projectKey("/Users/o/Developer/app/.claude/worktrees/fix-bug/src/lib")
                == "/Users/o/Developer/app")
    }

    @Test func theColourIndexIsFrom1To8() {
        let keys = [
            "", "/", "/a", "/a/b", "/Users/o/x", String(repeating: "z", count: 500), "é😀",
        ]
        for key in keys {
            #expect((1...8).contains(SessionIconRules.projectColourIndex(key)), "\(key)")
        }
    }

    // The index is FNV-1a of 32 bits on the UTF-8 bytes of the key, modulo 8, plus 1.
    @Test func theColourIndexOfKnownKeys() {
        #expect(SessionIconRules.projectColourIndex("/Users/o/Developer/app") == 2)
        #expect(SessionIconRules.projectColourIndex("/Users/o/Developer/bifrost") == 8)
        #expect(SessionIconRules.projectColourIndex("") == 6)
        #expect(SessionIconRules.projectColourIndex("é😀") == 5)
    }

    @Test func theIconKindIsTheKindOfTheRowOrParked() {
        #expect(SessionIconRules.iconKind(overviewRow("a", kind: .owned)) == .owned)
        #expect(SessionIconRules.iconKind(overviewRow("a", kind: .external)) == .external)
        #expect(SessionIconRules.iconKind(overviewRow("a", state: .parked)) == .parked)
        #expect(
            SessionIconRules.iconKind(overviewRow("a", kind: .external, state: .parked)) == .parked)
    }

    // The app that shows a row. A chat window of Bifrost comes before a terminal app, an owned
    // row that nothing shows is Bifrost, and a parked row has no app.
    @Test func theHolderIsTheChatOfBifrostThenTheTerminalApp() {
        let warp = TerminalApp(name: "Warp", bundle: "/Applications/Warp.app")
        let owned = overviewRow("a", kind: .owned)
        let external = overviewRow("b", kind: .external)
        let parked = overviewRow("c", state: .parked)
        #expect(SessionIconRules.holder(owned, inChat: true, terminal: warp) == .bifrost)
        #expect(SessionIconRules.holder(owned, inChat: true, terminal: nil) == .bifrost)
        #expect(SessionIconRules.holder(owned, inChat: false, terminal: warp) == .terminal(warp))
        #expect(SessionIconRules.holder(owned, inChat: false, terminal: nil) == .bifrost)
        #expect(
            SessionIconRules.holder(external, inChat: false, terminal: warp) == .terminal(warp))
        #expect(SessionIconRules.holder(external, inChat: false, terminal: nil) == nil)
        #expect(SessionIconRules.holder(parked, inChat: true, terminal: warp) == nil)
        #expect(SessionIconRules.holder(parked, inChat: false, terminal: warp) == nil)
    }
}
