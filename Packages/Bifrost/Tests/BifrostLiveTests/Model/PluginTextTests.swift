import BifrostFoundation
import BifrostLive
import Testing

// The parse of the output of the claude plugin commands: the JSON list of a list command, the
// result line of a write command, the entries of the two lists and the texts of the failures.

private func ok(_ stdout: String) -> ExecResult { ExecResult(.exited(0), stdout: stdout) }

@Suite("The parse of the plugin output")
struct PluginTextTests {
    // MARK: - The lists

    @Test func theListStartsAtTheFirstLineThatBeginsWithABracket() throws {
        let result = ok("Update available\n[{\"id\":\"a\"},\n{\"id\":\"b\"}]\n")
        let list = try PluginText.list(result, name: .plugin)
        #expect(list == [["id": .string("a")], ["id": .string("b")]])
    }

    @Test func theListReadsLinesThatEndWithCRLF() throws {
        let list = try PluginText.list(ok("Note\r\n[{\"id\":\"a\"}]\r\n"), name: .plugin)
        #expect(list == [["id": .string("a")]])
    }

    @Test func theListKeepsOnlyTheObjects() throws {
        let list = try PluginText.list(ok("[1, \"x\", null, [], {\"id\":\"a\"}]"), name: .plugin)
        #expect(list == [["id": .string("a")]])
    }

    @Test func aFailedListNamesItsListAndGivesTheStderr() {
        let text = "Bifrost couldn't read the plugin list from Claude Code:"
        #expect(throws: PluginFailure.unreadableList(.plugin, end: .exited(1), stderr: "boom")) {
            try PluginText.list(ExecResult(.exited(1), stderr: "boom\n"), name: .plugin)
        }
        #expect(
            PluginFailure.unreadableList(.plugin, end: .exited(1), stderr: "boom").message
                == "\(text) boom")
        #expect(
            PluginFailure.unreadableList(.marketplace, end: .exited(1), stderr: "boom").message
                == "Bifrost couldn't read the marketplace list from Claude Code: boom")
    }

    @Test func aFailedListWithNoStderrGivesTheExitCode() {
        #expect(throws: PluginFailure.unreadableList(.plugin, end: .exited(3), stderr: "")) {
            try PluginText.list(ExecResult(.exited(3), stdout: "[]"), name: .plugin)
        }
        #expect(
            PluginFailure.unreadableList(.plugin, end: .exited(3), stderr: "").message
                == "Bifrost couldn't read the plugin list from Claude Code: it exited with code 3")
    }

    @Test func aListThatEndsWithASignalGivesTheTextOfTheEnd() {
        #expect(
            PluginFailure.unreadableList(.plugin, end: .signal(9), stderr: "").message
                == "Bifrost couldn't read the plugin list from Claude Code: "
                + "claude stopped with signal 9.")
    }

    @Test(arguments: ["no json here", "", "[1, 2", "{\"id\":\"a\"}", "[]x"])
    func outputWithNoListGivesNoList(_ stdout: String) {
        #expect(throws: PluginFailure.unreadableList(.plugin, end: .exited(0), stderr: "")) {
            try PluginText.list(ok(stdout), name: .plugin)
        }
        #expect(
            PluginFailure.unreadableList(.plugin, end: .exited(0), stderr: "").message
                == "Bifrost couldn't read the plugin list from Claude Code: it gave no list")
    }

    @Test func aBadListWithStderrGivesTheStderr() {
        let result = ExecResult(.exited(0), stdout: "nothing", stderr: "  warning  ")
        #expect(throws: PluginFailure.unreadableList(.plugin, end: .exited(0), stderr: "warning")) {
            try PluginText.list(result, name: .plugin)
        }
    }

    // MARK: - The entries

    @Test func aPluginEntryReadsItsFields() {
        let fields: [String: JSONValue] = [
            "id": "bifrost-live@bifrost-local", "enabled": true,
            "readFromFolder": "/h/.bifrost/mod",
            "errors": .array(["one", 2, "two"]),
        ]
        #expect(
            PluginEntry(fields)
                == PluginEntry(enabled: true, folder: "/h/.bifrost/mod", errors: ["one", "two"]))
    }

    @Test func aPluginEntryWithOddFieldsIsOffWithNoFolderAndNoErrors() {
        let fields: [String: JSONValue] = ["enabled": "true", "readFromFolder": 3, "errors": "x"]
        #expect(PluginEntry(fields) == PluginEntry(enabled: false, folder: nil, errors: []))
    }

    @Test func aMarketplaceEntryReadsItsFields() {
        #expect(
            MarketplaceEntry(["name": "bifrost-local", "source": "directory", "path": "/h/mod"])
                == MarketplaceEntry(source: "directory", path: "/h/mod"))
        #expect(
            MarketplaceEntry(["source": 1, "path": 2]) == MarketplaceEntry(source: "", path: nil))
    }

    // MARK: - The result line

    @Test func theResultCheckReadsOnlyTheLastLineThatIsNotEmpty() throws {
        try PluginText.check(ok("Run this command now?\n{\"outcome\":\"ok\"}\n\n  \n"))
        #expect(throws: PluginFailure.refused("bad")) {
            try PluginText.check(
                ExecResult(
                    .exited(1),
                    stdout: "{\"outcome\":\"ok\"}\n{\"outcome\":\"failed\",\"message\":\"bad\"}\n"))
        }
    }

    @Test func theResultCheckReadsALastLineThatEndsWithCRLF() throws {
        try PluginText.check(ok("Note\r\n{\"outcome\":\"ok\"}\r\n"))
    }

    @Test func alreadyInTheGoalStatePasses() throws {
        let line =
            #"{"command":"enable","outcome":"failed","#
            + #""message":"Plugin \"bifrost-live\" is already enabled","#
            + #""failureCode":"already_in_goal_state","alreadyInGoalState":true}"#
        try PluginText.check(ExecResult(.exited(1), stdout: line))
    }

    @Test func aFailedResultGivesItsMessage() {
        let line = #"{"command":"install","outcome":"failed","message":"Plugin not found"}"#
        #expect(throws: PluginFailure.refused("Plugin not found")) {
            try PluginText.check(ExecResult(.exited(1), stdout: line))
        }
        #expect(PluginFailure.refused("Plugin not found").message == "Plugin not found")
    }

    @Test(arguments: ["42", "null", "[]", #"{"command":"install"}"#, #"{"message":""}"#, ""])
    func exitZeroWithNoUsableResultFails(_ line: String) {
        #expect(throws: PluginFailure.noResult) { try PluginText.check(ok(line)) }
        #expect(PluginFailure.noResult.message == "Claude Code gave no result.")
    }

    @Test func aFailureWithNoMessageGivesTheStderrThenTheExitCode() {
        #expect(throws: PluginFailure.commandFailed(end: .exited(1), stderr: "oops")) {
            try PluginText.check(ExecResult(.exited(1), stdout: "text", stderr: "oops\n"))
        }
        #expect(PluginFailure.commandFailed(end: .exited(1), stderr: "oops").message == "oops")
        #expect(throws: PluginFailure.commandFailed(end: .exited(4), stderr: "")) {
            try PluginText.check(ExecResult(.exited(4), stdout: "42"))
        }
        #expect(
            PluginFailure.commandFailed(end: .exited(4), stderr: "").message
                == "claude exited with code 4")
        #expect(
            PluginFailure.commandFailed(end: .signal(15), stderr: "").message
                == "claude stopped with signal 15.")
    }

    // MARK: - The other texts

    @Test func theOtherFailuresHavePlainTexts() {
        #expect(PluginFailure.timedOut.message == "Claude Code didn't finish in 30 seconds.")
        #expect(
            PluginFailure.badFolder.message
                == "The plugin folder path must be absolute and have no line break")
        #expect(
            PluginFailure.optionLike("--help").message
                == "Bifrost won't pass --help to Claude Code, because it starts with a dash.")
        #expect(
            PluginFailure.busy.message == "Another change is still running. Try again in a moment.")
        #expect(PluginFailure.cancelled.message == "Bifrost stopped the Claude Code command.")
    }
}
