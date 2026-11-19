import Foundation

// The vim mode check that a hold runs (docs/behaviour/dictation.md, Vim mode). It reads
// <home>/.claude.json and <home>/.claude/settings.json of the home that the launch code gives, so
// a test home uses its own files. It only reads: it never writes a file and never logs the
// content of a file.
//
// ~/.claude.json can be many MB, so the check parses a file only when its stamp (the size and the
// modification time) changes. Claude writes the file often, so a read can see a part of it. A parse
// error then keeps the last good value of the file. With no good value, the file gives false. The
// stat, the read and the decode run off the main actor. The main actor keeps only the stamp cache.

// The time and the size of a regular file. A change of either one means a new content.
package struct FileStamp: Sendable, Equatable {
    package var seconds: Int
    package var nanoseconds: Int
    package var size: Int64
}

// The file work of the check.
package enum VimModeFile {
    // Bifrost skips a file above this size.
    package static let maxBytes = 20 * 1024 * 1024

    // The stamp and the vim mode of a file, after its last read.
    package struct Known: Sendable, Equatable {
        var stamp: FileStamp
        var vim: Bool
    }

    // The stamp of a regular file, or nil when no regular file is there. The stat follows a
    // symbolic link.
    package static func stamp(_ path: String) -> FileStamp? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return FileStamp(
            seconds: Int(info.st_mtimespec.tv_sec), nanoseconds: Int(info.st_mtimespec.tv_nsec),
            size: Int64(info.st_size))
    }

    // The vim mode of the content of a file, or nil when the read fails or the content is no
    // good value (VimMode.of). A file over maxBytes is not read: the stat gives its size first,
    // and the file can get larger after the stat.
    static func read(_ path: String, size: Int64) -> Bool? {
        guard size <= maxBytes, let data = FileManager.default.contents(atPath: path),
            data.count <= maxBytes
        else { return nil }
        return VimMode.of(data)
    }

    // The new cache entry of a file: nil when no regular file is there. The file is read only
    // when its stamp is not the stamp of the last read.
    @concurrent package static func check(_ path: String, last: Known?) async -> Known? {
        guard let stamp = stamp(path) else { return nil }
        if let last, last.stamp == stamp { return last }
        let vim = read(path, size: stamp.size) ?? last?.vim ?? false
        return Known(stamp: stamp, vim: vim)
    }
}

@MainActor public final class VimModeReader {
    private let json: String
    private let settings: String
    // The stamp and the vim mode of each file after its last read.
    private var known: [String: VimModeFile.Known] = [:]

    // home: the home folder that the launch code gives.
    package init(home: URL) {
        json = home.appending(path: ".claude.json").path(percentEncoded: false)
        settings = home.appending(path: ".claude/settings.json").path(percentEncoded: false)
    }

    // True when the settings of Claude turn vim mode on. A file that is not there, or that
    // cannot be read with no good value, gives false.
    public func vimMode() async -> Bool {
        let (json, settings) = (json, settings)
        let (lastJSON, lastSettings) = (known[json], known[settings])
        async let first = VimModeFile.check(json, last: lastJSON)
        async let second = VimModeFile.check(settings, last: lastSettings)
        let (a, b) = await (first, second)
        known[json] = a
        known[settings] = b
        return a?.vim == true || b?.vim == true
    }
}
