// The read of the vim mode of Claude Code and its cache (docs/behaviour/dictation.md). The reader
// reads real files in a TemporaryFolder home, so no test reads the real ~/.claude.json or
// ~/.claude/settings.json. The tests show the cache with the stamp: a file with a new content but
// the same size and the same time keeps its old value, so the reader did not parse it again.
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostDictation

private let earlier = Date(timeIntervalSince1970: 1_700_000_000)
private let later = Date(timeIntervalSince1970: 1_700_000_100)

// A home folder with the two settings files of Claude Code.
private struct Home {
    let folder: TemporaryFolder

    init() throws {
        folder = try TemporaryFolder(short: true)
        try FileManager.default.createDirectory(
            atPath: folder.appending(".claude"), withIntermediateDirectories: true)
    }

    var url: URL { URL(fileURLWithPath: folder.path) }
    var json: String { folder.appending(".claude.json") }
    var settings: String { folder.appending(".claude/settings.json") }

    // Write the text, with spaces after it up to the size, and give the file the time. The suites
    // run on the main actor, and a file can be 20 MB. So the spaces are bytes, not a String: a
    // String of 20 MB holds the main actor for a long time in a debug build.
    func write(_ path: String, _ text: String, size: Int? = nil, time: Date? = nil) throws {
        var data = Data(text.utf8)
        data.append(Data(repeating: UInt8(ascii: " "), count: max(0, (size ?? 0) - data.count)))
        try data.write(to: URL(fileURLWithPath: path))
        if let time { try touch(path, time) }
    }

    func touch(_ path: String, _ time: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: path)
    }

    func remove() { folder.remove() }
}

@Suite("vim mode check", .testTimeLimit)
@MainActor struct VimModeCheckTests {
    @Test("each file is read and vim mode in any of them counts")
    func eachFile() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write(home.json, #"{"theme":"dark"}"#)
        try home.write(home.settings, #"{"editorMode":"vim"}"#)
        #expect(await VimModeReader(home: home.url).vimMode())
        // Vim mode in the other file counts too.
        try home.write(home.json, #"{"vimMode":true}"#)
        try home.write(home.settings, #"{"theme":"dark"}"#)
        #expect(await VimModeReader(home: home.url).vimMode())
        try home.write(home.json, #"{"theme":"dark"}"#)
        #expect(await !VimModeReader(home: home.url).vimMode())
    }

    @Test("a file is parsed again only when its time or size changes")
    func stampCache() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write(home.json, #"{"theme":"dark"}"#, size: 30, time: earlier)
        let reader = VimModeReader(home: home.url)
        for _ in 0..<5 { #expect(await !reader.vimMode()) }
        // The same size and the same time: the reader keeps the value and does not parse.
        try home.write(home.json, #"{"editorMode":"vim"}"#, size: 30, time: earlier)
        #expect(await !reader.vimMode())
        // A new time: the reader parses the file again.
        try home.touch(home.json, later)
        #expect(await reader.vimMode())
        // A new size with the same time.
        try home.write(home.json, #"{"editorMode":"normal"}"#, size: 31, time: later)
        #expect(await !reader.vimMode())
        #expect(await !reader.vimMode())
    }

    @Test("a parse error keeps the last good value, or false with none")
    func parseError() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write(home.json, #"{"vimMode":true}"#, time: earlier)
        let reader = VimModeReader(home: home.url)
        #expect(await reader.vimMode())
        // Claude writes the file again, and the read sees a part of it.
        try home.write(home.json, #"{"vimMo"#, time: later)
        #expect(await reader.vimMode())
        #expect(await reader.vimMode())
        let fresh = try Home()
        defer { fresh.remove() }
        try fresh.write(fresh.json, #"{"vimMo"#)
        #expect(await !VimModeReader(home: fresh.url).vimMode())
    }

    @Test
    func missingAndFailing() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write(home.json, #"{"vimMode":true}"#)
        let reader = VimModeReader(home: home.url)
        #expect(await reader.vimMode())
        try FileManager.default.removeItem(atPath: home.json)
        #expect(await !reader.vimMode())
        // A read that fails: a file that the user cannot read. A stat that fails: ~/.claude is a
        // file, so ~/.claude/settings.json cannot be there (ENOTDIR). The root user can read a
        // file with mode 0, so a run as root skips the case of the read.
        let failing = try TemporaryFolder(short: true)
        defer { failing.remove() }
        if getuid() != 0 {
            let locked = failing.appending(".claude.json")
            try Data(#"{"vimMode":true}"#.utf8).write(to: URL(fileURLWithPath: locked))
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked)
        }
        try Data("{}".utf8).write(to: URL(fileURLWithPath: failing.appending(".claude")))
        #expect(await !VimModeReader(home: URL(fileURLWithPath: failing.path)).vimMode())
    }
}

@Suite("file stamp", .testTimeLimit)
struct FileStampTests {
    @Test("a regular file gives time and size and no file gives null")
    func stamp() throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let file = folder.appending("settings.json")
        try Data(#"{"a":1}"#.utf8).write(to: URL(fileURLWithPath: file))
        let stamp = VimModeFile.stamp(file)
        #expect(stamp?.size == 7)
        #expect(stamp?.seconds ?? 0 > 0)
        #expect(VimModeFile.stamp(folder.appending("none.json")) == nil)
        #expect(VimModeFile.stamp(folder.path) == nil)
    }
}

// New tests.
@MainActor struct VimModeReaderTests {
    // stat follows a symbolic link, so a linked settings file counts.
    @Test func aLinkToASettingsFileCounts() async throws {
        let home = try Home()
        defer { home.remove() }
        let target = home.folder.appending("dotfiles-settings.json")
        try home.write(target, #"{"editorMode":"vim"}"#)
        try FileManager.default.createSymbolicLink(
            atPath: home.settings, withDestinationPath: target)
        #expect(VimModeFile.stamp(home.settings)?.size == 20)
        #expect(await VimModeReader(home: home.url).vimMode())
    }

    // A file over 20 MB is not read (MAX_CLAUDE_JSON_BYTES), so it gives no good value.
    @Test func aFileOverTheLimitIsNotRead() async throws {
        let home = try Home()
        defer { home.remove() }
        #expect(VimModeFile.maxBytes == 20 * 1024 * 1024)
        try home.write(home.json, #"{"vimMode":true}"#, size: VimModeFile.maxBytes + 1)
        #expect(await !VimModeReader(home: home.url).vimMode())
        try home.write(home.json, #"{"vimMode":true}"#, size: VimModeFile.maxBytes)
        #expect(await VimModeReader(home: home.url).vimMode())
    }

    // A file that holds only the JSON literal null is no good value, : the last good value
    // stays. With no good value, it is false.
    @Test func aNullFileKeepsTheLastGoodValue() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write(home.json, #"{"vimMode":true}"#, time: earlier)
        let reader = VimModeReader(home: home.url)
        #expect(await reader.vimMode())
        try home.write(home.json, "null", time: later)
        #expect(await reader.vimMode())
        let fresh = try Home()
        defer { fresh.remove() }
        try fresh.write(fresh.json, " null ")
        #expect(await !VimModeReader(home: fresh.url).vimMode())
    }

    // A file that is valid JSON but not an object is a good value: false. So a later parse error
    // keeps false.
    @Test func aValueThatIsNotAnObjectIsAGoodValueOfFalse() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write(home.json, #"{"vimMode":true}"#, time: earlier)
        let reader = VimModeReader(home: home.url)
        #expect(await reader.vimMode())
        try home.write(home.json, #"["vim"]"#, time: later)
        #expect(await !reader.vimMode())
        try home.write(home.json, #"{"vimMo"#, time: earlier)
        #expect(await !reader.vimMode())
    }

    // Only the top level counts, and the other keys of a large file do not change the result.
    @Test func onlyTheTopLevelOfALargeFileCounts() async throws {
        let home = try Home()
        defer { home.remove() }
        let projects = (0..<2000).map { #""/p/\#($0)":{"vimMode":true,"history":["a","b"]}"# }
        try home.write(home.json, #"{"projects":{\#(projects.joined(separator: ","))}}"#)
        #expect(await !VimModeReader(home: home.url).vimMode())
        try home.write(
            home.json, #"{"projects":{\#(projects.joined(separator: ","))},"editorMode":"vim"}"#)
        #expect(await VimModeReader(home: home.url).vimMode())
    }
}
