import BifrostFoundation
import BifrostLayout
import BifrostSessions
import BifrostTestSupport
import BifrostWindows
import Testing

// The typed views of the UI state: the Overview configs and the dialog history. BifrostLayout
// keeps them raw, and these views read and write them with the rules of the Overview and of the
// history (the section "The Overviews and the dialog history in the UI state" of
// docs/behaviour/windows.md). UIStateValuesStoreTests has the tests through the store.

private let one = panel("overview:1")
private let two = panel("overview:2")
private let three = panel("overview:3")

// The saved values of the tests of the typed views of the UI state (UIStateValuesTests and
// UIStateValuesStoreTests).

// A saved config with one tab, this set name, and a field that this app does not know.
func savedOverviewConfig(_ name: String) -> JSONValue {
    ["name": .string(name), "tabs": [["id": "t1", "name": "All"]], "future": true]
}

// A config that the parse refuses: it has no good tab.
let unreadableOverviewConfig: JSONValue = ["tabs": [["id": "bad", "name": "No"]]]

// A saved history with a field that this app does not know.
let savedHistoryJSON: JSONValue = [
    "model": "opus", "permissionMode": "plan", "recentDirs": ["/a/b"], "recentSlash": ["/compact"],
    "future": 1,
]

func parsedConfig(_ value: JSONValue) throws -> OverviewConfig {
    try #require(OverviewConfig.parse(value))
}

// The state of a version 1 file with these fields.
private func state(_ fields: [String: JSONValue]) -> UIState {
    loaded(.object(fields.merging(["version": 1]) { _, version in version }), else: UIState())
}

// A saved config that the parse reads, but whose clean form is not the saved value: a name with
// spaces, an unknown column and a bad nextTab.
private let messyConfig: JSONValue = [
    "tabs": [["id": "t1", "name": " All ", "columns": ["nope", "name"]]], "nextTab": 0,
]

private func savedConfigs(_ configs: [String: JSONValue]) -> UIState {
    state(["overviews": .object(configs)])
}

@Suite("the typed views of the UI state")
struct UIStateValuesTests {
    @Test func aStateWithNoSavedValuesGivesTheStandardConfigAndTheEmptyHistory() {
        #expect(UIState().overviewConfig(one) == .standard)
        #expect(UIState().dialogHistory == .empty)
    }

    // A config that the parse refuses gives the standard config, and the other configs read as
    // they were saved. A bad history value gives the empty history.
    @Test func aBadConfigReadsAsTheStandardConfigAndTheOtherConfigsStay() throws {
        let s = state([
            "overviews": [
                "overview:1": savedOverviewConfig("A"), "overview:2": unreadableOverviewConfig,
                "overview:3": savedOverviewConfig("C"),
            ],
            "history": "x",
        ])
        #expect(s.overviewConfig(one) == (try parsedConfig(savedOverviewConfig("A"))))
        #expect(s.overviewConfig(two) == .standard)
        #expect(s.overviewConfig(three) == (try parsedConfig(savedOverviewConfig("C"))))
        #expect(s.dialogHistory == .empty)
    }

    @Test func theFirstChangeOfAnOverviewWithNoSavedConfigStartsFromTheStandardConfig() {
        var s = UIState()
        s.updateOverview(two) { $0.apply(.addTab) }
        var expected = OverviewConfig.standard
        expected.apply(.addTab)
        #expect(s.overviews == [two: expected.json])
        #expect(s.overviewConfig(two) == expected)
    }

    // The configs of the other panels stay as they were saved: a config that the parse refuses,
    // and a config that the parse would clean.
    @Test func aChangeWritesOnlyTheConfigOfItsOwnPanel() throws {
        var s = savedConfigs([
            "overview:1": savedOverviewConfig("A"), "overview:2": unreadableOverviewConfig,
            "overview:3": messyConfig,
        ])
        s.updateOverview(one) { $0.apply(.rename("Changed")) }
        var changed = try parsedConfig(savedOverviewConfig("A"))
        changed.apply(.rename("Changed"))
        #expect(
            s.overviews == [one: changed.json, two: unreadableOverviewConfig, three: messyConfig])
    }

    // The first change of the Overview of a refused config starts from the standard config and
    // replaces the saved value.
    @Test func aChangeOfTheOverviewOfARefusedConfigReplacesIt() {
        var s = savedConfigs(["overview:2": unreadableOverviewConfig])
        s.updateOverview(two) { $0.apply(.rename("Mine")) }
        var expected = OverviewConfig.standard
        expected.apply(.rename("Mine"))
        #expect(s.overviews == [two: expected.json])
    }

    @Test func aChangeWithNoEffectWritesNothing() {
        let saved = savedConfigs([
            "overview:1": savedOverviewConfig("A"), "overview:2": unreadableOverviewConfig,
            "overview:3": messyConfig,
        ])
        var s = saved
        s.updateOverview(one) { $0.apply(.activate("t1")) }
        s.updateOverview(two) { $0.apply(.activate("t1")) }
        s.updateOverview(three) { _ in }
        s.updateOverview(panel("overview:4")) { $0.apply(.rename("Default")) }
        #expect(s == saved)
    }

    @Test func anIDThatIsNotAnOverviewChangesNothing() {
        var s = UIState()
        s.updateOverview(panel("settings")) { $0.apply(.addTab) }
        s.updateOverview(panel("overview-settings:1")) { $0.apply(.addTab) }
        #expect(s == UIState())
    }

    @Test func theSetOfTheHistoryWritesItsJSONForm() {
        var s = UIState()
        let history = History.empty.remembering(cwd: "/a", model: .opus, mode: .plan)
        s.dialogHistory = history
        #expect(s.history == history.json)
        #expect(s.dialogHistory == history)
    }
}
