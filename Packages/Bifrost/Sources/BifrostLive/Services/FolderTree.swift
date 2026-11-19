import BifrostFoundation
import Darwin
import Foundation

// A folder of the folder sync and the skills list, opened with no link: the files below it,
// their bytes, the copy into a new folder and the removal of a folder.
//
// No call follows a link below the folder, and no call follows the folder itself when it is a
// link (docs/behaviour/skills.md, The folder sync):
// - The open of the folder refuses a link at its last part. The parents of the folder are as the
//   path gives them.
// - A list walks the folder with one descriptor for each sub-folder, so a sub-folder that
//   becomes a link during the walk does not take the walk out of the folder. A link is not a
//   regular file, and the walk does not go into a link. The list gives each item that is not a
//   regular file and not a folder (a link, a FIFO, a socket or a device) as an other item.
// - A read refuses a link at each part of its relative path, and a file that is not a regular
//   file.
// - A removal deletes a link, never the target of a link. It deletes the content of a folder
//   through the descriptor of that folder.
// Each call is synchronous. The callers run them off the main actor.
final class FolderTree {
    // The items below a folder, as relative paths with "/" between the parts, sorted by their
    // UTF-8 bytes.
    struct Listing {
        // The regular files, also the files of the dot folders.
        var files: [String] = []
        // The items that are not a regular file and not a folder.
        var others: [String] = []
    }

    let path: String
    private let descriptor: Int32

    private init(path: String, descriptor: Int32) {
        self.path = path
        self.descriptor = descriptor
    }

    deinit { close(descriptor) }

    // The folder at the path, or nil when no file is at the path. A link or a file at the path
    // throws.
    static func open(_ path: String) throws(FileError) -> FolderTree? {
        let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            let code = errno
            if code == ENOENT { return nil }
            throw .system(.read, path: path, code: code)
        }
        return FolderTree(path: path, descriptor: descriptor)
    }

    // The items below the folder.
    func list() throws(FileError) -> Listing {
        var listing = Listing()
        try Self.collect(descriptor, prefix: "", path: path, into: &listing)
        let byBytes: (String, String) -> Bool = { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        listing.files.sort(by: byBytes)
        listing.others.sort(by: byBytes)
        return listing
    }

    // The regular files below the folder (Listing.files).
    func regularFiles() throws(FileError) -> [String] { try list().files }

    // The names of the folders in the folder. A link to a folder is not a folder.
    func folders() throws(FileError) -> [String] {
        var folders: [String] = []
        for name in try Self.names(in: descriptor, path: path)
        where try Self.kind(of: name, in: descriptor, path: path) == S_IFDIR {
            folders.append(name)
        }
        return folders
    }

    // The bytes of a regular file below the folder.
    func read(_ relative: String) throws(FileError) -> Data {
        let full = "\(path)/\(relative)"
        let file = openat(descriptor, relative, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw .system(.read, path: full, code: errno) }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        var info = stat()
        guard fstat(file, &info) == 0 else { throw .system(.read, path: full, code: errno) }
        let kind = info.st_mode & S_IFMT
        guard kind == S_IFREG else {
            throw .system(.read, path: full, code: kind == S_IFDIR ? EISDIR : EFTYPE)
        }
        do {
            return try handle.readToEnd() ?? Data()
        } catch {
            throw FileError(error, call: .read, path: full)
        }
    }

    // Make a new folder at the path with the files: the folder and each folder of a file with
    // mode 0700, each file with mode 0600. Each file gets a full sync before the next file. No
    // file may be at the path. A relative path has no empty part, no "." and no "..".
    static func create(_ path: String, files: [(path: String, bytes: Data)]) throws(FileError) {
        guard mkdir(path, 0o700) == 0 else { throw .system(.createFolder, path: path, code: errno) }
        guard let folder = try open(path) else {
            throw .system(.createFolder, path: path, code: ENOENT)
        }
        for file in files { try folder.write(file.bytes, to: file.path) }
    }

    // Remove the file, the link or the folder with its content at the path. A missing path is
    // not an error.
    static func remove(_ path: String) throws(FileError) {
        var info = stat()
        if lstat(path, &info) != 0 {
            let code = errno
            if code == ENOENT { return }
            throw .system(.remove, path: path, code: code)
        }
        if info.st_mode & S_IFMT == S_IFDIR {
            // A folder that becomes a link after the lstat fails the open, so the removal never
            // goes through a link.
            guard let folder = try open(path) else { return }
            try folder.removeContent()
            if rmdir(path) != 0 {
                let code = errno
                if code != ENOENT { throw .system(.remove, path: path, code: code) }
            }
        } else if unlink(path) != 0 {
            let code = errno
            if code != ENOENT { throw .system(.remove, path: path, code: code) }
        }
    }

    // MARK: - The steps

    // Write one new file below the folder, and make each missing folder of its path.
    private func write(_ bytes: Data, to relative: String) throws(FileError) {
        let full = "\(path)/\(relative)"
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard let name = parts.last, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw .system(.save, path: full, code: EINVAL) }
        var parent = dup(descriptor)
        guard parent >= 0 else { throw .system(.save, path: full, code: errno) }
        defer { close(parent) }
        for part in parts.dropLast() {
            if mkdirat(parent, part, 0o700) != 0, errno != EEXIST {
                throw .system(.createFolder, path: full, code: errno)
            }
            let child = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw .system(.createFolder, path: full, code: errno) }
            close(parent)
            parent = child
        }
        let file = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw .system(.save, path: full, code: errno) }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: bytes)
            try WriteSteps.system.sync(handle)
        } catch {
            throw FileError(error, call: .save, path: full)
        }
    }

    // Remove each item in the folder. A sub-folder goes through its own descriptor.
    private func removeContent() throws(FileError) {
        try Self.removeContent(of: descriptor, path: path)
    }

    private static func removeContent(of folder: Int32, path: String) throws(FileError) {
        for name in try names(in: folder, path: path) {
            let full = "\(path)/\(name)"
            guard let kind = try kind(of: name, in: folder, path: path) else { continue }
            if kind == S_IFDIR {
                let child = openat(folder, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw .system(.remove, path: full, code: errno) }
                defer { close(child) }
                try removeContent(of: child, path: full)
                if unlinkat(folder, name, AT_REMOVEDIR) != 0, errno != ENOENT {
                    throw .system(.remove, path: full, code: errno)
                }
            } else if unlinkat(folder, name, 0) != 0, errno != ENOENT {
                throw .system(.remove, path: full, code: errno)
            }
        }
    }

    // Add the items below one folder to the listing.
    private static func collect(
        _ folder: Int32, prefix: String, path: String, into listing: inout Listing
    ) throws(FileError) {
        for name in try names(in: folder, path: path) {
            let full = "\(path)/\(name)"
            switch try kind(of: name, in: folder, path: path) {
            case S_IFREG?:
                listing.files.append(prefix + name)
            case S_IFDIR?:
                let child = openat(folder, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw .system(.read, path: full, code: errno) }
                defer { close(child) }
                try collect(child, prefix: "\(prefix)\(name)/", path: full, into: &listing)
            case nil:
                // The item went away during the walk.
                continue
            default:
                listing.others.append(prefix + name)
            }
        }
    }

    // The type bits of an item in a folder (S_IFREG, S_IFDIR, S_IFLNK and so on), with no
    // link followed. nil when the item went away.
    private static func kind(
        of name: String, in folder: Int32, path: String
    ) throws(FileError) -> mode_t? {
        var info = stat()
        guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            if code == ENOENT { return nil }
            throw .system(.check, path: "\(path)/\(name)", code: code)
        }
        return info.st_mode & S_IFMT
    }

    // The names of the items in a folder, with no "." and no "..".
    private static func names(in folder: Int32, path: String) throws(FileError) -> [String] {
        let copy = dup(folder)
        guard copy >= 0, let stream = fdopendir(copy) else {
            let code = errno
            if copy >= 0 { close(copy) }
            throw .system(.read, path: path, code: code)
        }
        defer { closedir(stream) }
        // The copy shares the read position of the descriptor, so the list starts at the start.
        rewinddir(stream)
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw .system(.read, path: path, code: errno) }
                return names
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { buffer in
                String(decoding: buffer.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != ".", name != ".." { names.append(name) }
        }
    }
}
