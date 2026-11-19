import BifrostTestSupport
import Foundation
import Observation
import Synchronization
import Testing

@testable import BifrostFoundation
@testable import BifrostLayout

// The store of ui-state.json. The store saves its own UIState, so a test changes the state and
// then saves. Each test uses a ManualClock, so no save timer fires unless the test moves the
// clock.

private func write(_ text: String, _ url: URL) throws {
    try Data(text.utf8).write(to: url)
}

private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

private func field(_ value: JSONValue?, _ key: String) -> JSONValue? {
    guard case .object(let fields)? = value else { return nil }
    return fields[key]
}

private let rect = LayoutRect(x: 10, y: 20, w: 300, h: 200)
private let settings = PanelID("settings")

// A layout with one frame, the Settings panel.
private func snapshot() -> LayoutSnapshot {
    guard let settings else { return LayoutSnapshot(frames: [], memory: [:]) }
    return LayoutSnapshot(
        frames: [
            SavedFrame(
                panels: [settings], active: settings, rect: rect, minimised: false, locked: false)
        ], memory: [:])
}

// The JSON form of snapshot().
private let snapshotJSON: JSONValue = [
    "frames": [
        [
            "active": "settings", "locked": false, "minimised": false, "panels": ["settings"],
            "rect": ["h": 200, "w": 300, "x": 10, "y": 20],
        ]
    ],
    "memory": [:],
]

// A file in the form that the app wrote before the UI state became Codable: sorted keys, two
// spaces of indent and the numbers of the old JSON values. The user's files have this form.
private let fileOfTheOldCode = """
    {
      "current" : {
        "frames" : [
          {
            "active" : "watchlist",
            "locked" : false,
            "minimised" : false,
            "panels" : [
              "settings",
              "watchlist"
            ],
            "rect" : {
              "h" : 200,
              "w" : 300,
              "x" : 10,
              "y" : 20.5
            }
          },
          {
            "active" : "overview:1",
            "locked" : true,
            "minimised" : true,
            "panels" : [
              "overview:1"
            ],
            "rect" : {
              "h" : 480,
              "w" : 640,
              "x" : 0,
              "y" : 0
            }
          }
        ],
        "memory" : {
          "event-log" : {
            "h" : 260,
            "w" : 420,
            "x" : 12.5,
            "y" : 40
          }
        }
      },
      "future" : {
        "x" : [
          1,
          null
        ]
      },
      "history" : {
        "model" : "opus",
        "recentDirs" : [
          "/a/b"
        ]
      },
      "layouts" : [
        {
          "name" : "Work 😀",
          "snapshot" : {
            "frames" : [
              {
                "active" : "settings",
                "locked" : false,
                "minimised" : false,
                "panels" : [
                  "settings"
                ],
                "rect" : {
                  "h" : 200,
                  "w" : 300,
                  "x" : 10,
                  "y" : 20
                }
              }
            ],
            "memory" : {

            }
          }
        }
      ],
      "overviews" : {
        "overview:1" : {
          "tabs" : [
            {
              "id" : "t1",
              "name" : "All"
            }
          ]
        }
      },
      "performance" : {
        "detailsOpen" : true
      },
      "version" : 1
    }

    """

// The state of fileOfTheOldCode.
private func stateOfTheOldFile() -> UIState {
    let ids = ["settings", "watchlist", "overview:1", "event-log"].compactMap(PanelID.init)
    let (settings, watchlist, overview, eventLog) = (ids[0], ids[1], ids[2], ids[3])
    var state = UIState()
    state.current = LayoutSnapshot(
        frames: [
            SavedFrame(
                panels: [settings, watchlist], active: watchlist,
                rect: LayoutRect(x: 10, y: 20.5, w: 300, h: 200), minimised: false, locked: false),
            SavedFrame(
                panels: [overview], active: overview, rect: LayoutRect(x: 0, y: 0, w: 640, h: 480),
                minimised: true, locked: true),
        ],
        memory: [eventLog: LayoutRect(x: 12.5, y: 40, w: 420, h: 260)])
    _ = state.saveLayout("Work 😀", snapshot())
    state.overviews = [panel("overview:1"): ["tabs": [["id": "t1", "name": "All"]]]]
    state.history = ["model": "opus", "recentDirs": ["/a/b"]]
    state.performance = ["detailsOpen": true]
    state.unknown = UnknownFields(["future": ["x": [1, .null]]])
    return state
}

@MainActor
private func openStore(
    _ file: URL, _ log: Recorder<StoreEvent> = .init(), clock: ManualClock = ManualClock(),
    steps: WriteSteps = .system
) async -> UIStateStore {
    await UIStateStore.open(file: file, clock: clock, log: log, steps: steps)
}

@MainActor
@Suite("the UI state store", .testTimeLimit)
struct UIStateStoreTests {
    @Test("a missing file gives the empty state and a working save")
    func missingFile() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "ui-state.json")
        let store = await openStore(file)
        #expect(store.state == UIState())
        store.change { $0.current = snapshot() }
        await store.saveNow()
        #expect(
            try readSaved(file) == ["current": snapshotJSON, "layouts": [], "version": 1])
    }

    @Test("bad JSON gives the empty state and a working save")
    func badJSON() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "ui-state.json")
        try write("{ no", file)
        let store = await openStore(file)
        #expect(store.state == UIState())
        store.change { $0.current = snapshot() }
        await store.saveNow()
        #expect(
            try readSaved(file) == ["current": snapshotJSON, "layouts": [], "version": 1])
    }

    @Test("a good file gives its data")
    func goodFile() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "ui-state.json")
        try write(#"{"version":1,"x":2,"layouts":[{"name":"A","snapshot":{}}]}"#, file)
        let store = await openStore(file)
        #expect(store.state.layouts.map(\.name) == ["A"])
        #expect(store.state.current == nil)
    }

    // A folder at the path of the file gives a read error. A save then writes nothing in the
    // folder.
    @Test("a read error turns saving off")
    func readError() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let log = Recorder<StoreEvent>()
        let store = await openStore(dir, log)
        #expect(store.state == UIState())
        let error = FileError.system(.read, path: path(dir), code: EISDIR)
        #expect(log.values == [.readFailed(file: path(dir), what: "the UI state", error: error)])
        store.change { $0.current = snapshot() }
        await store.saveNow()
        #expect(try names(dir) == [] && isFolder(dir))
    }

    // A state with more than 1,000,000 bytes of compact JSON is refused and logged.
    @Test
    func refusesALargeState() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "ui-state.json")
        let log = Recorder<StoreEvent>()
        let store = await openStore(file, log)
        store.change {
            $0.performance = ["big": .string(String(repeating: "x", count: UIState.maxBytes))]
        }
        await store.saveNow()
        #expect(
            log.values == [.tooLarge(file: path(file), what: "the UI state", limit: 1_000_000)])
        #expect(try names(dir) == [])
    }

    @Test("saving counts bytes, not characters")
    func countsBytes() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "ui-state.json")
        let store = await openStore(file)
        // 400,000 characters of 3 bytes each.
        let euros = String(repeating: "\u{20ac}", count: 400_000)
        store.change { $0.performance = ["big": .string(euros)] }
        await store.saveNow()
        #expect(try names(dir) == [])
    }

    @Test
    func lastSavedValue() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "ui-state.json")
        try write(#"{"version":1,"performance":"A"}"#, file)
        let store = await openStore(file)
        store.change { $0.performance = "B" }
        await store.saveNow()
        #expect(store.state.performance == "B")
        #expect(await openStore(file).state.performance == "B")
    }

    // Saves before the save task starts give one write, of the newest state.
    @Test("quick saves give one write of the newest state")
    func newestState() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "ui-state.json")
        let counter = WriteCounter()
        let store = await openStore(file, steps: counter.steps)
        var saves: [Task<Void, Never>?] = []
        for n in 1...3 {
            store.change { $0.performance = .int(n) }
            saves.append(store.startSave())
        }
        for save in saves { await save?.value }
        #expect(field(try readSaved(file), "performance") == 3)
        #expect(store.state.performance == 3)
        #expect(counter.writes == 1)
    }

    // One write runs at a time. A save during a write waits, and a newer save takes the place
    // of an older save that waits. So the file gets the newest state with the fewest writes.
    @Test func aSaveDuringAWriteWaitsAndTheNewestStateWins() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "ui-state.json")
        let gate = WriteGate()
        defer { gate.openAll() }
        let store = await openStore(file, steps: gate.steps)
        store.change { $0.performance = 1 }
        let first = try #require(store.startSave())
        try #require(await gate.waitUntilWriting())
        store.change { $0.performance = 2 }
        let second = store.startSave()
        store.change { $0.performance = 3 }
        let third = store.startSave()
        // The three saves share one save task.
        #expect(second == first)
        #expect(third == first)
        gate.open()
        gate.open()
        await first.value
        #expect(gate.writes == 2)
        #expect(field(try readSaved(file), "performance") == 3)
        // A save after the task ended starts a new task.
        store.change { $0.performance = 4 }
        let next = try #require(store.startSave())
        gate.open()
        await next.value
        #expect(next != first)
        #expect(gate.writes == 3)
        #expect(field(try readSaved(file), "performance") == 4)
    }

    // A failed write logs its error, and the next save writes. A refused save logs its size.
    @Test func aFailedWriteLogsTheErrorAndTheNextSaveWrites() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "ui-state.json")
        let log = Recorder<StoreEvent>()
        let store = await openStore(file, log)
        // A folder in place of the file makes the write fail.
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        store.change { $0.performance = 1 }
        await store.saveNow()
        try FileManager.default.removeItem(at: file)
        store.change { $0.performance = 2 }
        await store.saveNow()
        store.change {
            $0.performance = ["big": .string(String(repeating: "x", count: UIState.maxBytes))]
        }
        await store.saveNow()
        let error = FileError.system(.save, path: path(file), code: EISDIR)
        #expect(
            log.values == [
                .saveFailed(what: "the UI state", error: error),
                .tooLarge(file: path(file), what: "the UI state", limit: UIState.maxBytes),
            ])
        #expect(field(try readSaved(file), "performance") == 2)
    }

    // MARK: - New tests

    // A file from a newer app loses nothing (the section "Files on disk" of the architecture
    // design). A key of the state wins over an unknown field.
    @Test func unknownTopLevelKeysOfUiStateJsonSurviveASave() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "ui-state.json")
        try write(#"{"version":1,"future":{"deep":[1,{"x":null}]},"zoom":2}"#, file)
        let store = await openStore(file)
        store.change { $0.current = snapshot() }
        await store.saveNow()
        store.change { _ = $0.saveLayout("Work", snapshot()) }
        await store.saveNow()
        let saved = try readSaved(file)
        #expect(field(saved, "future") == ["deep": [1, ["x": .null]]])
        #expect(field(saved, "zoom") == 2)
        #expect(field(saved, "current") == snapshotJSON)
        #expect(field(saved, "version") == 1)
        #expect(field(saved, "layouts") == [["name": "Work", "snapshot": snapshotJSON]])
    }

    // The store keeps the Overview configs, the dialog history and the Performance state raw
    // (row U1 for the Performance state). BifrostWindows applies the rules of the configs and of
    // the history. So a save writes each value back as it came, also a value that those rules
    // would change. Only a key that is not the panel ID of an Overview goes.
    @Test func rawOverviewsHistoryAndPerformanceSurviveASave() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "ui-state.json")
        let config: JSONValue = ["tabs": [["id": "t1", "name": "All"]], "x": [1, .null]]
        let overviews: JSONValue = [
            "overview:1": config, "overview:2": ["tabs": []], "chat:x": ["tabs": []],
        ]
        let history: JSONValue = ["model": "opus", "recentDirs": ["/a/b", 7], "x": 1.5]
        let performance: JSONValue = ["detailsOpen": "yes"]
        try JSONFile.write(
            try JSONFile.encode([
                "history": history, "overviews": overviews, "performance": performance,
                "version": 1,
            ]), to: file)
        let store = await openStore(file)
        let kept: [PanelID: JSONValue] = [
            panel("overview:1"): config, panel("overview:2"): ["tabs": []],
        ]
        #expect(store.state.overviews == kept)
        #expect(store.state.history == history)
        #expect(store.state.performance == performance)
        store.change { $0.current = snapshot() }
        await store.saveNow()
        let saved = try readSaved(file)
        #expect(field(saved, "overviews") == ["overview:1": config, "overview:2": ["tabs": []]])
        #expect(field(saved, "history") == history)
        #expect(field(saved, "performance") == performance)
    }

    // A file that does not parse at all is copied one time before the first save
    // A raw value with no JSON form makes the file a file that does not parse, also with a
    // version that is not 1. The first save keeps a copy.
    @Test func aRawValueWithNoJSONFormInAnotherVersionIsCopiedBeforeASave() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "ui-state.json")
        let stored = #"{"history":[1e400],"version":2}"#
        try write(stored, file)
        let store = await openStore(file)
        store.change { $0.current = snapshot() }
        await store.saveNow()
        #expect(try text(dir.appending(path: "ui-state.json.unreadable")) == stored)
    }

    // An Overview config with no JSON form makes the file a file that does not parse, also under
    // a key that is not the panel ID of an Overview: the decode reads the whole overviews value
    // before it checks the keys. The store opens with the empty state, and the first save keeps
    // a copy.
    @Test(arguments: ["overview:1", "chat:x"])
    func anOverviewConfigWithNoJSONFormIsCopiedBeforeASave(key: String) async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "ui-state.json")
        let stored = #"{"overviews":{"\#(key)":[1e400]},"version":1}"#
        try write(stored, file)
        let store = await openStore(file)
        #expect(store.state == UIState())
        store.change { $0.current = snapshot() }
        await store.saveNow()
        #expect(try text(dir.appending(path: "ui-state.json.unreadable")) == stored)
        #expect(field(try readSaved(file), "overviews") == nil)
    }

    // over it.
    @Test func aDamagedUiStateJsonIsCopiedOnceBeforeASave() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "ui-state.json")
        try write("{ no", file)
        let log = Recorder<StoreEvent>()
        let store = await openStore(file, log)
        // The open itself writes nothing.
        #expect(try names(dir) == ["ui-state.json"])
        store.change { $0.current = snapshot() }
        await store.saveNow()
        let copy = dir.appending(path: "ui-state.json.unreadable")
        #expect(try text(copy) == "{ no")
        #expect(field(try readSaved(file), "current") == snapshotJSON)
        #expect(log.values == [.keptUnreadableCopy(file: path(file), copy: path(copy))])
        // The second save does not copy again.
        try FileManager.default.removeItem(at: copy)
        store.change { $0.current = nil }
        await store.saveNow()
        #expect(try names(dir) == ["ui-state.json"])
        #expect(log.values.count == 1)
    }

    // A drag holds the saves. The end of the drag starts the timer again, and one save follows.
    @Test func noSaveDuringADragAndOneSaveAfterIt() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "ui-state.json")
        let clock = ManualClock()
        let store = await openStore(file, clock: clock)
        store.change { $0.current = snapshot() }
        await clock.waitForSleepers(1)
        store.holdSaves(true)
        #expect(store.timerTask == nil)
        store.change { _ = $0.saveLayout("Drag", snapshot()) }
        #expect(store.timerTask == nil)
        clock.advance(by: .seconds(5))
        #expect(try names(dir) == [])
        store.holdSaves(false)
        let timer = try #require(store.timerTask)
        await clock.waitForSleepers(1)
        clock.advance(by: UIStateStore.saveDelay)
        await timer.value
        let saved = try readSaved(file)
        #expect(field(saved, "current") == snapshotJSON)
        #expect(field(saved, "layouts") == [["name": "Drag", "snapshot": snapshotJSON]])
        // One save only: no timer waits, and a later time writes nothing.
        try FileManager.default.removeItem(at: file)
        #expect(store.timerTask == nil)
        #expect(clock.sleeperCount == 0)
        clock.advance(by: .seconds(5))
        await store.saveNow()
        #expect(try names(dir) == [])
    }

    // A change starts the timer again, so the save comes 500 ms after the last change.
    @Test func aSaveComes500msAfterTheLastChange() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "ui-state.json")
        let clock = ManualClock()
        let store = await openStore(file, clock: clock)
        store.change { $0.performance = 1 }
        let first = try #require(store.timerTask)
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(300))
        store.change { $0.performance = 2 }
        // The second change stops the first timer and starts a new one.
        let timer = try #require(store.timerTask)
        #expect(first.isCancelled)
        #expect(!timer.isCancelled)
        await clock.waitForSleepers(1)
        // 799 ms after the first change: the timer still sleeps, so no save came. The timer
        // task runs on the main actor too, so the count of the sleepers is the proof, not the
        // folder.
        clock.advance(by: .milliseconds(499))
        #expect(clock.sleeperCount == 1)
        #expect(try names(dir) == [])
        clock.advance(by: .milliseconds(1))
        await timer.value
        #expect(field(try readSaved(file), "performance") == 2)
        // A change that changes nothing starts no timer.
        store.change { $0.performance = 2 }
        #expect(store.timerTask == nil)
    }

    // The quit calls saveNow after a save of the timer started its write. The state did not
    // change after that save, but saveNow must still wait until the write ends. Then the app
    // can stop.
    @Test func saveNowWaitsForTheWriteOfATimerSave() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "ui-state.json")
        let clock = ManualClock()
        let gate = WriteGate()
        defer { gate.openAll() }
        let store = await openStore(file, clock: clock, steps: gate.steps)
        store.change { $0.current = snapshot() }
        let timer = try #require(store.timerTask)
        await clock.waitForSleepers(1)
        clock.advance(by: UIStateStore.saveDelay)
        // The save of the timer starts its write, and the write waits at the gate.
        try #require(await gate.waitUntilWriting())
        #expect(gate.isWriting)
        #expect(store.timerTask == nil)
        // saveNow ends only after the gate opens. Task.immediate starts it in this turn, so an
        // end before its wait would come before the open.
        let order = Recorder<String>()
        let quit = Task.immediate {
            await store.saveNow()
            order.record("saved")
        }
        order.record("opened")
        gate.open()
        await quit.value
        #expect(order.values == ["opened", "saved"])
        #expect(field(try readSaved(file), "current") == snapshotJSON)
        await timer.value
    }

    // A file that the old code wrote gives the same state, and a save of that state writes the
    // same bytes again.
    @Test func aFileOfTheOldCodeLoadsTheSameAndSavesTheSameBytes() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "ui-state.json")
        try write(fileOfTheOldCode, file)
        let store = await openStore(file)
        let loaded = store.state
        #expect(loaded == stateOfTheOldFile())
        store.change { $0.current = nil }
        store.change { $0 = loaded }
        await store.saveNow()
        #expect(try text(file) == fileOfTheOldCode)
    }

    // The state is observable: a reader of the state gets the change of any writer, and a change
    // that changes nothing gives no change.
    @Test func aReaderOfTheStateGetsEachChange() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let store = await openStore(folder.url.appending(path: "ui-state.json"))
        let changes = Mutex(0)
        withObservationTracking {
            _ = store.state.current
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        store.change { $0.current = snapshot() }
        #expect(changes.withLock { $0 } == 1)
        let unchanged = Mutex(0)
        withObservationTracking {
            _ = store.state.current
        } onChange: {
            unchanged.withLock { $0 += 1 }
        }
        store.change { $0.current = snapshot() }
        #expect(unchanged.withLock { $0 } == 0)
    }
}
