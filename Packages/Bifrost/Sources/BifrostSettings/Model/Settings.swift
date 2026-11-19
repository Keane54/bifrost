import BifrostDailyUpdate
import BifrostFoundation
import BifrostKeyboard
import BifrostLook
import BifrostReviews
import BifrostSessions

// The settings (docs/behaviour/stores.md, "settings.json"). The app keeps them in settings.json,
// with the field names and the meaning of the file of the Electron app, so the two apps share the
// file format.

// The encode writes the family and the size. The decode of the settings reads each part alone.
public struct TerminalFont: Sendable, Equatable, Encodable {
    package var family: String
    package var size: Int

    package init(family: String, size: Int) {
        self.family = family
        self.size = size
    }
}

// Why the settings refuse an edit or a text. message is the friendly text. The settings window
// shows the text of a refused text field to the user.
public enum SettingsRefusal: Error, Sendable, Equatable {
    // The value of the field is outside its range or its choices. The pickers of the settings
    // window offer only good values, so only code can make this refusal.
    case field(Settings.Key)
    // A slash command does not start with "/" and then a character that is not white space.
    case slashStart
    // A slash command has a line break.
    case slashLines
    // A slash command has more than SettingsText.maxSlashLength Characters.
    case slashTooLong
    // The list has more than SettingsText.maxSlashCommands commands, or a command two times.
    case slashList
    // The slash command to add is already in the list.
    case slashCopy
    // The list to add to has SettingsText.maxSlashCommands commands.
    case slashFull
    // The font family is empty, too long, or has a character that it must not have.
    case fontFamily

    public var message: String {
        switch self {
        case .field(let key): "Bifrost can't use that value for \(key.stringValue)."
        case .slashStart: SettingsText.reasonSlashStart
        case .slashLines: SettingsText.reasonSlashLine
        case .slashTooLong: SettingsText.reasonSlashLong
        case .slashList: SettingsText.reasonSlashList
        case .slashCopy: SettingsText.reasonSlashCopy
        case .slashFull: SettingsText.reasonSlashFull
        case .fontFamily: SettingsText.reasonFont
        }
    }
}

public struct Settings: Sendable, Equatable {
    // Read the account usage with the Claude Code login.
    package var accountUsage = false
    package var labels = LabelSet.plain
    // nil means the first installed app of TerminalAppID (D14).
    package var terminalApp: TerminalAppID?
    // nil means VS Code, else Zed, else the first terminal app.
    package var projectApp: ProjectAppID?
    // 0 stops the escalation.
    package var escalationMinutes = 10
    package var rowFlash = true
    package var notifications = true
    package var redBoxSound = true
    package var startAtLogin = false
    package var pollSeconds = 2
    package var snapDistance = 8
    // The percent of the panel background that is transparent. 0 is solid.
    public var panelTransparency = ThemeTokens.defaultTransparency
    // The zoom of the window in percent.
    public var interfaceScale = 100
    // The colour fields of the background move slowly. false pauses them.
    public var animatedBackground = true
    // Check for updates automatically. Off stops all checks and downloads.
    public var autoUpdate = true
    package var slashCommands = ["/compact", "/clear", "/context"]
    // Watch the code host for the review requests and the PRs of the user (Reviews).
    package var reviewsWatch = false
    // Fix the review comments on the PRs of the user without a request.
    package var reviewsAutoFix = true
    // Show the review requests that a team gets, and not only the direct ones.
    package var reviewsTeamRequests = true
    package var reviewsMaxSessions = 3
    package var reviewsPauseMinutes = 60
    package var reviewsPollMinutes = 2
    package var reviewsRequestModel = ModelChoice.standard
    package var reviewsReviewModel = ModelChoice.standard
    // Send the fix commit of a request round through the API of the code host, so the host
    // signs the commit.
    package var reviewsSignedCommits = false
    // Entries of the form owner/repo or owner/*. The Reviews panel hides them.
    package var reviewsIgnore: [String] = []
    public var terminalFont = TerminalFont(family: "SF Mono", size: 13)
    // The settings of the Daily update. nil: no block in the file. A block that is not an object
    // is no block. In an object, a bad field gets its default (DailySettings).
    package var dailyUpdate: DailySettings?
    // The raw stored value. KeyMap(stored:) reads it with the key rules. It stays raw, so
    // a save keeps each entry that a later version wrote. nil: no value.
    public var keys: JSONValue?
    package var setupDone = false
    // The top-level fields of settings.json that this app does not know. A save writes them
    // again, so a file of a later app loses nothing.
    package var unknown = UnknownFields()

    // The defaults.
    package init() {}

    // The choices of the Poll select. The look has the choices of the Panel transparency
    // (ThemeTokens.transparencyChoices) and of the Interface scale (CanvasMetrics.scaleChoices).
    package static let pollChoices = [1, 2, 3, 5, 10]

    static let escalationRange = 0...120
    static let snapRange = 0...32
    static let fontSizeRange = 9...24
    static let reviewsMaxSessionsRange = 1...10
    static let reviewsPauseChoices = [15, 30, 60, 120, 240, 480]
    static let reviewsPollChoices = [1, 2, 5, 10]
}

// MARK: - Coding

extension Settings: Codable {
    // The top-level keys of settings.json: "version" and the name of each field.
    public enum Key: String, CodingKey, Sendable {
        case version, accountUsage, labels, terminalApp, projectApp, escalationMinutes, rowFlash
        case notifications, redBoxSound, startAtLogin, pollSeconds, snapDistance
        case panelTransparency, interfaceScale, animatedBackground, autoUpdate, slashCommands
        case reviewsWatch, reviewsAutoFix, reviewsTeamRequests, reviewsMaxSessions
        case reviewsPauseMinutes, reviewsPollMinutes, reviewsRequestModel, reviewsReviewModel
        case reviewsSignedCommits, reviewsIgnore, terminalFont, dailyUpdate, keys, setupDone
    }

    // The lenient decode of StoredSettings.
    public init(from decoder: any Decoder) throws {
        self = try StoredSettings(from: decoder).settings
    }

    // Version 1, each field, then the unknown fields. An app with no value (Automatic) is null. A
    // raw value that is nil has no key.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(1, forKey: .version)
        try container.encode(accountUsage, forKey: .accountUsage)
        try container.encode(labels, forKey: .labels)
        try container.encode(terminalApp, forKey: .terminalApp)
        try container.encode(projectApp, forKey: .projectApp)
        try container.encode(escalationMinutes, forKey: .escalationMinutes)
        try container.encode(rowFlash, forKey: .rowFlash)
        try container.encode(notifications, forKey: .notifications)
        try container.encode(redBoxSound, forKey: .redBoxSound)
        try container.encode(startAtLogin, forKey: .startAtLogin)
        try container.encode(pollSeconds, forKey: .pollSeconds)
        try container.encode(snapDistance, forKey: .snapDistance)
        try container.encode(panelTransparency, forKey: .panelTransparency)
        try container.encode(interfaceScale, forKey: .interfaceScale)
        try container.encode(animatedBackground, forKey: .animatedBackground)
        try container.encode(autoUpdate, forKey: .autoUpdate)
        try container.encode(slashCommands, forKey: .slashCommands)
        try container.encode(reviewsWatch, forKey: .reviewsWatch)
        try container.encode(reviewsAutoFix, forKey: .reviewsAutoFix)
        try container.encode(reviewsTeamRequests, forKey: .reviewsTeamRequests)
        try container.encode(reviewsMaxSessions, forKey: .reviewsMaxSessions)
        try container.encode(reviewsPauseMinutes, forKey: .reviewsPauseMinutes)
        try container.encode(reviewsPollMinutes, forKey: .reviewsPollMinutes)
        try container.encode(reviewsRequestModel, forKey: .reviewsRequestModel)
        try container.encode(reviewsReviewModel, forKey: .reviewsReviewModel)
        try container.encode(reviewsSignedCommits, forKey: .reviewsSignedCommits)
        try container.encode(reviewsIgnore, forKey: .reviewsIgnore)
        try container.encode(terminalFont, forKey: .terminalFont)
        try container.encodeIfPresent(dailyUpdate, forKey: .dailyUpdate)
        try container.encodeIfPresent(keys, forKey: .keys)
        try container.encode(setupDone, forKey: .setupDone)
        try unknown.encode(to: encoder)
    }
}

// What the decode of settings.json gives. The store logs the keys that got their defaults
// (docs/behaviour/stores.md, settings.json), and it copies a file of a later version before the
// first write over it.
package struct StoredSettings: Sendable, Equatable, Decodable {
    package let settings: Settings
    // The keys of the stored object whose values the settings do not keep, in sorted order. A
    // key is in the list when its field got its default, when its list lost an item (a bad
    // item, a repeated item, or an item after the limit), or when its font has a bad or a
    // missing part. The trim or the lower case of a kept item does not count. A missing key,
    // an unknown key, keys and dailyUpdate are never in the list.
    package let defaulted: [String]
    // The version of a file of a later app: a number above 1. Else nil.
    package let laterVersion: Double?

    // The value of a missing file: the defaults.
    package init() {
        settings = Settings()
        defaulted = []
        laterVersion = nil
    }

    // The decode refuses a value that is not an object. The store then uses the defaults.
    // The settings keep the unknown fields of each object. A version that is not the whole
    // number 1 gives the defaults, and the list has each known key of the object. Else a bad
    // field gets its default, and the other fields stay. keys keeps any JSON value, also
    // null. dailyUpdate is typed (DailySettings): a value that is not an object is no block. A
    // raw or an unknown value with no JSON form throws NoJSONForm, also in a file of another
    // version, so the store keeps a copy of the file (FileSaver).
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Settings.Key.self)
        var fields = FieldReader(container: container)
        fields.settings.unknown = try UnknownFields(from: decoder, known: Settings.Key.self)
        // The raw values are read before the version check, so a raw value with no JSON form
        // makes each file a file that does not parse, whatever its version.
        let dailyUpdate = try fields.raw(.dailyUpdate)
        let keys = try fields.raw(.keys)
        let version = try? container.decode(Double.self, forKey: .version)
        guard version == 1 else {
            settings = fields.settings
            defaulted = container.allKeys.map(\.stringValue).sorted()
            laterVersion = version.flatMap { $0 > 1 ? $0 : nil }
            return
        }
        fields.read(.accountUsage, \.accountUsage)
        fields.read(.labels, \.labels)
        fields.read(.terminalApp, \.terminalApp)
        fields.read(.projectApp, \.projectApp)
        fields.read(
            .escalationMinutes, \.escalationMinutes, where: Settings.escalationRange.contains)
        fields.read(.rowFlash, \.rowFlash)
        fields.read(.notifications, \.notifications)
        fields.read(.redBoxSound, \.redBoxSound)
        fields.read(.startAtLogin, \.startAtLogin)
        fields.read(.pollSeconds, \.pollSeconds, where: Settings.pollChoices.contains)
        fields.read(.snapDistance, \.snapDistance, where: Settings.snapRange.contains)
        fields.read(
            .panelTransparency, \.panelTransparency,
            where: ThemeTokens.transparencyChoices.contains)
        fields.read(
            .interfaceScale, \.interfaceScale, where: CanvasMetrics.scaleChoices.contains)
        fields.read(.animatedBackground, \.animatedBackground)
        fields.read(.autoUpdate, \.autoUpdate)
        fields.read(.slashCommands, \.slashCommands, as: [Lenient<String>].self) { items in
            kept(items, limit: SettingsText.maxSlashCommands) {
                try? SettingsText.checkSlashCommand($0)
            }
        }
        fields.read(.reviewsWatch, \.reviewsWatch)
        fields.read(.reviewsAutoFix, \.reviewsAutoFix)
        fields.read(.reviewsTeamRequests, \.reviewsTeamRequests)
        fields.read(
            .reviewsMaxSessions, \.reviewsMaxSessions,
            where: Settings.reviewsMaxSessionsRange.contains)
        fields.read(
            .reviewsPauseMinutes, \.reviewsPauseMinutes,
            where: Settings.reviewsPauseChoices.contains)
        fields.read(
            .reviewsPollMinutes, \.reviewsPollMinutes, where: Settings.reviewsPollChoices.contains)
        fields.read(.reviewsRequestModel, \.reviewsRequestModel)
        fields.read(.reviewsReviewModel, \.reviewsReviewModel)
        fields.read(.reviewsSignedCommits, \.reviewsSignedCommits)
        fields.read(.reviewsIgnore, \.reviewsIgnore, as: [Lenient<String>].self) { items in
            kept(items, limit: SettingsText.maxReviewsIgnore, SettingsText.cleanReviewsIgnore)
        }
        fields.read(.terminalFont, \.terminalFont, as: StoredFont.self) { $0.font }
        fields.settings.dailyUpdate = dailyUpdate.flatMap(DailySettings.init(json:))
        fields.settings.keys = keys
        fields.read(.setupDone, \.setupDone)
        settings = fields.settings
        defaulted = fields.defaulted.sorted()
        laterVersion = nil
    }
}

// Reads the fields of a stored object of version 1. Each field starts with its default.
private struct FieldReader {
    let container: KeyedDecodingContainer<Settings.Key>
    var settings = Settings()
    // The keys whose stored values the settings do not keep.
    var defaulted: [String] = []

    // A field that keeps a stored value of its own type when the check passes.
    mutating func read<Value: Decodable>(
        _ key: Settings.Key, _ field: WritableKeyPath<Settings, Value>,
        where accepts: (Value) -> Bool = { _ in true }
    ) {
        read(key, field, as: Value.self) { accepts($0) ? ($0, true) : nil }
    }

    // A field that make gives from a stored value of type Stored. A missing key changes nothing.
    // A value that does not decode as Stored, or that make refuses (nil), keeps the default and
    // lists the key. whole is false when the field keeps only a part of the stored value. Then
    // the key is listed too.
    mutating func read<Stored: Decodable, Value>(
        _ key: Settings.Key, _ field: WritableKeyPath<Settings, Value>, as _: Stored.Type,
        _ make: (Stored) -> (value: Value, whole: Bool)?
    ) {
        guard container.contains(key) else { return }
        let result = (try? container.decode(Stored.self, forKey: key)).flatMap(make)
        if let result { settings[keyPath: field] = result.value }
        if result?.whole != true { defaulted.append(key.stringValue) }
    }

    // A raw value: any JSON value, also null. A missing key gives nil. A value with no JSON form
    // throws.
    func raw(_ key: Settings.Key) throws(NoJSONForm) -> JSONValue? {
        guard container.contains(key) else { return nil }
        return try container.jsonValue(forKey: key)
    }
}

// The good items of a stored list in their clean form, each one time, and only the first limit
// items. clean gives nil for a bad item. whole is false when the list lost an item.
private func kept(
    _ items: [Lenient<String>], limit: Int, _ clean: (String) -> String?
) -> (value: [String], whole: Bool) {
    var list: [String] = []
    for case let text? in items.map(\.decoded) {
        guard list.count < limit else { break }
        if let item = clean(text), !list.contains(item) { list.append(item) }
    }
    return (list, list.count == items.count)
}

// The stored terminal font. A part that is missing or has the wrong type is nil.
private struct StoredFont: Decodable {
    let family: String?
    let size: Int?

    private enum Key: String, CodingKey {
        case family, size
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        family = try? container.decode(String.self, forKey: .family)
        size = try? container.decode(Int.self, forKey: .size)
    }

    // Each bad part gets its default alone. whole is true when both parts pass.
    var font: (value: TerminalFont, whole: Bool) {
        let standard = Settings().terminalFont
        let family = family.flatMap { try? SettingsText.checkFontFamily($0) }
        let size = size.flatMap { Settings.fontSizeRange.contains($0) ? $0 : nil }
        let font = TerminalFont(family: family ?? standard.family, size: size ?? standard.size)
        return (font, family != nil && size != nil)
    }
}

// MARK: - The check of an edit

extension Settings {
    // Check the settings after an edit, and give their clean form: the slash commands and the
    // font family trimmed, and the ignore entries trimmed and in lower case. The check is strict:
    // the first bad field, in the order of the fields of the file, refuses the edit with its
    // reason. The pickers of the settings window offer only good values, so a refusal comes from
    // a text field. Good settings, and each load, pass the check with no change.
    package func validated() throws(SettingsRefusal) -> Settings {
        func check(_ key: Key, _ good: Bool) throws(SettingsRefusal) {
            if !good { throw .field(key) }
        }
        var next = self
        try check(.escalationMinutes, Self.escalationRange.contains(escalationMinutes))
        try check(.pollSeconds, Self.pollChoices.contains(pollSeconds))
        try check(.snapDistance, Self.snapRange.contains(snapDistance))
        try check(.panelTransparency, ThemeTokens.transparencyChoices.contains(panelTransparency))
        try check(.interfaceScale, CanvasMetrics.scaleChoices.contains(interfaceScale))
        next.slashCommands = try Self.checkSlashList(slashCommands)
        try check(.reviewsMaxSessions, Self.reviewsMaxSessionsRange.contains(reviewsMaxSessions))
        try check(.reviewsPauseMinutes, Self.reviewsPauseChoices.contains(reviewsPauseMinutes))
        try check(.reviewsPollMinutes, Self.reviewsPollChoices.contains(reviewsPollMinutes))
        try check(.reviewsIgnore, SettingsText.checkReviewsIgnore(reviewsIgnore))
        next.reviewsIgnore = reviewsIgnore.compactMap(SettingsText.cleanReviewsIgnore)
        next.terminalFont = try Self.checkFont(terminalFont)
        try check(.dailyUpdate, dailyUpdate?.isValid ?? true)
        return next
    }

    // The full list of slash commands. A bad command gives its reason for the user. A list over
    // 12 or a repeated command gives the refusal of the list.
    private static func checkSlashList(_ items: [String]) throws(SettingsRefusal) -> [String] {
        guard items.count <= SettingsText.maxSlashCommands else { throw .slashList }
        var list: [String] = []
        for item in items {
            let command = try SettingsText.checkSlashCommand(item)
            guard !list.contains(command) else { throw .slashList }
            list.append(command)
        }
        return list
    }

    // The family and the size of the font. The family gets its trimmed form.
    private static func checkFont(_ font: TerminalFont) throws(SettingsRefusal) -> TerminalFont {
        guard let family = try? SettingsText.checkFontFamily(font.family),
            fontSizeRange.contains(font.size)
        else { throw .field(.terminalFont) }
        return TerminalFont(family: family, size: font.size)
    }
}

// MARK: - The apps of Open project

extension Settings {
    // The app of Open project with no menu choice, for example from the key of Open project. It
    // is never Finder: the setting when it is installed, then VS Code, then Zed, then the first
    // terminal app of the list. nil when the list has none of them.
    package func defaultProjectApp(_ apps: [ProjectApp]) -> ProjectAppID? {
        for id in [projectApp, .vscode, .zed] {
            if let id, id != .finder, apps.contains(where: { $0.id == id }) { return id }
        }
        return apps.first { $0.id.terminal != nil }?.id
    }

    // The value that the Settings select of the default app shows. A saved Finder acts as
    // Automatic (nil).
    package var shownProjectApp: ProjectAppID? {
        projectApp == .finder ? nil : projectApp
    }

    // The apps that the Settings select offers for the default app. Finder is not a choice.
    package static func projectAppChoices(_ apps: [ProjectApp]) -> [ProjectApp] {
        apps.filter { $0.id != .finder }
    }
}

// MARK: - Texts

// The checks of the texts of the settings: slash commands, the font family and the ignore list
// of Reviews. A length limit counts Characters (TextRules.swift).
package enum SettingsText {
    package static let maxSlashCommands = 12
    package static let maxSlashLength = SlashCommand.maxLength
    package static let maxFontFamily = 64
    package static let maxReviewsIgnore = IgnoreRule.maxEntries

    package static let reasonSlashStart = "Start the command with \"/\", with no space after it."
    package static let reasonSlashLine = "Keep the command on one line."
    package static let reasonSlashLong =
        "That's too long. The limit is \(maxSlashLength) characters."
    package static let reasonFont =
        "Use 1 to \(maxFontFamily) characters, without quotes or ; { } < >."

    package static let reasonSlashList =
        "Use up to \(maxSlashCommands) slash commands, each one only once."
    package static let reasonSlashCopy = "That command is already in the list."
    package static let reasonSlashFull = "You can keep up to \(maxSlashCommands) commands."

    // Check a slash command with the rule of SlashCommand.clean. The result is the trimmed
    // text, and a refusal gives the refusal of the settings with its text.
    package static func checkSlashCommand(_ text: String) throws(SettingsRefusal) -> String {
        do {
            return try SlashCommand.clean(text)
        } catch {
            switch error {
            case .start: throw .slashStart
            case .lines: throw .slashLines
            case .tooLong: throw .slashTooLong
            }
        }
    }

    // Check the family of the terminal font. The result is the trimmed family: 1 to 64
    // Characters, with none of " ' \ ; { } < > and no control character (C0, DEL or C1).
    package static func checkFontFamily(_ text: String) throws(SettingsRefusal) -> String {
        let family = text.trimmed()
        let forbidden: Set<Unicode.Scalar> = ["\"", "'", "\\", ";", "{", "}", "<", ">"]
        let bad =
            family.isEmpty || family.count > maxFontFamily
            || family.unicodeScalars.contains { forbidden.contains($0) || isControl($0) }
        if bad { throw .fontFamily }
        return family
    }

    // True when the list has only good entries, no entry two times in its clean form, and not
    // more than maxReviewsIgnore entries.
    package static func checkReviewsIgnore(_ list: [String]) -> Bool {
        guard list.count <= maxReviewsIgnore else { return false }
        var seen: Set<String> = []
        for item in list {
            guard let entry = cleanReviewsIgnore(item), seen.insert(entry).inserted else {
                return false
            }
        }
        return true
    }

    // The clean form of an ignore entry (trimmed and lower case), or nil for a bad entry. The
    // rule is the rule of Reviews (IgnoreEntry).
    static func cleanReviewsIgnore(_ text: String) -> String? {
        IgnoreEntry(text)?.text
    }

    // C0, DEL or C1.
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }
}
