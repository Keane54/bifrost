// The key parts of the settings, which the key rules read and write. The settings keep
// the raw keys value (Settings.keys, row S2). The settings edge converts it: KeyChanges(stored:)
// and KeyMap(stored:) read it with the key rules, and KeyChanges.stored(keeping:) writes it.
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostFoundation
@testable import BifrostKeyboard
@testable import BifrostSettings

private func stored(_ fields: [String: JSONValue]) -> JSONValue {
    var object = fields
    object["version"] = 1
    return .object(object)
}

@Suite("the key parts")
struct KeyMapSettingsTests {
    // The default settings have keys: {}. A value that is not settings gives the defaults, so it
    // gives the default key map.
    @Test
    func defaultsForBadData() {
        let bad: [JSONValue] = [.null, [], "x", 7, ["version": 2], ["labels": "space"]]
        for value in bad {
            let keys = decodedSettings(value).keys
            #expect(KeyChanges(stored: keys).isEmpty, "\(String(describing: value))")
            #expect(KeyMap(stored: keys) == .defaults)
        }
        #expect(KeyChanges(stored: Settings().keys).isEmpty)
    }

    @Test
    func appsChoicesFontAndKeys() {
        let keys: JSONValue = ["nope:mod": "Mod+J", "open:key": "K"]
        let parsed = decodedSettings(stored(["keys": keys, "pollSeconds": 10]))
        #expect(KeyChanges(stored: parsed.keys) == keyChanges(["open:key": "K"]))
        #expect(KeyMap(stored: parsed.keys)[keySlot("open:key")] == .chord(chord("K")))
        #expect(KeySlot("nope:mod") == nil)
    }

    @Test("a damaged settings file keeps its good key values")
    func damagedFile() {
        let keys: JSONValue = ["nope:mod": "Mod+J", "open:mod": "Mod+K"]
        let parsed = decodedSettings(
            stored(["keys": keys, "labels": "space", "pollSeconds": 0, "theme": "light"]))
        #expect(KeyChanges(stored: parsed.keys) == keyChanges(["open:mod": "Mod+K"]))
        #expect(KeyMap(stored: parsed.keys)[keySlot("open:mod")] == .chord(chord("Mod+K")))
    }

    // The settings keep the raw value, so an entry of a later version (an unknown slot, or a key
    // that this version refuses) stays in the file. The key map reads only the good entries.
    @Test func theKeyMapReadsTheRawKeysAndTheRawKeysStay() {
        let keys: JSONValue = [
            "future:mod": "Mod+J", "open:mod": "cmd+k", "stop:mod": .null, "rename:key": 5,
        ]
        let parsed = decodedSettings(stored(["keys": keys]))
        #expect(parsed.keys == keys)
        let map = KeyMap(stored: parsed.keys)
        #expect(map == KeyMap(keyChanges(["open:mod": "Mod+K", "stop:mod": nil])))
        #expect(map[keySlot("rename:key")] == .chord(chord("R")))
    }

    // A key edit goes through the settings file and back: the typed changes become the stored
    // keys, the settings save and load, and the stored keys give the same changes. A changed key
    // has its standard form, Off is null, and each entry of a slot with no change stays as it
    // was: the entry of a later version and a value that this version cannot read.
    @Test func aKeyEditGoesThroughTheSettingsFileAndBack() throws {
        let keys: JSONValue = ["future:mod": "Mod+J", "open:mod": "cmd+k", "rename:key": 5]
        var settings = decodedSettings(stored(["keys": keys]))
        var changes = KeyChanges(stored: settings.keys)
        changes.set(.off, for: .dictation)
        changes.set(.chord(chord("Mod+Shift+W")), for: .closePanel)
        changes.set(.chord(chord("Mod+N")), for: keySlot("event-log:mod"))
        changes.reset(keySlot("open:mod"))
        settings.keys = changes.stored(keeping: settings.keys)
        #expect(
            settings.keys == [
                "future:mod": "Mod+J", "rename:key": 5, "dictation:hold": .null,
                "close-panel:mod": "Mod+Shift+W", "event-log:mod": "Mod+N",
            ])
        let file = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(settings))
        let loaded = decodedSettings(file)
        #expect(loaded.keys == settings.keys)
        #expect(KeyChanges(stored: loaded.keys) == changes)
        let map = KeyMap(stored: loaded.keys)
        #expect(map == KeyMap(changes))
        #expect(map.dictationKey == nil)
        #expect(map[.closePanel] == .chord(chord("Mod+Shift+W")))
        // The conflict of event-log:mod with new-session:mod stays in the file.
        let pair = KeyConflict(first: keySlot("new-session:mod"), second: keySlot("event-log:mod"))
        #expect(map.conflicts == [pair])
    }

    // A later version can write a key that this version cannot read, for example a new modifier.
    // The key map gives the slot its default key, and a save that changes another slot keeps
    // the entry. A key in another spelling also stays as it was while its slot has no change.
    @Test func aSaveKeepsTheKeysThatThisVersionCannotRead() {
        let keys: JSONValue = [
            "open:mod": "Hyper+K", "stop:key": "Mod+Hyper+X", "copy-id:mod": "cmd+shift+k",
        ]
        var changes = KeyChanges(stored: keys)
        #expect(changes == [keySlot("copy-id:mod"): .chord(chord("Mod+Shift+K"))])
        #expect(KeyMap(changes)[keySlot("open:mod")] == .chord(keySlot("open:mod").defaultBinding))
        #expect(changes.stored(keeping: keys) == keys)
        changes.set(.off, for: keySlot("rename:key"))
        #expect(
            changes.stored(keeping: keys) == [
                "open:mod": "Hyper+K", "stop:key": "Mod+Hyper+X", "copy-id:mod": "cmd+shift+k",
                "rename:key": .null,
            ])
        // A changed slot gets the standard form of its new key.
        changes.set(.chord(chord("ctrl+k")), for: keySlot("open:mod"))
        let saved = changes.stored(keeping: keys)
        #expect(
            saved == [
                "open:mod": "Control+K", "stop:key": "Mod+Hyper+X", "copy-id:mod": "cmd+shift+k",
                "rename:key": .null,
            ])
        #expect(KeyChanges(stored: saved) == changes)
    }
}
