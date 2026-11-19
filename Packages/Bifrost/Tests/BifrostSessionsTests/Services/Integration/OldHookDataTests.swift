import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostSessions

// The items that the clean-up never touches.
private let kept = [
    "mod/keep.txt", "live.sock", "live.lock", "statusline-original.json",
    "backups/settings-1.json",
]

// The dot folder of Bifrost in a test home, with the data of the old hooks and the old app.
private struct BifrostHome {
    let folder: TemporaryFolder
    let home: URL
    let log = Recorder<IntegrationLogEvent>()

    init() throws {
        folder = try TemporaryFolder(short: true)
        home = SharedClaudeState(home: folder.url).bifrostHome
    }

    func path(_ name: String) -> String {
        home.appending(path: name).path(percentEncoded: false)
    }

    func exists(_ name: String) -> Bool {
        var info = stat()
        return lstat(path(name), &info) == 0
    }

    func seed() throws {
        for name in ["events", "sessions", "bin", "mod", "backups"] {
            try FileManager.default.createDirectory(
                atPath: path(name), withIntermediateDirectories: true)
        }
        for name in [
            "active", "events/1-2.json", "sessions/s.json", "bin/bifrost-hook", "mod/keep.txt",
            "live.sock", "live.lock", "statusline-original.json", "backups/settings-1.json",
        ] {
            try Data("x".utf8).write(to: URL(fileURLWithPath: path(name)))
        }
    }

    func remove(keepScripts: Bool) async {
        await OldHookData.remove(home, keepScripts: keepScripts, log: log)
    }
}

@Suite("the old hook data", .testTimeLimit)
struct OldHookDataTests {
    @Test func theOldHookDataKeepsModSocketOriginalAndBackups() async throws {
        let bifrost = try BifrostHome()
        defer { bifrost.folder.remove() }
        try bifrost.seed()
        await bifrost.remove(keepScripts: true)
        for gone in ["active", "events", "sessions"] { #expect(!bifrost.exists(gone), "\(gone)") }
        for name in kept + ["bin/bifrost-hook"] { #expect(bifrost.exists(name), "\(name)") }
        #expect(bifrost.log.values == [.oldHookDataRemoved(["active", "events", "sessions"])])
    }

    @Test func binStaysWithKeepScriptsAndGoesWithout() async throws {
        let bifrost = try BifrostHome()
        defer { bifrost.folder.remove() }
        try bifrost.seed()
        await bifrost.remove(keepScripts: true)
        #expect(bifrost.exists("bin/bifrost-hook"))
        await bifrost.remove(keepScripts: false)
        #expect(!bifrost.exists("bin"))
        for name in kept { #expect(bifrost.exists(name), "\(name)") }
        #expect(
            bifrost.log.values == [
                .oldHookDataRemoved(["active", "events", "sessions"]), .oldHookDataRemoved(["bin"]),
            ])
    }

    @Test func aHomeWithNothingInItIsFine() async throws {
        let bifrost = try BifrostHome()
        defer { bifrost.folder.remove() }
        await bifrost.remove(keepScripts: false)
        try FileManager.default.createDirectory(
            atPath: bifrost.path(""), withIntermediateDirectories: false)
        await bifrost.remove(keepScripts: false)
        #expect(bifrost.log.values.isEmpty)
    }

    // An item that is a link goes as a link. The folder that it names keeps its files, and so
    // does a folder that a link inside an item names.
    @Test func aLinkGoesButNotItsTarget() async throws {
        let bifrost = try BifrostHome()
        defer { bifrost.folder.remove() }
        let outside = bifrost.folder.appending("outside")
        try FileManager.default.createDirectory(
            atPath: outside, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: URL(fileURLWithPath: "\(outside)/keep.txt"))
        try FileManager.default.createDirectory(
            atPath: bifrost.path("sessions"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: bifrost.path("events"), withDestinationPath: outside)
        try FileManager.default.createSymbolicLink(
            atPath: bifrost.path("sessions/inner"), withDestinationPath: outside)
        await bifrost.remove(keepScripts: false)
        #expect(!bifrost.exists("events"))
        #expect(!bifrost.exists("sessions"))
        #expect(FileManager.default.fileExists(atPath: "\(outside)/keep.txt"))
    }

    // A dot folder that is a link stays refused (user decision, 2026-11-17): the clean-up removes
    // nothing in the folder that it names.
    @Test func aDotFolderThatIsALinkKeepsItsData() async throws {
        let bifrost = try BifrostHome()
        defer { bifrost.folder.remove() }
        let real = bifrost.folder.appending("real")
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            atPath: bifrost.folder.appending(".bifrost"), withDestinationPath: real)
        try bifrost.seed()
        await bifrost.remove(keepScripts: false)
        for name in ["active", "events/1-2.json", "sessions/s.json", "bin/bifrost-hook"] {
            #expect(FileManager.default.fileExists(atPath: "\(real)/\(name)"), "\(name)")
        }
        #expect(bifrost.log.values.isEmpty)
    }

    // An item that does not go is logged, and the clean-up goes on with the next item.
    @Test func aFailureIsLoggedAndTheNextItemsGo() async throws {
        let bifrost = try BifrostHome()
        defer { bifrost.folder.remove() }
        try bifrost.seed()
        #expect(chmod(bifrost.path("events"), 0o500) == 0)
        defer { chmod(bifrost.path("events"), 0o700) }
        await bifrost.remove(keepScripts: false)
        #expect(bifrost.exists("events/1-2.json"))
        for gone in ["active", "sessions", "bin"] { #expect(!bifrost.exists(gone), "\(gone)") }
        let values = bifrost.log.values
        #expect(values.count == 2)
        guard case .oldHookDataNotRemoved(let path, _)? = values.first else {
            Issue.record("No failure in the log: \(values)")
            return
        }
        #expect(path == bifrost.path("events"))
        #expect(values.last == .oldHookDataRemoved(["active", "sessions", "bin"]))
    }
}
