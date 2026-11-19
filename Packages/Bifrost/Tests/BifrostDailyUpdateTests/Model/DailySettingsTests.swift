import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostDailyUpdate

// The settings block (docs/behaviour/daily-update.md, "The settings").
@Suite("the Daily update settings", .timeLimit(.minutes(1)))
struct DailySettingsTests {
    private func read(_ value: JSONValue) -> DailySettings {
        DailySettings(json: value) ?? .defaults
    }

    @Test func theElectronBlockOpensWithEveryValue() throws {
        let json = try fixtureJSON("settings-block.json")
        let block = try #require(DailySettings(json: json))
        #expect(
            block.source
                == DailySource(
                    server: "board-one",
                    tools: ["mcp__board-one__list_items", "mcp__board-one__get_item"]))
        #expect(block.you == "person@example.test")
        #expect(!block.mergedPrs)
        #expect(block.draftTime == ClockTime(hour: 8, minute: 45))
        #expect(block.deadline == ClockTime(hour: 11, minute: 15))
        #expect(block.days == [1, 3, 5])
        #expect(block.model == .sonnet)
        #expect(block.format.template == "**Update**\n**Done**\n**Next**")
        #expect(block.format.examples == ["Example one", "Example two"])
        #expect(block.areas.map(\.id) == ["area-1", "area-2"])
        #expect(
            block.areas[0]
                == WorkArea(
                    id: "area-1", on: true, name: "Alpha", channel: "team-alpha",
                    description: "Work on the alpha project.", takesRest: false))
        #expect(block.areas[1].takesRest)
        #expect(!block.areas[1].on)
        #expect(block.unknown.values["futureField"] != nil)
        #expect(block.isValid)
        // The save gives the same block, with the unknown field and "server": null kept.
        let saved = try JSONDecoder().decode(
            JSONValue.self, from: JSONEncoder().encode(block))
        #expect(saved == json)
    }

    @Test func theDefaultsNameNoBoardNoCompanyAndNoPerson() throws {
        let defaults = DailySettings.defaults
        #expect(defaults.source == DailySource(server: nil, tools: []))
        #expect(defaults.you.isEmpty)
        #expect(defaults.areas.isEmpty)
        #expect(defaults.days == [1, 2, 3, 4, 5])
        #expect(defaults.draftTime.text == "09:30")
        #expect(defaults.deadline.text == "10:00")
        #expect(defaults.model == .standard)
        #expect(defaults.format.template.hasPrefix("**Daily update**"))
        #expect(defaults.isValid)
        let saved = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(defaults))
        #expect(saved.fields?["source"] == ["server": .null, "tools": []])
        #expect(saved.fields?["days"] == [1, 2, 3, 4, 5])
    }

    @Test func aBadFieldCostsOnlyThatField() {
        let block = read([
            "you": 5, "mergedPrs": "yes", "draftTime": "9:30", "deadline": "10:30",
            "days": [1, 9], "model": "fable", "source": ["server": 3, "tools": ["x"]],
            "format": ["template": "", "examples": "no"], "areas": "none",
        ])
        var expected = DailySettings.defaults
        expected.deadline = ClockTime(hour: 10, minute: 30)
        #expect(block == expected)
        // The good fields next to the bad ones stay.
        let mixed = read(["you": "me", "days": [], "model": "haiku", "draftTime": "07:00"])
        #expect(mixed.you == "me")
        #expect(mixed.model == .haiku)
        #expect(mixed.days == DailySettings.defaults.days)
        #expect(mixed.draftTime == ClockTime(hour: 7, minute: 0))
    }

    @Test func aDeadlineTooNearTheDraftTimeGivesBothTheirDefaults() {
        let block = read(["draftTime": "08:00", "deadline": "08:09"])
        #expect(block.draftTime == DailySettings.defaults.draftTime)
        #expect(block.deadline == DailySettings.defaults.deadline)
        #expect(read(["draftTime": "08:00", "deadline": "08:10"]).deadline.text == "08:10")
    }

    @Test func aToolListWithABadToolIsDropped() {
        let good = "mcp__board-one__list_items"
        func tools(_ list: [JSONValue], server: String = "board-one") -> [String] {
            read(["source": ["server": .string(server), "tools": .array(list)]]).source.tools
        }
        #expect(tools([.string(good)]) == [good])
        #expect(tools([.string(good), "mcp__other__get"]).isEmpty)
        #expect(tools([.string(good), "mcp__board-one__"]).isEmpty)
        #expect(tools([.string(good), 4]).isEmpty)
        // The prefix follows the name rule: each other character becomes an underscore.
        #expect(DailySource.toolPrefix(of: "my board.1") == "mcp__my_board_1__")
        #expect(tools(["mcp__my_board_1__get"], server: "my board.1") == ["mcp__my_board_1__get"])
        // The server stays when the tools are bad.
        #expect(
            read(["source": ["server": "board-one", "tools": [4]]]).source.server == "board-one")
    }

    @Test func atMostOneAreaTakesAllOtherWork() {
        func area(_ id: String, rest: Bool) -> JSONValue {
            [
                "id": .string(id), "on": true, "name": .string(id), "channel": "",
                "description": "",
                "takesRest": .bool(rest),
            ]
        }
        let block = read([
            "areas": [area("a", rest: true), area("b", rest: true), area("c", rest: false)]
        ])
        #expect(block.areas.map(\.takesRest) == [true, false, false])
        var edit = block
        edit.areas[1].takesRest = true
        #expect(!edit.isValid)
    }

    @Test func theAreasAndTheExamplesHaveTheirLimits() {
        let areas: [JSONValue] = (0..<12).map { index in
            [
                "id": .string("a\(index)"), "on": true, "name": "N", "channel": "",
                "description": "",
                "takesRest": false,
            ]
        }
        #expect(read(["areas": .array(areas)]).areas.count == 10)
        let repeated = [areas[0], areas[0]]
        #expect(read(["areas": .array(repeated)]).areas.count == 1)
        let noName: JSONValue = [
            "id": "x", "on": true, "name": "", "channel": "", "description": "",
            "takesRest": false,
        ]
        #expect(read(["areas": [noName]]).areas.isEmpty)
        #expect(
            read(["format": ["template": "t", "examples": ["a", "b", "c", "d"]]]).format.examples
                .isEmpty)
        var edit = DailySettings.defaults
        edit.format.examples = ["a", "b", "c", "d"]
        #expect(!edit.isValid)
    }

    @Test func aTimeIsTwoDigitsEach() {
        #expect(ClockTime("00:00") == ClockTime(hour: 0, minute: 0))
        #expect(ClockTime("23:59")?.minutes == 23 * 60 + 59)
        for text in ["24:00", "9:30", "09:60", "0930", "09:3", "aa:bb", "", "09:30:00", "٠٩:٣٠"] {
            #expect(ClockTime(text) == nil, "\(text)")
        }
        #expect(ClockTime(hour: 9, minute: 5).text == "09:05")
    }

    @Test func aBlockThatIsNotAnObjectIsNoBlock() {
        for value: JSONValue in [.null, 7, "x", [1]] {
            #expect(DailySettings(json: value) == nil)
        }
    }
}
