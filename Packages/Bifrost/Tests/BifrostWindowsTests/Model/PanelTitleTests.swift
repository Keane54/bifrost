import BifrostLayout
import BifrostSessions
import BifrostTestSupport
import BifrostWindows
import Testing

// The title of each panel kind. A chat panel and a Show
// Info panel take the name of the row of their session.

private func panelID(_ raw: String) throws -> PanelID { try #require(PanelID(raw)) }

private let session = "5a0e0001-0000-4000-8000-000000000001"

private func row(_ name: String) -> SessionRow {
    SessionRow(
        sessionId: session, shortId: "5a0e0001", name: name, claudeName: "claude-name",
        kind: .owned, pid: nil, cwd: "/tmp", status: .idle, state: .idle, lastActivity: 0,
        startedAt: 0)
}

@Suite("panel title")
struct PanelTitleTests {
    @Test func eachFixedKindHasItsTitle() throws {
        let titles: [(String, String)] = [
            ("selected-item", "Selected Item"), ("settings", "Settings"),
            ("watchlist", "Watchlist"), ("event-log", "Event log"), ("usage-hud", "Usage HUD"),
            ("service-status", "Service status"), ("reviews", "Reviews"),
            ("performance", "Performance"), ("daily-update", "Daily update"),
            ("trust", "Trust a repository"), ("answer", "Answer Claude"),
            ("review-draft", "Review"), ("heimdall", "Heimdall"), ("module:abc:main", "Module"),
        ]
        for (raw, title) in titles {
            #expect(PanelTitle.of(try panelID(raw), rows: []) == title, "\(raw)")
        }
    }

    // overview:1 is the Overview. Another number names the Overview.
    @Test func anOverviewTitleHasItsNumberAfterTheFirst() throws {
        #expect(PanelTitle.of(try panelID("overview:1"), rows: []) == "Overview")
        #expect(PanelTitle.of(try panelID("overview:12"), rows: []) == "Overview 12")
        #expect(
            PanelTitle.of(try panelID("overview-settings:1"), rows: []) == "Overview Settings")
        #expect(
            PanelTitle.of(try panelID("overview-settings:3"), rows: []) == "Overview 3 Settings")
    }

    // A chat title is the name of its row, else "Chat". The first row of the session wins.
    @Test func aChatTitleIsTheNameOfItsRow() throws {
        let chat = try panelID("chat:\(session)")
        #expect(PanelTitle.of(chat, rows: []) == "Chat")
        #expect(PanelTitle.of(chat, rows: [row("alpha"), row("beta")]) == "alpha")
        let info = try panelID("show-info:\(session)")
        #expect(PanelTitle.of(info, rows: []) == "Show Info")
        #expect(PanelTitle.of(info, rows: [row("alpha")]) == "Show Info: alpha")
    }
}
