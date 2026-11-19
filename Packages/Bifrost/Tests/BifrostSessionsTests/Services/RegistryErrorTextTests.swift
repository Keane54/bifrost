import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostFoundation
@testable import BifrostSessions

// The texts of the errors in the log lines of the registry store and in the error line of the
// session list (final review, item 1). A system error gives the action of the call, the path and
// the text of the system. The text never has the debug text of an NSError.

// True when the text has a part of the debug text of an NSError.
private func hasDebugText(_ text: String) -> Bool {
    ["Error Domain", "0x", "UserInfo", "\u{201C}", "\u{201D}"].contains { text.contains($0) }
}

@MainActor
@Suite("the texts of the errors of the registry", .timeLimit(.minutes(1)))
struct RegistryErrorTextTests {
    @Test func aRegistryFileThatCannotBeReadLogsTheReason() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = path(dir.appending(path: "registry.json"))
        try FileManager.default.createDirectory(atPath: file, withIntermediateDirectories: false)
        let log = Recorder<StoreEvent>()
        _ = StoreFile.open(path: file, log: log)
        let text = FileError.system(.read, path: file, code: EISDIR)
        #expect(text.message == "Cannot read \(file): Is a directory.")
        #expect(
            log.values == [.readFailed(file: file, what: "the registry store", error: text)])
    }

    // A folder with the name of the copy makes the copy fail: the rename of the safe write gives
    // EISDIR, a POSIXError.
    @Test func aFailedRegistryCopyLogsTheReason() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = path(dir.appending(path: "registry.json"))
        try "not json".write(toFile: file, atomically: false, encoding: .utf8)
        let copy = "\(file).unreadable"
        try FileManager.default.createDirectory(atPath: copy, withIntermediateDirectories: false)
        let log = Recorder<StoreEvent>()
        let opened = StoreFile.open(path: file, log: log)
        try opened.saver.save(RegistryStore(names: ["s1": "alpha"]))
        let text = FileError.system(.copy(to: copy), path: file, code: EISDIR)
        #expect(text.message == "Cannot copy \(file) to \(copy): Is a directory.")
        #expect(
            log.values == [
                .copyFailed(file: file, copy: copy, what: "the registry store", error: text)
            ])
    }

    // The registry service logs the message of a failed save, so the saver gives the text.
    @Test func aFailedRegistrySaveGivesTheReason() throws {
        let folder = try TemporaryFolder()
        let dir = folder.url
        defer {
            chmod(folder.path, 0o700)
            folder.remove()
        }
        let file = path(dir.appending(path: "registry.json"))
        try "{}".write(toFile: file, atomically: false, encoding: .utf8)
        let opened = StoreFile.open(path: file, log: Recorder<StoreEvent>())
        #expect(chmod(path(dir), 0o500) == 0)
        let error = #expect(throws: RegistryFailure.self) {
            try opened.saver.save(RegistryStore(names: ["s1": "alpha"]))
        }
        #expect(error == RegistryFailure("Cannot save \(file): Permission denied."))
        #expect(error.map { hasDebugText($0.message) } == false)
    }

    @Test func aRegistryFailureGivesItsMessage() {
        let failure = RegistryFailure("claude not found")
        #expect(ErrorText.of(failure) == "claude not found")
        #expect(ErrorText.of(failure, call: .save, path: "/tmp/a") == "claude not found")
    }
}
