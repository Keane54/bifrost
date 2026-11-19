import BifrostFoundation
import BifrostSessions
import Testing

// The history of the New session dialog: the parse of the saved value, its JSON form, the
// remembered values and the folder list (the section "The Overviews and the dialog history in
// the UI state" of docs/behaviour/windows.md).

private let empty = History.empty
private let tooLong = "/" + String(repeating: "x", count: 200)
private let longest = "/" + String(repeating: "x", count: 199)

private func texts(_ items: [String]) -> JSONValue { .array(items.map(JSONValue.string)) }

// A row with this ID and working folder.
private func row(_ id: String, cwd: String) -> SessionRow {
    SessionRow(
        sessionId: id, name: id, claudeName: id, kind: .owned, cwd: cwd, status: .busy,
        state: .working, lastActivity: 0, startedAt: 0)
}

@Suite("dialog history")
struct HistoryTests {
    @Test func thePermissionModesAreTheModesOfClaudeWithoutBypass() {
        #expect(
            PermissionMode.allCases.map(\.rawValue) == [
                "acceptEdits", "auto", "manual", "dontAsk", "plan",
            ])
    }

    @Test func theEmptyHistoryHasTheDefaultModelAndModeAndNoLists() {
        #expect(
            empty
                == History(recentDirs: [], model: .standard, permissionMode: nil, recentSlash: []))
    }

    @Test(
        "bad data gives the empty history",
        arguments: [
            nil, .null, [], "x", 7, ["model": "gpt"], ["model": 1, "permissionMode": true],
            ["recentDirs": "x", "recentSlash": [:]],
        ] as [JSONValue?])
    func badData(value: JSONValue?) {
        #expect(History.parse(value) == empty)
    }

    @Test func theParseKeepsTheGoodValuesAndDropsTheBadOnes() {
        let parsed = History.parse([
            "model": "sonnet", "permissionMode": "plan",
            "recentDirs": ["/a", "rel/b", "/a", 7, .null, "/c"],
            "recentSlash": [
                "/compact", "/two\nlines", "no slash", "/compact", .string(tooLong), "/ok",
            ],
        ])
        #expect(
            parsed
                == History(
                    recentDirs: ["/a", "/c"], model: .sonnet, permissionMode: .plan,
                    recentSlash: ["/compact", "/ok"]))
    }

    @Test func eachModelAndEachModeLoads() {
        for model in ModelChoice.allCases {
            #expect(History.parse(["model": .string(model.rawValue)]).model == model)
        }
        for mode in PermissionMode.allCases {
            let parsed = History.parse(["permissionMode": .string(mode.rawValue)])
            #expect(parsed.permissionMode == mode)
        }
    }

    @Test(
        "a mode that is not a mode of the list gives the default mode",
        arguments: ["bypassPermissions", "", "Plan", "default", " plan"])
    func unknownMode(mode: String) {
        #expect(History.parse(["permissionMode": .string(mode)]).permissionMode == nil)
    }

    // The limit counts the kept items, so a bad item or a repeat does not use a place.
    @Test func theListsKeepTheFirstTenFoldersAndTheFirstEightCommands() {
        let many = (0..<30).map { "/d\($0)" }
        let parsed = History.parse(["recentDirs": texts(many), "recentSlash": texts(many)])
        #expect(parsed.recentDirs == Array(many.prefix(10)))
        #expect(parsed.recentSlash == Array(many.prefix(8)))
        let withBad = History.parse(["recentDirs": texts(["rel", "/d0", "/d0"] + many)])
        #expect(withBad.recentDirs == Array(many.prefix(10)))
    }

    // A folder starts with the scalar "/", so a combining mark after the slash does not refuse it.
    @Test func aFolderNeedsAPathThatStartsWithASlash() {
        let parsed = History.parse([
            "recentDirs": ["", "a/b", "~/x", " /lead", "/\u{301}mark", "/"]
        ])
        #expect(parsed.recentDirs == ["/\u{301}mark", "/"])
    }

    // A saved command passes the check of the settings and is already trimmed.
    @Test func theParseChecksEachCommandAsTheSettingsDo() {
        let parsed = History.parse([
            "recentSlash": [
                "/a\rb", .string(longest), .string(longest + "x"), " /a", "/b ", "/ c", "/", "/d",
            ]
        ])
        #expect(parsed.recentSlash == [longest, "/d"])
    }

    // The limit of a command counts Characters, as in the settings (row S15 of the stores).
    @Test func theLimitOfACommandCountsCharacters() {
        let emoji = "/" + String(repeating: "😀", count: 199)
        let parsed = History.parse(["recentSlash": texts([emoji, emoji + "😀"])])
        #expect(parsed.recentSlash == [emoji])
        #expect(empty.rememberingSlash(emoji).recentSlash == [emoji])
        #expect(empty.rememberingSlash(emoji + "😀") == empty)
    }

    // Two forms of one accented letter are one String, so they are one folder and one command
    // (row U10).
    @Test func twoFormsOfOneTextAreOneEntry() {
        let composed = "/caf\u{e9}"
        let decomposed = "/cafe\u{301}"
        let parsed = History.parse([
            "recentDirs": texts([composed, decomposed]),
            "recentSlash": texts([composed, decomposed]),
        ])
        let scalars = { (texts: [String]) in texts.map { Array($0.unicodeScalars) } }
        #expect(scalars(parsed.recentDirs) == scalars([composed]))
        #expect(parsed.recentSlash.count == 1)
        let remembered = parsed.remembering(cwd: decomposed, model: .standard, mode: nil)
        #expect(scalars(remembered.recentDirs) == scalars([decomposed]))
    }

    @Test func rememberingASessionPutsTheFolderFirstAndKeepsTheModelAndTheMode() {
        var history = empty
        for number in 0..<12 {
            history = history.remembering(cwd: "/d\(number)", model: .opus, mode: .plan)
        }
        history = history.remembering(cwd: "/d5", model: .opus, mode: .plan)
        #expect(
            history.recentDirs == [
                "/d5", "/d11", "/d10", "/d9", "/d8", "/d7", "/d6", "/d4", "/d3", "/d2",
            ])
        #expect(history.model == .opus)
        #expect(history.permissionMode == .plan)
        let plain = history.remembering(cwd: "/d2", model: .standard, mode: nil)
        #expect(plain.model == .standard)
        #expect(plain.permissionMode == nil)
        #expect(plain.recentDirs.first == "/d2")
        #expect(plain.recentDirs.count == 10)
    }

    @Test func rememberingACommandKeepsTheEightNewestWithNoRepeat() {
        var history = empty
        for number in 0..<10 { history = history.rememberingSlash("/c\(number)") }
        history = history.rememberingSlash("  /c5  ")
        #expect(history.recentSlash == ["/c5", "/c9", "/c8", "/c7", "/c6", "/c4", "/c3", "/c2"])
        #expect(history.recentDirs.isEmpty)
    }

    @Test(
        "remembering a text that is not a slash command changes nothing",
        arguments: ["hello", "", "   ", "/a\nb", "/a\rb", "/ a", "/", tooLong])
    func notACommand(text: String) {
        #expect(empty.rememberingSlash(text) == empty)
    }

    @Test func rememberingKeepsACommandOf200Characters() {
        #expect(empty.rememberingSlash(longest).recentSlash == [longest])
    }

    // The folders of the rows are their project folders: a worktree gives its repository, and a
    // row with no folder adds nothing.
    @Test func theRecentFoldersAreTheHistoryThenTheProjectFoldersOfTheRows() {
        var history = empty
        history.recentDirs = ["/h", "/r"]
        let rows = [
            row("1", cwd: "/r/.claude/worktrees/fix-a"), row("2", cwd: "/r/"),
            row("3", cwd: ""), row("4", cwd: "/z"), row("5", cwd: "rel"),
        ]
        #expect(history.recentDirectories(rows) == ["/h", "/r", "/z"])
        let many = (0..<12).map { row("\($0)", cwd: "/p\($0)") }
        #expect(history.recentDirectories(many) == ["/h", "/r"] + (0..<8).map { "/p\($0)" })
        #expect(empty.recentDirectories([]).isEmpty)
    }

    // The JSON form has the field names of the file. The default model and the default mode are
    // the empty text, and the unknown fields stay.
    @Test func theJSONFormHasTheFieldsOfTheFileAndKeepsTheUnknownFields() {
        let saved: JSONValue = [
            "model": "haiku", "permissionMode": "auto", "recentDirs": ["/a"],
            "recentSlash": ["/b"], "future": [1, .null],
        ]
        let history = History.parse(saved)
        #expect(history.json == saved)
        #expect(History.parse(history.json) == history)
        #expect(
            empty.json == ["model": "", "permissionMode": "", "recentDirs": [], "recentSlash": []])
        let cleaned = History.parse(["model": "gpt", "recentDirs": ["rel", "/a"], "x": "y"])
        #expect(
            cleaned.json == [
                "model": "", "permissionMode": "", "recentDirs": ["/a"], "recentSlash": [],
                "x": "y",
            ])
    }
}
