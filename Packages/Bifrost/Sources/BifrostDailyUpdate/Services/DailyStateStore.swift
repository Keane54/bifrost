import BifrostFoundation
import Foundation
import Observation

package enum DailyStoreError: Error, Sendable, Equatable {
    // Another copy of Bifrost holds the lock of the Daily update.
    case otherCopy
    // The folder or the lock file cannot be used.
    case unavailable(FileError)

    // The text for the panel.
    package var message: String {
        switch self {
        case .otherCopy: "Daily update is running in another copy of Bifrost."
        case .unavailable(let error): "Bifrost can't open the Daily update. \(error.message)"
        }
    }
}

// The store of state.json of the Daily update: the one place of the day state. It holds the state
// on the main actor, and the one save task of the file writes it off the main actor (SaveQueue).
// - The open takes the lock of the folder (FileLock) and holds it until close(). A second copy
//   of Bifrost gets otherCopy and writes nothing.
// - The state of the Electron app opens in place. The first open of this app keeps a copy of the
//   file as state.json.before-native, and nothing writes over that copy
//   (JSONFile.keepFirstCopy). If the copy fails, the store holds the state in memory and does
//   not save, so it cannot lose the old file.
// - A missing or damaged file gives the empty state. A file that cannot be read gives the empty
//   state and no save, so the store never writes over a file that it did not read (FileSaver).
@MainActor
@Observable
package final class DailyStateStore {
    // What the store does with a new state.
    private enum Mode {
        // Save each state through the one save task of the file.
        case saving(SaveQueue<DailyState>)
        // After a read error or a failed copy: keep the state in memory and write nothing.
        case memoryOnly
        // During close(): the last save ends, then the lock is freed. Each new state is ignored.
        case closing(Task<Void, Never>)
        // After close(): ignore each new state.
        case closed
    }

    package private(set) var state: DailyState
    private var mode: Mode
    @ObservationIgnored private let lock: FileLock

    private init(state: DailyState, mode: Mode, lock: FileLock) {
        self.state = state
        self.mode = mode
        self.lock = lock
    }

    // Take the lock, keep the first copy, and read the state. A test gives the steps of the safe
    // writes (the copy and the saves) to fail them.
    package static func open(
        layout: DailyLayout, log: any StoreLog = SystemStoreLog(), steps: WriteSteps = .system
    ) async throws(DailyStoreError) -> DailyStateStore {
        let prepared = try await prepare(layout, log: log, steps: steps)
        let opened = await FileSaver.open(
            layout.stateFile, default: DailyState.empty, what: "the Daily update state",
            steps: steps, log: log)
        let saver = prepared.copied ? opened.saver : nil
        return DailyStateStore(
            state: opened.value, mode: saver.map { .saving(SaveQueue($0)) } ?? .memoryOnly,
            lock: prepared.lock)
    }

    // Take the lock, then keep the copy of the state file of the Electron app. A failed copy is
    // logged, and the store does not save.
    @concurrent private static func prepare(
        _ layout: DailyLayout, log: any StoreLog, steps: WriteSteps
    ) async throws(DailyStoreError) -> (lock: FileLock, copied: Bool) {
        let lock: FileLock
        do {
            lock = try FileLock.take(layout.lockFile)
        } catch {
            switch error {
            case .held: throw .otherCopy
            case .failed(let failure): throw .unavailable(failure)
            }
        }
        let (file, copy) = (layout.stateFile, layout.stateCopy)
        let source = file.path(percentEncoded: false)
        let target = copy.path(percentEncoded: false)
        let manager = FileManager.default
        guard manager.fileExists(atPath: source), !manager.fileExists(atPath: target) else {
            return (lock, true)
        }
        do {
            // The copy waits for a full sync, so it runs on the blocking executor. A copy that
            // comes during the copy stays as it is.
            try await BlockingExecutor.run { () throws -> Void in
                guard let data = try JSONFile.read(file) else { return }
                _ = try JSONFile.keepFirstCopy(data, at: copy, steps: steps)
            }
            return (lock, true)
        } catch {
            let failure = FileError(error, call: .copy(to: target), path: source)
            log.record(
                .copyFailed(
                    file: source, copy: target, what: "the Daily update state", error: failure))
            return (lock, false)
        }
    }

    // Wait for the save that runs, then free the lock. After this, the store writes nothing. A
    // second call during the close waits for the same end, so the lock is never freed while the
    // last save runs.
    package func close() async {
        switch mode {
        case .closed:
            return
        case .closing(let ending):
            await ending.value
        case .saving, .memoryOnly:
            let queue: SaveQueue<DailyState>?
            if case .saving(let current) = mode { queue = current } else { queue = nil }
            let lock = self.lock
            let ending = Task {
                await queue?.task?.value
                lock.release()
            }
            mode = .closing(ending)
            await ending.value
            mode = .closed
        }
    }

    // Keep the next state and start its save. The one save task of the file writes the newest
    // state last, with the fewest writes (SaveQueue), so the caller needs no order of its own.
    // During and after the close, the store ignores each new state.
    package func keep(_ next: DailyState) {
        switch mode {
        case .closing, .closed:
            return
        case .memoryOnly:
            state = next
        case .saving(let queue):
            state = next
            _ = queue.save(next)
        }
    }

    // The end of the save that runs or waits. A test and the quit wait for it.
    package func saved() async {
        if case .saving(let queue) = mode { await queue.task?.value }
    }
}
