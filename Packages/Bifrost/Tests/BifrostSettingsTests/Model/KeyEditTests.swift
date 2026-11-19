// The key edits through the settings store (docs/behaviour/stores.md, settings.json): the key
// edit of a raw value, the save of a recorded key and Reset all keys. Each test opens a store in
// a temporary folder with a seeded settings.json.
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostFoundation
@testable import BifrostKeyboard
@testable import BifrostSettings

// A temporary folder with a settings.json of these keys, and the store of the file.
@MainActor
private final class SeededStore {
    let folder: TemporaryFolder
    let file: URL
    let store: SettingsStore

    init(keys: JSONValue?) async throws {
        folder = try TemporaryFolder()
        file = folder.url.appending(path: "settings.json")
        var fields: [String: JSONValue] = ["version": 1]
        if let keys { fields["keys"] = keys }
        try JSONEncoder().encode(JSONValue.object(fields)).write(to: file)
        store = await SettingsStore.open(file: file, log: Recorder<StoreEvent>())
    }

    // The keys value of the file, or nil when the file has none.
    func savedKeys() throws -> JSONValue? {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
        guard case .object(let fields) = value else { return nil }
        return fields["keys"]
    }

    // The keys after the store opens the file again.
    func reopenedKeys() async -> JSONValue? {
        await SettingsStore.open(file: file, log: Recorder<StoreEvent>()).settings.keys
    }

    // A key edit of a raw value, as the test port makes it: the check against the keys of the
    // store, then one edit.
    func edit(_ patch: JSONValue) async throws {
        let edit = try KeyEdit(patch: patch, old: store.settings.keys)
        try await store.edit { $0.keys = edit.stored(keeping: $0.keys) }
    }

    // A recorded key event for a slot, as the key recorder saves it: the check against the keys
    // of the store, then one edit of the newest keys.
    func record(_ event: KeyEvent, for slot: KeySlot) async throws {
        let chord = try KeyEditor.checkRecorded(
            event, slot: slot, old: KeyMap(stored: store.settings.keys)
        ).get()
        try await store.edit {
            var changes = KeyChanges(stored: $0.keys)
            changes.set(.chord(chord), for: slot)
            $0.keys = changes.stored(keeping: $0.keys)
        }
    }

    deinit { folder.remove() }
}

// The key down of a letter of a US keyboard with Cmd.
private func commandKey(_ letter: Character) -> KeyEvent {
    KeyEvent(
        keyCode: KeyCode(us: letter) ?? KeyCode(.space), characters: String(letter).lowercased(),
        modifiers: .command)
}

@MainActor
@Suite("the key edits of the settings", .testTimeLimit)
struct KeyEditTests {
    // An unknown slot, a bad value and a new conflict refuse the edit. The settings and the file
    // stay as they were.
    @Test func aRefusedKeyEditLeavesTheSettingsAndTheFile() async throws {
        let keys: JSONValue = ["stop:key": .null]
        let seeded = try await SeededStore(keys: keys)
        let before = seeded.store.settings
        let refused: [(JSONValue, KeyEditRefusal)] = [
            (["nope:mod": "Mod+K"], .unknownSlot("nope:mod")),
            (["open:mod": "Mod+Q"], .badValue(keySlot("open:mod"))),
            (["open:mod": 7], .badValue(keySlot("open:mod"))),
            (["open:mod": "Mod+L"], .newConflict),
            ([], .notAnObject),
        ]
        for (patch, refusal) in refused {
            await #expect(throws: refusal, "\(patch)") { try await seeded.edit(patch) }
        }
        #expect(seeded.store.settings == before)
        #expect(try seeded.savedKeys() == keys)
    }

    // The file has a conflict: the Event log has the key of New session. An edit of another
    // slot saves and keeps the conflict, and the key map still gives the key to New session.
    @Test func aKeyEditKeepsAConflictOfTheFile() async throws {
        let seeded = try await SeededStore(keys: ["event-log:mod": "Mod+N"])
        try await seeded.edit(["open:mod": "Mod+K"])
        let saved: JSONValue = ["event-log:mod": "Mod+N", "open:mod": "Mod+K"]
        #expect(try seeded.savedKeys() == saved)
        let reopened = await seeded.reopenedKeys()
        #expect(reopened == saved)
        let map = KeyMap(stored: reopened)
        let pair = KeyConflict(first: keySlot("new-session:mod"), second: keySlot("event-log:mod"))
        #expect(map.conflicts == [pair])
        #expect(map.activeBindings.first { $0.chord == chord("Mod+N") }?.slot == pair.first)
        // A recorded key of a third slot saves too.
        try await seeded.record(commandKey("J"), for: keySlot("copy-id:mod"))
        #expect(KeyMap(stored: seeded.store.settings.keys).conflicts == [pair])
    }

    // A saved key edit keeps each other entry of the file as it was: a slot of a later version,
    // a key that this version cannot read, and a key of another spelling.
    @Test func aSavedKeyEditKeepsEveryOtherEntryOfTheFile() async throws {
        let keys: JSONValue = [
            "future:mod": "Mod+J", "open:mod": "Hyper+K", "copy-id:mod": "cmd+shift+k",
            "rename:key": 5,
        ]
        let seeded = try await SeededStore(keys: keys)
        try await seeded.edit(["stop:key": .null, "dictation:hold": "K"])
        let saved: JSONValue = [
            "future:mod": "Mod+J", "open:mod": "Hyper+K", "copy-id:mod": "cmd+shift+k",
            "rename:key": 5, "stop:key": .null, "dictation:hold": "K",
        ]
        #expect(try seeded.savedKeys() == saved)
        #expect(await seeded.reopenedKeys() == saved)
    }

    // An edit that gives each named slot the key that it has writes nothing.
    @Test func aKeyEditThatChangesNothingWritesNothing() async throws {
        let seeded = try await SeededStore(keys: ["stop:key": .null, "open:mod": "Mod+K"])
        let before = seeded.store.settings
        try FileManager.default.removeItem(at: seeded.file)
        try await seeded.edit(["stop:key": .null, "open:mod": "mod+k", "rename:key": "R"])
        #expect(seeded.store.settings == before)
        #expect(!FileManager.default.fileExists(atPath: seeded.file.path(percentEncoded: false)))
    }

    // A recorded key saves only its own slot. An entry of a later version stays in the file.
    @Test func anUnknownKeyEntrySurvivesARecordedKey() async throws {
        let keys: JSONValue = ["future:mod": "Mod+J", "open:mod": "Hyper+K", "rename:key": 5]
        let seeded = try await SeededStore(keys: keys)
        try await seeded.record(commandKey("K"), for: keySlot("copy-id:mod"))
        let saved: JSONValue = [
            "future:mod": "Mod+J", "open:mod": "Hyper+K", "rename:key": 5, "copy-id:mod": "Mod+K",
        ]
        #expect(try seeded.savedKeys() == saved)
        #expect(await seeded.reopenedKeys() == saved)
        // A refused key saves nothing: Cmd+L is the key of the Event log.
        await #expect(throws: RecordRefusal.binding(.conflict(with: keySlot("event-log:mod")))) {
            try await seeded.record(commandKey("L"), for: keySlot("open:mod"))
        }
        #expect(try seeded.savedKeys() == saved)
    }

    // Seeded key maps with conflicts, unknown slots and Space go through the store and back:
    // a recorded key saves, and the next open reads the same keys.
    @Test(
        arguments: [
            ["event-log:mod": "Mod+N", "usage-hud:mod": "Mod+N"],
            ["future:mod": "Mod+J", "later.2:hold": .null, "open:key": "Space"],
            ["dictation:hold": "Space", "open:hold": "Space", "send-message:key": "space"],
            ["open:key": "K", "open:hold": "K", "dictation:hold": "K"],
            ["select-row.1:mod": .null, "escape:key": "Hyper+Escape", "stop:key": ["x": 1]],
        ] as [JSONValue])
    func seededKeyMapsGoThroughTheStoreAndBack(_ keys: JSONValue) async throws {
        let seeded = try await SeededStore(keys: keys)
        let map = KeyMap(stored: seeded.store.settings.keys)
        try await seeded.record(commandKey("G"), for: keySlot("resume:mod"))
        let saved = try #require(try seeded.savedKeys())
        #expect(await seeded.reopenedKeys() == saved)
        // Each old entry stays, and the recorded key is in the file.
        guard case .object(let old) = keys, case .object(let new) = saved else {
            Issue.record("the keys are not objects")
            return
        }
        #expect(new.filter { $0.key != "resume:mod" } == old)
        #expect(new["resume:mod"] == "Mod+G")
        // The key map changed only for the recorded slot.
        var expected = KeyChanges(stored: keys)
        expected.set(.chord(chord("Mod+G")), for: keySlot("resume:mod"))
        #expect(KeyMap(stored: saved) == KeyMap(expected))
        #expect(KeyMap(stored: saved).conflicts == map.conflicts)
    }

    // Reset all keys gives every slot its default key and saves only the entries that this
    // version cannot read. With no keys in the file, a reset writes nothing.
    @Test func resetAllKeysSavesOnlyTheEntriesThatThisVersionCannotRead() async throws {
        let keys: JSONValue = [
            "future:mod": "Mod+J", "open:mod": "Hyper+K", "stop:key": .null, "copy-id:mod": "Mod+K",
        ]
        let seeded = try await SeededStore(keys: keys)
        try await seeded.store.edit { $0.keys = KeyEditor.resetAll(keeping: $0.keys) }
        let saved: JSONValue = ["future:mod": "Mod+J", "open:mod": "Hyper+K"]
        #expect(try seeded.savedKeys() == saved)
        #expect(KeyMap(stored: seeded.store.settings.keys) == .defaults)
        let empty = try await SeededStore(keys: nil)
        try FileManager.default.removeItem(at: empty.file)
        try await empty.store.edit { $0.keys = KeyEditor.resetAll(keeping: $0.keys) }
        #expect(empty.store.settings.keys == nil)
        #expect(!FileManager.default.fileExists(atPath: empty.file.path(percentEncoded: false)))
    }
}
