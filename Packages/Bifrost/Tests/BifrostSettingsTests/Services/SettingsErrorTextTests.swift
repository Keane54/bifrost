import BifrostFoundation
import BifrostKeyboard
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostSettings

// The texts of the errors in the log events of the settings store (final review, item 1). A
// system error gives the action of the call, the path and the text of the system, for example
// "Cannot save /a: Permission denied.".

@MainActor
@Suite("the texts of the errors of the settings store", .testTimeLimit)
struct SettingsErrorTextTests {
    // A folder at the path makes the read fail with EISDIR, a Cocoa error with a POSIX error.
    @Test func aSettingsFileThatCannotBeReadLogsTheReason() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "settings.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let log = Recorder<StoreEvent>()
        _ = await SettingsStore.open(file: file, log: log)
        let text = FileError.system(.read, path: path(file), code: EISDIR)
        #expect(text.message == "Cannot read \(path(file)): Is a directory.")
        #expect(log.values == [.readFailed(file: path(file), what: "the settings", error: text)])
    }

    @Test func aFailedSettingsCopyLogsTheReason() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "settings.json")
        try Data(#"{"version":4}"#.utf8).write(to: file)
        let backup = dir.appending(path: "settings.v4.backup.json")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
        let log = Recorder<StoreEvent>()
        let store = await SettingsStore.open(file: file, log: log)
        _ = try await store.edit { $0.labels = .space }
        let text = FileError.system(.copy(to: path(backup)), path: path(file), code: EISDIR)
        #expect(text.message == "Cannot copy \(path(file)) to \(path(backup)): Is a directory.")
        #expect(
            log.values.last
                == .copyFailed(
                    file: path(file), copy: path(backup), what: "the settings", error: text))
    }

    // A folder that only the owner can read and open makes the open of the temporary file fail
    // with EACCES, a POSIXError. The test does not run as root, so the mode applies.
    @Test func aFailedSettingsWriteGivesTheReason() async throws {
        let folder = try TemporaryFolder()
        let dir = folder.url
        defer {
            chmod(folder.path, 0o700)
            folder.remove()
        }
        let file = dir.appending(path: "settings.json")
        try Data("{}".utf8).write(to: file)
        #expect(chmod(path(dir), 0o500) == 0)
        let store = await SettingsStore.open(file: file, log: Recorder<StoreEvent>())
        let error = await #expect(throws: SettingsError.self) {
            try await store.edit { $0.labels = .space }
        }
        #expect(error == .notSaved(.system(.save, path: path(file), code: EACCES)))
        #expect(error?.message == "Cannot save \(path(file)): Permission denied.")
    }
}
