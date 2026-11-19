import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostDailyUpdate

// The probe of the MCP servers with the fake claude: it prints the init event and then waits as
// a run that calls the model. The reader stops it after the event.
@MainActor
@Suite("the read of the MCP servers", .testTimeLimit, .tags(.realProcess))
struct InventoryReaderTests {
    @Test func theProbeGivesTheServersAndStops() async throws {
        let home = try RunHome()
        defer { home.finish() }
        let reader = InventoryReader(claude: home.claude)
        let found = await reader.read(in: home.folder.url)
        #expect(found == inventory)
        #expect(home.calls == [RunArgs.inventory().joined(separator: " ")])
    }

    @Test func aProbeWithNoInitEventGivesNothing() async throws {
        let home = try RunHome()
        defer { home.finish() }
        let initFile = home.folder.url.appending(path: "fake-mcp-init.json")
        try FileManager.default.removeItem(at: initFile)
        let reader = InventoryReader(claude: home.claude)
        #expect(await reader.read(in: home.folder.url) == nil)
    }
}
