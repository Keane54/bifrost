import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

// The store of usage-alerts.json (docs/behaviour/usage.md, "The usage notification"). The parse
// rules are in UsageAlertRulesTests.swift. Each test uses its own temporary folder.

private let nowMs = utcMs(2026, 11, 10, 12, 0)
private let now = Date(timeIntervalSince1970: Double(nowMs) / 1000)
private let five = utcMs(2026, 11, 10, 14, 5)
private let seven = utcMs(2026, 11, 13, 13, 0)
private let day = 24 * 3_600_000

// The form of the file that the Electron app writes.
private let electronFile = """
    {
      "fiveHour": \(five),
      "sevenDay": null
    }

    """

@MainActor
private func openStore(
    _ file: URL, _ log: Recorder<StoreEvent> = .init(), steps: WriteSteps = .system
) async -> UsageAlertStore {
    await UsageAlertStore.open(file: file, now: now, log: log, steps: steps)
}

@MainActor
@Suite("usage alert store", .testTimeLimit)
struct UsageAlertStoreTests {
    @Test func noFileGivesNoNotifiedPeriod() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = folder.url.appending(path: "usage-alerts.json")
        let log = Recorder<StoreEvent>()
        #expect(await openStore(file, log).periods == NotifiedPeriods())
        #expect(log.values == [])
        #expect(try names(folder.url) == [])
    }

    @Test func aFileOfTheElectronAppGivesItsPeriods() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = folder.url.appending(path: "usage-alerts.json")
        try Data(electronFile.utf8).write(to: file)
        #expect(await openStore(file).periods == NotifiedPeriods(fiveHour: five))
    }

    @Test func aKeptValueMoreThan8DaysAfterTheOpenIsNoPeriod() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = folder.url.appending(path: "usage-alerts.json")
        try Data(#"{"fiveHour":\#(nowMs + 30 * day),"sevenDay":\#(seven)}"#.utf8).write(to: file)
        #expect(await openStore(file).periods == NotifiedPeriods(sevenDay: seven))
    }

    @Test func aSetWritesThePeriodsAndANewStoreReadsThem() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = folder.url.appending(path: "usage-alerts.json")
        let store = await openStore(file)
        let saved = NotifiedPeriods(fiveHour: five)
        await store.set(saved)?.value
        #expect(store.periods == saved)
        #expect(try readSaved(file) == ["fiveHour": .int(five), "sevenDay": .null])
        let mode = try FileManager.default.attributesOfItem(atPath: path(file))[.posixPermissions]
        #expect(mode as? Int == 0o600)
        #expect(try names(folder.url) == ["usage-alerts.json"])
        #expect(await openStore(file).periods == saved)
    }

    // The monitor reads the periods again before the write ends, so a set changes them at once.
    // A value that waits while a write runs gives its place to a newer value.
    @Test func aSetChangesThePeriodsAtOnceAndTheNewestValueWinsOnDisk() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = folder.url.appending(path: "usage-alerts.json")
        let gate = WriteGate()
        defer { gate.openAll() }
        let store = await openStore(file, steps: gate.steps)
        let first = store.set(NotifiedPeriods(fiveHour: five))
        #expect(store.periods == NotifiedPeriods(fiveHour: five))
        try #require(await gate.waitUntilWriting())
        store.set(NotifiedPeriods(sevenDay: seven))
        let last = store.set(NotifiedPeriods(fiveHour: five, sevenDay: seven))
        #expect(store.periods == NotifiedPeriods(fiveHour: five, sevenDay: seven))
        gate.open()
        gate.open()
        await first?.value
        await last?.value
        #expect(gate.writes == 2)
        #expect(await openStore(file).periods == NotifiedPeriods(fiveHour: five, sevenDay: seven))
    }

    // A file that does not parse gives no period. Before the first save over it, the store keeps
    // one copy of it (docs/behaviour/stores.md, Loading a file).
    @Test func aFileThatIsNotJSONGivesNoPeriodAndASaveKeepsACopyFirst() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = folder.url.appending(path: "usage-alerts.json")
        try Data("{ not json".utf8).write(to: file)
        let log = Recorder<StoreEvent>()
        let store = await openStore(file, log)
        #expect(store.periods == NotifiedPeriods())
        #expect(log.values == [])
        await store.set(NotifiedPeriods(fiveHour: five))?.value
        let copy = folder.url.appending(path: "usage-alerts.json.unreadable")
        #expect(try String(contentsOf: copy, encoding: .utf8) == "{ not json")
        #expect(try readSaved(file) == ["fiveHour": .int(five), "sevenDay": .null])
        #expect(log.values == [.keptUnreadableCopy(file: path(file), copy: path(copy))])
    }

    // JSON that is not an object gives no period, and a save writes over it.
    @Test func jsonThatIsNotAnObjectGivesNoPeriod() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = folder.url.appending(path: "usage-alerts.json")
        try Data("[\(five)]".utf8).write(to: file)
        let store = await openStore(file)
        #expect(store.periods == NotifiedPeriods())
        await store.set(NotifiedPeriods(sevenDay: seven))?.value
        #expect(try readSaved(file) == ["fiveHour": .null, "sevenDay": .int(seven)])
    }

    @Test func theStoreNeverWritesOverAFileThatItCannotRead() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        // A folder in place of the file gives a read error that is not ENOENT.
        let file = folder.url.appending(path: "usage-alerts.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let log = Recorder<StoreEvent>()
        let store = await openStore(file, log)
        #expect(store.periods == NotifiedPeriods())
        #expect(store.set(NotifiedPeriods(fiveHour: five)) == nil)
        #expect(store.periods == NotifiedPeriods(fiveHour: five))
        let error = FileError.system(.read, path: path(file), code: EISDIR)
        #expect(
            log.values == [.readFailed(file: path(file), what: "the usage alerts", error: error)])
        #expect(isFolder(file))
    }

    // A failed write logs its error and keeps the value in memory. The next set writes.
    @Test func aFailedWriteLogsTheErrorAndKeepsTheValue() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = folder.url.appending(path: "usage-alerts.json")
        let log = Recorder<StoreEvent>()
        let store = await openStore(file, log)
        // A folder in place of the file makes the write fail.
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await store.set(NotifiedPeriods(sevenDay: seven))?.value
        #expect(store.periods == NotifiedPeriods(sevenDay: seven))
        let error = FileError.system(.save, path: path(file), code: EISDIR)
        #expect(log.values == [.saveFailed(what: "the usage alerts", error: error)])
        try FileManager.default.removeItem(at: file)
        await store.set(NotifiedPeriods(fiveHour: five, sevenDay: seven))?.value
        #expect(try readSaved(file) == ["fiveHour": .int(five), "sevenDay": .int(seven)])
    }

    @Test func unknownTopLevelKeysSurviveASave() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = folder.url.appending(path: "usage-alerts.json")
        try Data(#"{"fiveHour":\#(five),"sevenDay":"x","later":{"a":1}}"#.utf8).write(to: file)
        let store = await openStore(file)
        #expect(store.periods.fiveHour == five)
        #expect(store.periods.sevenDay == nil)
        #expect(store.periods.unknown == UnknownFields(["later": ["a": 1]]))
        var next = store.periods
        next.sevenDay = seven
        await store.set(next)?.value
        #expect(
            try readSaved(file) == [
                "fiveHour": .int(five), "later": ["a": 1], "sevenDay": .int(seven),
            ])
    }
}
