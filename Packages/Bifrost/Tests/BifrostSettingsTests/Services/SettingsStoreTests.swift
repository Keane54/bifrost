import BifrostDailyUpdate
import BifrostKeyboard
import BifrostSessions
import BifrostTestSupport
import Foundation
import Observation
import Synchronization
import Testing

@testable import BifrostFoundation
@testable import BifrostSettings

// The settings store: the load of settings.json, the edits, the copies and the writes. Each test
// opens a SettingsStore in a temporary folder. A WriteGate holds a write, so a test can see what
// waits for it.

private func write(_ text: String, _ url: URL, mode: Int = 0o644) throws {
    let made = FileManager.default.createFile(
        atPath: path(url), contents: Data(text.utf8), attributes: [.posixPermissions: mode])
    if !made { throw CocoaError(.fileWriteUnknown) }
}

private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

// The JSON value that the encode of the settings gives.
private func json(_ settings: Settings) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(settings))
}

private func field(_ value: JSONValue, _ key: String) -> JSONValue? {
    guard case .object(let fields) = value else { return nil }
    return fields[key]
}

private func mode(_ url: URL) throws -> Int? {
    (try FileManager.default.attributesOfItem(atPath: path(url))[.posixPermissions] as? Int)
        .map { $0 & 0o777 }
}

private func with(_ change: (inout Settings) -> Void) -> Settings {
    var settings = Settings()
    change(&settings)
    return settings
}

private let space = with { $0.labels = .space }

// A settings.json in the form that the Electron app writes: JSON.stringify with an indent of 2
// and a final newline. The keys are in sorted order. Each field has a value that is not the
// default.
private let electronSettings = """
    {
      "accountUsage": true,
      "animatedBackground": false,
      "autoUpdate": false,
      "dailyUpdate": {
        "areas": [],
        "days": [
          1,
          2,
          3,
          4,
          5
        ],
        "deadline": "10:00",
        "draftTime": "09:30",
        "format": {
          "examples": [],
          "template": "Done: {{done}}"
        },
        "mergedPrs": true,
        "model": "",
        "source": {
          "server": null,
          "tools": []
        },
        "you": ""
      },
      "escalationMinutes": 0,
      "interfaceScale": 120,
      "keys": {
        "open:mod": "Mod+K",
        "stop:mod": null
      },
      "labels": "space",
      "notifications": false,
      "panelTransparency": 30,
      "pollSeconds": 5,
      "projectApp": "zed",
      "redBoxSound": false,
      "reviewsAutoFix": false,
      "reviewsIgnore": [
        "owner/*",
        "team/tools"
      ],
      "reviewsMaxSessions": 5,
      "reviewsPauseMinutes": 120,
      "reviewsPollMinutes": 5,
      "reviewsRequestModel": "sonnet",
      "reviewsReviewModel": "opus",
      "reviewsSignedCommits": true,
      "reviewsTeamRequests": false,
      "reviewsWatch": true,
      "rowFlash": false,
      "setupDone": true,
      "slashCommands": [
        "/compact",
        "/review"
      ],
      "snapDistance": 16,
      "startAtLogin": true,
      "terminalApp": "ghostty",
      "terminalFont": {
        "family": "Menlo",
        "size": 14
      },
      "version": 1
    }

    """

// A settings.json in the exact form that the store writes (JSONFile.encode), with the unknown
// fields future and theme.
private let storeSettings = """
    {
      "accountUsage" : false,
      "animatedBackground" : true,
      "autoUpdate" : true,
      "escalationMinutes" : 10,
      "future" : {
        "list" : [
          1,
          2.5
        ],
        "on" : true
      },
      "interfaceScale" : 100,
      "keys" : {
        "open:mod" : "Mod+K"
      },
      "labels" : "plain",
      "notifications" : true,
      "panelTransparency" : 15,
      "pollSeconds" : 2,
      "projectApp" : null,
      "redBoxSound" : true,
      "reviewsAutoFix" : true,
      "reviewsFixCI" : false,
      "reviewsIgnore" : [
        "owner/*"
      ],
      "reviewsMaxSessions" : 3,
      "reviewsPauseMinutes" : 60,
      "reviewsPollMinutes" : 2,
      "reviewsRequestModel" : "",
      "reviewsResolveConflicts" : false,
      "reviewsReviewModel" : "",
      "reviewsSignedCommits" : false,
      "reviewsTeamRequests" : true,
      "reviewsWatch" : false,
      "rowFlash" : true,
      "setupDone" : false,
      "slashCommands" : [
        "/compact",
        "/clear",
        "/context"
      ],
      "snapDistance" : 8,
      "startAtLogin" : false,
      "terminalApp" : null,
      "terminalFont" : {
        "family" : "SF Mono",
        "size" : 13
      },
      "theme" : "light",
      "version" : 1
    }

    """

// The steps of a safe write whose sync fails with an I/O error while failing is true.
private final class FailingSync: Sendable {
    let failing = Mutex(true)

    var steps: WriteSteps {
        WriteSteps(
            sync: { [self] handle in
                if failing.withLock({ $0 }) { throw POSIXError(.EIO) }
                try WriteSteps.system.sync(handle)
            }, rename: WriteSteps.system.rename)
    }
}

// The order of the steps of a test: the edits and the tasks add to it on the main actor.
@MainActor
private final class Steps {
    var all: [String] = []
}

// Counts the calls of onChange of one observation of the settings.
private final class Told: Sendable {
    private let count = Mutex(0)

    var calls: Int { count.withLock { $0 } }

    func tell() { count.withLock { $0 += 1 } }
}

@MainActor
private func observe(_ store: SettingsStore) -> Told {
    let told = Told()
    withObservationTracking { _ = store.settings } onChange: { told.tell() }
    return told
}

@MainActor
private func openStore(
    _ file: URL, _ log: Recorder<StoreEvent> = .init(), steps: WriteSteps = .system
) async -> SettingsStore {
    await SettingsStore.open(file: file, log: log, steps: steps)
}

@MainActor
@Suite("the settings store", .testTimeLimit)
struct SettingsStoreTests {
    @Test func aMissingFileGivesTheDefaultsAndAnEditSaves() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "settings.json")
        let store = await openStore(file)
        #expect(store.settings == Settings())
        let next = try await store.edit { $0.labels = .space }
        #expect(next == space)
        #expect(store.settings == next)
        #expect(try readSaved(file) == json(space))
        #expect(try mode(file) == 0o600)
    }

    @Test func badJSONGivesTheDefaultsAndAnEditSaves() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "settings.json")
        try write("{ no", file)
        let store = await openStore(file)
        #expect(store.settings == Settings())
        try await store.edit { $0.pollSeconds = 5 }
        let saved = try readSaved(file)
        #expect(field(saved, "pollSeconds") == 5)
        #expect(field(saved, "version") == 1)
    }

    @Test func aDamagedFileKeepsItsGoodValues() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "settings.json")
        let keys: JSONValue = ["nope:mod": "Mod+J", "open:mod": "Mod+K"]
        let stored: JSONValue = [
            "keys": keys, "labels": "space", "pollSeconds": 0,
            "slashCommands": ["/review", "/two\nlines"],
            "terminalFont": ["family": "Menlo", "size": 200], "theme": "light", "version": 1,
        ]
        try JSONFile.write(try JSONFile.encode(stored), to: file)
        let store = await openStore(file)
        // keys stays raw (the key part is in KeyMapSettingsTests). theme is an unknown field.
        #expect(
            store.settings
                == with {
                    $0.keys = keys
                    $0.labels = .space
                    $0.slashCommands = ["/review"]
                    $0.terminalFont = TerminalFont(family: "Menlo", size: 13)
                    $0.unknown = UnknownFields(["theme": "light"])
                })
    }

    // With the save off, an edit changes the settings and writes nothing.
    @Test func aFileThatCannotBeReadIsNeverWritten() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "settings.json")
        // The path is a folder, so the read fails with EISDIR.
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let log = Recorder<StoreEvent>()
        let store = await openStore(file, log)
        let error = FileError.system(.read, path: path(file), code: EISDIR)
        #expect(log.values == [.readFailed(file: path(file), what: "the settings", error: error)])
        #expect(store.settings == Settings())
        let next = try await store.edit { $0.labels = .space }
        #expect(next.labels == .space)
        #expect(store.settings.labels == .space)
        #expect(log.values.count == 1)
        // Nothing writes: the folder stays empty and no temporary file is next to it.
        #expect(isFolder(file))
        #expect(try names(file) == [])
        #expect(try names(dir) == ["settings.json"])
    }

    // The settings are observed: an edit tells each observer before it returns. An
    // edit that changes nothing writes nothing and tells no observer.
    @Test func anEditTellsTheObserversAndAnEditThatChangesNothingDoesNot() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "settings.json")
        let store = await openStore(file)
        let first = observe(store)
        let next = try await store.edit { $0.labels = .space }
        #expect(first.calls == 1)
        #expect(store.settings == next)
        #expect(next == space)
        try FileManager.default.removeItem(at: file)
        let second = observe(store)
        #expect(try await store.edit { $0.labels = .space } == next)
        #expect(second.calls == 0)
        #expect(!FileManager.default.fileExists(atPath: path(file)))
    }

    // A refused edit throws the reason of its check. The settings stay, nothing is written, no
    // observer hears of it, and the next edit runs. A refused text gives its friendly reason.
    @Test func aRefusedEditThrowsItsReasonAndChangesNothing() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "settings.json")
        let store = await openStore(file)
        let told = observe(store)
        await #expect(throws: SettingsError.refused(.field(.pollSeconds))) {
            try await store.edit { $0.pollSeconds = 4 }
        }
        await #expect(throws: SettingsError.refused(.slashStart)) {
            try await store.edit { $0.slashCommands.append("compact") }
        }
        await #expect(throws: SettingsError.refused(.field(.interfaceScale))) {
            try await store.edit { $0.interfaceScale = 155 }
        }
        #expect(store.settings == Settings())
        #expect(told.calls == 0)
        #expect(try names(dir) == [])
        #expect(try await store.edit { $0.interfaceScale -= 10 }.interfaceScale == 90)
        #expect(field(try readSaved(file), "interfaceScale") == 90)
    }

    // Two quick edits never start from the same old value: an edit runs on the newest settings
    // after the earlier edits end, in the order of the calls. The first write waits at the gate,
    // so the later edits wait too.
    @Test func quickEditsRunInTurnOnTheNewestSettings() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "settings.json")
        let gate = WriteGate()
        defer { gate.openAll() }
        let store = await openStore(file, steps: gate.steps)
        let steps = Steps()
        let first = Task.immediate {
            try await store.edit {
                steps.all.append("edit 1")
                $0.interfaceScale += 10
            }
        }
        try #require(await gate.waitUntilWriting())
        let second = Task.immediate {
            try await store.edit {
                steps.all.append("edit 2")
                $0.interfaceScale += 10
            }
        }
        let third = Task.immediate {
            try await store.edit {
                steps.all.append("edit 3")
                $0.labels = .space
            }
        }
        // The edits started at once (Task.immediate) and wait for the first.
        #expect(steps.all == ["edit 1"])
        #expect(store.settings == Settings())
        for _ in 0..<3 { gate.open() }
        let results = try await [first.value, second.value, third.value]
        #expect(steps.all == ["edit 1", "edit 2", "edit 3"])
        #expect(results.map(\.interfaceScale) == [110, 120, 120])
        let expected = with {
            $0.interfaceScale = 120
            $0.labels = .space
        }
        #expect(store.settings == expected)
        #expect(try readSaved(file) == json(expected))
    }

    // A failed write keeps the old settings and throws notSaved with the text of the error. The
    // next edit starts from the old settings. The log gets the failed save one time, for the
    // health log of the app (HealthStoreLog).
    @Test func aFailedWriteKeepsTheOldSettingsAndThrowsNotSaved() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "settings.json")
        let failing = FailingSync()
        let log = Recorder<StoreEvent>()
        let store = await openStore(file, log, steps: failing.steps)
        let told = observe(store)
        let error = await #expect(throws: SettingsError.self) {
            try await store.edit { $0.labels = .space }
        }
        let failure = FileError.system(.save, path: path(file), code: EIO)
        #expect(error == .notSaved(failure))
        #expect(log.values == [.saveFailed(what: "the settings", error: failure)])
        #expect(store.settings == Settings())
        #expect(told.calls == 0)
        #expect(try names(dir) == [])
        failing.failing.withLock { $0 = false }
        #expect(try await store.edit { $0.pollSeconds = 5 } == with { $0.pollSeconds = 5 })
        _ = try? await store.edit { $0.pollSeconds = 4 }
        try await store.edit { $0.pollSeconds = 5 }
        #expect(log.values.count == 1)
        #expect(try readSaved(file) == json(with { $0.pollSeconds = 5 }))
    }

    @Test func theFirstWriteOverALaterVersionKeepsOneCopy() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "settings.json")
        let later = """
            {
                "labels": "space",
                "newThing": {
                    "a": 1
                },
                "version": 2
            }

            """
        try write(later, file, mode: 0o644)
        let backup = dir.appending(path: "settings.v2.backup.json")
        let log = Recorder<StoreEvent>()
        let store = await openStore(file, log)
        // The open itself writes nothing.
        #expect(try names(dir) == ["settings.json"])
        try await store.edit { $0.pollSeconds = 5 }
        #expect(try text(backup) == later)
        #expect(try mode(backup) == 0o600)
        let saved = try readSaved(file)
        #expect(field(saved, "pollSeconds") == 5)
        #expect(field(saved, "version") == 1)
        // A good copy of a later version logs nothing more than the load line.
        #expect(log.values == [.defaulted(file: path(file), keys: ["labels", "version"])])
        // The second write does not copy again.
        try FileManager.default.removeItem(at: backup)
        try await store.edit { $0.pollSeconds = 10 }
        #expect(try names(dir) == ["settings.json"])
    }

    @Test func theCopyReplacesAnOlderCopyWithMode0600() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "settings.json")
        try write(#"{"version":2}"#, file)
        let backup = dir.appending(path: "settings.v2.backup.json")
        try write("old", backup, mode: 0o644)
        try await openStore(file).edit { $0.pollSeconds = 5 }
        #expect(try text(backup) == #"{"version":2}"#)
        #expect(try mode(backup) == 0o600)
    }

    // Bad JSON gets the copy settings.json.unreadable. It is not a backup copy.
    @Test func aVersion1FileAMissingFileAndBadJSONGiveNoBackupCopy() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "settings.json")
        try write(#"{"version":1}"#, file)
        try await openStore(file).edit { $0.pollSeconds = 5 }
        try FileManager.default.removeItem(at: file)
        try await openStore(file).edit { $0.pollSeconds = 5 }
        #expect(try names(dir) == ["settings.json"])
        try write(#"{ "version": 3"#, file)
        try await openStore(file).edit { $0.pollSeconds = 5 }
        #expect(try names(dir) == ["settings.json", "settings.json.unreadable"])
    }

    // A failed copy turns the save off, so the file of the later version stays. The edit still
    // changes the settings. The load also logs the keys that got their defaults, so the log has
    // two lines.
    @Test func aFailedCopyKeepsTheFileAndTurnsTheSaveOff() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "settings.json")
        try write(#"{"version":4}"#, file)
        // A folder with the name of the copy makes the copy fail.
        let backup = dir.appending(path: "settings.v4.backup.json")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
        let log = Recorder<StoreEvent>()
        let store = await openStore(file, log)
        #expect(try await store.edit { $0.labels = .space } == space)
        let error = FileError.system(.copy(to: path(backup)), path: path(file), code: EISDIR)
        #expect(
            log.values == [
                .defaulted(file: path(file), keys: ["version"]),
                .copyFailed(
                    file: path(file), copy: path(backup), what: "the settings", error: error),
            ])
        #expect(try readSaved(file) == ["version": 4])
        #expect(try await store.edit { $0.pollSeconds = 5 }.pollSeconds == 5)
        #expect(try readSaved(file) == ["version": 4])
        #expect(log.values.count == 2)
    }

    // A file from a newer app has fields that this app does not know. Each save keeps them.
    @Test func unknownFieldsOfSettingsJsonSurviveAnEdit() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "settings.json")
        let future: JSONValue = ["list": [1, 2], "on": true]
        let stored: JSONValue = [
            "version": 1, "labels": "space", "theme": "light", "future": future,
        ]
        try JSONFile.write(try JSONFile.encode(stored), to: file)
        let store = await openStore(file)
        try await store.edit { $0.pollSeconds = 5 }
        try await store.edit { $0.rowFlash = false }
        let saved = try readSaved(file)
        #expect(field(saved, "theme") == "light")
        #expect(field(saved, "future") == future)
        #expect(
            field(saved, "labels") == "space" && field(saved, "pollSeconds") == 5
                && field(saved, "rowFlash") == false)
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: file))
        #expect(decoded == store.settings)
    }

    // A settings.json in the form that the Electron app writes (JSON.stringify with an indent of
    // 2), with a value that is not the default in each field. Each value loads, and a save
    // keeps each field as it is, also the raw keys and the raw daily update.
    @Test func anElectronFileLoadsEachValueAndASaveKeepsEachField() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "settings.json")
        try write(electronSettings, file)
        let tree = try readSaved(file)
        let log = Recorder<StoreEvent>()
        let store = await openStore(file, log)
        #expect(log.values.isEmpty)
        #expect(store.settings.unknown.values.isEmpty)
        #expect(
            store.settings
                == with {
                    $0.accountUsage = true
                    $0.animatedBackground = false
                    $0.autoUpdate = false
                    $0.dailyUpdate = field(tree, "dailyUpdate").flatMap(DailySettings.init(json:))
                    $0.escalationMinutes = 0
                    $0.interfaceScale = 120
                    $0.keys = ["open:mod": "Mod+K", "stop:mod": .null]
                    $0.labels = .space
                    $0.notifications = false
                    $0.panelTransparency = 30
                    $0.pollSeconds = 5
                    $0.projectApp = .zed
                    $0.redBoxSound = false
                    $0.reviewsAutoFix = false
                    $0.reviewsIgnore = ["owner/*", "team/tools"]
                    $0.reviewsMaxSessions = 5
                    $0.reviewsPauseMinutes = 120
                    $0.reviewsPollMinutes = 5
                    $0.reviewsRequestModel = .sonnet
                    $0.reviewsReviewModel = .opus
                    $0.reviewsSignedCommits = true
                    $0.reviewsTeamRequests = false
                    $0.reviewsWatch = true
                    $0.rowFlash = false
                    $0.setupDone = true
                    $0.slashCommands = ["/compact", "/review"]
                    $0.snapDistance = 16
                    $0.startAtLogin = true
                    $0.terminalApp = .ghostty
                    $0.terminalFont = TerminalFont(family: "Menlo", size: 14)
                })
        try await store.edit { $0.pollSeconds = 10 }
        var fields = try #require(tree.fields, "the file is an object")
        fields["pollSeconds"] = 10
        // The settings that only this app has get their defaults.
        fields["reviewsFixCI"] = false
        fields["reviewsResolveConflicts"] = false
        #expect(try readSaved(file) == .object(fields))
    }

    // A file in the exact form that the store writes, with two unknown fields. It loads, and a
    // save of the same settings writes the same bytes.
    @Test func aFileOfTheStoreLoadsTheSameAndSavesTheSameBytes() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "settings.json")
        try write(storeSettings, file)
        let log = Recorder<StoreEvent>()
        let store = await openStore(file, log)
        #expect(log.values.isEmpty)
        let future: JSONValue = ["list": [1, 2.5], "on": true]
        #expect(
            store.settings
                == with {
                    $0.keys = ["open:mod": "Mod+K"]
                    $0.reviewsIgnore = ["owner/*"]
                    $0.unknown = UnknownFields(["future": future, "theme": "light"])
                })
        try await store.edit { $0.pollSeconds = 5 }
        try await store.edit { $0.pollSeconds = 2 }
        #expect(try text(file) == storeSettings)
    }

    // JSONDecoder refuses a number outside the Double range in a raw value, so all
    // settings get their defaults. The file is not lost: before the first save, the store keeps
    // a copy. The copy and its log line come before the write.
    @Test func aFileThatDoesNotParseIsKeptAsUnreadableBeforeTheFirstSave() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "settings.json")
        let stored = #"{"keys":{"open:mod":1e400},"labels":"space","version":1}"#
        try write(stored, file)
        let gate = WriteGate()
        defer { gate.openAll() }
        let log = Recorder<StoreEvent>()
        let store = await openStore(file, log, steps: gate.steps)
        #expect(store.settings == Settings())
        // The open itself writes nothing.
        #expect(try names(dir) == ["settings.json"])
        let edit = Task.immediate { try await store.edit { $0.pollSeconds = 5 } }
        try #require(await gate.waitUntilWriting())
        let copy = dir.appending(path: "settings.json.unreadable")
        #expect(try text(copy) == stored)
        #expect(log.values == [.keptUnreadableCopy(file: path(file), copy: path(copy))])
        #expect(try text(file) == stored)
        gate.open()
        _ = try await edit.value
        #expect(field(try readSaved(file), "pollSeconds") == 5)
        // The second save does not copy again.
        try FileManager.default.removeItem(at: copy)
        gate.open()
        try await store.edit { $0.pollSeconds = 10 }
        #expect(try names(dir) == ["settings.json"])
        #expect(log.values.count == 1)
    }

    // A number outside the Double range in a field with a type is a bad value: the field gets
    // its default, the other fields stay, and the load logs the key. The file is JSON, so no
    // copy is kept.
    @Test func aNumberOutsideTheDoubleRangeInAFieldGetsTheDefault() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "settings.json")
        try write(#"{"labels":"space","pollSeconds":1e400,"version":1}"#, file)
        let log = Recorder<StoreEvent>()
        let store = await openStore(file, log)
        #expect(store.settings == space)
        #expect(log.values == [.defaulted(file: path(file), keys: ["pollSeconds"])])
        try await store.edit { $0.pollSeconds = 5 }
        #expect(try names(dir) == ["settings.json"])
    }

    // A failed copy of a file that does not parse logs only the failure, and the save
    // is off. The edit still changes the settings.
    @Test func aFailedCopyOfAFileThatDoesNotParseLogsOnlyTheFailure() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "settings.json")
        try write("{ no", file)
        let copy = dir.appending(path: "settings.json.unreadable")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: false)
        let log = Recorder<StoreEvent>()
        let store = await openStore(file, log)
        #expect(try await store.edit { $0.labels = .space } == space)
        let error = FileError.system(.copy(to: path(copy)), path: path(file), code: EISDIR)
        #expect(
            log.values == [
                .copyFailed(file: path(file), copy: path(copy), what: "the settings", error: error)
            ])
        #expect(try text(file) == "{ no")
    }

    // A raw value with no JSON form makes a file of a later version a file that does not parse:
    // the store keeps the .unreadable copy, not the backup copy of the later version.
    @Test func aRawValueWithNoJSONFormInALaterVersionGivesTheUnreadableCopy() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "settings.json")
        let stored = #"{"keys":{"open:mod":1e400},"version":2}"#
        try write(stored, file)
        try await openStore(file).edit { $0.pollSeconds = 5 }
        #expect(try names(dir) == ["settings.json", "settings.json.unreadable"])
        #expect(try text(dir.appending(path: "settings.json.unreadable")) == stored)
    }

    // The store keeps one copy. The new copy replaces an old copy.
    @Test func theUnreadableCopyReplacesAnOldCopy() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "settings.json")
        // A lone surrogate escape in a raw value. JSONDecoder refuses it.
        let stored = #"{"keys":{"open:mod":"\ud800"},"labels":"space","version":1}"#
        try write(stored, file)
        let copy = dir.appending(path: "settings.json.unreadable")
        try write("old", copy)
        try await openStore(file).edit { $0.labels = .space }
        #expect(try text(copy) == stored)
        #expect(try names(dir) == ["settings.json", "settings.json.unreadable"])
    }

    // The load logs the keys whose values the settings do not keep, in one line.
    @Test func theLoadLogsTheKeysThatGotTheirDefaults() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "settings.json")
        let stored: JSONValue = [
            "labels": "space", "pollSeconds": 0, "slashCommands": ["/review", "/two\nlines"],
            "terminalFont": ["family": "Menlo", "size": 200], "theme": "light", "version": 1,
        ]
        try JSONFile.write(try JSONFile.encode(stored), to: file)
        let log = Recorder<StoreEvent>()
        _ = await openStore(file, log)
        let keys = ["pollSeconds", "slashCommands", "terminalFont"]
        #expect(log.values == [.defaulted(file: path(file), keys: keys)])
        // A good file logs nothing.
        let good: JSONValue = ["labels": "space", "version": 1]
        try JSONFile.write(try JSONFile.encode(good), to: file)
        let quiet = Recorder<StoreEvent>()
        _ = await openStore(file, quiet)
        #expect(quiet.values.isEmpty)
    }

    // The name of the backup copy has the version of the file: a whole number with no ".0",
    // else the decimal text of the number.
    @Test func theBackupNameHasTheVersionOfTheFile() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "settings.json")
        for (stored, name) in [
            (#"{"version":2}"#, "settings.v2.backup.json"),
            (#"{"version":2.0}"#, "settings.v2.backup.json"),
            (#"{"version":3e2}"#, "settings.v300.backup.json"),
            (#"{"version":2.5}"#, "settings.v2.5.backup.json"),
            (#"{"version":1e21}"#, "settings.v1e+21.backup.json"),
        ] {
            try write(stored, file)
            try await openStore(file).edit { $0.pollSeconds = 5 }
            #expect(try names(dir) == ["settings.json", name])
            try FileManager.default.removeItem(at: dir.appending(path: name))
        }
    }

    // The quit waits for the settings writes. The first write waits at the gate when the quit
    // starts to wait, and a second edit comes during the wait. waitForWrites ends only after both
    // writes. With no edit, it ends at once.
    @Test func waitForWritesWaitsForEachEditThatRunsOrWaits() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "settings.json")
        let gate = WriteGate()
        defer { gate.openAll() }
        let store = await openStore(file, steps: gate.steps)
        await store.waitForWrites()
        let steps = Steps()
        let first = Task.immediate {
            try await store.edit {
                steps.all.append("edit 1")
                $0.pollSeconds = 5
            }
        }
        try #require(await gate.waitUntilWriting())
        let quit = Task.immediate {
            await store.waitForWrites()
            steps.all.append("quit")
        }
        let second = Task.immediate {
            try await store.edit {
                steps.all.append("edit 2")
                $0.pollSeconds = 10
            }
        }
        gate.open()
        await waitUntil { steps.all == ["edit 1", "edit 2"] }
        // The write of the second edit waits at the gate, so the quit waits too.
        try #require(await gate.waitUntilWriting())
        #expect(steps.all == ["edit 1", "edit 2"])
        gate.open()
        await quit.value
        #expect(steps.all == ["edit 1", "edit 2", "quit"])
        #expect(field(try readSaved(file), "pollSeconds") == 10)
        _ = try await (first.value, second.value)
    }
}
