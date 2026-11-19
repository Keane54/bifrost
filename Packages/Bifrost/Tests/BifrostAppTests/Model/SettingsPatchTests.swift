import BifrostFoundation
import BifrostSessions
import Foundation
import Testing

@testable import BifrostApp
@testable import BifrostKeyboard
@testable import BifrostSettings

// The patch of the settings that the debug test port gives: the fields of settings.json with new
// values. The check is strict: the first bad field, in the order of the field names, refuses the
// whole patch. A key patch is a key edit (KeyEdit), so a new conflict is refused with the text of
// the key edit.
@Suite("settings patch")
struct SettingsPatchTests {
    // The settings of a file with a field that this version does not know.
    private static func settingsWithUnknownField() throws -> Settings {
        let file = #"{"version":1,"rowFlash":true,"later":{"a":1}}"#
        return try JSONDecoder().decode(Settings.self, from: Data(file.utf8))
    }

    // A patch changes only its fields. The other fields keep their values, also a field of a
    // later version. An app with no value is null (Automatic).
    @Test func aPatchChangesOnlyItsFields() throws {
        var settings = try Self.settingsWithUnknownField()
        settings.terminalApp = .warp
        let before = settings
        let patch = try SettingsPatch(
            ["interfaceScale": 120, "rowFlash": false, "terminalApp": .null], settings: settings)
        patch.apply(to: &settings)
        var expected = before
        expected.interfaceScale = 120
        expected.rowFlash = false
        expected.terminalApp = nil
        #expect(settings == expected)
        #expect(settings.unknown == before.unknown)
        // An empty patch changes nothing.
        var same = before
        try SettingsPatch([:], settings: same).apply(to: &same)
        #expect(same == before)
    }

    // A field that the patch cannot change, and a value that the load of settings.json would not
    // keep, refuse the whole patch. The first bad field in the order of the names gives the
    // reason.
    @Test func aBadFieldRefusesThePatch() throws {
        let settings = Settings()
        let cases: [([String: JSONValue], SettingsPatchRefusal)] = [
            (["colour": "red"], .unknownField("colour")),
            (["version": 2], .unknownField("version")),
            (["interfaceScale": 121], .badValue(.interfaceScale)),
            (["rowFlash": "yes"], .badValue(.rowFlash)),
            (["rowFlash": .null], .badValue(.rowFlash)),
            (["slashCommands": ["/a", "b"]], .badValue(.slashCommands)),
            (["terminalFont": ["family": "Menlo"]], .badValue(.terminalFont)),
            (["zoom": 1, "interfaceScale": 121, "rowFlash": false], .badValue(.interfaceScale)),
        ]
        for (patch, refusal) in cases {
            #expect(throws: refusal, "\(patch)") {
                try SettingsPatch(patch, settings: settings)
            }
        }
        #expect(
            SettingsPatchRefusal.unknownField("colour").message
                == #"Bifrost has no setting called "colour"."#)
        #expect(
            SettingsPatchRefusal.badValue(.interfaceScale).message
                == "Bifrost can't use that value for interfaceScale.")
        #expect(
            SettingsPatchRefusal.notOpen.message
                == "Bifrost can't change the settings yet, because they haven't loaded.")
    }

    // A key patch changes only the named slots, and each other entry of the keys stays, also an
    // entry of a later version.
    @Test func aKeyPatchKeepsTheOtherEntries() throws {
        var settings = Settings()
        settings.keys = ["future:mod": "Mod+J"]
        let patch = try SettingsPatch(
            ["keys": ["close-panel:mod": "Mod+Shift+K"], "rowFlash": false], settings: settings)
        patch.apply(to: &settings)
        #expect(settings.keys == ["future:mod": "Mod+J", "close-panel:mod": "Mod+Shift+K"])
        #expect(!settings.rowFlash)
    }

    // A key patch that gives two actions of one class the same key is refused with the text of
    // the key edit. So are a slot that does not exist and a keys value that is not an object.
    @Test func aKeyConflictIsRefusedWithTheTextOfTheKeyEdit() throws {
        let settings = Settings()
        // Cmd+L is the key of Event log.
        #expect(throws: SettingsPatchRefusal.keys(.newConflict)) {
            try SettingsPatch(["keys": ["close-panel:mod": "Mod+L"]], settings: settings)
        }
        #expect(
            SettingsPatchRefusal.keys(.newConflict).message
                == "Two actions can't share the same key.")
        #expect(throws: SettingsPatchRefusal.keys(.unknownSlot("nothing:mod"))) {
            try SettingsPatch(["keys": ["nothing:mod": "Mod+L"]], settings: settings)
        }
        #expect(throws: SettingsPatchRefusal.keys(.notAnObject)) {
            try SettingsPatch(["keys": "Mod+L"], settings: settings)
        }
    }

    // The fields of the settings as settings.json has them, for the state of the test port.
    @Test func theFieldsOfTheSettingsAreTheFieldsOfTheFile() throws {
        var settings = try Self.settingsWithUnknownField()
        settings.interfaceScale = 120
        let fields = try #require(SettingsPatch.fields(of: settings))
        #expect(fields["version"] == 1)
        #expect(fields["interfaceScale"] == 120)
        #expect(fields["terminalApp"] == .null)
        #expect(fields["later"] == ["a": 1])
        #expect(fields["keys"] == nil)
    }
}
