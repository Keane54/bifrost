import BifrostSessions
import BifrostTestSupport
import Testing

@testable import BifrostChat
@testable import BifrostLayout

// A session ID in upper case: claude agents --json gives it, and a chat panel holds it. The
// registry keeps the ID of the row in lower case, and the panel keeps its session ID in lower
// case. So the chat finds its row and attaches. The test uses the fake PTY of the fixture: no
// child process starts.
@Suite(
    "an upper-case session ID", .serialized, .testTimeLimit, .tags(.window))
@MainActor
struct UpperCaseSessionTests {
    @Test func aChatOfAnUpperCaseSessionIDOpensAndAttaches() async throws {
        let upper = FakeSession.first.uppercased()
        let short = FakeSession.shortId(FakeSession.first)
        let chat = try ChatFixture(
            rows: { home in
                let list = AgentList(output: 
                    """
                    [{"sessionId":"\(upper)","cwd":"\(home)","kind":"background","id":"\(short)",\
                    "status":"idle"}]
                    """)
                var registry = SessionRegistry(store: RegistryStore(), escalation: .seconds(600))
                registry.applyAgents(list.entries, sampledAt: 1)
                return registry.rows()
            }, fakePTY: true)
        #expect(chat.rows.map(\.sessionId) == [FakeSession.first])
        let panel = try #require(PanelID("chat:\(upper)"))
        chat.openPanel(panel, at: rect(0, 0, 640, 400))
        let terminal = try chat.terminal()
        await waitUntil { terminal.state.attached }
        let spawn = try #require(chat.fakes.spawns.first)
        #expect(spawn.arguments == ["attach", short])
        #expect(spawn.directory == chat.home)
        await chat.close()
    }
}
