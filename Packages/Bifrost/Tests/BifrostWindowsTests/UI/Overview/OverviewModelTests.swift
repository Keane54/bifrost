import BifrostFoundation
import BifrostLayout
import BifrostSessions
import BifrostTestSupport
import Foundation
import Observation
import Synchronization
import Testing

@testable import BifrostWindows

// The Overview model: the config of each Overview through the UI state store, and the default
// open action of a double-click.
@Suite("Overview model", .testTimeLimit)
@MainActor
struct OverviewModelTests {
    private static let one = panel("overview:1")
    private static let two = panel("overview:2")

    private func openStore(_ file: URL) async -> UIStateStore {
        await UIStateStore.open(file: file, clock: ManualClock(), log: Recorder<StoreEvent>())
    }

    private func model(_ store: UIStateStore, rows: FakeRowSource = FakeRowSource())
        -> (OverviewModel, WindowLayoutModel)
    {
        let sessions = SessionListModel.reading(rows)
        let layout = WindowLayoutModel(layout: WindowLayout(bounds: LayoutSize(w: 1200, h: 800)))
        let model = OverviewModel(
            store: store, sessions: sessions, selection: SelectionModel(list: sessions),
            layout: layout, clock: ManualClock(), now: { Date(timeIntervalSince1970: 0) })
        return (model, layout)
    }

    @Test func anUpdateSavesTheConfigThroughTheStore() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = folder.url.appending(path: "ui-state.json")
        let store = await openStore(file)
        let (model, _) = model(store)
        model.update(Self.one, .addTab)
        model.update(Self.one, .rename("Mine"))
        var expected = OverviewConfig.standard
        expected.apply(.addTab)
        expected.apply(.rename("Mine"))
        #expect(model.config(Self.one) == expected)
        #expect(store.state.overviews[Self.one] == expected.json)
        // Only the config of the panel changes. An action with no effect writes nothing.
        #expect(store.state.overviews[Self.two] == nil)
        model.update(Self.two, .activate("t99"))
        #expect(store.state.overviews[Self.two] == nil)
        await store.saveNow()
        #expect(await openStore(file).state.overviewConfig(Self.one) == expected)
    }

    // An edit gives the config of now to a rule of the Overview Settings panel, inside the
    // change of the store. An edit with no effect writes nothing, and only an Overview panel
    // has a config.
    @Test func anEditChangesTheConfigOfNowThroughTheStore() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let store = await openStore(folder.url.appending(path: "ui-state.json"))
        let (model, _) = model(store)
        model.update(Self.one, .activate("t3"))
        model.edit(Self.one) { config in
            config = OverviewSettingsRules.setBoxOnly(config, tab: config.active, true)
        }
        #expect(model.config(Self.one).activeTab.filter.boxOnly)
        #expect(model.config(Self.one).active == "t3")
        #expect(store.state.overviews[Self.one] == model.config(Self.one).json)
        model.edit(Self.two) { _ in }
        #expect(store.state.overviews[Self.two] == nil)
        model.edit(panel("overview-settings:1")) { $0.apply(.addTab) }
        #expect(store.state.overviews[panel("overview-settings:1")] == nil)
    }

    // A reader of a config gets a change of the store from any writer, also a write that does
    // not go through the model (for example the import or a later writer).
    @Test func aReaderOfAConfigGetsAChangeFromAnyWriter() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let store = await openStore(folder.url.appending(path: "ui-state.json"))
        let (model, _) = model(store)
        let changes = Mutex(0)
        withObservationTracking {
            _ = model.config(Self.one)
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        var renamed = OverviewConfig.standard
        renamed.apply(.rename("Theirs"))
        store.change { $0.overviews[Self.one] = renamed.json }
        #expect(changes.withLock { $0 } == 1)
        #expect(model.config(Self.one).name == "Theirs")
    }

    @Test func aPanelWithNoConfigUsesTheStandardConfig() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let (model, _) = model(await openStore(folder.url.appending(path: "ui-state.json")))
        #expect(model.config(Self.one) == .standard)
        #expect(model.config(panel("overview:99")) == .standard)
        // The active tab of the standard config is All.
        #expect(model.config(Self.one).activeTab.name == "All")
    }

    // The view rows are the rows of the active tab: its filter, then its sort. A change of the
    // active tab or of the sort changes them at once.
    @Test func theViewRowsFollowTheActiveTab() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let rows = FakeRowSource()
        rows.apply(
            rows: [
                SessionRow.test(sessionId: "b", name: "bravo"),
                SessionRow.test(sessionId: "p", name: "papa", state: .parked),
                SessionRow.test(sessionId: "a", name: "alpha", state: .working),
            ], error: nil)
        let (model, _) = model(
            await openStore(folder.url.appending(path: "ui-state.json")), rows: rows)
        // All shows the sessions that run, by name.
        #expect(model.viewRows(Self.one).map(\.sessionId) == ["a", "b"])
        model.update(Self.one, .sortBy("t1", .name))
        #expect(model.viewRows(Self.one).map(\.sessionId) == ["b", "a"])
        model.update(Self.one, .activate("t5"))
        #expect(model.viewRows(Self.one).map(\.sessionId) == ["p"])
        // The other Overview keeps its own config.
        #expect(model.viewRows(Self.two).map(\.sessionId) == ["a", "b"])
    }

    // The default open action opens the chat of an owned session that is not parked. Another row
    // opens nothing.
    @Test func theOpenActionOpensOnlyTheChatOfAnOwnedSession() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let owned = "5a0e0001-0000-4000-8000-000000000001"
        let external = "5a0e0002-0000-4000-8000-000000000002"
        let parked = "5a0e0003-0000-4000-8000-000000000003"
        let rows = FakeRowSource()
        rows.apply(
            rows: [
                SessionRow.test(sessionId: owned),
                SessionRow.test(sessionId: external, kind: .external),
                SessionRow.test(sessionId: parked, state: .parked),
            ], error: nil)
        let (model, layout) = model(
            await openStore(folder.url.appending(path: "ui-state.json")), rows: rows)
        model.open(external)
        model.open(parked)
        #expect(layout.layout.frames.isEmpty)
        model.open(owned)
        #expect(layout.layout.topFrame?.active == panel("chat:\(owned)"))
        #expect(model.openChats == [try #require(SessionID(owned))])
    }
}
