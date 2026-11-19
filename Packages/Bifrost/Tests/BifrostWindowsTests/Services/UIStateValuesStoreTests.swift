import BifrostFoundation
import BifrostLayout
import BifrostSessions
import BifrostTestSupport
import BifrostWindows
import Foundation
import Testing

// The typed views of the UI state through the store: a save and a load keep each value
// (UIStateValuesTests has the views themselves).

private let one = panel("overview:1")
private let two = panel("overview:2")
private let three = panel("overview:3")

@MainActor
private func openStore(_ file: URL) async -> UIStateStore {
    await UIStateStore.open(file: file, clock: ManualClock(), log: Recorder<StoreEvent>())
}

// Write the value to the file as JSONFile writes a store.
private func write(_ value: JSONValue, _ file: URL) throws {
    try JSONFile.encode(value).write(to: file)
}

@Suite("the typed views of the UI state in the store", .testTimeLimit)
struct UIStateValuesStoreTests {
    // One refused config among three, with a layout and a history: after a change of another
    // Overview and a save, the two good configs, the layout and the history stay. The refused
    // config stays in the file as it came, until a change of its own Overview replaces it.
    @MainActor
    @Test func aBadOverviewConfigGoesAloneAndTheOtherValuesStay() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = folder.url.appending(path: "ui-state.json")
        try write(
            [
                "version": 1, "current": .null,
                "layouts": [["name": "Work", "snapshot": ["frames": [], "memory": [:]]]],
                "overviews": [
                    "overview:1": savedOverviewConfig("A"), "overview:2": unreadableOverviewConfig,
                    "overview:3": savedOverviewConfig("C"),
                ],
                "history": savedHistoryJSON,
            ], file)
        let store = await openStore(file)
        #expect(store.state.overviewConfig(two) == .standard)
        store.change { $0.updateOverview(one) { $0.apply(.rename("Changed")) } }
        await store.saveNow()

        let after = await openStore(file).state
        var changed = try parsedConfig(savedOverviewConfig("A"))
        changed.apply(.rename("Changed"))
        #expect(after.overviewConfig(one) == changed)
        #expect(after.overviewConfig(three) == (try parsedConfig(savedOverviewConfig("C"))))
        #expect(after.layouts.map(\.name) == ["Work"])
        #expect(after.dialogHistory == History.parse(savedHistoryJSON))
        #expect(after.history == savedHistoryJSON)
        let written = try readSaved(file).object?["overviews"]?.object
        #expect(written?["overview:2"] == unreadableOverviewConfig)
        #expect(written?["overview:3"] == savedOverviewConfig("C"))

        store.change { $0.updateOverview(two) { $0.apply(.rename("Mine")) } }
        await store.saveNow()
        var mine = OverviewConfig.standard
        mine.apply(.rename("Mine"))
        #expect(try readSaved(file).object?["overviews"]?.object?["overview:2"] == mine.json)
    }

    @MainActor
    @Test func anActionOnAnOverviewWithNoSavedConfigIsSaved() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = folder.url.appending(path: "ui-state.json")
        let store = await openStore(file)
        store.change { $0.updateOverview(one) { $0.apply(.addTab) } }
        await store.saveNow()
        var expected = OverviewConfig.standard
        expected.apply(.addTab)
        #expect(await openStore(file).state.overviewConfig(one) == expected)
    }

    // The file is compact JSON, which the store never writes. So the same text after the save
    // shows that the store wrote nothing.
    @MainActor
    @Test func aChangeWithNoEffectWritesNothing() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = folder.url.appending(path: "ui-state.json")
        let text = #"{"version":1,"overviews":{"overview:1":{"tabs":[{"id":"t1","name":"All"}]},"#
            + #""overview:2":{"tabs":[]}}}"#
        try Data(text.utf8).write(to: file)
        let store = await openStore(file)
        store.change { $0.updateOverview(one) { $0.apply(.activate("t1")) } }
        store.change { $0.updateOverview(two) { $0.apply(.activate("t1")) } }
        await store.saveNow()
        #expect(try String(contentsOf: file, encoding: .utf8) == text)
    }

    // The typed values, with their unknown fields, come back the same after a save and a load.
    @MainActor
    @Test func theTypedValuesRoundTripThroughTheStore() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = folder.url.appending(path: "ui-state.json")
        try write(["version": 1, "overviews": ["overview:2": savedOverviewConfig("Set")]], file)
        let store = await openStore(file)
        let history = History.parse(savedHistoryJSON).rememberingSlash("/review")
            .remembering(cwd: "/c", model: .haiku, mode: nil)
        store.change {
            $0.updateOverview(two) { config in
                config.apply(.addTab)
                config.apply(.toggleColumn("t2", .cost))
                config.apply(.setWidths("t2", [.name: 230]))
                config.apply(.sortBy("t2", .cost))
            }
            $0.updateOverview(three) { $0.apply(.rename("Third")) }
            $0.dialogHistory = history
        }
        await store.saveNow()

        let after = await openStore(file).state
        #expect(after == store.state)
        #expect(after.overviewConfig(two) == store.state.overviewConfig(two))
        #expect(after.overviewConfig(two).tabs.map(\.id) == ["t1", "t2"])
        #expect(after.overviewConfig(two).unknown.values == ["future": true])
        #expect(after.overviewConfig(three).name == "Third")
        #expect(after.dialogHistory == history)
        #expect(after.dialogHistory.unknown.values == ["future": 1])
    }
}
