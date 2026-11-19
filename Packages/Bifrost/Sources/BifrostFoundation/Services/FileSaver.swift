import Foundation
import Synchronization

// The open and the saves of one store file. Each store uses it: the settings, the registry
// store, the UI state and the window state.
// - The open decodes the file one time. The stored type keeps the unknown top-level fields of the
//   file (UnknownFields), so a save of a file from a newer app loses nothing.
// - A missing file and a value that the decode refuses give the default value, and a save works.
// - A file that does not parse at all gives the default value. Before the first save over it,
//   the saver copies it to <file>.unreadable, one time, and logs where the copy is
//   (docs/behaviour/stores.md, Loading a file).
//   A file does not parse when the JSON parser refuses it, or when the decode throws NoJSONForm
//   (a raw value or an unknown field with no JSON form).
// - The store can ask for a backup copy before the first save, for example of a file of a later
//   version. That copy logs nothing.
// - If a copy fails, the saver logs it and turns the save off, so the file stays. Then each save
//   writes nothing. A new copy replaces an old copy.
// - Another read error, for example a folder at the path or no permission, gives the default
//   value and no saver, so the store never writes over a file that it did not read.
// - With a size limit, a value whose compact JSON has more bytes than the limit is not saved,
//   and the saver logs it.
// - A save encodes the value one time, in the text form of the stores (JSONFile.encode).
// write(_:) runs one save at once, for a caller that runs one save at a time. The stores on the
// main actor use save(_:) or a SaveQueue.
package final class FileSaver: Sendable {
    // The result of one save.
    package enum SaveResult: Sendable, Equatable {
        case saved
        // No write ran: the save is off, or the value is larger than the limit.
        case skipped
        // The write failed.
        case failed(FileError)
    }

    // The result of the open of a store file.
    package struct Opened<Value: Sendable>: Sendable {
        package var value: Value
        // nil after a read error: the store does not save.
        package var saver: FileSaver?
    }

    // What the first save does before its write.
    private enum Step {
        // Copy the file to this path. logged is true for the copy of a file that does not parse.
        case copyFirst(String, logged: Bool)
        case save
        // The copy failed, so no save writes.
        case off
    }

    package let path: String
    // The name of the data in the log, for example "the UI state".
    let what: String
    let log: any StoreLog
    private let maxBytes: Int?
    // The steps of the safe write. A test can hold a write with them.
    private let steps: WriteSteps
    // A save holds the lock for the copy and the write. So a second write waits until the copy
    // is done, and it cannot write over the file first.
    private let step: Mutex<Step>

    // copy is the path of a copy that the first save makes first. unreadable is true when the
    // file does not parse: then the save logs the copy.
    private init(
        path: String, what: String, copy: String?, unreadable: Bool, maxBytes: Int?,
        steps: WriteSteps, log: any StoreLog
    ) {
        self.path = path
        self.what = what
        self.maxBytes = maxBytes
        self.steps = steps
        self.log = log
        step = Mutex(copy.map { .copyFirst($0, logged: unreadable) } ?? .save)
    }

    // Read and decode a store file off the main actor (see openNow).
    @concurrent package static func open<Value: Decodable & Sendable>(
        _ file: URL, default fallback: Value, what: String, maxBytes: Int? = nil,
        backup: @Sendable (Value) -> String? = { _ in nil }, steps: WriteSteps = .system,
        log: any StoreLog = SystemStoreLog()
    ) async -> Opened<Value> {
        openNow(
            file, default: fallback, what: what, maxBytes: maxBytes, backup: backup, steps: steps,
            log: log)
    }

    // Read and decode a store file on the current thread, with one decode. backup gives the path
    // of a copy that the first save makes first, for a value that needs one. A read error logs
    // one line.
    package static func openNow<Value: Decodable & Sendable>(
        _ file: URL, default fallback: Value, what: String, maxBytes: Int? = nil,
        backup: (Value) -> String? = { _ in nil }, steps: WriteSteps = .system,
        log: any StoreLog = SystemStoreLog()
    ) -> Opened<Value> {
        let path = file.path(percentEncoded: false)
        let data: Data?
        do {
            data = try JSONFile.read(file)
        } catch {
            let failure = FileError(error, call: .read, path: path)
            log.record(.readFailed(file: path, what: what, error: failure))
            return Opened(value: fallback, saver: nil)
        }
        var value = fallback
        var copy: String?
        var unreadable = false
        if let data {
            do {
                value = try JSONDecoder().decode(Value.self, from: data)
                copy = backup(value)
            } catch is NoJSONForm {
                // A raw value or an unknown field has no JSON form, so a save would lose it.
                copy = "\(path).unreadable"
                unreadable = true
            } catch DecodingError.dataCorrupted(let context) where context.codingPath.isEmpty {
                // The JSON parser refused the data.
                copy = "\(path).unreadable"
                unreadable = true
            } catch {
                // The data is JSON, but the type refused it, so the value is the default.
            }
        }
        let saver = FileSaver(
            path: path, what: what, copy: copy, unreadable: unreadable, maxBytes: maxBytes,
            steps: steps, log: log)
        return Opened(value: value, saver: saver)
    }

    // Save a value on the blocking executor: the copy and the write wait for a full sync of the
    // file.
    package func save(_ value: some Encodable & Sendable) async -> SaveResult {
        await BlockingExecutor.run { self.write(value) }
    }

    // Run one save now, on the current thread. A caller in async code uses save(_:), or runs this
    // call on the blocking executor.
    package func write(_ value: some Encodable) -> SaveResult {
        let data: Data
        do {
            data = try JSONFile.encode(value)
        } catch {
            return .failed(FileError(error, call: .save, path: path))
        }
        if let maxBytes, JSONFile.compactSize(ofStoreText: data) > maxBytes {
            log.record(.tooLarge(file: path, what: what, limit: maxBytes))
            return .skipped
        }
        return step.withLock { state in
            if case .copyFirst(let target, let logged) = state {
                do {
                    try JSONFile.copy(path, to: target)
                    if logged { log.record(.keptUnreadableCopy(file: path, copy: target)) }
                    state = .save
                } catch {
                    let failure = FileError(error, call: .copy(to: target), path: path)
                    log.record(.copyFailed(file: path, copy: target, what: what, error: failure))
                    state = .off
                }
            }
            guard case .save = state else { return .skipped }
            do {
                try JSONFile.write(data, to: URL(fileURLWithPath: path), steps: steps)
                return .saved
            } catch {
                return .failed(FileError(error, call: .save, path: path))
            }
        }
    }
}

// The one save task of a store file, for a store on the main actor. A save gives the newest
// value. The task writes it off the main actor, one write at a time. A value that waits while a
// write runs gives its place to a newer value, so the file gets the newest value with the fewest
// writes. A failed write logs one line.
// Each save gets a generation: one more than the save before it. saved(_:) gives the result of
// the first write whose generation is at least the generation of a save, so a store can wait
// until the file holds a change before it acts on it.
@MainActor
package final class SaveQueue<Value: Encodable & Sendable> {
    private let saver: FileSaver
    // The value that waits for its write, with its generation.
    private var waiting: (generation: Int, value: Value)?
    // The save task. nil when no write runs and no value waits.
    package private(set) var task: Task<Void, Never>?
    // The generation of the last save. The value of the open is generation 0.
    package private(set) var generation = 0
    // The last write that ended. The value of the open counts as saved, because a new open reads
    // the same value again.
    private var written = (generation: 0, saved: true)
    // The calls of saved(_:) that wait for the write of their generation.
    private var waiters: [(generation: Int, wake: CheckedContinuation<Bool, Never>)] = []

    package init(_ saver: FileSaver) {
        self.saver = saver
    }

    // True when each save has ended, and the last write failed or wrote nothing.
    package var lastWriteFailed: Bool {
        written.generation == generation && !written.saved
    }

    // Save the value after the write that runs. The task ends after the write of the newest
    // value, so it also ends after each earlier write.
    @discardableResult
    package func save(_ value: Value) -> Task<Void, Never> {
        generation += 1
        waiting = (generation, value)
        if let task { return task }
        let task = Task {
            while let next = waiting {
                waiting = nil
                let result = await saver.save(next.value)
                if case .failed(let failure) = result {
                    saver.log.record(.saveFailed(what: saver.what, error: failure))
                }
                finish(next.generation, saved: result == .saved)
            }
            self.task = nil
        }
        self.task = task
        return task
    }

    // True when the file holds the value of the generation: the first write whose generation is
    // at least this generation saved. A failed write and a write that the saver skipped give
    // false.
    package func saved(_ generation: Int) async -> Bool {
        if written.generation >= generation { return written.saved }
        return await withCheckedContinuation { waiters.append((generation, $0)) }
    }

    // Record the end of the write of the generation, and wake each call that waits for it.
    private func finish(_ ended: Int, saved: Bool) {
        written = (ended, saved)
        let due = waiters.filter { $0.generation <= ended }
        waiters.removeAll { $0.generation <= ended }
        for waiter in due { waiter.wake.resume(returning: saved) }
    }
}
