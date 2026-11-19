import Foundation
import Synchronization

// The lock of a store folder, so only one copy of Bifrost works on the folder at a time (the
// Reviews state and the Daily update state). The lock is an exclusive flock on a lock file in the
// folder, with no wait. The lock file stays open until release, and the system frees the lock
// when the process ends, also after a crash. flock locks an open file description, so a second
// take of the lock file is refused also in the same process.
package final class FileLock: Sendable {
    package enum Failure: Error, Sendable, Equatable {
        // Another holder has the lock: another copy of Bifrost.
        case held
        // A file call of the take failed.
        case failed(FileError)
    }

    // The open lock file. -1 after the release.
    private let file: Mutex<Int32>

    private init(_ file: Int32) {
        self.file = Mutex(file)
    }

    deinit { release() }

    // Take the lock of the lock file. The call makes the folder of the file with the mode 0700
    // and the lock file with the mode 0600, and sets these modes on a folder and a file that are
    // there. It refuses a link at either path, and a lock file that is not a regular file. The
    // calls do not wait, but an async caller runs them off the main actor.
    package static func take(_ lockFile: URL) throws(Failure) -> FileLock {
        let lockPath = lockFile.path(percentEncoded: false)
        // The path of the folder has no "/" at its end, so O_NOFOLLOW refuses a link there.
        let folderPath = (lockPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: folderPath, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw .failed(FileError(error, call: .createFolder, path: folderPath))
        }
        let folder = open(folderPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw .failed(.system(.check, path: folderPath, code: errno)) }
        defer { close(folder) }
        guard fchmod(folder, 0o700) == 0 else {
            throw .failed(.system(.setPermissions, path: folderPath, code: errno))
        }
        let name = lockFile.lastPathComponent
        let file = openat(folder, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw .failed(.system(.lock, path: lockPath, code: errno)) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(file)
            throw .failed(.system(.lock, path: lockPath, code: EFTYPE))
        }
        guard fchmod(file, 0o600) == 0 else {
            let code = errno
            close(file)
            throw .failed(.system(.setPermissions, path: lockPath, code: code))
        }
        guard flock(file, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(file)
            if code == EWOULDBLOCK { throw .held }
            throw .failed(.system(.lock, path: lockPath, code: code))
        }
        return FileLock(file)
    }

    // Free the lock: close the lock file. A second call does nothing.
    package func release() {
        let open = file.withLock { file in
            defer { file = -1 }
            return file
        }
        if open >= 0 { close(open) }
    }
}
