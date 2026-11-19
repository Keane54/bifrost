import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostSessions

private let now = try! Date("2026-11-04T15:30:00Z", strategy: .iso8601)
private let original =
    #"{"command":"printf 'ORIG'","padding":0,"refreshInterval":1,"type":"command"}"#
private let missingOriginal = "Bifrost cannot find your original statusLine setting."

// A test home in a short temp folder, with its shared paths and the folder .claude.
private struct Home: Sendable {
    let folder: TemporaryFolder
    let paths: SharedClaudeState
    let log = Recorder<IntegrationLogEvent>()

    init() throws {
        folder = try TemporaryFolder(short: true)
        paths = SharedClaudeState(home: folder.url)
        try FileManager.default.createDirectory(
            atPath: folder.appending(".claude"), withIntermediateDirectories: false)
    }

    var settings: String { paths.claudeSettings.path(percentEncoded: false) }
    var bifrost: String { folder.appending(".bifrost") }
    var backups: String { folder.appending(".bifrost/backups") }
    var saved: String { paths.savedStatusLine.path(percentEncoded: false) }

    func remove() { folder.remove() }

    func write(_ text: String, _ path: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    func bytes(_ path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    func names(_ folder: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder).sorted()
    }

    func mode(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.posixPermissions] as? Int ?? 0) & 0o777
    }

    // The settings of an old hook install from base, in settings.json. With a saved text, the
    // saved original holds it. With nil, the home has no saved original.
    func seedOldInstall(_ base: String = "{}", saved: String?) throws {
        try write(try oldInstalled(try BifrostSessionsTests.settings(base)).text, settings)
        if let saved {
            try FileManager.default.createDirectory(
                atPath: bifrost, withIntermediateDirectories: true)
            try write(saved + "\n", self.saved)
        }
    }

    // The saved original with this text, in a new dot folder.
    func writeSaved(_ text: String) throws {
        try FileManager.default.createDirectory(atPath: bifrost, withIntermediateDirectories: true)
        try write(text, saved)
    }

    func uninstall(beforeRename: (@Sendable () async -> Void)? = nil)
        async throws(IntegrationFailure)
    {
        try await ClaudeSettingsFile.uninstall(
            paths, now: now, beforeRename: beforeRename, log: log)
    }
}

// A file at the end of five folders with names of 200 characters. Its absolute path has more
// than 1,024 bytes, so only calls relative to a folder descriptor make and remove it.
private struct DeepFile {
    static let name = String(repeating: "d", count: 200)
    let folders: [Int32]
    // The path of the file from the folder.
    let relative = String(repeating: DeepFile.name + "/", count: 5) + "real.json"

    init(in folder: String, text: String) throws {
        var folders = [open(folder, O_RDONLY | O_DIRECTORY | O_CLOEXEC)]
        for _ in 0..<5 {
            let parent = try #require(folders.last.flatMap { $0 >= 0 ? $0 : nil })
            try #require(mkdirat(parent, Self.name, 0o700) == 0)
            folders.append(openat(parent, Self.name, O_RDONLY | O_DIRECTORY | O_CLOEXEC))
        }
        let last = try #require(folders.last.flatMap { $0 >= 0 ? $0 : nil })
        let file = openat(last, "real.json", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        try #require(file >= 0)
        let bytes = Array(text.utf8)
        try #require(write(file, bytes, bytes.count) == bytes.count)
        close(file)
        self.folders = folders
    }

    // Remove the file and the five folders, then close the descriptors.
    func remove() {
        if let last = folders.last { unlinkat(last, "real.json", 0) }
        for parent in folders.dropLast().reversed() { unlinkat(parent, Self.name, AT_REMOVEDIR) }
        for folder in folders { close(folder) }
    }
}

@Suite("the edit of the Claude Code settings file", .testTimeLimit)
struct ClaudeSettingsFileTests {
    // MARK: - The refusals

    @Test func aFileThatIsNotJSONIsRefusedAndNothingChanges() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write("{ not json", home.settings)
        await #expect(throws: IntegrationFailure.notJSON(file: home.settings)) {
            try await home.uninstall()
        }
        #expect(
            IntegrationFailure.notJSON(file: "/h/s.json").message
                == "The file /h/s.json is not valid JSON (or not valid UTF-8). "
                + "Bifrost did not change it.")
        #expect(try home.bytes(home.settings) == Data("{ not json".utf8))
        #expect(!home.exists(home.bifrost))
    }

    @Test func bytesThatAreNotUTF8AreRefused() async throws {
        let home = try Home()
        defer { home.remove() }
        let bytes = Data([0x7B, 0x22, 0x61, 0x22, 0x3A, 0x22, 0xE9, 0x22, 0x7D])
        try bytes.write(to: home.paths.claudeSettings)
        await #expect(throws: IntegrationFailure.notJSON(file: home.settings)) {
            try await home.uninstall()
        }
        #expect(try home.bytes(home.settings) == bytes)
        #expect(!home.exists(home.bifrost))
    }

    @Test func anEmptyFileIsNotValidJSON() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write("", home.settings)
        await #expect(throws: IntegrationFailure.notJSON(file: home.settings)) {
            try await home.uninstall()
        }
        #expect(try home.bytes(home.settings).isEmpty)
        #expect(!home.exists(home.bifrost))
    }

    @Test func aFileThatIsNotAnObjectIsRefused() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write("[]", home.settings)
        await #expect(throws: IntegrationFailure.notObject(file: home.settings)) {
            try await home.uninstall()
        }
        #expect(
            IntegrationFailure.notObject(file: "/h/s.json").message
                == "Unexpected type in /h/s.json. Expect a JSON object. Bifrost did not change it.")
        #expect(try home.bytes(home.settings) == Data("[]".utf8))
    }

    @Test func aFileWithTooManyLevelsIsRefused() async throws {
        let home = try Home()
        defer { home.remove() }
        let text =
            "{\"a\":" + String(repeating: "[", count: 600)
            + String(repeating: "]", count: 600) + "}"
        try home.write(text, home.settings)
        await #expect(throws: IntegrationFailure.tooDeep(file: home.settings)) {
            try await home.uninstall()
        }
        #expect(
            IntegrationFailure.tooDeep(file: "/h/s.json").message
                == "The file /h/s.json has more than 64 levels of nested values. "
                + "Bifrost did not change it.")
        #expect(try home.bytes(home.settings) == Data(text.utf8))
    }

    // A file larger than the limit is refused before the read of its bytes.
    @Test func aHugeFileIsRefusedAndKept() async throws {
        let home = try Home()
        defer { home.remove() }
        let huge = Data(#"{"a":""#.utf8) + Data(repeating: 0x78, count: ClaudeSettingsFile.maxBytes)
            + Data(#""}"#.utf8)
        try huge.write(to: home.paths.claudeSettings)
        await #expect(throws: IntegrationFailure.tooLarge(file: home.settings)) {
            try await home.uninstall()
        }
        #expect(
            IntegrationFailure.tooLarge(file: "/h/s.json").message
                == "The file /h/s.json is larger than 4 MB. Bifrost did not change it.")
        #expect(try home.bytes(home.settings) == huge)
        #expect(!home.exists(home.bifrost))
    }

    @Test func aFolderAtThePathIsRefused() async throws {
        let home = try Home()
        defer { home.remove() }
        try FileManager.default.createDirectory(
            atPath: home.settings, withIntermediateDirectories: false)
        await #expect(throws: IntegrationFailure.notAFile(file: home.settings)) {
            try await home.uninstall()
        }
        #expect(
            IntegrationFailure.notAFile(file: "/h/s.json").message
                == "/h/s.json is not a regular file. Bifrost did not change it.")
    }

    // The read does not wait on a FIFO.
    @Test func aFIFOAtThePathIsRefusedWithNoWait() async throws {
        let home = try Home()
        defer { home.remove() }
        #expect(mkfifo(home.settings, 0o600) == 0)
        await #expect(throws: IntegrationFailure.notAFile(file: home.settings)) {
            try await home.uninstall()
        }
        #expect(
            await ClaudeSettingsFile.oldInstall(home.paths)
                == .failure(.notAFile(file: home.settings)))
    }

    // MARK: - The edit

    @Test func aMissingFileIsAnEmptyObjectAndNothingChanges() async throws {
        let home = try Home()
        defer { home.remove() }
        try await home.uninstall()
        #expect(!home.exists(home.settings))
        #expect(!home.exists(home.bifrost))
        #expect(home.log.values.isEmpty)
    }

    @Test func aFileWithNoBifrostEntryStaysAsItIsWithNoBackup() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write(#"{"model":"x"}"#, home.settings)
        try await home.uninstall()
        #expect(try home.bytes(home.settings) == Data(#"{"model":"x"}"#.utf8))
        #expect(!home.exists(home.backups))
        #expect(home.log.values.isEmpty)
    }

    @Test func theOriginalStatusLineComesBackAndTheOtherKeysStay() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.seedOldInstall(#"{"model":"x","statusLine":\#(original)}"#, saved: original)
        try await home.uninstall()
        #expect(
            try settings(String(decoding: home.bytes(home.settings), as: UTF8.self))
                == settings(#"{"model":"x","statusLine":\#(original)}"#))
        // The saved original stays.
        #expect(try home.bytes(home.saved) == Data((original + "\n").utf8))
    }

    @Test func theWrapperGoesWhenTheUserHadNoStatusLine() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.seedOldInstall(#"{"model":"x"}"#, saved: "null")
        try await home.uninstall()
        #expect(try home.bytes(home.settings) == Data("{\n  \"model\": \"x\"\n}\n".utf8))
    }

    // The backup has the exact old bytes and the mode 0600, and the log names the backup.
    @Test func theBackupKeepsTheOldBytes() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.seedOldInstall(#"{"model":"x"}"#, saved: "null")
        let old = try home.bytes(home.settings)
        try await home.uninstall()
        let backup = "\(home.backups)/settings-20261104T153000Z.json"
        #expect(try home.bytes(backup) == old)
        #expect(try home.mode(backup) == 0o600)
        #expect(try home.names(home.backups) == ["settings-20261104T153000Z.json"])
        #expect(home.log.values == [.oldInstallRemoved(file: home.settings, backup: backup)])
    }

    // A new backups folder and a new dot folder get the mode 0700. A Bifrost hook with no
    // wrapper needs no saved original.
    @Test func aNewBackupsFolderIsPrivate() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write(#"{"hooks":{"Stop":[{"hooks":[\#(bifrostHookJSON)]}]}}"#, home.settings)
        try await home.uninstall()
        #expect(try home.bytes(home.settings) == Data("{}\n".utf8))
        #expect(try home.mode(home.bifrost) == 0o700)
        #expect(try home.mode(home.backups) == 0o700)
    }

    @Test func theFileKeepsItsMode() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.seedOldInstall(saved: "null")
        #expect(chmod(home.settings, 0o640) == 0)
        try await home.uninstall()
        #expect(try home.mode(home.settings) == 0o640)
        #expect(try home.bytes(home.settings) == Data("{}\n".utf8))
    }

    // The link stays, and its target gets the new text and keeps its mode.
    @Test func aSymlinkedSettingsFileStaysALink() async throws {
        let home = try Home()
        defer { home.remove() }
        let target = home.folder.appending("real-settings.json")
        try home.write(try oldInstalled(try settings(#"{"model":"x"}"#)).text, target)
        #expect(chmod(target, 0o640) == 0)
        try home.seedOldInstall(saved: "null")
        try FileManager.default.removeItem(atPath: home.settings)
        try FileManager.default.createSymbolicLink(
            atPath: home.settings, withDestinationPath: target)
        try await home.uninstall()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: home.settings) == target)
        #expect(try home.bytes(target) == Data("{\n  \"model\": \"x\"\n}\n".utf8))
        #expect(try home.mode(target) == 0o640)
        #expect(try home.names(home.folder.appending(".claude")) == ["settings.json"])
    }

    // A link to a file whose real path has more than 1,024 bytes: the open finds the file, but
    // the system cannot give its real path. realpath gives ENAMETOOLONG. F_GETPATH gives ENOSPC,
    // and the edit reports that code as ENAMETOOLONG, so the text gives the true reason. The edit
    // refuses, so it never writes beside the link: the link stays and the file stays.
    @Test func aLinkToAPathTooLongForTheSystemIsRefused() async throws {
        let home = try Home()
        defer { home.remove() }
        let old = try oldInstalled(try settings(#"{"model":"x"}"#)).text
        let deep = try DeepFile(in: home.folder.path, text: old)
        defer { deep.remove() }
        try home.writeSaved("null")
        let text = "../" + deep.relative
        try FileManager.default.createSymbolicLink(atPath: home.settings, withDestinationPath: text)
        try #require(RealPath.of(home.settings) == nil)
        do throws(IntegrationFailure) {
            try await home.uninstall()
            Issue.record("The edit did not refuse.")
        } catch {
            guard case .system(.system(.check, let path, let code)) = error else {
                Issue.record("Another refusal: \(error)")
                return
            }
            #expect(path == home.settings)
            #expect(code == ENAMETOOLONG)
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: home.settings) == text)
        #expect(try home.bytes(home.settings) == Data(old.utf8))
        #expect(try home.names(home.folder.appending(".claude")) == ["settings.json"])
        #expect(!home.exists(home.backups))
    }

    // A link that names no file is a missing file: nothing changes.
    @Test func aDanglingLinkIsAMissingFile() async throws {
        let home = try Home()
        defer { home.remove() }
        let target = home.folder.appending("gone.json")
        try FileManager.default.createSymbolicLink(
            atPath: home.settings, withDestinationPath: target)
        try await home.uninstall()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: home.settings) == target)
        #expect(!home.exists(target))
        #expect(!home.exists(home.bifrost))
    }

    @Test func twoBackupsInTheSameSecondGetANumberAndTheFirstStays() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.seedOldInstall(#"{"model":"x"}"#, saved: "null")
        let first = "\(home.backups)/settings-20261104T153000Z.json"
        try await home.uninstall()
        let firstBytes = try home.bytes(first)
        try home.write(try oldInstalled(try settings(#"{"model":"y"}"#)).text, home.settings)
        try await home.uninstall()
        #expect(try home.bytes(first) == firstBytes)
        #expect(home.exists("\(home.backups)/settings-20261104T153000Z-1.json"))
    }

    // A link at the backup name is a name that exists: the backup takes the next number, and
    // the link stays as it is.
    @Test func aLinkAtTheBackupNameIsNeverWrittenOver() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.seedOldInstall(saved: "null")
        try FileManager.default.createDirectory(
            atPath: home.backups, withIntermediateDirectories: true)
        let link = "\(home.backups)/settings-20261104T153000Z.json"
        let outside = home.folder.appending("outside.json")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)
        try await home.uninstall()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == outside)
        #expect(!home.exists(outside))
        #expect(home.exists("\(home.backups)/settings-20261104T153000Z-1.json"))
    }

    @Test func theTimeOfABackupIsUTCInWholeSeconds() {
        #expect(ClaudeSettingsFile.stamp(now) == "20261104T153000Z")
        #expect(ClaudeSettingsFile.stamp(now.addingTimeInterval(0.999)) == "20261104T153000Z")
        #expect(ClaudeSettingsFile.stamp(now.addingTimeInterval(-1)) == "20261104T152959Z")
    }

    // MARK: - The saved original

    @Test func aMissingSavedOriginalRefusesAndNamesTheNewestBackup() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.seedOldInstall(#"{"statusLine":\#(original)}"#, saved: nil)
        try FileManager.default.createDirectory(
            atPath: home.backups, withIntermediateDirectories: true)
        for name in [
            "settings-20261104T153000Z-2.json", "settings-20261104T153000Z-10.json",
            "settings-20261103T235959Z-99.json", "settings-20261105T000000Z.txt",
            "settings-2026110T153000Z.json", "settings-20261104T153000Z-.json", "notes.txt",
        ] {
            try home.write("{}", "\(home.backups)/\(name)")
        }
        let before = try home.bytes(home.settings)
        let count = try home.names(home.backups).count
        let newest = "\(home.backups)/settings-20261104T153000Z-10.json"
        await #expect(throws: IntegrationFailure.missingOriginal(newestBackup: newest)) {
            try await home.uninstall()
        }
        #expect(
            IntegrationFailure.missingOriginal(newestBackup: newest).message
                == "\(missingOriginal) Restore it from the newest backup: \(newest).")
        #expect(try home.bytes(home.settings) == before)
        #expect(try home.names(home.backups).count == count)
    }

    @Test(arguments: ["{ not json", "[]", "7", #"{"command":7}"#, #"{"type":"command"}"#])
    func aSavedOriginalThatIsNotUsableRefuses(_ saved: String) async throws {
        let home = try Home()
        defer { home.remove() }
        try home.seedOldInstall(#"{"statusLine":\#(original)}"#, saved: saved)
        let before = try home.bytes(home.settings)
        await #expect(throws: IntegrationFailure.missingOriginal(newestBackup: nil)) {
            try await home.uninstall()
        }
        #expect(try home.bytes(home.settings) == before)
    }

    @Test func theRefusalSaysNoBackupFoundWhenNoBackupExists() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.seedOldInstall(saved: nil)
        await #expect(throws: IntegrationFailure.missingOriginal(newestBackup: nil)) {
            try await home.uninstall()
        }
        #expect(
            IntegrationFailure.missingOriginal(newestBackup: nil).message
                == "\(missingOriginal) Restore it from the newest backup: no backup found.")
        #expect(!home.exists(home.backups))
    }

    // Without the wrapper, the edit needs no saved original.
    @Test func aMissingSavedOriginalIsFineWhenTheStatusLineIsNotTheWrapper() async throws {
        let home = try Home()
        defer { home.remove() }
        var old = try oldInstalled()
        let mine = try jsonValue(#"{"command":"printf 'NEW'","type":"command"}"#)
        old.setValue(mine, forKey: "statusLine")
        try home.write(old.text, home.settings)
        try await home.uninstall()
        #expect(
            String(decoding: try home.bytes(home.settings), as: UTF8.self) == """
                {
                  "statusLine": {
                    "command": "printf 'NEW'",
                    "type": "command"
                  }
                }

                """)
    }

    // Only the wrapper needs the saved original, so a removal of hooks only never reads it.
    @Test(arguments: [false, true])
    func aSavedOriginalThatIsNotAFileDoesNotStopAHooksOnlyRemoval(fifo: Bool) async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write(#"{"hooks":{"Stop":[{"hooks":[\#(bifrostHookJSON)]}]}}"#, home.settings)
        try FileManager.default.createDirectory(
            atPath: home.bifrost, withIntermediateDirectories: true)
        if fifo {
            #expect(mkfifo(home.saved, 0o600) == 0)
        } else {
            try FileManager.default.createDirectory(
                atPath: home.saved, withIntermediateDirectories: false)
        }
        try await home.uninstall()
        #expect(try home.bytes(home.settings) == Data("{}\n".utf8))
        #expect(home.exists(home.saved))
    }

    // The wrapper needs the saved original, so a folder or a FIFO at its path refuses. The
    // settings file keeps its bytes, no backup is made, and the item at the path stays. The paths
    // come from a home that has the item already, so the text names the path with no "/".
    @Test(arguments: [false, true])
    func aSavedOriginalThatIsNotAFileStopsTheRemovalOfTheWrapper(fifo: Bool) async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write(#"{"statusLine":\#(wrapperJSON)}"#, home.settings)
        try FileManager.default.createDirectory(
            atPath: home.bifrost, withIntermediateDirectories: true)
        if fifo {
            #expect(mkfifo(home.saved, 0o600) == 0)
        } else {
            try FileManager.default.createDirectory(
                atPath: home.saved, withIntermediateDirectories: false)
        }
        let paths = SharedClaudeState(home: home.folder.url)
        let saved = home.folder.appending(".bifrost/statusline-original.json")
        let before = try home.bytes(home.settings)
        await #expect(throws: IntegrationFailure.notAFile(file: saved)) {
            try await ClaudeSettingsFile.uninstall(paths, now: now, log: home.log)
        }
        #expect(
            IntegrationFailure.notAFile(file: saved).message
                == "\(saved) is not a regular file. Bifrost did not change it.")
        #expect(try home.bytes(home.settings) == before)
        #expect(!home.exists(home.backups))
        #expect(home.exists(home.saved))
    }

    // A byte order mark at the start of the saved original is skipped.
    @Test func aSavedOriginalWithAByteOrderMarkIsRead() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.seedOldInstall(#"{"statusLine":\#(original)}"#, saved: "\u{FEFF}" + original)
        try await home.uninstall()
        #expect(
            try settings(String(decoding: home.bytes(home.settings), as: UTF8.self))
                == settings(#"{"statusLine":\#(original)}"#))
    }

    // MARK: - A change during the edit

    // Another program writes the file between the stage and the rename: the edit refuses, the
    // file keeps the other program's bytes, and no temporary file stays. The backup has the
    // old bytes.
    @Test func aChangeBeforeTheRenameRefusesAndKeepsTheFile() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.seedOldInstall(#"{"statusLine":\#(original)}"#, saved: original)
        let old = try home.bytes(home.settings)
        let changed = #"{"model":"y"}"#
        let settings = home.settings
        await #expect(throws: IntegrationFailure.changed(file: home.settings)) {
            try await home.uninstall {
                try? Data(changed.utf8).write(to: URL(fileURLWithPath: settings))
            }
        }
        #expect(
            IntegrationFailure.changed(file: "/h/s.json").message
                == "The file /h/s.json changed while Bifrost worked. "
                + "Bifrost did not change it. Try again.")
        #expect(try home.bytes(home.settings) == Data(changed.utf8))
        #expect(try home.names(home.folder.appending(".claude")) == ["settings.json"])
        #expect(try home.bytes("\(home.backups)/settings-20261104T153000Z.json") == old)
        #expect(home.log.values.isEmpty)
    }

    // A change through a link: the link stays, and its target keeps the change and its mode.
    @Test func aChangeBeforeTheRenameKeepsTheLinkAndTheMode() async throws {
        let home = try Home()
        defer { home.remove() }
        let target = home.folder.appending("real-settings.json")
        try home.write(try oldInstalled().text, target)
        #expect(chmod(target, 0o604) == 0)
        try FileManager.default.createSymbolicLink(
            atPath: home.settings, withDestinationPath: target)
        try home.writeSaved("null")
        let settings = home.settings
        await #expect(throws: IntegrationFailure.changed(file: home.settings)) {
            try await home.uninstall {
                try? Data("{}".utf8).write(to: URL(fileURLWithPath: settings))
            }
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: home.settings) == target)
        #expect(try home.bytes(target) == Data("{}".utf8))
        #expect(try home.mode(target) == 0o604)
        #expect(try home.names(home.folder.path).filter { $0.hasSuffix(".tmp") }.isEmpty)
    }

    // A file that goes during the edit is a change too.
    @Test func aFileThatGoesBeforeTheRenameIsAChange() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.seedOldInstall(saved: "null")
        let settings = home.settings
        await #expect(throws: IntegrationFailure.changed(file: home.settings)) {
            try await home.uninstall { try? FileManager.default.removeItem(atPath: settings) }
        }
        #expect(!home.exists(home.settings))
        #expect(try home.names(home.folder.appending(".claude")).isEmpty)
    }

    // MARK: - Folders that refuse a write

    // The stage fails before any write: no backup, and the file stays.
    @Test func aReadOnlyFolderRefusesAndChangesNothing() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.seedOldInstall(saved: "null")
        let before = try home.bytes(home.settings)
        let claude = home.folder.appending(".claude")
        #expect(chmod(claude, 0o500) == 0)
        defer { chmod(claude, 0o700) }
        await #expect(
            throws: IntegrationFailure.system(.system(.save, path: home.settings, code: EACCES))
        ) {
            try await home.uninstall()
        }
        #expect(
            IntegrationFailure.system(.system(.save, path: "/h/s.json", code: EACCES)).message
                == "Cannot save /h/s.json: Permission denied.")
        #expect(try home.bytes(home.settings) == before)
        #expect(!home.exists(home.backups))
    }

    // The backup fails after the stage: the temporary file goes, and the file stays.
    @Test func aReadOnlyBackupsFolderRefusesAndLeavesNoTemporaryFile() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.seedOldInstall(saved: "null")
        let before = try home.bytes(home.settings)
        try FileManager.default.createDirectory(
            atPath: home.backups, withIntermediateDirectories: true)
        #expect(chmod(home.backups, 0o500) == 0)
        defer { chmod(home.backups, 0o700) }
        let backup = "\(home.backups)/settings-20261104T153000Z.json"
        let refusal = IntegrationFailure.system(.system(.save, path: backup, code: EACCES))
        await #expect(throws: refusal) {
            try await home.uninstall()
        }
        #expect(try home.bytes(home.settings) == before)
        #expect(try home.names(home.folder.appending(".claude")) == ["settings.json"])
        #expect(try home.names(home.backups).isEmpty)
    }

    // MARK: - The text

    // Each key keeps its place, each number keeps its text and each string keeps its escapes.
    // Only the Bifrost entries change, and the original statusLine takes the place of the wrapper.
    @Test func theKeyOrderAndTheNumberTextsStay() async throws {
        let home = try Home()
        defer { home.remove() }
        let hook = bifrostHookJSON
        try home.write(
            #"{"zeta":1.0,"statusLine":\#(wrapperJSON),"cleanupPeriodDays":3e1,"#
                + #""hooks":{"Stop":[{"hooks":[{"command":"say \u00e9","timeout":10.50},"#
                + #"\#(hook)]}],"#
                + #""PostToolUse":[{"matcher":"*","hooks":[\#(hook)]}]},"#
                + #""env":{"B":"2","A":"-0"},"big":12345678901234567890,"alpha":-0}"#,
            home.settings)
        try home.writeSaved(#"{"type":"command","command":"mine","padding":0.0}"#)
        try await home.uninstall()
        #expect(
            String(decoding: try home.bytes(home.settings), as: UTF8.self) == """
                {
                  "zeta": 1.0,
                  "statusLine": {
                    "type": "command",
                    "command": "mine",
                    "padding": 0.0
                  },
                  "cleanupPeriodDays": 3e1,
                  "hooks": {
                    "Stop": [
                      {
                        "hooks": [
                          {
                            "command": "say \\u00e9",
                            "timeout": 10.50
                          }
                        ]
                      }
                    ]
                  },
                  "env": {
                    "B": "2",
                    "A": "-0"
                  },
                  "big": 12345678901234567890,
                  "alpha": -0
                }

                """)
    }

    // A file in the form that Claude Code writes keeps that form: two spaces of indent, ": "
    // after a key and a newline at the end. Only the Bifrost entries go.
    @Test func aCommonFileKeepsItsFormAndLosesOnlyTheBifrostEntries() async throws {
        let home = try Home()
        defer { home.remove() }
        let base = try settings(
            #"{"permissions":{"allow":["Bash(git status)","Read(~/x/**)"],"deny":[]},"#
                + #""model":"opus","env":{"FOO":"1"},"statusLine":\#(original),"#
                + #""hooks":{"Stop":[{"hooks":[{"type":"command","command":"afplay x.aiff"}]}]},"#
                + #""alwaysThinkingEnabled":true,"includeCoAuthoredBy":false}"#)
        try home.write(try oldInstalled(base).text, home.settings)
        try home.writeSaved(original + "\n")
        try await home.uninstall()
        #expect(
            String(decoding: try home.bytes(home.settings), as: UTF8.self) == """
                {
                  "permissions": {
                    "allow": [
                      "Bash(git status)",
                      "Read(~/x/**)"
                    ],
                    "deny": []
                  },
                  "model": "opus",
                  "env": {
                    "FOO": "1"
                  },
                  "statusLine": {
                    "command": "printf 'ORIG'",
                    "padding": 0,
                    "refreshInterval": 1,
                    "type": "command"
                  },
                  "hooks": {
                    "Stop": [
                      {
                        "hooks": [
                          {
                            "type": "command",
                            "command": "afplay x.aiff"
                          }
                        ]
                      }
                    ]
                  },
                  "alwaysThinkingEnabled": true,
                  "includeCoAuthoredBy": false
                }

                """)
    }

    // A large file keeps each of its keys in its place.
    @Test func aLargeFileKeepsItsKeyOrder() async throws {
        let home = try Home()
        defer { home.remove() }
        let keys = (0..<20_000).reversed().map { "k\($0)" }
        let members = keys.map { #""\#($0)":[1.0,"x"]"# }.joined(separator: ",")
        try home.write(try oldInstalled(try settings("{\(members)}")).text, home.settings)
        try home.writeSaved("null")
        try await home.uninstall()
        let result = try ClaudeSettingsDocument.parse(home.bytes(home.settings))
        #expect(result.members.map(\.key.raw) == keys)
        #expect(result == (try settings("{\(members)}")))
    }

    // MARK: - The old install

    @Test func oldInstallFindsABifrostHookOrTheWrapper() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write(#"{"hooks":{"Stop":[{"hooks":[\#(bifrostHookJSON)]}]}}"#, home.settings)
        #expect(await ClaudeSettingsFile.oldInstall(home.paths) == .success(true))
        try home.write(#"{"statusLine":\#(wrapperJSON)}"#, home.settings)
        #expect(await ClaudeSettingsFile.oldInstall(home.paths) == .success(true))
        let entry = #"{"hooks":[\#(bifrostHookJSON)],"matcher":"Bash"}"#
        try home.write(#"{"hooks":{"PreToolUse":[\#(entry)]}}"#, home.settings)
        #expect(await ClaudeSettingsFile.oldInstall(home.paths) == .success(true))
    }

    @Test func oldInstallFindsNothingWithNoBifrostEntry() async throws {
        let home = try Home()
        defer { home.remove() }
        #expect(await ClaudeSettingsFile.oldInstall(home.paths) == .success(false))
        try home.write(
            #"{"hooks":{"Stop":[{"hooks":[{"command":"my-hook","type":"command"}]}]},"#
                + #""statusLine":{"command":"my-statusline","type":"command"}}"#,
            home.settings)
        #expect(await ClaudeSettingsFile.oldInstall(home.paths) == .success(false))
    }

    @Test func oldInstallGivesTheTextOfAFileThatIsNotJSON() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.write("{ not json", home.settings)
        #expect(
            await ClaudeSettingsFile.oldInstall(home.paths)
                == .failure(.notJSON(file: home.settings)))
    }

    // The look for an old install writes nothing.
    @Test func oldInstallOnlyReads() async throws {
        let home = try Home()
        defer { home.remove() }
        try home.seedOldInstall(saved: nil)
        let before = try home.bytes(home.settings)
        #expect(await ClaudeSettingsFile.oldInstall(home.paths) == .success(true))
        #expect(try home.bytes(home.settings) == before)
        #expect(try home.names(home.folder.path) == [".claude"])
        #expect(try home.names(home.folder.appending(".claude")) == ["settings.json"])
    }

    @Test func keepOldScriptsKeepsBinForAnOldInstallAndForSettingsThatBifrostCannotRead() {
        #expect(ClaudeSettingsFile.keepOldScripts(.success(true)))
        #expect(ClaudeSettingsFile.keepOldScripts(.failure(.notJSON(file: "/s.json"))))
        #expect(!ClaudeSettingsFile.keepOldScripts(.success(false)))
    }
}
