import BifrostDailyUpdate
import BifrostFoundation
import BifrostKeyboard
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostSettings

private func readValue(_ url: URL) throws -> JSONValue? {
    try JSONFile.read(url).map { try JSONDecoder().decode(JSONValue.self, from: $0) }
}

// A load and a save of settings.json with the settings model: one decode and one encode. The
// settings keep the unknown fields of the file.
@Suite("settings file", .timeLimit(.minutes(1)))
struct SettingsFileTests {
    private func load(_ file: URL) throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: JSONFile.read(file) ?? Data())
    }

    private func save(_ settings: Settings, _ file: URL) throws {
        try JSONFile.write(try JSONFile.encode(settings), to: file)
    }

    // A file from a newer app has fields that this app does not know. They stay in the file.
    @Test func unknownFieldsSurviveALoadAndASave() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "settings.json")
        let stored: JSONValue = [
            "version": 1, "labels": "space", "theme": "light",
            "future": ["list": [1, 2], "on": true], "pollSeconds": 4,
        ]
        try JSONFile.write(try JSONFile.encode(stored), to: file)
        let settings = try load(file)
        #expect(
            settings.unknown.values == ["theme": "light", "future": ["list": [1, 2], "on": true]])
        var changed = settings
        changed.pollSeconds = 5
        try save(changed, file)
        let fields = try #require(try readValue(file)?.fields, "the saved file is an object")
        #expect(fields["theme"] == "light")
        #expect(fields["future"] == ["list": [1, 2], "on": true])
        #expect(fields["labels"] == "space")
        #expect(fields["pollSeconds"] == 5)
        #expect(try load(file) == changed)
    }

    // keys and dailyUpdate stay raw until phases 3 and 5. The save writes them as they came.
    @Test func rawKeysAndDailyUpdateSurviveALoadAndASave() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "settings.json")
        let keys: JSONValue = ["open:mod": "Mod+L", "nope:mod": "Mod+J", "rename:key": .null]
        let daily: JSONValue = ["you": "me", "days": [1, 2], "other": ["x": 1]]
        let stored: JSONValue = ["version": 1, "keys": keys, "dailyUpdate": daily]
        try JSONFile.write(try JSONFile.encode(stored), to: file)
        let settings = try load(file)
        #expect(settings.keys == keys)
        #expect(settings.dailyUpdate?.you == "me")
        #expect(settings.dailyUpdate?.days == [1, 2])
        var changed = settings
        changed.labels = .space
        try save(changed, file)
        let fields = try #require(try readValue(file)?.fields, "the saved file is an object")
        #expect(fields["keys"] == keys)
        let block = try #require(fields["dailyUpdate"]?.fields, "the saved block is an object")
        #expect(block["you"] == "me")
        #expect(block["days"] == [1, 2])
        #expect(block["other"] == ["x": 1])
        // A file with no keys and no dailyUpdate gets none.
        try save(Settings(), file)
        let plain = try #require(try readValue(file)?.fields, "the saved file is an object")
        #expect(plain["keys"] == nil)
        #expect(plain["dailyUpdate"] == nil)
        #expect(plain["version"] == 1)
    }
}
