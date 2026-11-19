import BifrostFoundation
import BifrostLayout
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostWindows

// The store of window-state.json. The decode and the restore rules are in
// WindowStateTests.swift.

// A file in the form that the app wrote before the window state became Codable, with a field
// that this app does not know.
private let fileOfTheOldCode = """
    {
      "bounds" : {
        "height" : 900,
        "width" : 1440,
        "x" : -240.5,
        "y" : 25
      },
      "display" : {
        "id" : 2
      },
      "mode" : "borderless"
    }

    """

@MainActor
private func openStore(
    _ file: URL, _ log: Recorder<StoreEvent> = .init(), steps: WriteSteps = .system
) async -> WindowStateStore {
    await WindowStateStore.open(file: file, log: log, steps: steps)
}

@MainActor
@Suite("window-state store", .timeLimit(.minutes(1)))
struct WindowStateStoreTests {
    @Test
    func savesEachChange() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "window-state.json")
        let store = await openStore(file)
        #expect(store.state == WindowState(mode: .window, bounds: nil))
        await store.update(mode: .borderless)
        let bounds = WindowBounds(x: 10, y: 20, width: 800, height: 600)
        await store.update(bounds: bounds)
        #expect(
            try readSaved(file) == [
                "bounds": ["height": 600, "width": 800, "x": 10, "y": 20], "mode": "borderless",
            ])
        #expect(await openStore(file).state == WindowState(mode: .borderless, bounds: bounds))
    }

    // The shell can change the mode while a write of the bounds runs. Both updates end after the
    // write of the newest state, and that state has both changes.
    @Test func anUpdateDuringAWriteEndsAfterTheWriteOfTheNewestState() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "window-state.json")
        let gate = WriteGate()
        defer { gate.openAll() }
        let store = await openStore(file, steps: gate.steps)
        let bounds = WindowBounds(x: 10, y: 20, width: 800, height: 600)
        let first = Task { await store.update(bounds: bounds) }
        try #require(await gate.waitUntilWriting())
        // Task.immediate starts each update in this turn, so the updates come in order.
        let second = Task.immediate { await store.update(mode: .borderless) }
        let third = Task.immediate { await store.update(mode: .fullscreen) }
        gate.open()
        gate.open()
        for update in [first, second, third] { await update.value }
        #expect(gate.writes == 2)
        #expect(
            try readSaved(file) == [
                "bounds": ["height": 600, "width": 800, "x": 10, "y": 20], "mode": "fullscreen",
            ])
    }

    @Test("the store never writes over a file that it cannot read")
    func readError() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        // A directory in place of the file gives a read error that is not ENOENT.
        let file = dir.appending(path: "window-state.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let log = Recorder<StoreEvent>()
        let store = await openStore(file, log)
        await store.update(mode: .fullscreen)
        let error = FileError.system(.read, path: path(file), code: EISDIR)
        #expect(
            log.values == [.readFailed(file: path(file), what: "the window state", error: error)])
        #expect(isFolder(file))
        #expect(store.state.mode == .fullscreen)
    }

    // A failed write logs its error, and the next update writes.
    @Test func aFailedWriteLogsTheErrorAndTheNextUpdateWrites() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "window-state.json")
        let log = Recorder<StoreEvent>()
        let store = await openStore(file, log)
        // A folder in place of the file makes the write fail.
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await store.update(mode: .borderless)
        let text = FileError.system(.save, path: path(file), code: EISDIR)
        #expect(log.values == [.saveFailed(what: "the window state", error: text)])
        try FileManager.default.removeItem(at: file)
        await store.update(mode: .fullscreen)
        #expect(try readSaved(file) == ["bounds": .null, "mode": "fullscreen"])
    }

    // A file that does not parse gets one copy through the shared saver, and the load keeps the
    // unknown fields (docs/behaviour/stores.md, "window-state.json").
    @Test func aDamagedWindowStateJsonIsCopiedOnceBeforeASave() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "window-state.json")
        try Data("{ no".utf8).write(to: file)
        let log = Recorder<StoreEvent>()
        let store = await openStore(file, log)
        await store.update(mode: .borderless)
        let copy = dir.appending(path: "window-state.json.unreadable")
        #expect(try String(contentsOf: copy, encoding: .utf8) == "{ no")
        #expect(try readSaved(file) == ["bounds": .null, "mode": "borderless"])
        #expect(log.values == [.keptUnreadableCopy(file: path(file), copy: path(copy))])
        try FileManager.default.removeItem(at: copy)
        await store.update(mode: .window)
        #expect(try names(dir) == ["window-state.json"])
    }

    @Test func unknownTopLevelKeysOfWindowStateJsonSurviveASave() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "window-state.json")
        try Data(#"{"mode":"fullscreen","display":{"id":2},"bounds":7}"#.utf8).write(to: file)
        let store = await openStore(file)
        #expect(store.state.mode == .fullscreen)
        #expect(store.state.bounds == nil)
        #expect(store.state.unknown.values == ["display": ["id": 2]])
        await store.update(mode: .window)
        #expect(
            try readSaved(file) == ["bounds": .null, "display": ["id": 2], "mode": "window"])
    }

    // A file that the old code wrote gives the same state, and a save of that state writes the
    // same bytes again.
    @Test func aFileOfTheOldCodeLoadsTheSameAndSavesTheSameBytes() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "window-state.json")
        try Data(fileOfTheOldCode.utf8).write(to: file)
        let store = await openStore(file)
        var expected = WindowState(
            mode: .borderless, bounds: WindowBounds(x: -240.5, y: 25, width: 1440, height: 900))
        expected.unknown = UnknownFields(["display": ["id": 2]])
        #expect(store.state == expected)
        await store.update(mode: .borderless)
        #expect(try String(contentsOf: file, encoding: .utf8) == fileOfTheOldCode)
    }
}
