import BifrostFoundation
import Foundation
import Synchronization

// The failure of the open of the Reviews store. message is its text for the panel.
package enum ReviewsStoreError: Error, Sendable, Equatable {
    // Another process holds the lock of the Reviews folder: another copy of Bifrost runs Reviews.
    case otherCopy
    // A file call of the open failed: the folder, the lock file, the read of state.json or the
    // safety copy. Reviews then does not start, so it never writes over a file that it did not
    // read or copy.
    case unreadable(FileError)
    // state.json has the version of a newer app. Reviews does not start, and nothing writes the
    // file, so the newer app loses nothing.
    case laterVersion
    // state.json has no version or a version that this app does not know. Reviews does not
    // start, and nothing writes the file.
    case unknownVersion

    package var message: String {
        switch self {
        case .otherCopy:
            "Reviews is running in another copy of Bifrost."
        case .unreadable(let failure):
            "Reviews can't start because Bifrost can't open its files. \(failure.message)"
        case .laterVersion:
            """
            Reviews is off because a newer version of Bifrost saved its data. Update this copy \
            of Bifrost to use Reviews here.
            """
        case .unknownVersion:
            """
            Reviews is off because Bifrost doesn't recognise its saved data, so it leaves that \
            data as it is.
            """
        }
    }
}

// The log of the Reviews store for one run of the app. Each name of a field that a read dropped
// goes to the log one time in the run, so a damaged record that each open reads again before a
// save gives one line. The other events pass each time.
package final class ReviewsStoreLog: StoreLog {
    private let base: any StoreLog
    private let logged = Mutex<Set<String>>([])

    package init(base: any StoreLog) {
        self.base = base
    }

    package func record(_ event: StoreEvent) {
        guard case .defaulted(let file, let keys) = event else {
            base.record(event)
            return
        }
        let new = logged.withLock { logged in keys.filter { logged.insert($0).inserted } }
        if !new.isEmpty { base.record(.defaulted(file: file, keys: new)) }
    }
}

// The store of ~/.bifrost/reviews/state.json (docs/behaviour/reviews.md, "The state").
// - The store holds the lock of the Reviews folder from the open to the close (FileLock).
// - The open takes the state over from the Electron app at the first open: it keeps a copy of
//   state.json first, then changes the state (ReviewsState.takeOver) and saves at once.
// - The decode is lenient per field: a bad field gets its empty value, and the log names it. An
//   unknown top-level field survives a save. A file that does not parse gives the empty state,
//   and the first save copies it to state.json.unreadable first (FileSaver).
// - A change changes the state at once, on the main actor, and the one save task of the file
//   (SaveQueue) writes the newest state off the main actor. The ticket of the change gives
//   whether the write that carried the change saved it, so a caller can save a plan before it
//   acts on GitHub (update). A failed write logs one line, and the next change tries again.
@MainActor
package final class ReviewsStore {
    // The change of a state that waits for its write: saved(_:) gives the result of that write.
    package struct SaveTicket: Sendable, Equatable {
        // The generation of the save (SaveQueue). nil: the store was closed, so nothing changed.
        fileprivate let generation: Int?
    }

    // The name of the data in the log.
    nonisolated private static let what = "the Reviews state"

    package private(set) var state: ReviewsState
    // True when this open took the state over from the Electron app.
    package let tookOver: Bool
    private let queue: SaveQueue<ReviewsState>
    // nil after the close.
    private var lock: FileLock?

    private init(_ files: OpenedFiles) {
        state = files.state
        tookOver = files.takeOver
        queue = SaveQueue(files.saver)
        lock = files.lock
    }

    // Take the lock, read state.json and take it over when this is the first open. The file work
    // runs off the main actor. now is the start of the new work after a take-over. A test gives
    // the steps of the safe write to hold, count or fail a save.
    package static func open(
        layout: ReviewsLayout, log: any StoreLog, now: Date = .now, steps: WriteSteps = .system
    ) async throws(ReviewsStoreError) -> ReviewsStore {
        let store = ReviewsStore(try await openFiles(layout, log: log, steps: steps))
        if store.tookOver {
            // The save runs at once, so a quit before the next change cannot leave an outbox of
            // the Electron app in the file. If it fails, the next open takes over again.
            await store.update { $0.takeOver(now: now) }
        }
        return store
    }

    // Take the lock of the Reviews folder, so no other copy of Bifrost runs Reviews. Another
    // holder of the lock gives otherCopy, and each other failure gives unreadable. The calls do
    // not wait, but an async caller runs them off the main actor.
    nonisolated package static func takeLock(
        _ layout: ReviewsLayout
    ) throws(ReviewsStoreError) -> FileLock {
        do throws(FileLock.Failure) {
            return try FileLock.take(layout.lockFile)
        } catch {
            switch error {
            case .held: throw .otherCopy
            case .failed(let failure): throw .unreadable(failure)
            }
        }
    }

    // Change the state at once, and save it. The ticket gives the result of the write. A change
    // that changes nothing writes again only when the last write failed, else its ticket gives
    // the result of the write of the current state. A change after the close changes nothing,
    // and its ticket gives false.
    @discardableResult
    package func change(_ change: (inout ReviewsState) -> Void) -> SaveTicket {
        guard lock != nil else { return SaveTicket(generation: nil) }
        var next = state
        change(&next)
        if next != state || queue.lastWriteFailed {
            state = next
            queue.save(next)
        }
        return SaveTicket(generation: queue.generation)
    }

    // True when the file holds the change of the ticket: the first write whose generation is at
    // least the generation of the change saved. A failed write, a write that the saver skipped
    // (the save is off) and a change after the close give false.
    package func saved(_ ticket: SaveTicket) async -> Bool {
        guard let generation = ticket.generation else { return false }
        return await queue.saved(generation)
    }

    // Change the state, then wait for its write (change, then saved). The result is true when the
    // file holds the change.
    @discardableResult
    package func update(_ change: (inout ReviewsState) -> Void) async -> Bool {
        await saved(self.change(change))
    }

    // True from the open to the close: the store holds the lock, so this copy of Bifrost runs
    // Reviews. A write of a panel to GitHub goes only while the store is open.
    package var isOpen: Bool { lock != nil }

    // Close the store: the saves that run or wait end, then the lock goes, so another open can
    // take it. The task ends when the lock is free.
    @discardableResult
    package func close() -> Task<Void, Never> {
        guard let lock else { return Task {} }
        self.lock = nil
        let saving = queue.task
        return Task {
            await saving?.value
            lock.release()
        }
    }

    // MARK: - The files

    private struct OpenedFiles: Sendable {
        let lock: FileLock
        let state: ReviewsState
        let saver: FileSaver
        let takeOver: Bool
    }

    // The lock first, so no other copy reads or writes the files during the open. Then the read,
    // and the check of the version before any write: a file of another version stops the open,
    // and nothing writes a file.
    @concurrent nonisolated private static func openFiles(
        _ layout: ReviewsLayout, log: any StoreLog, steps: WriteSteps
    ) async throws(ReviewsStoreError) -> OpenedFiles {
        let lock = try takeLock(layout)
        do throws(ReviewsStoreError) {
            let file = layout.stateFile
            let path = file.path(percentEncoded: false)
            let bytes: Data
            do {
                bytes = try JSONFile.read(file) ?? Data()
            } catch {
                throw .unreadable(FileError(error, call: .read, path: path))
            }
            let opened = FileSaver.openNow(
                file, default: StoredReviewsState(), what: what, steps: steps, log: log)
            guard let saver = opened.saver else {
                // The second read failed. The saver logged why.
                throw .unreadable(.other("Bifrost can't read \(path)."))
            }
            switch opened.value.version {
            case .current: break
            case .later: throw .laterVersion
            case .unknown: throw .unknownVersion
            }
            let takeOver = try keepCopy(bytes, layout)
            if !opened.value.dropped.isEmpty {
                log.record(.defaulted(file: path, keys: opened.value.dropped))
            }
            return OpenedFiles(
                lock: lock, state: opened.value.state, saver: saver, takeOver: takeOver)
        } catch {
            lock.release()
            throw error
        }
    }

    // The safety copy of the take-over. The first open copies the bytes of state.json as they
    // are (no bytes when there is no file) to state.json.before-native, with the mode 0600. A
    // copy is never written over (JSONFile.keepFirstCopy). The result is true when the state
    // needs the take-over: at the first open, and at a later open while state.json still holds
    // the bytes of the copy, so a quit before the first save cannot skip the take-over.
    nonisolated private static func keepCopy(
        _ bytes: Data, _ layout: ReviewsLayout
    ) throws(ReviewsStoreError) -> Bool {
        let statePath = layout.stateFile.path(percentEncoded: false)
        let copyPath = layout.stateCopy.path(percentEncoded: false)
        func copy() throws(ReviewsStoreError) -> Data? {
            do {
                return try JSONFile.read(layout.stateCopy)
            } catch {
                throw .unreadable(FileError(error, call: .read, path: copyPath))
            }
        }
        if let kept = try copy() { return kept == bytes }
        do {
            if try JSONFile.keepFirstCopy(bytes, at: layout.stateCopy) { return true }
        } catch {
            throw .unreadable(FileError(error, call: .copy(to: copyPath), path: statePath))
        }
        // A copy came between the read and the write. It is the first copy.
        return try copy() == bytes
    }
}
