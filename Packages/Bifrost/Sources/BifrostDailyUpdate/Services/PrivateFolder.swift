import BifrostFoundation
import Foundation

// A folder of the Daily update that only the user can read: mode 0700, also when it was there
// before with another mode. The run folders and the skill export use it.
enum PrivateFolder {
    static func make(_ folder: URL) throws(FileError) {
        let path = folder.path(percentEncoded: false)
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw FileError(error, call: .createFolder, path: path)
        }
        // The mask of the process can take bits away at the create, and a folder from before
        // can have another mode.
        if chmod(path, 0o700) != 0 {
            throw .system(.setPermissions, path: path, code: errno)
        }
    }
}
