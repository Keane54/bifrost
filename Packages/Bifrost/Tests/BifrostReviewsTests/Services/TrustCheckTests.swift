// The trust check of a review clone (docs/behaviour/reviews.md, "Clones and trust"): a read only
// of .claude.json in the test home, and the change events of that file. Each test writes the file
// in a temporary folder. No test reads the real ~/.claude.json.
import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostReviews

// A test home with a clone folder in a Reviews folder.
private struct TrustHome {
    let folder: TemporaryFolder
    let home: URL
    let clone: URL

    init() throws {
        folder = try TemporaryFolder()
        home = URL(filePath: folder.realPath, directoryHint: .isDirectory)
        clone = home.appending(
            path: ".bifrost/reviews/repos/owner-a/repo-a", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
    }

    var file: String { home.path(percentEncoded: false) + ".claude.json" }

    var clonePath: String {
        let path = clone.path(percentEncoded: false)
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    func write(_ text: String) throws {
        try text.write(toFile: file, atomically: false, encoding: .utf8)
    }

    // The text of a file with one project entry for the path.
    static func entry(_ path: String, _ value: String = "true") -> String {
        "{\"numStartups\": 3, \"projects\": {\"\(path)\": {\"allowedTools\": [], "
            + "\"hasTrustDialogAccepted\": \(value)}}}"
    }
}

@MainActor
@Suite("the trust check of Reviews", .testTimeLimit)
struct TrustCheckTests {
    // A folder is trusted when its entry, or the entry of a folder above it, has the value true
    // at hasTrustDialogAccepted. Another value, another folder and a missing file give false.
    @Test func aTrustedFolderIsTrusted() async throws {
        let t = try TrustHome()
        defer { t.folder.remove() }
        #expect(!(await TrustCheck.isTrusted(t.clone, home: t.home)))
        try t.write(TrustHome.entry(t.clonePath))
        #expect(await TrustCheck.isTrusted(t.clone, home: t.home))
        let parent = (t.clonePath as NSString).deletingLastPathComponent
        try t.write(TrustHome.entry(parent))
        #expect(await TrustCheck.isTrusted(t.clone, home: t.home))
        try t.write(TrustHome.entry(t.clonePath + "-other"))
        #expect(!(await TrustCheck.isTrusted(t.clone, home: t.home)))
        for value in ["false", "\"true\"", "1", "null", "{}"] {
            try t.write(TrustHome.entry(t.clonePath, value))
            #expect(!(await TrustCheck.isTrusted(t.clone, home: t.home)))
        }
        // The clone behind a link: the entry of the real path counts.
        let link = t.folder.realPath + "/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: t.clonePath)
        try t.write(TrustHome.entry(t.clonePath))
        #expect(await TrustCheck.isTrusted(URL(filePath: link), home: t.home))
        // A project entry that is not an object does not stop the read of the others.
        try t.write(
            "{\"projects\": {\"/a\": 3, \"\(t.clonePath)\": {\"hasTrustDialogAccepted\": true}}}")
        #expect(await TrustCheck.isTrusted(t.clone, home: t.home))
    }

    // One read gives the trust of each folder, in the order of the folders.
    @Test func oneReadGivesTheTrustOfEachFolder() async throws {
        let t = try TrustHome()
        defer { t.folder.remove() }
        let other = t.home.appending(path: "other", directoryHint: .isDirectory)
        #expect(await TrustCheck.trusted([t.clone, other], home: t.home) == [false, false])
        try t.write(TrustHome.entry(t.clonePath))
        #expect(await TrustCheck.trusted([t.clone, other], home: t.home) == [true, false])
        #expect(await TrustCheck.trusted([], home: t.home) == [])
    }

    @Test func aFileOver20MBOrNotJSONGivesNotTrusted() async throws {
        let t = try TrustHome()
        defer { t.folder.remove() }
        try t.write("{\"projects\": {\"\(t.clonePath)\": {\"hasTrustDialogAccepted\": true}")
        #expect(!(await TrustCheck.isTrusted(t.clone, home: t.home)))
        let entry = Data(TrustHome.entry(t.clonePath).utf8)
        var large = entry
        large.removeLast()
        large += Data(", \"pad\": \"".utf8)
        large += Data(repeating: UInt8(ascii: "x"), count: ClaudeJSON.maxBytes)
        large += Data("\"}".utf8)
        try large.write(to: URL(filePath: t.file))
        #expect(!(await TrustCheck.isTrusted(t.clone, home: t.home)))
        // A folder at the path of the file.
        try FileManager.default.removeItem(atPath: t.file)
        try FileManager.default.createDirectory(atPath: t.file, withIntermediateDirectories: false)
        #expect(!(await TrustCheck.isTrusted(t.clone, home: t.home)))
    }

    // The check only reads: the bytes and the modification time of the file stay.
    @Test func theCheckNeverWrites() async throws {
        let t = try TrustHome()
        defer { t.folder.remove() }
        try t.write(TrustHome.entry(t.clonePath))
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: t.file)
        let before = try Data(contentsOf: URL(filePath: t.file))
        for _ in 0..<3 { #expect(await TrustCheck.isTrusted(t.clone, home: t.home)) }
        let after = try Data(contentsOf: URL(filePath: t.file))
        let attributes = try FileManager.default.attributesOfItem(atPath: t.file)
        #expect(after == before)
        #expect(attributes[.modificationDate] as? Date == old)
    }

    // Claude Code writes the file with a rename of a new file over it. The events follow the new
    // file: a write of the file gives an event, a rename over it gives one, and a write of the new
    // file gives one too. A file that comes after the start gives an event as well.
    @Test(.tags(.timing)) func aRenameOfTheFileGivesAChangeEvent() async throws {
        let t = try TrustHome()
        defer { t.folder.remove() }
        let changes = TrustCheck.changes(home: t.home)
        let count = Counter()
        let reading = Task { @MainActor in
            for await _ in changes { count.value += 1 }
        }
        defer { reading.cancel() }
        // No file yet: the source watches the folder of the home until the file comes. The
        // stream arms its source when it is made, so the write comes after the arm.
        try t.write("{}")
        #expect(await waitUntil { count.value >= 1 })
        try await settle(count)
        let seen = count.value
        let next = t.file + ".tmp"
        try TrustHome.entry(t.clonePath).write(toFile: next, atomically: false, encoding: .utf8)
        #expect(rename(next, t.file) == 0)
        #expect(await waitUntil { count.value > seen })
        try await settle(count)
        let renamed = count.value
        let handle = try #require(FileHandle(forWritingAtPath: t.file))
        handle.seekToEndOfFile()
        handle.write(Data(" ".utf8))
        try handle.close()
        #expect(await waitUntil { count.value > renamed })
    }

    // While no file is at the path, a change of another item of the home gives no event. The
    // file that comes gives one, and its later writes give more.
    @Test(.tags(.timing)) func aChangeOfAnotherItemOfTheHomeGivesNoEvent() async throws {
        let t = try TrustHome()
        defer { t.folder.remove() }
        let changes = TrustCheck.changes(home: t.home)
        let count = Counter()
        let reading = Task { @MainActor in
            for await _ in changes { count.value += 1 }
        }
        defer { reading.cancel() }
        let other = t.home.path(percentEncoded: false) + "other.json"
        try "{}".write(toFile: other, atomically: false, encoding: .utf8)
        try FileManager.default.removeItem(atPath: other)
        try FileManager.default.createDirectory(
            atPath: other, withIntermediateDirectories: false)
        try await settle(count)
        #expect(count.value == 0)
        try t.write("{}")
        #expect(await waitUntil { count.value >= 1 })
        try await settle(count)
        let seen = count.value
        try append(" ", to: t.file)
        #expect(await waitUntil { count.value > seen })
    }

    // A rename of a new file over the path between the open of the file and the start of its
    // source gives an event, and the watch follows the new file: its later writes give events.
    @Test(.tags(.timing)) func aRenameBeforeTheStartOfTheSourceIsNotLost() async throws {
        let t = try TrustHome()
        defer { t.folder.remove() }
        try t.write("{}")
        let file = t.file
        let once = Mutex(true)
        let changes = TrustCheck.changes(home: t.home) {
            guard once.withLock({ first in defer { first = false }; return first }) else { return }
            let next = file + ".tmp"
            try? TrustHome.entry("/a").write(toFile: next, atomically: false, encoding: .utf8)
            rename(next, file)
        }
        let count = Counter()
        let reading = Task { @MainActor in
            for await _ in changes { count.value += 1 }
        }
        defer { reading.cancel() }
        #expect(await waitUntil { count.value >= 1 })
        try await settle(count)
        let seen = count.value
        try append(" ", to: file)
        #expect(await waitUntil { count.value > seen })
    }

    // A file that comes between the failed open of the file and the start of the source on the
    // home folder gives an event, and the watch follows the file.
    @Test(.tags(.timing)) func aFileThatComesBeforeTheStartOfTheSourceIsNotLost() async throws {
        let t = try TrustHome()
        defer { t.folder.remove() }
        let file = t.file
        let once = Mutex(true)
        let changes = TrustCheck.changes(home: t.home) {
            guard once.withLock({ first in defer { first = false }; return first }) else { return }
            try? "{}".write(toFile: file, atomically: false, encoding: .utf8)
        }
        let count = Counter()
        let reading = Task { @MainActor in
            for await _ in changes { count.value += 1 }
        }
        defer { reading.cancel() }
        #expect(await waitUntil { count.value >= 1 })
        try await settle(count)
        let seen = count.value
        try append(" ", to: file)
        #expect(await waitUntil { count.value > seen })
    }

    // Add the text at the end of the file.
    private func append(_ text: String, to path: String) throws {
        let handle = try #require(FileHandle(forWritingAtPath: path))
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try handle.close()
    }

    // Wait until no event came for 200 ms. One write can give its events in more than one
    // batch, so a check of the next step waits for the end of the events of this step.
    @MainActor
    private func settle(_ count: Counter) async throws {
        var last = -1
        while last != count.value {
            last = count.value
            try await Task.sleep(for: .milliseconds(200))
        }
    }
}

@MainActor
private final class Counter {
    var value = 0
}
