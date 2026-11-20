import BifrostDailyUpdate
import BifrostFoundation
import BifrostKeyboard
import BifrostLook
import BifrostSessions
import BifrostSettings
import BifrostTestSupport
import Foundation
import Testing

// The settings model: the decode of settings.json, the encode, the checks of a text and the
// check of an edit. SettingsEdgeTests.swift has the limits of each field.

// The JSON form of the default settings. keys stays raw, and dailyUpdate is typed. The defaults
// have neither.
private let defaultsJSON: JSONValue = [
    "accountUsage": false,
    "animatedBackground": true,
    "autoUpdate": true,
    "escalationMinutes": 10,
    "interfaceScale": 100,
    "labels": "plain",
    "notifications": true,
    "panelTransparency": 15,
    "pollSeconds": 2,
    "projectApp": .null,
    "redBoxSound": true,
    "reviewsAutoFix": true,
    "reviewsFixCI": false,
    "reviewsIgnore": [],
    "reviewsMaxSessions": 3,
    "reviewsPauseMinutes": 60,
    "reviewsPollMinutes": 2,
    "reviewsRequestModel": "",
    "reviewsResolveConflicts": false,
    "reviewsReviewModel": "",
    "reviewsSignedCommits": false,
    "reviewsTeamRequests": true,
    "reviewsWatch": false,
    "rowFlash": true,
    "setupDone": false,
    "slashCommands": ["/compact", "/clear", "/context"],
    "snapDistance": 8,
    "startAtLogin": false,
    "terminalApp": .null,
    "terminalFont": ["family": "SF Mono", "size": 13],
    "version": 1,
]

// A stored object with version 1 and the given fields.
private func stored(_ fields: [String: JSONValue]) -> JSONValue {
    .object(fields.merging(["version": 1]) { field, _ in field })
}

// One field of each kind: a stored value that the decode keeps, the saved form of that value,
// and a stored value that gets the default. A raw value keeps each stored value, so it has no
// refused value.
private struct FieldKind: Sendable, CustomTestStringConvertible {
    var key: String
    var kept: JSONValue
    var saved: JSONValue
    var refused: JSONValue?

    var testDescription: String { key }
}

private let fieldKinds = [
    FieldKind(key: "rowFlash", kept: false, saved: false, refused: "false"),
    FieldKind(key: "labels", kept: "space", saved: "space", refused: "Space"),
    FieldKind(key: "reviewsReviewModel", kept: "haiku", saved: "haiku", refused: "fable"),
    FieldKind(key: "terminalApp", kept: "warp", saved: "warp", refused: "finder"),
    FieldKind(key: "projectApp", kept: .null, saved: .null, refused: 7),
    FieldKind(key: "escalationMinutes", kept: 0, saved: 0, refused: 121),
    FieldKind(key: "pollSeconds", kept: 10, saved: 10, refused: 4),
    FieldKind(key: "slashCommands", kept: [" /a ", "/b"], saved: ["/a", "/b"], refused: "/a"),
    FieldKind(key: "reviewsIgnore", kept: [" Owner/X "], saved: ["owner/x"], refused: "owner/x"),
    FieldKind(
        key: "terminalFont", kept: ["family": " Menlo ", "size": 20],
        saved: ["family": "Menlo", "size": 20], refused: "Menlo"),
    FieldKind(
        key: "keys", kept: ["open:mod": "Mod+K", "x": 5], saved: ["open:mod": "Mod+K", "x": 5]),
]

@Suite("the decode of the settings")
struct SettingsDecodeTests {
    @Test func theDefaultsOfSpec12() throws {
        #expect(try encoded(Settings()) == defaultsJSON)
        let stored = storedSettings(["version": 1])
        #expect(stored?.settings == Settings())
        #expect(stored?.defaulted == [])
        #expect(stored?.laterVersion == nil)
    }

    // The other field (setupDone) shows that the other fields stay.
    @Test("a good stored value stays and lists no key", arguments: fieldKinds)
    fileprivate func goodValue(field: FieldKind) {
        let value = stored([field.key: field.kept, "setupDone": true])
        let settings = decodedSettings(value)
        #expect(savedField(settings, field.key) == field.saved)
        #expect(settings.setupDone)
        #expect(defaultedKeys(value) == [])
    }

    @Test(
        "a bad stored value gets the default and lists its key",
        arguments: fieldKinds.filter { $0.refused != nil })
    fileprivate func badValue(field: FieldKind) {
        let value = stored([field.key: field.refused ?? .null, "setupDone": true])
        let settings = decodedSettings(value)
        #expect(savedField(settings, field.key) == savedField(Settings(), field.key))
        #expect(settings.setupDone)
        #expect(defaultedKeys(value) == [field.key])
    }

    // JSON has one number type, so 1.0 and 5.0 are the whole numbers 1 and 5.
    @Test func aWholeNumberInDoubleFormPasses() throws {
        let text = #"{"version":1.0,"pollSeconds":5.0,"terminalFont":{"family":"A","size":2e1}}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(text.utf8))
        #expect(settings.pollSeconds == 5)
        #expect(settings.terminalFont.size == 20)
        let half = #"{"version":1.5,"pollSeconds":5}"#
        #expect(try JSONDecoder().decode(Settings.self, from: Data(half.utf8)) == Settings())
    }

    // Each key of the encode is a known key, so a decode of the encode keeps no unknown field.
    @Test func theEncodeHasOnlyKnownKeys() throws {
        var settings = Settings()
        settings.keys = ["open:key": "K"]
        settings.dailyUpdate = .defaults
        let fields = try #require(try encoded(settings).fields, "the JSON form is an object")
        #expect(fields.count == 33)
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(Settings.self, from: data).unknown.values.isEmpty)
    }

    // An app with no value (Automatic) is null. A raw value that is nil has no key.
    @Test func theEncodeHasVersionOneAndTheDecodeGivesTheSameSettings() throws {
        var settings = Settings()
        settings.keys = ["open:key": "K"]
        settings.dailyUpdate = .defaults
        settings.terminalApp = .iterm2
        settings.reviewsIgnore = ["owner/*"]
        let fields = try #require(try encoded(settings).fields, "the JSON form is an object")
        #expect(fields["version"] == 1)
        #expect(fields["terminalApp"] == "iterm2")
        #expect(fields["projectApp"] == .null)
        #expect(fields["keys"] == ["open:key": "K"])
        #expect(fields["dailyUpdate"]?.fields?["draftTime"] == "09:30")
        #expect(savedField(Settings(), "keys") == nil)
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(Settings.self, from: data) == settings)
    }

    // The settings keep an unknown key (UnknownFields), and the encode writes it again.
    @Test func anUnknownKeyStaysInTheEncode() {
        let value = stored(["theme": "light", "pollSeconds": 5])
        #expect(decodedSettings(value).unknown.values == ["theme": "light"])
        #expect(savedField(decodedSettings(value), "theme") == "light")
        #expect(decodedSettings(value).pollSeconds == 5)
    }
}

// The decode also gives the keys that it did not keep, so the store can log them.
@Suite("the keys that got their defaults")
struct DefaultedKeyTests {
    @Test func theListHasTheKeysThatGotTheirDefaultsInSortedOrder() {
        let value = stored([
            "pollSeconds": 4, "labels": "fancy", "snapDistance": 32, "rowFlash": "yes",
            "terminalApp": .null, "projectApp": "notepad", "theme": "light", "keys": "x",
            "dailyUpdate": 7, "escalationMinutes": 2.5,
        ])
        #expect(
            defaultedKeys(value) == [
                "escalationMinutes", "labels", "pollSeconds", "projectApp", "rowFlash",
            ])
        var expected = Settings()
        expected.snapDistance = 32
        expected.keys = "x"
        expected.unknown = UnknownFields(["theme": "light"])
        #expect(decodedSettings(value) == expected)
    }

    // A list that lost an item is listed. The trim or the lower case of a kept item is not.
    @Test func aListThatLostAnItemIsListed() {
        #expect(defaultedKeys(stored(["slashCommands": ["/a", "b"]])) == ["slashCommands"])
        #expect(defaultedKeys(stored(["slashCommands": ["/a", " /a "]])) == ["slashCommands"])
        #expect(defaultedKeys(stored(["slashCommands": ["  /a  ", "/b"]])) == [])
        let twice: JSONValue = ["Owner/X", "owner/x"]
        #expect(defaultedKeys(stored(["reviewsIgnore": twice])) == ["reviewsIgnore"])
        #expect(defaultedKeys(stored(["reviewsIgnore": [" Owner/X "]])) == [])
    }

    // A font with a bad or a missing part is listed. A key of the font that the settings do not
    // read is not.
    @Test func aFontWithABadPartIsListed() {
        let font = { (value: JSONValue) in defaultedKeys(stored(["terminalFont": value])) }
        #expect(font(["family": "a;b", "size": 13]) == ["terminalFont"])
        #expect(font(["family": "Menlo"]) == ["terminalFont"])
        #expect(font(["family": "Menlo", "size": 13, "x": 1]) == [])
    }

    // A version that is not 1 gives the defaults for all fields, so each known key of the object
    // is listed. A value that is not an object has no keys.
    @Test func aBadVersionListsEachKnownKey() {
        let later: JSONValue = ["version": 2, "labels": "space", "theme": "light"]
        #expect(defaultedKeys(later) == ["labels", "version"])
        #expect(defaultedKeys(["labels": "space"]) == ["labels"])
        let others: [JSONValue] = [.null, [], "x", 7]
        #expect(others.allSatisfy { defaultedKeys($0).isEmpty })
    }

    // The store copies a file of a later version before the first write over it.
    @Test func aLaterVersionIsANumberAboveOne() {
        let later = { (version: JSONValue) in storedSettings(["version": version])?.laterVersion }
        #expect(later(2) == 2)
        #expect(later(2.5) == 2.5)
        #expect(later(1e21) == 1e21)
        let none: [JSONValue] = [1, 0, -1, 1.0, "2", .null, true, [2]]
        #expect(none.allSatisfy { later($0) == nil })
        #expect(storedSettings(["labels": "space"])?.laterVersion == nil)
    }
}

// The settings window shows these texts to the user. SettingsEdgeTests.swift has the checks.
@Suite("the refusal texts")
struct RefusalTextTests {
    @Test func theTextsOfARefusedSlashCommandOrFontAreFriendly() {
        let start = "Start the command with \"/\", with no space after it."
        #expect(SettingsText.reasonSlashStart == start)
        #expect(SettingsText.reasonSlashLine == "Keep the command on one line.")
        #expect(SettingsText.reasonSlashLong == "That's too long. The limit is 200 characters.")
        #expect(SettingsText.reasonFont == "Use 1 to 64 characters, without quotes or ; { } < >.")
    }

    // Each refusal has its text. A refused field names the field, and no text is a code.
    @Test func eachRefusalHasItsText() {
        #expect(SettingsRefusal.slashStart.message == SettingsText.reasonSlashStart)
        #expect(SettingsRefusal.slashLines.message == SettingsText.reasonSlashLine)
        #expect(SettingsRefusal.slashTooLong.message == SettingsText.reasonSlashLong)
        #expect(SettingsRefusal.fontFamily.message == SettingsText.reasonFont)
        #expect(
            SettingsRefusal.slashList.message
                == "Use up to 12 slash commands, each one only once.")
        #expect(
            SettingsRefusal.field(.pollSeconds).message
                == "Bifrost can't use that value for pollSeconds.")
        #expect(
            SettingsError.refused(.slashStart).message == SettingsText.reasonSlashStart)
    }
}

@Suite("the Reviews settings")
struct ReviewsSettingsTests {
    // A model or an app ID that is not a choice cannot be a value of the enum. The raw value
    // check takes the place of the check of an edit.
    @Test func eachReviewsNumberHasItsRange() {
        #expect(reasonOf { $0.reviewsMaxSessions = 11 } == .field(.reviewsMaxSessions))
        #expect(reasonOf { $0.reviewsPauseMinutes = 45 } == .field(.reviewsPauseMinutes))
        #expect(reasonOf { $0.reviewsPollMinutes = 3 } == .field(.reviewsPollMinutes))
        #expect(ModelChoice(rawValue: "gpt") == nil)
        let good = reasonOf {
            $0.reviewsMaxSessions = 10
            $0.reviewsReviewModel = .haiku
        }
        #expect(good == nil)
    }

    @Test func eachModelIsAChoiceAndFableIsNot() {
        #expect(ModelChoice.allCases.map(\.rawValue) == ["", "opus", "sonnet", "haiku"])
        for model in ModelChoice.allCases {
            #expect(reasonOf { $0.reviewsReviewModel = model } == nil)
            #expect(reasonOf { $0.reviewsRequestModel = model } == nil)
        }
        #expect(ModelChoice(rawValue: "fable") == nil)
    }

    @Test func anEditOfTheIgnoreListIsCheckedAndCleaned() throws {
        let result = try edited { $0.reviewsIgnore = [" Acme/API ", "acme/*"] }
        #expect(result.reviewsIgnore == ["acme/api", "acme/*"])
        let refused = SettingsRefusal.field(.reviewsIgnore)
        #expect(reasonOf { $0.reviewsIgnore = ["bad"] } == refused)
        #expect(reasonOf { $0.reviewsIgnore = ["a/b", "A/B"] } == refused)
        let many = (0..<51).map { "acme/r\($0)" }
        #expect(reasonOf { $0.reviewsIgnore = many } == refused)
        #expect(reasonOf { $0.reviewsIgnore = Array(many.prefix(50)) } == nil)
    }

    // The settings of the merge conflicts and of the failing CI of the PRs of the user are off by
    // default. A stored true or false stays, and the encode writes it with its key. A value that
    // is not a flag gets the default and lists its key.
    @Test func theNewReviewsSettingsDefaultOffAndRoundTrip() throws {
        let defaults = Settings()
        #expect(!defaults.reviewsResolveConflicts && !defaults.reviewsFixCI)
        for flag in [true, false] {
            let value = stored([
                "reviewsResolveConflicts": .bool(flag), "reviewsFixCI": .bool(!flag),
            ])
            let settings = decodedSettings(value)
            #expect(settings.reviewsResolveConflicts == flag && settings.reviewsFixCI == !flag)
            #expect(defaultedKeys(value) == [])
            #expect(savedField(settings, "reviewsResolveConflicts") == .bool(flag))
            #expect(savedField(settings, "reviewsFixCI") == .bool(!flag))
            let data = try JSONEncoder().encode(settings)
            #expect(try JSONDecoder().decode(Settings.self, from: data) == settings)
        }
        let bad = stored(["reviewsResolveConflicts": "true", "reviewsFixCI": 1])
        #expect(!decodedSettings(bad).reviewsResolveConflicts && !decodedSettings(bad).reviewsFixCI)
        #expect(defaultedKeys(bad) == ["reviewsFixCI", "reviewsResolveConflicts"])
    }
}

// The store checks each edit with validated(). The check refuses a bad value with the reason of
// its field, and it gives the clean form of the texts.
@Suite("the check of an edit")
struct ValidatedTests {
    // The forms that the types refuse are not in the Swift test (docs/behaviour/stores.md).
    @Test func eachBadValueIsRefusedWithItsReason() {
        #expect(reasonOf { $0.pollSeconds = 4 } == .field(.pollSeconds))
        #expect(LabelSet(rawValue: "fancy") == nil)
        #expect(reasonOf { $0.escalationMinutes = 121 } == .field(.escalationMinutes))
        #expect(TerminalAppID(rawValue: "finder") == nil)
        #expect(reasonOf { $0.panelTransparency = 7 } == .field(.panelTransparency))
        #expect(reasonOf { $0.interfaceScale = 160 } == .field(.interfaceScale))
        #expect(reasonOf { $0.snapDistance = 33 } == .field(.snapDistance))
        let slash = { (list: [String]) in reasonOf { $0.slashCommands = list } }
        #expect(slash(["/a", "b"]) == .slashStart)
        #expect(slash(["/a", "/a\nb"]) == .slashLines)
        #expect(slash(["/a", " /a "]) == .slashList)
        let thirteen = (0..<13).map { "/c\($0)" }
        #expect(slash(thirteen) == .slashList)
        #expect(slash(Array(thirteen.prefix(12))) == nil)
        let font = { (family: String, size: Int) in
            reasonOf { $0.terminalFont = TerminalFont(family: family, size: size) }
        }
        #expect(font("Menlo", 30) == .field(.terminalFont))
        #expect(font("a;b", 13) == .field(.terminalFont))
    }

    // Each flag, choice and app has no check: each value of its type is good.
    @Test func aFlagAChoiceOrAnAppIsNeverRefused() throws {
        let result = try edited {
            $0.accountUsage = true
            $0.animatedBackground = false
            $0.autoUpdate = false
            $0.labels = .space
            $0.terminalApp = .warp
            $0.projectApp = .finder
            $0.setupDone = true
        }
        #expect(result.accountUsage)
        #expect(!result.animatedBackground)
        #expect(!result.autoUpdate)
        #expect(result.labels == .space)
        #expect(result.setupDone)
        #expect(result.terminalApp == .warp)
        #expect(result.projectApp == .finder)
    }

    // The defaults and the settings of a load pass the check with no change. So an edit that
    // changes nothing gives equal settings, and the store writes nothing.
    @Test func goodSettingsPassTheCheckWithNoChange() throws {
        #expect(try Settings().validated() == Settings())
        let stored: JSONValue = [
            "version": 1, "labels": "space", "reviewsIgnore": [" Acme/API "],
            "slashCommands": [" /review "], "terminalFont": ["family": " Menlo ", "size": 14],
        ]
        let loaded = decodedSettings(stored)
        #expect(try loaded.validated() == loaded)
    }

    @Test func anEditKeepsItsValuesAndTrimsACommand() throws {
        let result = try edited {
            $0.labels = .space
            $0.escalationMinutes = 0
            $0.slashCommands = ["  /review  "]
        }
        var expected = Settings()
        expected.escalationMinutes = 0
        expected.labels = .space
        expected.slashCommands = ["/review"]
        #expect(result == expected)
    }

    // nil is Automatic. The file has null for it.
    @Test func anEditCanSetTheAppsToAutomatic() throws {
        var current = try edited {
            $0.terminalApp = .warp
            $0.projectApp = .zed
        }
        current.terminalApp = nil
        current.projectApp = nil
        let automatic = try current.validated()
        #expect(automatic.terminalApp == nil)
        #expect(automatic.projectApp == nil)
        #expect(savedField(automatic, "terminalApp") == .null)
        #expect(savedField(automatic, "projectApp") == .null)
    }

    @Test func anEditKeepsTheTrimmedFontFamily() throws {
        let result = try edited { $0.terminalFont = TerminalFont(family: "  Menlo  ", size: 14) }
        #expect(result.terminalFont == TerminalFont(family: "Menlo", size: 14))
    }

    // The checks go in the order of the fields of the settings (row S3 of
    // docs/ports/stores/DELIBERATE-DIFFERENCES.md).
    @Test func twoBadFieldsGiveTheReasonOfTheFirstField() {
        let reason = reasonOf {
            $0.escalationMinutes = 121
            $0.reviewsPollMinutes = 3
        }
        #expect(reason == .field(.escalationMinutes))
    }

    // keys stays raw. The check keeps it, and a good typed dailyUpdate, as they are.
    @Test func theCheckKeepsTheRawValues() throws {
        let keys: JSONValue = ["open:mod": "Mod+K", "nope:mod": .null]
        var daily = DailySettings.defaults
        daily.you = "me"
        let result = try edited {
            $0.keys = keys
            $0.dailyUpdate = daily
        }
        #expect(result.keys == keys)
        #expect(result.dailyUpdate == daily)
    }
}

@Suite("the choices of the two step selects")
struct StepChoiceTests {
    @Test func panelTransparencyOffers0To50InStepsOf5AndEachChoicePasses() {
        #expect(ThemeTokens.transparencyChoices == [0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50])
        for value in ThemeTokens.transparencyChoices {
            #expect(reasonOf { $0.panelTransparency = value } == nil)
        }
    }

    @Test func interfaceScaleOffers80To150InStepsOf10AndEachChoicePasses() {
        #expect(CanvasMetrics.scaleChoices == [80, 90, 100, 110, 120, 130, 140, 150])
        for value in CanvasMetrics.scaleChoices {
            #expect(reasonOf { $0.interfaceScale = value } == nil)
        }
    }
}

// The default app of Open project, the Settings select of that app and the terminal apps
// (docs/behaviour/stores.md, "The apps of the settings").
@Suite("the apps of the settings")
struct ProjectAppSettingTests {
    private let finder = ProjectApp(id: .finder, label: "Finder")
    private let vscode = ProjectApp(id: .vscode, label: "VS Code")
    private let zed = ProjectApp(id: .zed, label: "Zed")
    private let terminal = ProjectApp(id: .terminal, label: "Terminal")
    private let warp = ProjectApp(id: .warp, label: "Warp")

    private func defaultApp(_ apps: [ProjectApp], _ setting: ProjectAppID?) -> ProjectAppID? {
        var settings = Settings()
        settings.projectApp = setting
        return settings.defaultProjectApp(apps)
    }

    @Test func theDefaultIsTheSettingThenVSCodeThenZedThenATerminalApp() {
        #expect(defaultApp([finder, zed], .vscode) == .zed)
        #expect(defaultApp([finder, vscode, zed], .zed) == .zed)
        #expect(defaultApp([finder, vscode, zed], nil) == .vscode)
        #expect(defaultApp([finder, zed, terminal], nil) == .zed)
        #expect(defaultApp([finder, terminal, warp], nil) == .terminal)
        #expect(defaultApp([finder, warp, terminal], .vscode) == .warp)
        #expect(defaultApp([finder, vscode], .warp) == .vscode)
    }

    @Test func theDefaultIsNeverFinder() {
        #expect(defaultApp([finder], nil) == nil)
        #expect(defaultApp([finder, zed], .finder) == .zed)
        #expect(defaultApp([finder, vscode, zed], .finder) == .vscode)
        #expect(defaultApp([zed], nil) == .zed)
        #expect(defaultApp([], .zed) == nil)
    }

    @Test func theSettingsSelectHasNoFinderAndShowsASavedFinderAsAutomatic() {
        #expect(Settings.projectAppChoices([finder, vscode, zed]).map(\.id) == [.vscode, .zed])
        var settings = Settings()
        settings.projectApp = .finder
        #expect(settings.shownProjectApp == nil)
        settings.projectApp = .zed
        #expect(settings.shownProjectApp == .zed)
        settings.projectApp = nil
        #expect(settings.shownProjectApp == nil)
    }

    // The terminal app IDs of the setting are the order in which Open in terminal looks for a
    // terminal app.
    @Test func theTerminalAppIdsAreTheTerminalOrder() {
        #expect(TerminalAppID.allCases.map(\.rawValue) == ["warp", "ghostty", "iterm2", "terminal"])
        let all = ProjectApps.terminals(
            home: URL(filePath: "/home/u"), exists: { _ in true })
        #expect(all.compactMap(\.app.id.terminal) == TerminalAppID.allCases)
    }
}

// The block of the Daily update is a typed value (the rules are in BifrostDailyUpdateTests).
@Suite("the Daily update block of the settings")
struct DailyUpdateBlockTests {
    @Test func aBlockThatIsNotAnObjectIsNoBlock() {
        for value: JSONValue in [7, .null, "x", [1]] {
            #expect(decodedSettings(stored(["dailyUpdate": value])).dailyUpdate == nil)
        }
        #expect(decodedSettings(stored(["setupDone": true])).dailyUpdate == nil)
    }

    @Test func aBadFieldCostsOnlyThatField() {
        let value = stored(["dailyUpdate": ["you": "me", "draftTime": "25:00", "mergedPrs": false]])
        let block = decodedSettings(value).dailyUpdate
        #expect(block?.you == "me")
        #expect(block?.mergedPrs == false)
        #expect(block?.draftTime == DailySettings.defaults.draftTime)
        #expect(defaultedKeys(value) == [])
    }

    @Test func aBlockSurvivesASaveWithItsUnknownField() throws {
        let value = stored(["dailyUpdate": ["you": "me", "later": [1, 2]]])
        let settings = decodedSettings(value)
        let saved = try #require(try encoded(settings).fields?["dailyUpdate"]?.fields)
        #expect(saved["later"] == [1, 2])
        #expect(saved["you"] == "me")
        #expect(saved["source"] == ["server": .null, "tools": []])
    }

    @Test func anEditWithABadBlockIsRefused() throws {
        var settings = Settings()
        settings.dailyUpdate = .defaults
        _ = try settings.validated()
        var bad = DailySettings.defaults
        bad.deadline = bad.draftTime
        settings.dailyUpdate = bad
        #expect(throws: SettingsRefusal.field(.dailyUpdate)) { try settings.validated() }
    }
}
