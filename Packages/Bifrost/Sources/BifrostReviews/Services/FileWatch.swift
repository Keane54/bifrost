// The watch of one file of Reviews by its path (docs/behaviour/reviews.md, "Clones and trust" and
// "PR sessions"): ~/.claude.json for the trust read, and result.json of a review round. Each
// change of the file gives one call of changed, and so does the coming of a file that was
// missing. Nothing polls.
import Darwin
import Foundation
import Synchronization

// The watch of one file by its path, through file system object sources on one serial queue.
// Each start of a source and each event runs on that queue, so two starts never overlap. The
// state is also behind a lock, because the stop comes from the reader.
final class FileWatch: Sendable {
    private struct State {
        var source: (any DispatchSourceFileSystemObject)?
        // True while the source watches the file, false while it watches the folder.
        var onFile = false
        var stopped = false
    }

    // The most starts of a source in one arm. Each new start follows a real change of the path
    // and gives an element, so the limit only stops a path that changes with no end.
    private static let maxStarts = 8

    private let file: String
    private let folder: String
    private let changed: @Sendable () -> Void
    private let beforeStart: @Sendable () -> Void
    private let state = Mutex(State())
    private let queue: DispatchQueue

    // label names the queue of the watch.
    init(
        file: String, folder: String, label: String = "bifrost.trust-watch",
        changed: @escaping @Sendable () -> Void,
        beforeStart: @escaping @Sendable () -> Void = {}
    ) {
        queue = DispatchQueue(label: label)
        self.file = file
        self.folder = folder
        self.changed = changed
        self.beforeStart = beforeStart
    }

    // The first source, on the queue. The call returns after the start, so a change that comes
    // after the make of the stream is never missed. The start opens one item and makes one
    // source, so the wait is short.
    func start() {
        queue.sync { arm() }
    }

    // Watch the file, or the folder while the file is missing. A new source replaces the old
    // one. After the start of the source, the real path is checked once: a source on a file that
    // a rename replaced, or a source on the folder while the file is there now, starts again,
    // and the change gives an element. After the stop, no source starts. It runs on the queue.
    private func arm() {
        dispatchPrecondition(condition: .onQueue(queue))
        for _ in 0..<Self.maxStarts {
            let onFile: Bool
            let source: any DispatchSourceFileSystemObject
            if let made = Self.source(
                file, [.write, .extend, .attrib, .link, .rename, .delete, .revoke], queue)
            {
                (source, onFile) = (made, true)
            } else if let made = Self.source(folder, [.write], queue) {
                (source, onFile) = (made, false)
            } else {
                return
            }
            source.setEventHandler { [weak self] in self?.fired() }
            let started = state.withLock { s -> Bool in
                guard !s.stopped else { return false }
                s.source?.cancel()
                s.source = source
                s.onFile = onFile
                return true
            }
            guard started else {
                // libdispatch stops the process when a source that never became active is
                // released, so the cancelled source becomes active once. Its handler never
                // runs after the cancel.
                source.cancel()
                source.activate()
                return
            }
            beforeStart()
            source.activate()
            if watchesPath(source, onFile: onFile) { return }
            changed()
        }
    }

    func stop() {
        state.withLock { s in
            s.stopped = true
            s.source?.cancel()
            s.source = nil
        }
    }

    // A change of the file, or of the folder while the file was missing. After a rename or a
    // delete of the file, the watch opens the path again: the file at the path can be a new file
    // now. A change of the folder counts only when the file is there now.
    private func fired() {
        let (event, onFile) = state.withLock { s in (s.source?.data ?? [], s.onFile) }
        if onFile {
            changed()
            if !event.isDisjoint(with: [.link, .rename, .delete, .revoke]) { arm() }
        } else if Self.isFile(file) {
            changed()
            arm()
        }
    }

    // True when the source watches what the path names now: the file that is at the path (the
    // same device and inode), or the folder while no file is at the path.
    private func watchesPath(_ source: any DispatchSourceFileSystemObject, onFile: Bool) -> Bool {
        guard onFile else { return !Self.isFile(file) }
        var open = stat()
        var path = stat()
        return fstat(Int32(source.handle), &open) == 0 && stat(file, &path) == 0
            && open.st_dev == path.st_dev && open.st_ino == path.st_ino
    }

    private static func isFile(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    // A source on the item at the path, or nil when it cannot be opened. The source owns the
    // descriptor and closes it at its cancel. O_EVTONLY opens the item for events only.
    private static func source(
        _ path: String, _ events: DispatchSource.FileSystemEvent, _ queue: DispatchQueue
    ) -> (any DispatchSourceFileSystemObject)? {
        let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: events, queue: queue)
        source.setCancelHandler { close(descriptor) }
        return source
    }
}
