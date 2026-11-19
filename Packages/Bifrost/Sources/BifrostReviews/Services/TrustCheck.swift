// The trust check of a review clone (docs/behaviour/reviews.md, "Clones and trust"). Claude Code
// keeps the workspace trust of each folder in ~/.claude.json, at
// projects["<folder>"].hasTrustDialogAccepted, and a trust of a folder covers each folder below
// it. Bifrost only reads that file, with the 20 MB cap of ClaudeJSON: it never writes it, never
// logs it, and never accepts a trust prompt. Every running claude writes the file, so a write
// from Bifrost could break it. The home is the resolved home of the app, so a test home uses its
// own file.
//
// The check follows the real state: it reads the file when something can have changed it (the
// output of the trust terminal settled, its claude ended, or the file changed) and again before
// a round, never on a timer.
import BifrostFoundation
import BifrostSessions
import Darwin
import Foundation
import Synchronization

package enum TrustCheck {
    // True when Claude Code trusts the folder: the entry of the folder, or of a folder above it,
    // has the value true at hasTrustDialogAccepted. Claude Code can write the key as the path
    // that it got or as the real path, so both count. A missing file, a file over the cap and a
    // file that is not JSON give false. The read runs on the blocking executor.
    @concurrent package static func isTrusted(_ folder: URL, home: URL) async -> Bool {
        await trusted([folder], home: home).first ?? false
    }

    // The trust of each folder, in the order of the folders, from one read and one decode of the
    // file (the rules of isTrusted).
    @concurrent package static func trusted(_ folders: [URL], home: URL) async -> [Bool] {
        await BlockingExecutor.run {
            guard let data = ClaudeJSON.cappedRead(ClaudeJSON.file(home: home)),
                let file = try? JSONDecoder().decode(TrustFile.self, from: data)
            else { return folders.map { _ in false } }
            return folders.map { folder in
                let given = folder.path(percentEncoded: false)
                let paths = [given, RealPath.of(given)].compactMap { $0 }
                return paths.contains { file.trusts($0) }
            }
        }
    }

    // The change events of ~/.claude.json: one element for each batch of changes of the file
    // (a write, a rename over it, a delete). A file system object source watches the open file.
    // Claude Code writes the file with a rename of a new file over it, so after a rename or a
    // delete the source opens the path again and watches the new file. While no file is at the
    // path, a source watches the home folder, and only the coming of the file gives an element:
    // a change of another item of the home gives none. After each start of a source, the watch
    // checks the real file once, so a rename or a new file between the open and the start of the
    // source is never lost. The end of the reader (a cancel, or the end of its loop) ends the
    // sources.
    package static func changes(home: URL) -> AsyncStream<Void> {
        changes(home: home, beforeStart: {})
    }

    // beforeStart runs between the open of the item and the start of its source. A test changes
    // the file there.
    static func changes(home: URL, beforeStart: @escaping @Sendable () -> Void)
        -> AsyncStream<Void>
    {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let watch = FileWatch(
            file: ClaudeJSON.file(home: home).path(percentEncoded: false),
            folder: home.path(percentEncoded: false), changed: { continuation.yield() },
            beforeStart: beforeStart)
        continuation.onTermination = { _ in watch.stop() }
        watch.start()
        return stream
    }
}

// The part of ~/.claude.json that the check reads: the trust flag of each project. The decode
// reads no other value, and a project entry that is not an object counts as not trusted, so a
// strange entry elsewhere does not stop the read.
private struct TrustFile: Decodable {
    struct Entry: Decodable {
        let trusted: Bool

        private enum Key: String, CodingKey {
            case hasTrustDialogAccepted
        }

        init(from decoder: any Decoder) throws {
            let container = try? decoder.container(keyedBy: Key.self)
            let flag = try? container?.decodeIfPresent(Bool.self, forKey: .hasTrustDialogAccepted)
            trusted = flag == true
        }
    }

    let projects: [String: Entry]?

    // True when the path or a folder above it is trusted.
    func trusts(_ path: String) -> Bool {
        guard let projects else { return false }
        var at = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        while true {
            if projects[at]?.trusted == true { return true }
            let up = (at as NSString).deletingLastPathComponent
            if up == at || up.isEmpty { return false }
            at = up
        }
    }
}
