import Foundation
import Testing

@testable import BifrostFoundation
@testable import BifrostSettings

// The edge cases of the settings: the limits of each field, the texts of the lists and the
// font, a file of another version and a value that is not an object. A stored value that fails
// its check gives the default of its field alone. An edit with a bad value is refused.

private func stored(_ key: String, _ value: JSONValue) -> JSONValue {
    ["version": 1, key: value]
}

// The saved form of the decoded settings of a stored value, at one key.
private func read(_ value: JSONValue, _ key: String) -> JSONValue? {
    savedField(decodedSettings(value), key)
}

private let defaults = Settings()

private struct WholeField: Sendable, CustomTestStringConvertible {
    var key: String
    var accepted: [Int]
    var refused: [Int]
    var set: @Sendable (inout Settings, Int) -> Void

    var testDescription: String { key }

    // The coding key of the field, for its refusal.
    var codingKey: Settings.Key { Settings.Key(rawValue: key)! }
}

private let wholeFields: [WholeField] = [
    WholeField(
        key: "escalationMinutes", accepted: [0, 1, 10, 60, 119, 120],
        refused: [-1, 121, -10, 1000],
        set: { $0.escalationMinutes = $1 }),
    WholeField(
        key: "interfaceScale", accepted: [80, 90, 100, 110, 120, 130, 140, 150],
        refused: [70, 79, 85, 155, 160, 0], set: { $0.interfaceScale = $1 }),
    WholeField(
        key: "panelTransparency", accepted: Array(stride(from: 0, through: 50, by: 5)),
        refused: [7, 55, -5, 51, 1], set: { $0.panelTransparency = $1 }),
    WholeField(
        key: "pollSeconds", accepted: [1, 2, 3, 5, 10], refused: [0, 4, 6, 11, -1],
        set: { $0.pollSeconds = $1 }),
    WholeField(
        key: "reviewsMaxSessions", accepted: Array(1...10), refused: [0, 11, -1, 100],
        set: { $0.reviewsMaxSessions = $1 }),
    WholeField(
        key: "reviewsPauseMinutes", accepted: [15, 30, 60, 120, 240, 480],
        refused: [45, 0, 61, 14, 481], set: { $0.reviewsPauseMinutes = $1 }),
    WholeField(
        key: "reviewsPollMinutes", accepted: [1, 2, 5, 10], refused: [3, 0, 4, 11],
        set: { $0.reviewsPollMinutes = $1 }),
    WholeField(
        key: "snapDistance", accepted: Array(0...32), refused: [-1, 33, 64],
        set: { $0.snapDistance = $1 }),
]

@Suite("settings: whole number fields")
struct WholeFieldEdgeTests {
    @Test("a stored value in range or on a step stays", arguments: wholeFields)
    fileprivate func parseKeeps(field: WholeField) {
        for n in field.accepted {
            #expect(read(stored(field.key, .int(n)), field.key) == .int(n), "\(field.key) \(n)")
        }
    }

    @Test("a stored value off range or off step gives the default", arguments: wholeFields)
    fileprivate func parseRefuses(field: WholeField) {
        let standard = savedField(defaults, field.key)
        for n in field.refused {
            #expect(read(stored(field.key, .int(n)), field.key) == standard, "\(field.key) \(n)")
        }
    }

    @Test(
        "a stored value that is not a number gives the default",
        arguments: [
            JSONValue.string("10"), .bool(true), .null, .array([]), .object([:]), .double(2.5),
            .double(-0.5), .double(1e20),
        ])
    func parseAlien(value: JSONValue) {
        for field in wholeFields {
            let standard = savedField(defaults, field.key)
            #expect(read(stored(field.key, value), field.key) == standard, "\(field.key)")
        }
    }

    @Test("an edit with an accepted value changes the field", arguments: wholeFields)
    fileprivate func editAccepts(field: WholeField) throws {
        for n in field.accepted {
            let next = try edited { field.set(&$0, n) }
            #expect(savedField(next, field.key) == .int(n), "\(field.key) \(n)")
        }
    }

    @Test("an edit with a refused value is refused and names the field", arguments: wholeFields)
    fileprivate func editRefuses(field: WholeField) {
        for n in field.refused {
            #expect(reasonOf { field.set(&$0, n) } == .field(field.codingKey), "\(n)")
        }
    }

    // JSON has one number type. The raw text of the file has the number in double form, so
    // the JSON encoder of a test value cannot give it.
    @Test("a whole number in double form stays", arguments: wholeFields)
    fileprivate func doubleForm(field: WholeField) throws {
        let n = try #require(field.accepted.last)
        let text = #"{"version":1,"\#(field.key)":\#(n).0}"#
        let stored = try JSONDecoder().decode(StoredSettings.self, from: Data(text.utf8))
        #expect(savedField(stored.settings, field.key) == .int(n))
        #expect(stored.defaulted.isEmpty)
    }
}

@Suite("settings: choices and flags")
struct ChoiceEdgeTests {
    @Test(
        "a stored choice that the type holds stays",
        arguments: [
            ("labels", "plain"), ("labels", "space"), ("reviewsRequestModel", ""),
            ("reviewsRequestModel", "opus"), ("reviewsRequestModel", "sonnet"),
            ("reviewsReviewModel", "haiku"), ("terminalApp", "warp"), ("terminalApp", "ghostty"),
            ("terminalApp", "iterm2"), ("terminalApp", "terminal"), ("projectApp", "finder"),
            ("projectApp", "vscode"), ("projectApp", "zed"), ("projectApp", "warp"),
            ("projectApp", "ghostty"), ("projectApp", "iterm2"), ("projectApp", "terminal"),
        ])
    func kept(key: String, value: String) {
        #expect(read(stored(key, .string(value)), key) == .string(value))
    }

    @Test("the app can be null for Automatic", arguments: ["terminalApp", "projectApp"])
    func appNull(key: String) {
        #expect(read(stored(key, .null), key) == .null)
    }

    @Test(
        "a stored choice outside the values gives the default",
        arguments: [
            ("labels", JSONValue.string("fancy")), ("labels", "Plain"), ("labels", ""),
            ("labels", 7), ("labels", .null), ("labels", .bool(true)),
            ("reviewsRequestModel", "fable"), ("reviewsRequestModel", "gpt"),
            ("reviewsRequestModel", "Opus"), ("reviewsRequestModel", " opus"),
            ("reviewsReviewModel", "fable"), ("reviewsReviewModel", .null),
            ("reviewsReviewModel", 1),
            ("terminalApp", "finder"), ("terminalApp", "vscode"), ("terminalApp", "zed"),
            ("terminalApp", "Warp"), ("terminalApp", ""), ("terminalApp", 7),
            ("terminalApp", .bool(true)), ("terminalApp", .object([:])),
            ("projectApp", "notepad"), ("projectApp", "VSCode"), ("projectApp", ""),
            ("projectApp", 7), ("projectApp", .bool(false)),
        ])
    func refused(key: String, value: JSONValue) {
        #expect(read(stored(key, value), key) == savedField(defaults, key))
    }

    @Test(
        "a stored flag keeps true and false and refuses other values",
        arguments: [
            "accountUsage", "animatedBackground", "autoUpdate", "notifications", "redBoxSound",
            "reviewsAutoFix", "reviewsSignedCommits", "reviewsTeamRequests", "reviewsWatch",
            "rowFlash", "setupDone", "startAtLogin",
        ])
    func flag(key: String) {
        for flag in [true, false] {
            #expect(read(stored(key, .bool(flag)), key) == .bool(flag))
        }
        for alien in [
            JSONValue.string("yes"), .string("true"), .int(0), .int(1), .null,
            .array([]), .object([:]),
        ] {
            #expect(read(stored(key, alien), key) == savedField(defaults, key))
        }
    }

    // A flag has no check: an edit with true or false passes and saves that value.
    @Test func anEditSetsEachFlagToTrueAndFalse() throws {
        let flags: [(String, WritableKeyPath<Settings, Bool>)] = [
            ("accountUsage", \.accountUsage), ("animatedBackground", \.animatedBackground),
            ("autoUpdate", \.autoUpdate), ("notifications", \.notifications),
            ("redBoxSound", \.redBoxSound), ("reviewsAutoFix", \.reviewsAutoFix),
            ("reviewsSignedCommits", \.reviewsSignedCommits),
            ("reviewsTeamRequests", \.reviewsTeamRequests), ("reviewsWatch", \.reviewsWatch),
            ("rowFlash", \.rowFlash), ("setupDone", \.setupDone), ("startAtLogin", \.startAtLogin),
        ]
        for (key, field) in flags {
            for flag in [true, false] {
                #expect(savedField(try edited { $0[keyPath: field] = flag }, key) == .bool(flag))
            }
        }
    }
}

@Suite("settings: slash commands")
struct SlashCommandEdgeTests {
    @Test(
        "a good command stays, trimmed",
        arguments: [
            ("/compact", "/compact"), ("  /a  ", "/a"), ("\t/b\n", "/b"), ("/x y", "/x y"),
            ("/é", "/é"),
            ("/" + String(repeating: "x", count: 199), "/" + String(repeating: "x", count: 199)),
        ])
    func good(text: String, expected: String) throws {
        #expect(try SettingsText.checkSlashCommand(text) == expected)
    }

    @Test(
        "a command with no slash, a space after it or a line break is refused",
        arguments: [
            ("b", SettingsRefusal.slashStart), ("/", .slashStart), ("/ x", .slashStart),
            ("/\u{A0}x", .slashStart), ("/\u{3000}x", .slashStart), ("", .slashStart),
            ("  ", .slashStart), ("/a\nb", .slashLines), ("/a\rb", .slashLines),
            ("/a\r\nb", .slashLines), ("/" + String(repeating: "x", count: 200), .slashTooLong),
        ])
    func refused(text: String, reason: SettingsRefusal) {
        #expect(throws: reason) {
            try SettingsText.checkSlashCommand(text)
        }
    }

    private func stack(_ items: [String]) -> JSONValue { .array(items.map { .string($0) }) }

    // A bad item does not count to the limit of 12.
    @Test("a stored list drops bad and repeated items and items after the 12th")
    func parseList() {
        let many = (0..<14).map { "/c\($0)" }
        let cases: [([JSONValue], [String])] = [
            ([.string("/a"), .string("b"), .string("/ a"), .string("/b")], ["/a", "/b"]),
            ([.string("/a"), .string(" /a "), .string("/b")], ["/a", "/b"]),
            ([.string("/a"), .int(5), .null, .string("/b")], ["/a", "/b"]),
            (many.map { .string($0) }, Array(many.prefix(12))),
            (
                [.string("b"), .int(7), .string("/c0")] + many.map { .string($0) },
                Array(many.prefix(12))
            ),
            ([], []),
        ]
        for (items, expected) in cases {
            let settings = decodedSettings(stored("slashCommands", .array(items)))
            #expect(settings.slashCommands == expected)
        }
        for alien: JSONValue in ["/a", .null, ["/a": "/b"]] {
            let settings = decodedSettings(stored("slashCommands", alien))
            #expect(settings.slashCommands == defaults.slashCommands)
        }
        #expect(decodedSettings(stored("slashCommands", [7])).slashCommands == [])
    }

    @Test("an edit of the list is refused for a bad command, a repeat after trim or a 13th item")
    func editList() throws {
        let refused = SettingsRefusal.slashList
        let reason = { (items: [String]) in reasonOf { $0.slashCommands = items } }
        #expect(reason(["/a", "/b"]) == nil)
        #expect(reason((0..<12).map { "/c\($0)" }) == nil)
        #expect(reason((0..<13).map { "/c\($0)" }) == refused)
        #expect(reason(["/a", " /a "]) == refused)
        #expect(reason(["/a", "b"]) == .slashStart)
        #expect(reason(["/a\nb"]) == .slashLines)
        #expect(try edited { $0.slashCommands = ["  /a  "] }.slashCommands == ["/a"])
    }
}

@Suite("settings: the ignore list of Reviews")
struct IgnoreListEdgeTests {
    @Test(
        "a good entry stays in its clean form",
        arguments: [
            ("acme/api", "acme/api"), (" Acme/API ", "acme/api"), ("acme/*", "acme/*"),
            ("ACME/*", "acme/*"), ("a/b", "a/b"), ("acme-/x", "acme-/x"),
            ("o/r.e_p-o", "o/r.e_p-o"),
            (String(repeating: "a", count: 39) + "/r", String(repeating: "a", count: 39) + "/r"),
            ("o/" + String(repeating: "r", count: 100), "o/" + String(repeating: "r", count: 100)),
            ("\tteam/tools\n", "team/tools"),
            // The Kelvin sign lower-cases to the letter k.
            ("\u{212A}/x", "k/x"),
        ])
    func good(entry: String, clean: String) {
        #expect(SettingsText.cleanReviewsIgnore(entry) == clean)
    }

    @Test(
        "a bad entry has no clean form",
        arguments: [
            "bad", "a/b/c", "-acme/x", "acme/", "/x", "*/x", "ac me/x", "acme/x y",
            String(repeating: "a", count: 40) + "/r", "o/" + String(repeating: "r", count: 101),
            "o/**", "é/x", "\u{130}/x", "a/\nb", "",
        ])
    func bad(entry: String) {
        #expect(SettingsText.cleanReviewsIgnore(entry) == nil)
    }

    @Test("a stored list keeps good entries once each, up to 50")
    func parseList() {
        let ignore = { (value: JSONValue) in
            decodedSettings(stored("reviewsIgnore", value)).reviewsIgnore
        }
        let fifty = (0..<52).map { "acme/r\($0)" }
        #expect(ignore(.array(fifty.map { .string($0) })) == Array(fifty.prefix(50)))
        #expect(ignore(["a/b", "A/B", "bad", 7, " c/d "]) == ["a/b", "c/d"])
        #expect(ignore([" Acme/API ", "acme/*", "acme/api", "bad"]) == ["acme/api", "acme/*"])
        for alien in [JSONValue.string("x"), .null, .object(["a": "a/b"])] {
            #expect(ignore(alien) == [])
        }
    }

    @Test("a list is refused for a bad entry, a repeat or a 51st entry")
    func checkList() {
        #expect(SettingsText.checkReviewsIgnore((0..<50).map { "acme/r\($0)" }))
        #expect(!SettingsText.checkReviewsIgnore((0..<51).map { "acme/r\($0)" }))
        #expect(!SettingsText.checkReviewsIgnore(["a/b", "A/B"]))
        #expect(!SettingsText.checkReviewsIgnore(["a/b", "bad"]))
        #expect(SettingsText.checkReviewsIgnore([]))
    }
}

@Suite("settings: the terminal font")
struct FontEdgeTests {
    @Test(
        "a good family stays, trimmed",
        arguments: [
            ("SF Mono", "SF Mono"), ("Menlo", "Menlo"), ("  Menlo  ", "Menlo"),
            (String(repeating: "x", count: 64), String(repeating: "x", count: 64)),
            (String(repeating: "é", count: 64), String(repeating: "é", count: 64)),
            ("\u{A0}Plain Code\u{3000}", "Plain Code"), ("Mono\u{2028}", "Mono"),
            ("a-b_c.d", "a-b_c.d"), ("a\u{A0}b", "a\u{A0}b"),
        ])
    func good(text: String, expected: String) throws {
        #expect(try SettingsText.checkFontFamily(text) == expected)
    }

    @Test(
        "a bad family is refused",
        arguments: [
            "A\"B", "A'B", "a\\b", "a;b", "{x}", "<b>", "", "   ",
            String(repeating: "x", count: 65), String(repeating: "é", count: 65), "a\tb", "a\nb",
            "a\r\nb", "a\u{1}b", "a\u{7F}b", "a\u{80}b", "a\u{9F}b",
        ])
    func bad(text: String) {
        #expect(throws: SettingsRefusal.fontFamily) {
            try SettingsText.checkFontFamily(text)
        }
    }

    @Test(
        "a stored font keeps its good part and a bad part gets its default",
        arguments: [
            (["family": "Menlo", "size": 12], TerminalFont(family: "Menlo", size: 12)),
            (["family": "Menlo", "size": 9], TerminalFont(family: "Menlo", size: 9)),
            (["family": "Menlo", "size": 24], TerminalFont(family: "Menlo", size: 24)),
            (["family": "Menlo", "size": 8], TerminalFont(family: "Menlo", size: 13)),
            (["family": "Menlo", "size": 25], TerminalFont(family: "Menlo", size: 13)),
            (["family": "Menlo", "size": 13.5], TerminalFont(family: "Menlo", size: 13)),
            (["family": "Menlo", "size": "13"], TerminalFont(family: "Menlo", size: 13)),
            (["family": "A\"B", "size": 12], TerminalFont(family: "SF Mono", size: 12)),
            (["family": 7, "size": 12], TerminalFont(family: "SF Mono", size: 12)),
            (["size": 12], TerminalFont(family: "SF Mono", size: 12)),
            (["family": "Menlo"], TerminalFont(family: "Menlo", size: 13)),
            (["family": "  Menlo  ", "size": 10], TerminalFont(family: "Menlo", size: 10)),
        ] as [([String: JSONValue], TerminalFont)])
    func parse(fields: [String: JSONValue], expected: TerminalFont) {
        #expect(decodedSettings(stored("terminalFont", .object(fields))).terminalFont == expected)
    }

    @Test(
        "a stored font that is not an object gives the default font",
        arguments: [JSONValue.string("Menlo"), .null, .array([]), .int(7)])
    func parseAlien(value: JSONValue) {
        let font = decodedSettings(stored("terminalFont", value)).terminalFont
        #expect(font == defaults.terminalFont)
    }

    @Test("an edit of the font is refused for a bad family or a size outside 9 to 24")
    func editFont() throws {
        for font in [
            TerminalFont(family: "A\"B", size: 13), TerminalFont(family: "Menlo", size: 8),
            TerminalFont(family: "Menlo", size: 25), TerminalFont(family: "", size: 13),
            TerminalFont(family: "Menlo", size: 0), TerminalFont(family: "Menlo", size: -13),
        ] {
            #expect(reasonOf { $0.terminalFont = font } == .field(.terminalFont))
        }
        let next = try edited { $0.terminalFont = TerminalFont(family: " Menlo ", size: 24) }
        #expect(next.terminalFont == TerminalFont(family: "Menlo", size: 24))
    }
}

@Suite("settings: the file")
struct SettingsFileEdgeTests {
    // The decode refuses a value that is not an object. The store then uses the defaults and
    // logs no key.
    @Test(arguments: [
        JSONValue.null, .array([]), .string("x"), .int(7), .bool(true), .array([["version": 1]]),
    ])
    func notAnObject(value: JSONValue) {
        #expect(storedSettings(value) == nil)
    }

    @Test(
        "a version other than 1 gives the defaults and lists each known key",
        arguments: [
            JSONValue?.none, .some(0), .some(2), .some(1.5), .some(3), .some("1"), .some(.null),
            .some(-1), .some(true), .some([1]),
        ])
    func version(version: JSONValue?) {
        var fields: [String: JSONValue] = ["pollSeconds": 5, "rowFlash": false, "theme": "light"]
        if let version { fields["version"] = version }
        let stored = storedSettings(.object(fields))
        var expected = defaults
        expected.unknown = UnknownFields(["theme": "light"])
        #expect(stored?.settings == expected)
        #expect(
            stored?.defaulted
                == (version == nil
                    ? ["pollSeconds", "rowFlash"] : ["pollSeconds", "rowFlash", "version"]))
    }

    @Test(
        "an unknown key is ignored",
        arguments: ["theme", "zoom", "constructor", "toString", "futureSetting", "Version"])
    func unknown(key: String) {
        #expect(decodedSettings(["version": 1, key: "light", "pollSeconds": 5]).pollSeconds == 5)
        #expect(defaultedKeys(["version": 1, key: 1]) == [])
    }
}
