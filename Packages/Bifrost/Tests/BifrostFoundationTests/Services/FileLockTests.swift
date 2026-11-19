import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostFoundation

// The lock of a store folder. A second take of the lock file in this process is a second open
// file description, as a second copy of the app has, so flock refuses it too.

private func mode(_ path: String) -> mode_t {
    var info = stat()
    guard lstat(path, &info) == 0 else { return 0 }
    return info.st_mode & 0o777
}

@Suite("the lock of a store folder", .testTimeLimit)
struct FileLockTests {
    // The take makes the folder and the lock file with private modes. A second take is held,
    // and after the release a new take works. A second release does nothing.
    @Test func aSecondTakeIsHeldUntilTheRelease() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let lockFile = folder.url.appending(path: "store/.lock")
        let lock = try FileLock.take(lockFile)
        #expect(throws: FileLock.Failure.held) { try FileLock.take(lockFile) }
        #expect(mode(folder.path + "/store/.lock") == 0o600)
        #expect(mode(folder.path + "/store") == 0o700)
        lock.release()
        lock.release()
        try FileLock.take(lockFile).release()
    }

    // A folder and a lock file that are there get the private modes.
    @Test func theTakeSetsThePrivateModes() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let store = folder.path + "/store"
        try FileManager.default.createDirectory(
            atPath: store, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755])
        #expect(FileManager.default.createFile(atPath: store + "/.lock", contents: nil))
        #expect(chmod(store + "/.lock", 0o644) == 0)
        try FileLock.take(URL(filePath: store + "/.lock")).release()
        #expect(mode(store) == 0o700)
        #expect(mode(store + "/.lock") == 0o600)
    }

    // A link at the folder or at the lock file, and a lock file that is not a regular file, are
    // refused: the lock is never the lock of another item.
    @Test func aLinkOrAFolderIsRefused() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let real = folder.path + "/real"
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            atPath: folder.path + "/linked", withDestinationPath: real)
        #expect(throws: FileLock.Failure.self) {
            try FileLock.take(URL(filePath: folder.path + "/linked/.lock"))
        }
        let store = folder.path + "/store"
        try FileManager.default.createDirectory(atPath: store, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            atPath: store + "/.lock", withDestinationPath: real + "/other")
        #expect(throws: FileLock.Failure.self) {
            try FileLock.take(URL(filePath: store + "/.lock"))
        }
        #expect(!FileManager.default.fileExists(atPath: real + "/other"))
        let other = folder.path + "/other"
        try FileManager.default.createDirectory(
            atPath: other + "/.lock", withIntermediateDirectories: true)
        #expect(throws: FileLock.Failure.self) {
            try FileLock.take(URL(filePath: other + "/.lock"))
        }
    }
}
