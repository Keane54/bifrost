import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostDailyUpdate

// The store of state.json and its lock (docs/behaviour/daily-update.md, "The store").
@MainActor
@Suite("the Daily update store", .timeLimit(.minutes(1)))
struct DailyStateStoreTests {
    private struct Setup {
        let home: TemporaryFolder
        let layout: DailyLayout
        let log = Recorder<StoreEvent>()

        // A test home with a state file of the Electron app, or with no file.
        init(electronState: Bool) throws {
            home = try TemporaryFolder()
            layout = DailyLayout(folder: home.url.appending(path: "daily-update"))
            if electronState {
                try FileManager.default.createDirectory(
                    at: layout.folder, withIntermediateDirectories: true)
                try fixtureData("daily-update/state.json").write(to: layout.stateFile)
            }
        }

        func open() async throws -> DailyStateStore {
            try await DailyStateStore.open(layout: layout, log: log)
        }
    }

    @Test func theFirstOpenKeepsACopy() async throws {
        let setup = try Setup(electronState: true)
        defer { setup.home.remove() }
        let original = try fixtureData("daily-update/state.json")
        let store = try await setup.open()
        #expect(try Data(contentsOf: setup.layout.stateCopy) == original)
        // A later save and a later open never replace the copy.
        var next = store.state
        next.setSkipped(true)
        store.keep(next)
        await store.saved()
        await store.close()
        let again = try await setup.open()
        #expect(again.state.marks.skipped)
        #expect(try Data(contentsOf: setup.layout.stateCopy) == original)
        #expect(setup.log.values.isEmpty)
    }

    @Test func theElectronStateOpensWithEveryValue() async throws {
        let setup = try Setup(electronState: true)
        defer { setup.home.remove() }
        let store = try await setup.open()
        let state = store.state
        #expect(state.marks.date == "2026-11-17")
        #expect(state.marks.firstShown)
        #expect(!state.marks.secondShown)
        #expect(state.marks.sent == ["area-2": Date(timeIntervalSince1970: 1_780_001_000)])
        #expect(state.lastSent == ["area-1": Date(timeIntervalSince1970: 1_779_900_000)])
        #expect(state.prevSent == ["area-1": Date(timeIntervalSince1970: 1_779_800_000)])
        let view = try #require(state.areas["area-1"])
        #expect(view.draft == "**Update**\nDone: one thing")
        #expect(view.edited)
        #expect(view.moved)
        #expect(view.pending == "**Update**\nA newer draft")
        #expect(view.since == Date(timeIntervalSince1970: 1_780_000_000))
        #expect(
            view.items.first
                == DailyItem(
                    kind: .ticket, id: "T-1", title: "A ticket", from: "Open", to: "Done",
                    url: "https://example.test/T-1"))
        #expect(view.items.last == DailyItem(kind: .pr, id: "PR-7", title: "A merged PR"))
        #expect(state.areas["area-2"]?.since == nil)
        #expect(state.unplaced == [DailyItem(kind: .ticket, id: "T-9", title: "Unplaced")])
        #expect(
            state.lastRun
                == DailyRun(
                    at: Date(timeIntervalSince1970: 1_780_003_600), ok: false, failure: .timeout))
        // A save gives the same file, so the Electron form is kept.
        store.keep(state)
        await store.saved()
        #expect(try readSaved(setup.layout.stateFile) == fixtureJSON("daily-update/state.json"))
    }

    @Test func aMissingFileGivesTheEmptyStateAndNoCopy() async throws {
        let setup = try Setup(electronState: false)
        defer { setup.home.remove() }
        let store = try await setup.open()
        #expect(store.state == .empty)
        #expect(!FileManager.default.fileExists(atPath: path(setup.layout.stateCopy)))
        var next = store.state
        next.rollDay(to: "2026-11-18")
        store.keep(next)
        await store.saved()
        #expect(try readSaved(setup.layout.stateFile).fields?["version"] == 1)
    }

    @Test func aSecondOpenIsRefused() async throws {
        let setup = try Setup(electronState: false)
        defer { setup.home.remove() }
        let first = try await setup.open()
        // The Electron file appears while the first copy runs.
        try fixtureData("daily-update/state.json").write(to: setup.layout.stateFile)
        await #expect(throws: DailyStoreError.otherCopy) { try await setup.open() }
        #expect(
            DailyStoreError.otherCopy.message
                == "Daily update is running in another copy of Bifrost.")
        // The refused copy wrote nothing.
        #expect(!FileManager.default.fileExists(atPath: path(setup.layout.stateCopy)))
        #expect(
            try Data(contentsOf: setup.layout.stateFile) == fixtureData("daily-update/state.json"))
        await first.close()
    }

    @Test func aClosedStoreFreesTheLock() async throws {
        let setup = try Setup(electronState: false)
        defer { setup.home.remove() }
        let first = try await setup.open()
        await first.close()
        // A closed store keeps and writes nothing.
        var next = first.state
        next.rollDay(to: "2026-11-18")
        first.keep(next)
        await first.saved()
        #expect(first.state == .empty)
        #expect(!FileManager.default.fileExists(atPath: path(setup.layout.stateFile)))
        let second = try await setup.open()
        await second.close()
    }

    // Two closes at the same time both end, and they free the lock one time.
    @Test func aSecondCloseWaitsForTheFirst() async throws {
        let setup = try Setup(electronState: false)
        defer { setup.home.remove() }
        let first = try await setup.open()
        var next = first.state
        next.rollDay(to: "2026-11-18")
        first.keep(next)
        await first.saved()
        async let one: Void = first.close()
        async let two: Void = first.close()
        _ = await (one, two)
        #expect(FileManager.default.fileExists(atPath: path(setup.layout.stateFile)))
        let second = try await setup.open()
        #expect(second.state == next)
        await second.close()
    }

    @Test func aFailedCopyKeepsTheStateInMemoryAndWritesNothing() async throws {
        let setup = try Setup(electronState: true)
        defer { setup.home.remove() }
        // A sync that fails makes the copy fail, after the lock is taken.
        let failing = WriteSteps(
            sync: { _ in throw POSIXError(.EIO) }, rename: WriteSteps.system.rename)
        let original = try fixtureData("daily-update/state.json")
        let store = try await DailyStateStore.open(
            layout: setup.layout, log: setup.log, steps: failing)
        #expect(store.state.marks.date == "2026-11-17")
        let failed = setup.log.values.contains {
            if case .copyFailed = $0 { true } else { false }
        }
        #expect(failed)
        var next = store.state
        next.setSkipped(true)
        store.keep(next)
        await store.saved()
        #expect(store.state.marks.skipped)
        #expect(try Data(contentsOf: setup.layout.stateFile) == original)
        await store.close()
    }

    @Test func theLayoutHasTheElectronFiles() {
        let layout = DailyLayout(
            folder: URL(filePath: "/tmp/x/daily-update", directoryHint: .isDirectory))
        #expect(layout.stateFile.lastPathComponent == "state.json")
        #expect(layout.stateCopy.lastPathComponent == "state.json.before-native")
        #expect(layout.exportFile.lastPathComponent == "settings.json")
        #expect(layout.runsFolder.lastPathComponent == "runs")
        #expect(layout.lockFile.lastPathComponent == ".lock")
    }
}
