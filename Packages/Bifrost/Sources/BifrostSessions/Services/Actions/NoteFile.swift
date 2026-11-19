// The note file of Hand over (docs/behaviour/actions.md, "Hand over"). Bifrost writes each note
// to a new file in the handovers folder and never writes over a file. Only the user can read the
// folder and the file.
import BifrostFoundation
import Darwin
import Foundation

// Why a note file could not be written.
package enum NoteFileError: Error, Sendable, Equatable {
    // The name is not a plain file name.
    case badName
    // Each name of the tries is used.
    case tooMany
    // A call of the system failed.
    case file(FileError)

    package var message: String {
        switch self {
        case .badName: "The note file name isn't valid."
        case .tooMany: "Too many hand-over notes have this name."
        case .file(let error): error.message
        }
    }
}

package enum NoteFile {
    // The number of names that a write tries: the name, then -2 to -100 before the extension.
    package static let tries = 100

    // Write the text to a new file in the folder, and give the URL of the file. The folder and
    // each missing parent are made with mode 0700. A folder that exists keeps its mode. The file
    // is made with mode 0600, and the open fails when something is at the path, also a link, so
    // no write goes over a file or through a link. Then the next name counts. The name must be a
    // plain file name, so the file is always in the folder. The write runs off the actor of the
    // caller.
    @concurrent package static func write(_ text: String, named name: String, in folder: URL)
        async throws(NoteFileError) -> URL
    {
        guard isPlainName(name) else { throw .badName }
        var path = folder.path(percentEncoded: false)
        if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if let code = makeFolder(path) {
            throw .file(.system(.createFolder, path: path, code: code))
        }
        let (stem, ext) = split(name)
        for number in 1...tries {
            let file = folder.appending(
                path: number == 1 ? name : "\(stem)-\(number)\(ext)", directoryHint: .notDirectory)
            let filePath = file.path(percentEncoded: false)
            let fd = open(filePath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd < 0 {
                let code = errno
                if code == EEXIST { continue }
                throw .file(.system(.save, path: filePath, code: code))
            }
            if let code = writeAll(Array(text.utf8), to: fd) {
                close(fd)
                // The file is new and holds part of the note, so it goes.
                unlink(filePath)
                throw .file(.system(.save, path: filePath, code: code))
            }
            guard close(fd) == 0 else {
                let code = errno
                unlink(filePath)
                throw .file(.system(.save, path: filePath, code: code))
            }
            return file
        }
        throw .tooMany
    }

    // A name with no "/" and no NUL that is not empty, "." or "..".
    private static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.unicodeScalars.contains { $0 == "/" || $0 == "\0" }
    }

    // The stem and the extension of the name: the extension starts at the last "." that is not
    // the first character.
    private static func split(_ name: String) -> (stem: String, ext: String) {
        let scalars = name.unicodeScalars
        guard let dot = scalars.lastIndex(of: "."), dot != scalars.startIndex else {
            return (name, "")
        }
        return (String(scalars[..<dot]), String(scalars[dot...]))
    }

    // Make the folder and each missing parent with mode 0700. nil when the folder is there, else
    // the error number. A path that is there and is not a folder gives ENOTDIR.
    private static func makeFolder(_ path: String) -> Int32? {
        if mkdir(path, 0o700) == 0 { return nil }
        let code = errno
        switch code {
        case EEXIST:
            var info = stat()
            guard stat(path, &info) == 0 else { return errno }
            return info.st_mode & S_IFMT == S_IFDIR ? nil : ENOTDIR
        case ENOENT:
            let parent = (path as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != path, makeFolder(parent) == nil else { return code }
            if mkdir(path, 0o700) == 0 { return nil }
            return errno == EEXIST ? makeFolder(path) : errno
        default:
            return code
        }
    }

    // Write each byte to the file. nil when each byte is written, else the error number.
    private static func writeAll(_ bytes: [UInt8], to fd: Int32) -> Int32? {
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(fd, base + written, bytes.count - written)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return errno
            }
            written += count
        }
        return nil
    }
}
