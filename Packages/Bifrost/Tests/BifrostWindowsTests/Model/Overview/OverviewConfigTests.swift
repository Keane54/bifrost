import BifrostFoundation
import BifrostSessions
import BifrostWindows
import Foundation
import Testing

// The config of one Overview: the standard config, the parse of a saved config, its JSON form and
// the actions (the sections "Tabs and columns" and "The saved config" of
// docs/behaviour/overview.md).

private let standard = OverviewConfig.standard

private func parse(_ value: JSONValue) throws -> OverviewConfig {
    try #require(OverviewConfig.parse(value))
}

// The config after the actions, in order.
private func applying(_ actions: OverviewAction..., to start: OverviewConfig = standard)
    -> OverviewConfig
{
    var config = start
    for action in actions { config.apply(action) }
    return config
}

private func tab(_ config: OverviewConfig, _ id: String) throws -> OverviewTab {
    try #require(config.tabs.first { $0.id == id })
}

private func tabIDs(_ config: OverviewConfig) -> [String] { config.tabs.map(\.id) }

// True when the action would change the config. The config itself does not change.
private func wouldChange(_ config: OverviewConfig, _ action: OverviewAction) -> Bool {
    var copy = config
    return copy.apply(action)
}

// The saved form of a tab with an ID and a name, and the other fields.
private func savedTab(_ id: String, _ name: String, _ fields: [String: JSONValue] = [:])
    -> JSONValue
{
    .object(fields.merging(["id": .string(id), "name": .string(name)]) { _, new in new })
}

private func columnTexts(_ columns: [OverviewColumn]) -> String {
    columns.map(\.rawValue).joined(separator: ",")
}

private let liveStates: [SessionState] = [.working, .needsYou, .error, .idle]

@Suite("overview config")
struct OverviewConfigTests {
    // MARK: - The columns

    @Test func theColumnsHaveTheirLabelsWidthsAndFirstSortDirection() {
        #expect(
            OverviewColumn.allCases.map(\.label) == [
                "", "Name", "Priority", "State", "Project", "Branch", "Model", "Context %", "Cost",
                "Activity",
            ])
        #expect(
            OverviewColumn.allCases.map(\.defaultWidth) == [
                28, 184, 76, 84, 200, 130, 90, 84, 68, 112,
            ])
        #expect(
            OverviewColumn.allCases.filter(\.sortsDescendingFirst) == [.context, .cost, .activity])
        #expect(OverviewColumn.defaultVisible == [.kind, .name, .state, .project, .activity])
        #expect(OverviewColumn.minWidth == 24)
        #expect(OverviewColumn.maxWidth == 600)
    }

    @Test func theTableColumnsAreTheVisibleColumnsInTabOrderWithTheirWidths() {
        var custom = standard.tabs[0]
        custom.columns = [.kind, .state, .name]
        custom.widths = [.name: 200]
        #expect(custom.tableColumns.map { $0.column } == [.kind, .state, .name])
        #expect(custom.tableColumns.map { $0.width } == [28, 84, 200])
        let plain = standard.tabs[0]
        #expect(plain.tableColumns.map { $0.column } == [.kind, .name, .state, .project, .activity])
        #expect(plain.tableColumns.map { $0.width } == [28, 184, 84, 200, 112])
    }

    // MARK: - The standard config

    @Test func theStandardConfigHasSixTabsWithTheWatchedTabThird() throws {
        #expect(standard.name == "Default")
        #expect(standard.active == "t1")
        #expect(standard.nextTab == 6)
        #expect(tabIDs(standard) == ["t1", "t2", "t0", "t3", "t4", "t5"])
        #expect(
            standard.tabs.map(\.name) == ["All", "Alerts", "Watched", "Working", "Idle", "Parked"])
        #expect(standard.tabs.map(\.colour) == [0, 1, 5, 2, 3, 4])
        #expect(standard.tabs.map(\.filter.boxOnly) == [false, true, false, false, false, false])
        #expect(
            standard.tabs.map(\.filter.watchedOnly) == [false, false, true, false, false, false])
        #expect(
            standard.tabs.map(\.filter.states) == [
                liveStates, liveStates, TabFilter.allStates, [.working], [.idle], [.parked],
            ])
        for tab in standard.tabs {
            #expect(tab.columns == OverviewColumn.defaultVisible, "\(tab.id)")
            #expect(tab.order == OverviewColumn.allCases, "\(tab.id)")
            #expect(tab.filter.kinds == [.owned, .external], "\(tab.id)")
            #expect(tab.widths.isEmpty, "\(tab.id)")
            #expect(tab.sort == SortSpec(column: .name, descending: false), "\(tab.id)")
        }
        #expect(standard.activeTab.id == "t1")
    }

    @Test func theActiveTabIsTheTabWithTheActiveID() throws {
        let config = try parse([
            "active": "t2", "tabs": [savedTab("t1", "A"), savedTab("t2", "B")],
        ])
        #expect(config.activeTab.id == "t2")
        #expect(applying(.activate("t0")).activeTab.id == "t0")
    }

    // MARK: - The saved config

    @Test func theStandardConfigParsesBackUnchanged() throws {
        #expect(try parse(standard.json) == standard)
        let text = try JSONFile.encode(standard.json)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: text)
        #expect(try parse(decoded) == standard)
    }

    @Test func aChangedConfigParsesBackUnchanged() throws {
        let changed = applying(
            .addTab, .renameTab("t6", name: "Mine"), .toggleColumn("t6", .cost),
            .moveColumn("t6", .cost, before: .name), .sortBy("t6", .cost),
            .setWidths("t6", [.cost: 90.4, .name: 150]), .setTabColour("t6", 11),
            .setFilter(
                "t6",
                TabFilter(states: [.parked, .idle], kinds: [.external], boxOnly: true,
                    watchedOnly: true)),
            .moveTab("t6", by: -1), .rename("Work"))
        #expect(try parse(changed.json) == changed)
    }

    @Test func theSavedFormHasTheFieldNamesOfTheFile() throws {
        guard case .object(let fields) = standard.json else {
            Issue.record("The JSON form is not an object.")
            return
        }
        #expect(Set(fields.keys) == ["active", "name", "nextTab", "tabs"])
        guard case .array(let tabs) = fields["tabs"], case .object(let first) = tabs.first else {
            Issue.record("The tabs are not a list of objects.")
            return
        }
        #expect(
            Set(first.keys) == [
                "color", "columns", "filter", "id", "name", "order", "sort", "widths",
            ])
        #expect(
            first["filter"] == [
                "boxOnly": false, "kinds": ["owned", "external"],
                "states": ["working", "needs-you", "error", "idle"], "watchedOnly": false,
            ])
        #expect(first["sort"] == ["column": "name", "desc": false])
        #expect(first["color"] == 0)
    }

    // The states and the kinds have no text of their own. The config gives each one its text in
    // the file.
    @Test func eachStateAndKindHasItsTextInTheFile() throws {
        #expect(
            TabFilter.allStates.map { OverviewConfig.fileText($0) } == [
                "working", "needs-you", "error", "idle", "parked",
            ])
        #expect(TabFilter.allKinds.map { OverviewConfig.fileText($0) } == ["owned", "external"])
        let saved = savedTab(
            "t1", "A",
            [
                "filter": [
                    "states": ["parked", "idle", "error", "needs-you", "working"],
                    "kinds": ["external", "owned"],
                ]
            ])
        let filter = try tab(try parse(["tabs": [saved]]), "t1").filter
        #expect(filter.states == [.parked, .idle, .error, .needsYou, .working])
        #expect(filter.kinds == [.external, .owned])
    }

    @Test func theWidthsEncodeWithSortedKeys() throws {
        let one = applying(.setWidths("t1", [.project: 150]), .setWidths("t1", [.name: 230]),
            .setWidths("t1", [.cost: 70]))
        let two = applying(.setWidths("t1", [.cost: 70, .name: 230, .project: 150]))
        let textOne = try JSONFile.encode(one.json)
        #expect(textOne == (try JSONFile.encode(two.json)))
        let text = String(decoding: textOne, as: UTF8.self)
        let cost = try #require(text.range(of: "\"cost\" : 70"))
        let name = try #require(text.range(of: "\"name\" : 230"))
        let project = try #require(text.range(of: "\"project\" : 150"))
        #expect(cost.lowerBound < name.lowerBound)
        #expect(name.lowerBound < project.lowerBound)
    }

    @Test func parseRefusesBadDataAndAConfigWithNoGoodTab() {
        let bad: [JSONValue?] = [
            nil, .null, [], "x", ["tabs": []], ["tabs": [[:]]], ["tabs": "x"],
            ["tabs": [savedTab("t12345", "A")]],
        ]
        for value in bad {
            #expect(OverviewConfig.parse(value) == nil, "\(String(describing: value))")
        }
    }

    @Test func parseDropsARepeatedIDABadNameAndUnknownColumns() throws {
        let config = try parse([
            "tabs": [
                savedTab("t1", " A ", ["columns": ["name", "kind", "foo", "name", 3]]),
                savedTab("t1", "Again"),
                savedTab("t2", ""),
                savedTab("t3", String(repeating: "x", count: 25)),
                savedTab("x4", "Bad ID"),
                savedTab("t05", "Five"),
                ["id": "t6", "name": 6],
                ["id": "t8\n", "name": "Line break"],
                savedTab("t7", "Seven"),
            ]
        ])
        #expect(config.tabs.map(\.id) == ["t1", "t05", "t7"])
        #expect(config.tabs.map(\.name) == ["A", "Five", "Seven"])
        #expect(try tab(config, "t1").columns == [.kind, .name])
        #expect(config.name == "Default")
        #expect(config.nextTab == 8)
        // A tab with no saved colour takes the colour of its place.
        #expect(config.tabs.map(\.colour) == [0, 1, 2])
    }

    // A tab name counts Characters: an emoji or a letter with a combining mark counts one.
    @Test func aTabNameCountsCharacters() throws {
        let fits = String(repeating: "😀", count: 24)
        let long = String(repeating: "😀", count: 25)
        let accents = String(repeating: "e\u{301}", count: 24)
        let config = try parse([
            "tabs": [savedTab("t1", fits), savedTab("t2", long), savedTab("t3", accents)]
        ])
        #expect(tabIDs(config) == ["t1", "t3"])
        #expect(config.tabs.first?.name == fits)
        #expect(applying(.renameTab("t1", name: long)) == standard)
        #expect(try tab(applying(.renameTab("t1", name: fits)), "t1").name == fits)
    }

    @Test func theSetNameCountsCharacters() throws {
        let forty = String(repeating: "😀", count: 40)
        let more = String(repeating: "😀", count: 41)
        let tabs: JSONValue = [savedTab("t1", "A")]
        #expect(try parse(["name": .string(forty), "tabs": tabs]).name == forty)
        #expect(try parse(["name": .string(more), "tabs": tabs]).name == "Default")
        #expect(applying(.rename(more)) == standard)
        #expect(applying(.rename(forty)).name == forty)
    }

    @Test func parseRenamesOnlyTabT2NamedNeedsYou() throws {
        func names(_ t2: String, _ t7: String) throws -> [String] {
            try parse([
                "nextTab": 8,
                "tabs": [savedTab("t1", "All"), savedTab("t2", t2), savedTab("t7", t7)],
            ]).tabs.map(\.name)
        }
        #expect(try names("Needs you", "Needs you") == ["All", "Alerts", "Needs you"])
        #expect(try names("My alerts", "x") == ["All", "My alerts", "x"])
        #expect(try names("needs you", "x") == ["All", "needs you", "x"])
    }

    @Test func parseClampsTheWidthsAndFixesABadSortAndABadActiveTab() throws {
        let config = try parse([
            "active": "t99",
            "tabs": [
                savedTab(
                    "t1", "A",
                    [
                        "sort": ["column": "foo", "desc": true],
                        "widths": [
                            "cost": 33.6, "foo": 5, "name": 9999, "state": 5, "kind": "x",
                            "project": 40.5,
                        ],
                    ])
            ],
        ])
        let first = try tab(config, "t1")
        #expect(first.widths == [.cost: 34, .name: 600, .state: 24, .project: 41])
        #expect(first.sort == SortSpec(column: .name, descending: false))
        #expect(config.active == "t1")
    }

    @Test func parseKeepsAGoodSortAndAGoodActiveTab() throws {
        let config = try parse([
            "active": "t2",
            "tabs": [
                savedTab("t1", "A"),
                savedTab("t2", "B", ["sort": ["column": "state", "desc": true]]),
                savedTab("t3", "C", ["sort": ["column": "state", "desc": "yes"]]),
            ],
        ])
        #expect(config.active == "t2")
        #expect(try tab(config, "t2").sort == SortSpec(column: .state, descending: true))
        #expect(try tab(config, "t3").sort == SortSpec(column: .state, descending: false))
    }

    @Test func parseKeepsTheFirst12Tabs() throws {
        let tabs = (1...15).map { savedTab("t\($0)", "T\($0)") }
        let config = try parse(["tabs": .array(tabs)])
        #expect(config.tabs.count == 12)
        #expect(config.nextTab == 13)
    }

    @Test func parseBoundsTheNextTabNumberAndNeverRepeatsATabID() throws {
        let tabs: JSONValue = [savedTab("t1", "A")]
        let bad: [JSONValue] = [1e21, .int(1 << 53), -1, 1.5, "9", 0, 10000, .null]
        for nextTab in bad {
            #expect(try parse(["nextTab": nextTab, "tabs": tabs]).nextTab == 2, "\(nextTab)")
        }
        #expect(try parse(["nextTab": 40, "tabs": tabs]).nextTab == 40)
        #expect(try parse(["nextTab": 40.0, "tabs": tabs]).nextTab == 40)
        var last = try parse(["nextTab": 9999, "tabs": tabs])
        let changed = last.apply(.addTab)
        #expect(changed)
        #expect(tabIDs(last) == ["t1", "t9999"])
        #expect(wouldChange(last, .addTab) == false)
        // After a saved tab t9999 no tab can be added.
        let highest = try parse(["tabs": [savedTab("t1", "A"), savedTab("t9999", "Z")]])
        #expect(highest.nextTab == 10000)
        #expect(wouldChange(highest, .addTab) == false)
    }

    @Test func parseGivesTheDefaultColumnsForAMissingOrDamagedList() throws {
        let config = try parse([
            "tabs": [savedTab("t1", "A"), savedTab("t2", "B", ["columns": "name"])]
        ])
        let defaults = OverviewColumn.defaultVisible
        #expect(config.tabs.map(\.columns) == [defaults, defaults])
        #expect(config.tabs.map(\.order) == [OverviewColumn.allCases, OverviewColumn.allCases])
    }

    // A tab from before the column order keeps its columns: they come first in their order, and
    // the hidden columns follow in the default order.
    @Test func aTabWithNoSavedOrderKeepsItsColumns() throws {
        let config = try parse([
            "tabs": [
                savedTab(
                    "t1", "All",
                    ["columns": .array(OverviewColumn.allCases.map { .string($0.rawValue) })]),
                savedTab("t2", "B", ["columns": ["kind", "cost", "name"]]),
            ]
        ])
        #expect(try tab(config, "t1").columns == OverviewColumn.allCases)
        #expect(try tab(config, "t1").order == OverviewColumn.allCases)
        #expect(try tab(config, "t2").columns == [.kind, .cost, .name])
        #expect(
            columnTexts(try tab(config, "t2").order)
                == "kind,cost,name,priority,state,project,branch,model,context,activity")
    }

    @Test func parseKeepsThePlacesOfHiddenColumnsAndAddsMissingColumns() throws {
        let config = try parse([
            "tabs": [
                savedTab(
                    "t1", "A",
                    [
                        "columns": ["kind", "name", "cost"],
                        "order": ["cost", "kind", "branch", "name", "foo", "name"],
                    ])
            ]
        ])
        let first = try tab(config, "t1")
        #expect(
            columnTexts(first.order)
                == "kind,cost,branch,name,priority,state,project,model,context,activity")
        // The visible columns follow the saved order.
        #expect(first.columns == [.kind, .cost, .name])
    }

    @Test func parseMovesTheSortOfASavedTabOffAHiddenColumn() throws {
        let config = try parse([
            "tabs": [
                savedTab(
                    "t1", "A",
                    ["columns": ["kind", "name", "state"], "sort": ["column": "cost", "desc": true]]
                ),
                savedTab(
                    "t2", "B",
                    [
                        "columns": ["kind", "state", "project"],
                        "sort": ["column": "name", "desc": true],
                    ]),
                savedTab(
                    "t3", "C", ["columns": ["kind"], "sort": ["column": "state", "desc": true]]),
                savedTab(
                    "t4", "D",
                    ["columns": ["kind", "cost"], "sort": ["column": "cost", "desc": true]]),
            ]
        ])
        #expect(
            config.tabs.map(\.sort) == [
                SortSpec(column: .name, descending: false),
                SortSpec(column: .state, descending: false),
                SortSpec(column: .kind, descending: false),
                SortSpec(column: .cost, descending: true),
            ])
    }

    @Test func parseReadsWatchedOnlyAndGivesFalseForAnOldFilter() throws {
        func watchedOnly(_ filter: JSONValue?) throws -> Bool {
            let saved = savedTab("t1", "A", filter.map { ["filter": $0] } ?? [:])
            return try tab(try parse(["tabs": [saved]]), "t1").filter.watchedOnly
        }
        #expect(
            try watchedOnly([
                "boxOnly": false, "kinds": ["owned"], "states": ["idle"], "watchedOnly": true,
            ]))
        #expect(
            try watchedOnly(["boxOnly": false, "kinds": ["owned"], "states": ["idle"]]) == false)
        #expect(try watchedOnly(["watchedOnly": "yes"]) == false)
        #expect(try watchedOnly(nil) == false)
        #expect(try watchedOnly("x") == false)
    }

    @Test func parseGivesBothKindsToAFilterWithNoKindsAndDropsUnknownValues() throws {
        let config = try parse([
            "tabs": [
                savedTab("t1", "A", ["filter": ["states": ["idle"]]]),
                savedTab(
                    "t2", "B", ["filter": ["kinds": ["external", "x", "external"], "states": []]]),
                savedTab(
                    "t3", "C", ["filter": ["kinds": "owned", "states": "idle", "boxOnly": 1]]),
                savedTab(
                    "t4", "D",
                    [
                        "filter": [
                            "states": ["idle", "Idle", "idle", "needs-you", 2], "boxOnly": true,
                        ]
                    ]),
            ]
        ])
        let both: [SessionKind] = [.owned, .external]
        #expect(config.tabs.map(\.filter.kinds) == [both, [.external], both, both])
        #expect(config.tabs.map(\.filter.states) == [[.idle], [], [], [.idle, .needsYou]])
        #expect(config.tabs.map(\.filter.boxOnly) == [false, false, false, true])
    }

    @Test func parseKeepsASavedColourAndRefusesABadOne() throws {
        func colour(_ value: JSONValue, at index: Int) throws -> Int {
            let before = (0..<index).map { savedTab("t\($0 + 1)", "T\($0 + 1)") }
            let config = try parse([
                "active": "t1", "name": "X", "nextTab": 20,
                "tabs": .array(before + [savedTab("t19", "Last", ["color": value])]),
            ])
            return try tab(config, "t19").colour
        }
        #expect(OverviewConfig.tabColours == 12)
        for value in [0, 5, 11] {
            #expect(try colour(.int(value), at: 1) == value)
        }
        #expect(try colour(5.0, at: 1) == 5)
        let bad: [JSONValue] = [12, -1, 1.5, "3", .null]
        for value in bad {
            #expect(try colour(value, at: 8) == 8 % 6, "\(value)")
        }
    }

    @Test func aSavedConfigKeepsItsOwnTabs() throws {
        let config = try parse(["name": " Mine ", "tabs": [savedTab("t1", "One")]])
        #expect(config.tabs.map(\.name) == ["One"])
        #expect(config.name == "Mine")
    }

    // MARK: - The actions

    @Test func addTabAppendsTab6ActivatesItAndRefusesA13thTab() throws {
        var config = standard
        let changed = config.apply(.addTab)
        #expect(changed)
        let added = try tab(config, "t6")
        #expect(config.tabs.last?.id == "t6")
        #expect(added.name == "Tab 6")
        #expect(added.colour == 5)
        #expect(added.filter == standard.tabs[0].filter)
        #expect(added.columns == OverviewColumn.defaultVisible)
        #expect(config.active == "t6")
        #expect(config.nextTab == 7)
        for _ in 0..<5 { config.apply(.addTab) }
        #expect(config.tabs.count == 12)
        let full = config
        #expect(wouldChange(config, .addTab) == false)
        #expect(config == full)
    }

    @Test func addTabCyclesThroughTheFirstSixColours() throws {
        for (next, colours) in [(7, [0, 1, 2]), (13, [0, 1, 2])] {
            var config = try parse(["nextTab": .int(next), "tabs": [savedTab("t1", "All")]])
            for _ in 0..<3 { config.apply(.addTab) }
            #expect(config.tabs.dropFirst().map(\.colour) == colours, "\(next)")
        }
        var config = try parse(["nextTab": 5, "tabs": [savedTab("t1", "All")]])
        for _ in 0..<3 { config.apply(.addTab) }
        #expect(config.tabs.dropFirst().map(\.colour) == [4, 5, 0])
    }

    // MARK: - The unknown fields

    // A saved config with fields of a later version: the config and each tab keep the fields
    // that this app does not know. The filter and the sort keep only their known fields.
    private static let future: JSONValue = [
        "active": "t1", "name": "Mine", "nextTab": 3, "layout": "grid", "pinned": [1, 2],
        "tabs": [
            [
                "id": "t1", "name": "A", "icon": "star",
                "filter": ["states": ["idle"], "match": "x"],
                "sort": ["column": "name", "desc": false, "then": "cost"],
            ],
            ["id": "t2", "name": "B"],
        ],
    ]

    @Test func unknownFieldsOfTheConfigAndOfATabSurviveAParseAndTheJSONForm() throws {
        let config = try parse(Self.future)
        #expect(config.unknown.values == ["layout": "grid", "pinned": [1, 2]])
        #expect(try tab(config, "t1").unknown.values == ["icon": "star"])
        #expect(try tab(config, "t2").unknown.values.isEmpty)
        #expect(try parse(config.json) == config)
        let json = try #require(config.json.object)
        #expect(json["layout"] == "grid")
        let first = try #require(json["tabs"]?.array?.first?.object)
        #expect(first["icon"] == "star")
        #expect(first["filter"]?.object?["match"] == nil)
        #expect(first["sort"]?.object?["then"] == nil)
    }

    @Test func aKnownKeyNeverComesFromTheUnknownFields() throws {
        var config = try parse(Self.future)
        config.unknown = UnknownFields(["name": "Other", "tabs": [], "layout": "grid"])
        let json = try #require(config.json.object)
        #expect(json["name"] == "Mine")
        #expect(json["tabs"]?.array?.count == 2)
        #expect(json["layout"] == "grid")
        // The parse never puts a known key into the unknown fields.
        let parsed = try parse(Self.future)
        #expect(Set(parsed.unknown.values.keys) == ["layout", "pinned"])
        #expect(Set(try tab(parsed, "t1").unknown.values.keys) == ["icon"])
    }

    @Test func theActionsKeepTheUnknownFieldsOfATab() throws {
        let start = try parse(Self.future)
        let changed = applying(
            .toggleColumn("t1", .cost), .setWidths("t1", [.name: 200]), .resetTab("t1"),
            .moveTab("t1", by: 1), .renameTab("t1", name: "New"), to: start)
        #expect(tabIDs(changed) == ["t2", "t1"])
        #expect(try tab(changed, "t1").unknown.values == ["icon": "star"])
        #expect(changed.unknown == start.unknown)
        let added = applying(.addTab, to: start)
        #expect(try tab(added, "t3").unknown.values.isEmpty)
    }

    @Test func removeTabActivatesTheTabToTheLeftAndRefusesTheLastTab() throws {
        var config = applying(.activate("t3"), .removeTab("t3"))
        #expect(tabIDs(config) == ["t1", "t2", "t0", "t4", "t5"])
        #expect(config.active == "t0")
        config.apply(.activate("t1"))
        config.apply(.removeTab("t1"))
        #expect(config.active == "t2")
        // A tab that is not active goes, and the active tab stays.
        config.apply(.removeTab("t5"))
        #expect(config.active == "t2")
        let one = try parse(["tabs": [savedTab("t1", "A")]])
        #expect(wouldChange(one, .removeTab("t1")) == false)
        #expect(tabIDs(one) == ["t1"])
    }

    @Test func renameTabTrimsAndRefusesAnEmptyOrALongName() throws {
        #expect(try tab(applying(.renameTab("t2", name: "  Mine ")), "t2").name == "Mine")
        let config = standard
        #expect(wouldChange(config, .renameTab("t2", name: "  ")) == false)
        let long = String(repeating: "x", count: 25)
        #expect(wouldChange(config, .renameTab("t2", name: long)) == false)
        #expect(wouldChange(config, .renameTab("t2", name: " Alerts ")) == false)
    }

    @Test func moveTabSwapsWithTheNeighbourAndStopsAtTheEdge() {
        #expect(tabIDs(applying(.moveTab("t1", by: 1))) == ["t2", "t1", "t0", "t3", "t4", "t5"])
        #expect(tabIDs(applying(.moveTab("t0", by: -1))) == ["t1", "t0", "t2", "t3", "t4", "t5"])
        let config = standard
        #expect(wouldChange(config, .moveTab("t1", by: -1)) == false)
        #expect(wouldChange(config, .moveTab("t5", by: 1)) == false)
        #expect(wouldChange(config, .moveTab("t5", by: Int.max)) == false)
        #expect(wouldChange(config, .moveTab("nope", by: 1)) == false)
    }

    @Test func toggleColumnShowsAColumnAtItsPlaceHidesItAndNeverHidesKind() throws {
        let on = applying(.toggleColumn("t1", .cost))
        #expect(try tab(on, "t1").columns == [.kind, .name, .state, .project, .cost, .activity])
        let off = applying(.toggleColumn("t1", .cost), to: on)
        #expect(try tab(off, "t1").columns == standard.tabs[0].columns)
        #expect(try tab(off, "t1").order == standard.tabs[0].order)
        let config = standard
        #expect(wouldChange(config, .toggleColumn("t1", .kind)) == false)
        #expect(wouldChange(config, .toggleColumn("nope", .cost)) == false)
    }

    @Test func moveColumnMovesBeforeAColumnToTheEndAndNeverBeforeKind() throws {
        func columns(_ config: OverviewConfig) throws -> String {
            columnTexts(try tab(config, "t1").columns)
        }
        func order(_ config: OverviewConfig) throws -> String {
            columnTexts(try tab(config, "t1").order)
        }
        let first = applying(.moveColumn("t1", .activity, before: .name))
        #expect(try columns(first) == "kind,activity,name,state,project")
        #expect(
            try order(first)
                == "kind,activity,name,priority,state,project,branch,model,context,cost")
        let last = applying(.moveColumn("t1", .name, before: nil))
        #expect(try columns(last) == "kind,state,project,activity,name")
        let beforeKind = applying(.moveColumn("t1", .project, before: .kind))
        #expect(try columns(beforeKind) == "kind,project,name,state,activity")
        // A hidden column moves in the order only.
        let hidden = applying(.moveColumn("t1", .cost, before: .name))
        #expect(try columns(hidden) == (try columns(standard)))
        #expect(
            try order(hidden)
                == "kind,cost,name,priority,state,project,branch,model,context,activity")
        let config = standard
        #expect(wouldChange(config, .moveColumn("t1", .kind, before: .name)) == false)
        #expect(wouldChange(config, .moveColumn("t1", .name, before: .name)) == false)
        #expect(wouldChange(config, .moveColumn("t1", .name, before: .priority)) == false)
        #expect(wouldChange(config, .moveColumn("t1", .activity, before: nil)) == false)
    }

    @Test func sortByFlipsTheSameColumnAndStartsContextCostAndActivityDescending() throws {
        let shown = applying(.toggleColumn("t1", .cost), .toggleColumn("t1", .context))
        func sort(_ column: OverviewColumn) throws -> SortSpec {
            try tab(applying(.sortBy("t1", column), to: shown), "t1").sort
        }
        #expect(try sort(.name) == SortSpec(column: .name, descending: true))
        #expect(try sort(.cost) == SortSpec(column: .cost, descending: true))
        #expect(try sort(.context) == SortSpec(column: .context, descending: true))
        #expect(try sort(.activity) == SortSpec(column: .activity, descending: true))
        #expect(try sort(.state) == SortSpec(column: .state, descending: false))
        let twice = applying(.sortBy("t1", .cost), .sortBy("t1", .cost), to: shown)
        #expect(try tab(twice, "t1").sort == SortSpec(column: .cost, descending: false))
    }

    @Test func sortByRefusesAHiddenColumn() {
        let config = standard
        #expect(wouldChange(config, .sortBy("t1", .cost)) == false)
        #expect(wouldChange(config, .sortBy("nope", .name)) == false)
    }

    @Test func hidingTheSortColumnSortsByNameAscending() throws {
        let byState = applying(.sortBy("t1", .state), .sortBy("t1", .state))
        #expect(try tab(byState, "t1").sort == SortSpec(column: .state, descending: true))
        let hidden = applying(.toggleColumn("t1", .state), to: byState)
        #expect(try tab(hidden, "t1").sort == SortSpec(column: .name, descending: false))
        // A column that is not the sort column does not change the sort.
        let other = applying(.toggleColumn("t1", .project), to: byState)
        #expect(try tab(other, "t1").sort == SortSpec(column: .state, descending: true))
    }

    @Test func hidingNameWhileItSortsSortsByTheFirstVisibleColumnAfterKind() throws {
        let byName = applying(.sortBy("t1", .name))
        #expect(try tab(byName, "t1").sort == SortSpec(column: .name, descending: true))
        let hidden = try tab(applying(.toggleColumn("t1", .name), to: byName), "t1")
        #expect(hidden.columns == [.kind, .state, .project, .activity])
        #expect(hidden.sort == SortSpec(column: .state, descending: false))
    }

    @Test func aResetThatHidesTheSortColumnSortsByNameAscending() throws {
        let byCost = applying(.toggleColumn("t1", .cost), .sortBy("t1", .cost))
        #expect(try tab(byCost, "t1").sort == SortSpec(column: .cost, descending: true))
        let reset = try tab(applying(.resetTab("t1"), to: byCost), "t1")
        #expect(reset.columns.contains(.cost) == false)
        #expect(reset.sort == SortSpec(column: .name, descending: false))
    }

    @Test func aResetKeepsAVisibleSort() throws {
        let byState = applying(.sortBy("t1", .state), .toggleColumn("t1", .cost))
        let reset = try tab(applying(.resetTab("t1"), to: byState), "t1")
        #expect(reset.sort == SortSpec(column: .state, descending: false))
    }

    @Test func resetTabClearsTheWidthsOfItsTabOnly() throws {
        let widths = applying(.setWidths("t1", [.name: 207]), .setWidths("t2", [.project: 90]))
        let reset = applying(.resetTab("t1"), to: widths)
        #expect(try tab(reset, "t1").widths.isEmpty)
        #expect(try tab(reset, "t2") == (try tab(widths, "t2")))
    }

    @Test func resetTabRestoresTheDefaultColumnsAndFilter() throws {
        let config = standard
        #expect(wouldChange(config, .resetTab("t2")) == false)
        let changed = applying(
            .toggleColumn("t2", .cost), .moveColumn("t2", .branch, before: .name),
            .setFilter("t2", TabFilter(states: [], kinds: [], boxOnly: false, watchedOnly: false)))
        let reset = applying(.resetTab("t2"), to: changed)
        #expect(try tab(reset, "t2") == standard.tabs[1])
        // A tab that the user added gets the filter of All.
        let added = applying(
            .addTab, .setFilter("t6", TabFilter(states: [.parked], kinds: [.owned], boxOnly: true,
                watchedOnly: true)), .resetTab("t6"))
        #expect(try tab(added, "t6").filter == standard.tabs[0].filter)
    }

    @Test func resetTabKeepsTheColourAndTheName() throws {
        var reset = applying(
            .setTabColour("t1", 8), .renameTab("t1", name: "Mine"), .toggleColumn("t1", .cost))
        let changed = reset.apply(.resetTab("t1"))
        #expect(changed)
        #expect(try tab(reset, "t1").colour == 8)
        #expect(try tab(reset, "t1").name == "Mine")
        #expect(try tab(reset, "t1").columns == OverviewColumn.defaultVisible)
    }

    @Test func setWidthsChangesOnlyTheNamedColumnsAndClamps() throws {
        let config = applying(
            .setWidths("t1", [.name: 207, .project: 150]), .setWidths("t1", [.name: 230]))
        #expect(try tab(config, "t1").widths == [.name: 230, .project: 150])
        let clamped = applying(.setWidths("t1", [.cost: 1, .name: 700.4, .state: 84.5]))
        #expect(try tab(clamped, "t1").widths == [.cost: 24, .name: 600, .state: 85])
        let same = config
        #expect(wouldChange(same, .setWidths("t1", [.name: 229.6])) == false)
        #expect(wouldChange(same, .setWidths("t1", [.name: .nan, .cost: .infinity])) == false)
    }

    @Test func setFilterAndSetWidthsChangeOnlyTheNamedTab() throws {
        let filter = TabFilter(states: [.idle], kinds: [.owned], boxOnly: true, watchedOnly: false)
        let filtered = applying(.setFilter("t4", filter))
        #expect(try tab(filtered, "t4").filter == filter)
        #expect(try tab(filtered, "t1") == standard.tabs[0])
        let sized = applying(.setWidths("t2", [.cost: 1, .name: 700.4]), to: filtered)
        #expect(try tab(sized, "t2").widths == [.cost: 24, .name: 600])
        #expect(try tab(sized, "t4") == (try tab(filtered, "t4")))
    }

    @Test func setFilterKeepsWatchedOnlyAndASameFilterChangesNothing() throws {
        let watched = TabFilter(states: [.idle], kinds: [.owned], boxOnly: false, watchedOnly: true)
        #expect(try tab(applying(.setFilter("t4", watched)), "t4").filter.watchedOnly)
        var config = standard
        #expect(wouldChange(config, .setFilter("t2", standard.tabs[1].filter)) == false)
        // The order of the lists counts, as in the filter lists of the panel.
        var reordered = standard.tabs[1].filter
        reordered.kinds = [.external, .owned]
        let changed = config.apply(.setFilter("t2", reordered))
        #expect(changed)
    }

    @Test func setTabColourSetsTheColourOfOneTab() throws {
        var config = standard
        let changed = config.apply(.setTabColour("t2", 11))
        #expect(changed)
        #expect(config.tabs.map(\.colour) == [0, 11, 5, 2, 3, 4])
        #expect(wouldChange(config, .setTabColour("t2", 11)) == false)
    }

    @Test func setTabColourIgnoresABadColourOrAnUnknownTab() {
        let config = standard
        for colour in [12, -1, Int.max] {
            #expect(wouldChange(config, .setTabColour("t1", colour)) == false, "\(colour)")
        }
        #expect(wouldChange(config, .setTabColour("none", 3)) == false)
    }

    @Test func activateChangesTheActiveTabOnlyToAKnownOtherTab() {
        var config = standard
        #expect(wouldChange(config, .activate("nope")) == false)
        #expect(wouldChange(config, .activate("t1")) == false)
        let changed = config.apply(.activate("t0"))
        #expect(changed)
        #expect(config.active == "t0")
    }

    @Test func renameSetsTheTrimmedNameOfTheSet() {
        var config = standard
        #expect(wouldChange(config, .rename("Default")) == false)
        #expect(wouldChange(config, .rename("")) == false)
        #expect(wouldChange(config, .rename(String(repeating: "x", count: 41))) == false)
        let changed = config.apply(.rename(" Work "))
        #expect(changed)
        #expect(config.name == "Work")
    }

    // A run of actions as the tab menu, the header and the Settings panel send them.
    @Test func aRunOfActionsGivesTheExpectedConfig() throws {
        var config = standard
        let actions: [OverviewAction] = [
            .addTab, .renameTab("t6", name: "Reviews"), .toggleColumn("t6", .branch),
            .moveColumn("t6", .branch, before: .name), .sortBy("t6", .branch),
            .sortBy("t6", .branch), .setWidths("t6", [.branch: 160]), .moveTab("t6", by: -1),
            .removeTab("t3"), .activate("t1"), .setTabColour("t6", 9), .toggleColumn("t6", .branch),
        ]
        let changes = actions.map { config.apply($0) }
        #expect(changes == Array(repeating: true, count: actions.count))
        #expect(tabIDs(config) == ["t1", "t2", "t0", "t4", "t6", "t5"])
        #expect(config.active == "t1")
        #expect(config.nextTab == 7)
        let added = try tab(config, "t6")
        #expect(added.name == "Reviews")
        #expect(added.colour == 9)
        #expect(added.columns == OverviewColumn.defaultVisible)
        #expect(
            columnTexts(added.order)
                == "kind,branch,name,priority,state,project,model,context,cost,activity")
        #expect(added.widths == [.branch: 160])
        #expect(added.sort == SortSpec(column: .name, descending: false))
        #expect(try parse(config.json) == config)
    }
}
