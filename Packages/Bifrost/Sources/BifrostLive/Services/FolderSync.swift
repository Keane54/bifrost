import BifrostFoundation
import Darwin
import Foundation

// The failure of a folder sync, a removal or a list, with its text for the user.
package struct SyncFailure: MessageError, Sendable, Equatable {
    package let message: String

    package init(message: String) {
        self.message = message
    }

    init(_ error: FileError) {
        message = error.message
    }
}

// The steps of a sync that a test can replace: the swap of two folders, the rename of a folder
// and the removal of a folder. The system swap calls renamex_np(2) with RENAME_SWAP: it changes
// the two names in one step, and it gives ENOENT when a path is missing and ENOTSUP on a file
// system that cannot swap. The system rename calls rename(2). No system step follows a link.
// The system removal is FolderTree.remove.
package struct SwapSteps: Sendable {
    package var exchange: @Sendable (_ from: String, _ to: String) throws(FileError) -> Void
    package var rename: @Sendable (_ from: String, _ to: String) throws(FileError) -> Void
    package var remove: @Sendable (_ path: String) throws(FileError) -> Void

    package init(
        exchange: @escaping @Sendable (_ from: String, _ to: String) throws(FileError) -> Void,
        rename: @escaping @Sendable (_ from: String, _ to: String) throws(FileError) -> Void,
        remove: @escaping @Sendable (_ path: String) throws(FileError) -> Void
    ) {
        self.exchange = exchange
        self.rename = rename
        self.remove = remove
    }

    package static let system = SwapSteps(
        exchange: { from, to throws(FileError) in
            if renamex_np(from, to, UInt32(RENAME_SWAP)) != 0 {
                throw .system(.rename(to: to), path: from, code: errno)
            }
        },
        rename: { from, to throws(FileError) in
            if Darwin.rename(from, to) != 0 {
                throw .system(.rename(to: to), path: from, code: errno)
            }
        },
        remove: { path throws(FileError) in try FolderTree.remove(path) })
}

// The installed copies of the mod folder and the skills folder of the app
// (docs/behaviour/skills.md, The folder sync).
// - The mod folder holds exactly the four modFiles. The skills folder holds each regular file of
//   the skills folder of the app.
// - A copy is current when it has the bytes of the app for each file and holds no item that is
//   not a regular file or a folder (a link, a FIFO). The copy of the skills folder must also have
//   no other file. A missing folder and a failed read give "not current".
// - A sync of a current copy changes nothing. Else it reads each file of the app first, so a
//   missing file throws before any change. Then it writes the files to <dest>.<uuid>.tmp
//   (folders 0700, files 0600) and swaps that folder with dest in one step, so dest is never
//   missing. Then it removes the old folder from the temporary path. A failed removal of the
//   old folder is not an error.
// - With no folder at dest, or on a file system that cannot swap, the sync renames the old
//   folder to <dest>.<uuid>.old, renames the new folder to dest and removes the old folder. If
//   the second rename fails, the sync puts the old folder back. If the old folder cannot go
//   back, the error names it.
// - If a step fails, the sync removes the temporary folder and throws the first error.
// - No step follows a link below the folders, or a link at dest (FolderTree). So a link in a
//   copy or at dest makes the copy "not current", and the sync replaces it.
// A caller runs one sync or removal of a folder at a time.
// Each function runs off the main actor. A sync and a removal run on the blocking executor,
// because each file write waits for a full sync of the file.
package enum FolderSync {
    // The files of the mod folder. The sync copies no other file of the mod folder of the app.
    package static let modFiles = [
        ".claude-plugin/plugin.json", ".claude-plugin/marketplace.json", "hooks/hooks.json",
        "hooks/register.ts",
    ]

    // True only when each of the four mod files of dest has the bytes of the file in source.
    @concurrent package static func modCurrent(source: URL, dest: URL) async -> Bool {
        modIsCurrent(path(source), path(dest))
    }

    // Make dest a copy of the four mod files of source.
    @concurrent package static func syncMod(
        source: URL, dest: URL, steps: SwapSteps = .system
    ) async throws(SyncFailure) {
        let source = path(source)
        let dest = path(dest)
        try await BlockingExecutor.run { () throws(SyncFailure) in
            if modIsCurrent(source, dest) { return }
            do throws(FileError) {
                guard let folder = try FolderTree.open(source) else {
                    throw .system(.read, path: source, code: ENOENT)
                }
                let files = try modFiles.map { file throws(FileError) in
                    (path: file, bytes: try folder.read(file))
                }
                try swap(dest, files: files, steps: steps)
            } catch {
                throw SyncFailure(error)
            }
        }
    }

    // True only when dest has the same regular files as source, with the same bytes, and source
    // has at least one file.
    @concurrent package static func skillsCurrent(source: URL, dest: URL) async -> Bool {
        skillsAreCurrent(path(source), path(dest))
    }

    // Make dest a copy of the regular files of source. An extra file in dest goes.
    @concurrent package static func syncSkills(
        source: URL, dest: URL, steps: SwapSteps = .system
    ) async throws(SyncFailure) {
        let source = path(source)
        let dest = path(dest)
        try await BlockingExecutor.run { () throws(SyncFailure) in
            if skillsAreCurrent(source, dest) { return }
            let files: [(path: String, bytes: Data)]
            do throws(FileError) {
                if let folder = try FolderTree.open(source) {
                    files = try folder.regularFiles().map { file throws(FileError) in
                        (path: file, bytes: try folder.read(file))
                    }
                } else {
                    files = []
                }
            } catch {
                throw SyncFailure(error)
            }
            if files.isEmpty {
                throw SyncFailure(message: "The skills folder in the app has no files.")
            }
            do throws(FileError) {
                try swap(dest, files: files, steps: steps)
            } catch {
                throw SyncFailure(error)
            }
        }
    }

    // Remove a folder of the sync with its content. A missing folder is not an error. A link at
    // the path goes, and its target stays.
    @concurrent package static func remove(_ folder: URL) async throws(SyncFailure) {
        let folder = path(folder)
        try await BlockingExecutor.run { () throws(SyncFailure) in
            do throws(FileError) {
                try FolderTree.remove(folder)
            } catch {
                throw SyncFailure(error)
            }
        }
    }

    // The regular files below a folder, as relative paths sorted by their bytes. A missing
    // folder gives an empty list. A link is not a regular file, and the list does not go into a
    // link.
    @concurrent package static func listFiles(_ folder: URL) async throws(SyncFailure)
        -> [String]
    {
        do throws(FileError) {
            return try FolderTree.open(path(folder))?.regularFiles() ?? []
        } catch {
            throw SyncFailure(error)
        }
    }

    // MARK: - The steps

    private static func modIsCurrent(_ source: String, _ dest: String) -> Bool {
        do {
            guard let from = try FolderTree.open(source), let to = try FolderTree.open(dest) else {
                return false
            }
            guard try to.list().others.isEmpty else { return false }
            for file in modFiles where try from.read(file) != to.read(file) {
                return false
            }
            return true
        } catch {
            return false
        }
    }

    private static func skillsAreCurrent(_ source: String, _ dest: String) -> Bool {
        do {
            guard let from = try FolderTree.open(source), let to = try FolderTree.open(dest) else {
                return false
            }
            let files = try from.regularFiles()
            let copies = try to.list()
            let sameNames = files.elementsEqual(copies.files) { $0.utf8.elementsEqual($1.utf8) }
            guard !files.isEmpty, sameNames, copies.others.isEmpty else { return false }
            for file in files where try from.read(file) != to.read(file) {
                return false
            }
            return true
        } catch {
            return false
        }
    }

    // Write the files to a new temporary folder, then swap it with dest. A failure removes the
    // temporary folder and keeps the old folder at dest.
    private static func swap(
        _ dest: String, files: [(path: String, bytes: Data)], steps: SwapSteps
    ) throws(FileError) {
        let id = UUID().uuidString.lowercased()
        let temporary = "\(dest).\(id).tmp"
        do throws(FileError) {
            try makeParent(of: dest)
            try FolderTree.create(temporary, files: files)
        } catch {
            try? steps.remove(temporary)
            throw error
        }
        do throws(FileError) {
            try steps.exchange(temporary, dest)
        } catch .system(_, path: _, code: ENOENT) {
            // No folder is at dest yet. The renames put the new folder there.
            return try renameInTwoSteps(temporary, to: dest, old: "\(dest).\(id).old", steps)
        } catch .system(_, path: _, code: ENOTSUP) {
            // The file system cannot swap two folders in one step.
            return try renameInTwoSteps(temporary, to: dest, old: "\(dest).\(id).old", steps)
        } catch {
            try? steps.remove(temporary)
            throw error
        }
        // The old folder is at the temporary path now. dest is current, so a failed removal of
        // the old folder is not an error.
        try? steps.remove(temporary)
    }

    // Rename the old folder at dest to old, then the new folder to dest, then remove the old
    // folder. A missing dest is not an error. A failure puts the old folder back and removes the
    // new folder. When the old folder cannot go back, it stays at old (<dest>.<uuid>.old), and
    // the error names that path.
    private static func renameInTwoSteps(
        _ temporary: String, to dest: String, old: String, _ steps: SwapSteps
    ) throws(FileError) {
        var moved = false
        do throws(FileError) {
            do throws(FileError) {
                try steps.rename(dest, old)
                moved = true
            } catch .system(_, path: _, code: ENOENT) {
                // No folder is at dest yet.
            }
            try steps.rename(temporary, dest)
        } catch let first {
            var failure = first
            if moved {
                do throws(FileError) {
                    try steps.rename(old, dest)
                } catch {
                    failure = .other(
                        "\(first.message) The old folder is at \(old). Move it back to \(dest).")
                }
            }
            try? steps.remove(temporary)
            throw failure
        }
        // dest is current now, so a failed removal of the old folder is not an error.
        if moved { try? steps.remove(old) }
    }

    // Make the parent folder of dest and each missing parent of it with mode 0700.
    private static func makeParent(of dest: String) throws(FileError) {
        let parent = (dest as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: parent, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw FileError(error, call: .createFolder, path: parent)
        }
    }

    // The path of a file URL with no "/" at its end, so "<dest>.<uuid>.tmp" is a sibling of dest
    // also for a folder URL. The strip also keeps the swap from following a link at dest: for
    // the path "link/", RENAME_SWAP swaps the target of the link, not the link.
    private static func path(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
