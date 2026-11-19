import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

// The extra usage flag of ~/.claude.json (docs/behaviour/usage.md, "The usage notification").
// SAFETY: each test reads the file of its own temporary home, never the real ~/.claude.json.

private let on = #"{"oauthAccount":{"hasExtraUsageEnabled":true}}"#

private func write(_ text: String, in home: TemporaryFolder) throws {
    try Data(text.utf8).write(to: ClaudeJSON.file(home: home.url))
}

private func flag(_ home: TemporaryFolder) async -> Bool {
    await ClaudeJSON.extraUsageFlag(home: home.url)
}

@Suite("~/.claude.json flag", .timeLimit(.minutes(1)))
struct ClaudeJSONTests {
    @Test func theFileIsClaudeJsonInTheHome() {
        let home = URL(filePath: "/tmp/test-home", directoryHint: .isDirectory)
        #expect(path(ClaudeJSON.file(home: home)) == "/tmp/test-home/.claude.json")
    }

    @Test func onlyOauthAccountHasExtraUsageEnabledTrueGivesTheFlag() async throws {
        let home = try TemporaryFolder(short: true)
        defer { home.remove() }
        try write(on, in: home)
        #expect(await flag(home))
        try write(#"{"oauthAccount":{"hasExtraUsageEnabled":false}}"#, in: home)
        #expect(await !flag(home))
        try write(#"{"oauthAccount":{}}"#, in: home)
        #expect(await !flag(home))
        try write(#"{"oauthAccount":{"hasExtraUsageEnabled":"true"}}"#, in: home)
        #expect(await !flag(home))
        try write(#"{"oauthAccount":[]}"#, in: home)
        #expect(await !flag(home))
        try write("[]", in: home)
        #expect(await !flag(home))
    }

    // Only the value true at oauthAccount.hasExtraUsageEnabled counts as on.
    @Test func eachOtherValueGivesNoFlag() async throws {
        let home = try TemporaryFolder(short: true)
        defer { home.remove() }
        let off = [
            "null", "7", #""x""#, "{}", #"{"oauthAccount":null}"#,
            #"{"oauthAccount":{"hasExtraUsageEnabled":null}}"#,
            #"{"oauthAccount":{"hasExtraUsageEnabled":1}}"#, #"{"hasExtraUsageEnabled":true}"#,
        ]
        for text in off {
            try write(text, in: home)
            #expect(await !flag(home), "\(text)")
        }
    }

    @Test func aMissingFileAFolderAFifoAndBadJSONGiveNoFlag() async throws {
        let home = try TemporaryFolder(short: true)
        defer { home.remove() }
        let file = path(ClaudeJSON.file(home: home.url))
        #expect(await !flag(home))
        #expect(mkdir(file, 0o700) == 0)
        #expect(await !flag(home))
        #expect(rmdir(file) == 0)
        // The read of a FIFO does not wait for a writer.
        #expect(mkfifo(file, 0o600) == 0)
        #expect(await !flag(home))
        #expect(unlink(file) == 0)
        try write(#"{ "oauthAccount": { "hasExtraUsageEnabled": true "#, in: home)
        #expect(await !flag(home))
        try write("", in: home)
        #expect(await !flag(home))
    }

    // The open follows a link, as a stat does.
    @Test func aLinkToTheFileGivesTheFlagOfTheFile() async throws {
        let home = try TemporaryFolder(short: true)
        defer { home.remove() }
        let target = home.appending("real.json")
        try Data(on.utf8).write(to: URL(filePath: target))
        #expect(symlink(target, path(ClaudeJSON.file(home: home.url))) == 0)
        #expect(await flag(home))
        #expect(unlink(target) == 0)
        #expect(await !flag(home))
    }

    @Test func aFileAbove20MBIsSkipped() async throws {
        let home = try TemporaryFolder(short: true)
        defer { home.remove() }
        #expect(ClaudeJSON.maxBytes == 20 * 1024 * 1024)
        // JSON allows white space after the value, so the size alone decides.
        let padding = String(repeating: " ", count: ClaudeJSON.maxBytes - on.utf8.count)
        try write(on + padding, in: home)
        #expect(await flag(home))
        try write(on + padding + " ", in: home)
        #expect(await !flag(home))
    }

    // The read decodes only the key path of the flag. Thus a value elsewhere in the file that a
    // JSON value cannot hold (row S6 of docs/ports/stores/DELIBERATE-DIFFERENCES.md) does not
    // stop the read.
    @Test func aValueThatAJSONValueCannotHoldElsewhereInTheFileDoesNotStopTheRead() async throws {
        let home = try TemporaryFolder(short: true)
        defer { home.remove() }
        try write(
            #"""
            {"projects":{"a":{"text":"\ud83d","size":1e400}},
             "oauthAccount":{"displayName":"\udc00","hasExtraUsageEnabled":true}}
            """#, in: home)
        #expect(await flag(home))
    }

    @Test func theReadNeverChangesTheFile() async throws {
        let home = try TemporaryFolder(short: true)
        defer { home.remove() }
        let file = ClaudeJSON.file(home: home.url)
        try write(on, in: home)
        let before = try FileManager.default.attributesOfItem(atPath: path(file))
        #expect(await flag(home))
        let after = try FileManager.default.attributesOfItem(atPath: path(file))
        #expect(try String(contentsOf: file, encoding: .utf8) == on)
        #expect(after[.modificationDate] as? Date == before[.modificationDate] as? Date)
        #expect(after[.posixPermissions] as? Int == before[.posixPermissions] as? Int)
        #expect(try names(home.url) == [".claude.json"])
    }
}
