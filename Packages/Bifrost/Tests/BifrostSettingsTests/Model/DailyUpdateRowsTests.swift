// The rows of Settings > Daily update and the rules of the section
// (docs/behaviour/daily-update.md, "Settings > Daily update").
import BifrostDailyUpdate
import Foundation
import Testing

@testable import BifrostSettings

private let boardTools = [
    "mcp__board__list_items", "mcp__board__get_item", "mcp__board__update_item",
    "mcp__board__work_items_mark_comment_read", "mcp__board__summary",
]

@Suite("the rows of Settings > Daily update")
struct DailyUpdateRowsTests {
    @Test func eachRowHasItsLabelInOrder() {
        #expect(
            DailyUpdateRow.allCases.map(\.rawValue) == [
                "Ticket source", "Tools the run can use", "You on the board", "Use merged PRs",
                "Draft and first reminder", "Deadline", "Days", "Model", "Format",
                "Examples of your updates", "Work areas", "Daily update panel",
            ])
    }

    @Test(arguments: DailyUpdateRow.allCases)
    func theSearchFindsEachRow(_ row: DailyUpdateRow) {
        let index = SettingsSearch.index(
            general: [], slash: [], keys: [], live: [], skills: [],
            dailyUpdate: DailyUpdateRow.allCases, shown: [.dailyUpdate])
        #expect(index.map(\.id) == [.dailyUpdate])
        let hits = SettingsSearch.search(row.rawValue, index)
        #expect(hits?.first?.rows.contains(row.rawValue) == true)
    }

    @Test func theTitleOfTheSectionFindsAllRows() {
        let index = SettingsSearch.index(
            general: [], slash: [], keys: [], live: [], skills: [],
            dailyUpdate: DailyUpdateRow.allCases, shown: [.dailyUpdate])
        let hit = SettingsSearch.search("daily update", index)?.first
        #expect(hit?.whole == true)
        #expect(hit?.rows == DailyUpdateRow.allCases.map(\.rawValue))
    }

    @Test func eachReasonSaysWhatIsWrong() {
        var settings = DailySettings.defaults
        #expect(DailyUpdateRows.reason(settings) == nil)
        settings.deadline = ClockTime(hour: 9, minute: 35)
        #expect(DailyUpdateRows.reason(settings) == DailyUpdateRows.gapReason)
        settings = .defaults
        settings.days = []
        #expect(DailyUpdateRows.reason(settings) == "Pick at least one day.")
        settings = .defaults
        settings.format.template = ""
        #expect(DailyUpdateRows.reason(settings) == DailyUpdateRows.formatReason)
        settings = .defaults
        settings.areas = [WorkArea(id: "a1", name: "")]
        #expect(DailyUpdateRows.reason(settings) == "Each work area needs a name.")
        settings.areas = [WorkArea(id: "a1", name: String(repeating: "n", count: 61))]
        #expect(DailyUpdateRows.reason(settings) == DailyUpdateRows.nameReason)
        settings.areas = [
            WorkArea(id: "a1", name: "One", takesRest: true),
            WorkArea(id: "a2", name: "Two", takesRest: true),
        ]
        #expect(DailyUpdateRows.reason(settings) == DailyUpdateRows.restReason)
    }

    // Every server is a choice, also a Slack server (user decision, 2026-11-18). A server that is
    // not connected shows its status and is off.
    @Test func everyServerIsAChoice() {
        let inventory = MCPInventory(
            servers: [
                MCPServer(name: "board", status: "connected"),
                MCPServer(name: "plugin:slack:slack", status: "connected"),
                MCPServer(name: "claude.ai Claude Docs", status: "needs-auth"),
            ], tools: [])
        let choices = DailyUpdateRows.serverChoices(inventory)
        #expect(choices.map(\.name) == ["board", "plugin:slack:slack", "claude.ai Claude Docs"])
        #expect(choices.map(\.enabled) == [true, true, false])
        #expect(choices[2].label == "claude.ai Claude Docs (needs sign-in)")
    }

    // A read tool is proposed. A tool with a write word is never ticked and has its note, also
    // with a read word in its name.
    @Test func theToolsHaveTheirNotes() {
        let inventory = MCPInventory(
            servers: [MCPServer(name: "board", status: "connected", tools: boardTools)],
            tools: boardTools)
        let source = DailySource(
            server: "board", tools: ["mcp__board__list_items", "mcp__board__update_item"])
        let rows = DailyUpdateRows.toolRows(inventory, source, proposal: nil)
        #expect(rows.map(\.name) == [
            "list_items", "get_item", "update_item", "work_items_mark_comment_read", "summary",
        ])
        #expect(rows.map(\.on) == [true, false, false, false, false])
        #expect(rows.map(\.note) == [
            nil, nil, DailyUpdateRows.neverUsed, DailyUpdateRows.neverUsed,
            DailyUpdateRows.mayChange,
        ])
        // A proposal of the source gives the ticks.
        let proposal = ToolProposalDraft(server: "board", tools: ["mcp__board__get_item"])
        let proposed = DailyUpdateRows.toolRows(inventory, source, proposal: proposal)
        #expect(proposed.map(\.on) == [false, true, false, false, false])
    }

    // Each example box keeps its ID with its example, also after a remove. A list with another
    // count than the IDs gives new boxes, so no box keeps the text of another example.
    @Test func eachExampleBoxKeepsItsIdentity() {
        let ids = [UUID(), UUID(), UUID()]
        let items = DailyUpdateRows.exampleItems(["a", "b", "c"], ids: ids)
        #expect(items.map(\.id) == ids.map(\.uuidString))
        #expect(items.map(\.index) == [0, 1, 2])
        let removed = DailyUpdateRows.exampleItems(["a", "c"], ids: [ids[0], ids[2]])
        #expect(removed.map(\.id) == [ids[0].uuidString, ids[2].uuidString])
        #expect(removed.map(\.index) == [0, 1])
        #expect(removed.map(\.text) == ["a", "c"])
        let other = DailyUpdateRows.exampleItems(["a", "c"], ids: ids)
        #expect(Set(other.map(\.id)).isDisjoint(with: ids.map(\.uuidString)))
    }

    @Test func aNewAreaGetsAFreeName() {
        let areas = [WorkArea(id: "a1", name: "Work area 2")]
        let area = DailyUpdateRows.newArea(after: areas, id: "new")
        #expect(area.name == "Work area 3")
        #expect(area.on)
        #expect(!area.takesRest)
    }
}
