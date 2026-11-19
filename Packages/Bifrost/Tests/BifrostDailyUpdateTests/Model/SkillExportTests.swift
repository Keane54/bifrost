import BifrostFoundation
import BifrostSessions
import Foundation
import Testing

@testable import BifrostDailyUpdate

// The settings that the skill reads when the user runs it by hand.
@Suite("the skill export")
struct SkillExportTests {
    @Test func theExportHoldsOnlyTheAreasThatAreOn() throws {
        var settings = boardSettings(areas: [
            WorkArea(id: "area-1", name: "Alpha", channel: "#alpha"),
            WorkArea(id: "area-2", on: false, name: "Off"),
        ])
        settings.you = "sam"
        settings.mergedPrs = false
        settings.model = .opus
        let export = SkillExport(settings)
        #expect(export.areas.map(\.id) == ["area-1"])
        #expect(export.source.server == "board")
        #expect(export.you == "sam")
        #expect(!export.mergedPrs)
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONFile.encode(export))
        let fields = try #require(json.object)
        // No time, no day, no model: only what the skill reads.
        #expect(Set(fields.keys) == ["version", "areas", "format", "mergedPrs", "source", "you"])
        #expect(fields["version"] == 1)
        let area = try #require(fields["areas"]?.array?.first?.object)
        #expect(Set(area.keys) == ["id", "on", "name", "channel", "description", "takesRest"])
    }

    // The user picked update_item, a write tool. The run never gets it, and the export does not
    // hold it either.
    @Test func aWriteToolIsNotExported() {
        let export = SkillExport(boardSettings())
        #expect(export.source.server == "board")
        #expect(export.source.tools == ["mcp__board__list_items", "mcp__board__get_item"])
    }

}
