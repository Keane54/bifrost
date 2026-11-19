import BifrostFoundation
import Foundation
import Testing

@testable import BifrostDailyUpdate

// The input file of a run: the fields that the skill bifrost-daily-update reads.
@Suite("the input of the run")
struct RunInputTests {
    @Test func theInputHasTheFieldsOfTheSkill() throws {
        var settings = boardSettings(areas: [
            WorkArea(id: "area-1", name: "Alpha", channel: "#alpha", description: "Payments"),
            WorkArea(id: "area-2", on: false, name: "Off"),
            WorkArea(id: "area-3", name: "Shield", takesRest: true),
        ])
        settings.you = "sam@example.com"
        let monday = moment(2026, 11, 16, 17, 0, in: calendar())
        var state = DailyState.empty
        state.lastSent["area-1"] = monday
        let input = RunInput(
            settings: settings, state: state, now: wednesday(9, 30), calendar: calendar(),
            prs: [], tools: ["mcp__board__list_items"])
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONFile.encode(input))
        let fields = try #require(json.object)
        let keys: Set = ["version", "now", "timeZone", "you", "areas", "format", "prs", "source"]
        #expect(Set(fields.keys) == keys)
        #expect(fields["version"] == 1)
        #expect(fields["now"] == "2026-11-18T09:30:00.000Z")
        #expect(fields["timeZone"] == "Europe/London")
        #expect(fields["you"] == "sam@example.com")
        #expect(fields["prs"] == [])
        #expect(fields["source"] == ["server": "board", "tools": ["mcp__board__list_items"]])
        let template = JSONValue.string(DailySettings.defaultTemplate)
        #expect(fields["format"] == ["template": template, "examples": []])
        // Only the areas that are on. An area with a send starts at it; another area starts at
        // the start of the last due day (Tuesday).
        #expect(
            fields["areas"] == [
                [
                    "id": "area-1", "name": "Alpha", "description": "Payments",
                    "takesRest": false, "since": "2026-11-16T17:00:00.000Z",
                ],
                [
                    "id": "area-3", "name": "Shield", "description": "", "takesRest": true,
                    "since": "2026-11-17T00:00:00.000Z",
                ],
            ])
        let tuesday = moment(2026, 11, 17, 0, 0, in: calendar())
        #expect(input.since == ["area-1": monday, "area-3": tuesday])
    }

    // With no source, the input has "server": null.
    @Test func noSourceGivesNull() throws {
        let input = runInput()
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONFile.encode(input))
        #expect(json.object?["source"] == ["server": .null, "tools": []])
    }

    @Test func thePRsStartAtTheEarliestArea() {
        var state = DailyState.empty
        let monday = moment(2026, 11, 16, 17, 0, in: calendar())
        state.lastSent["area-1"] = monday
        let two = settings(areas: [areaOne, WorkArea(id: "area-2", name: "Beta")])
        let since = RunInput.earliestSince(
            two, state: state, now: wednesday(9, 30), calendar: calendar())
        #expect(since == monday)
        let none = RunInput.earliestSince(
            settings(areas: []), state: state, now: wednesday(9, 30), calendar: calendar())
        #expect(none == wednesday(9, 30))
    }
}
