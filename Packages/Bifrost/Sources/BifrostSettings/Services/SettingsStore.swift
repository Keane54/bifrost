import BifrostFoundation
import Foundation
import Observation

// The error of one edit of the settings. message is its text.
public enum SettingsError: Error, Sendable, Equatable {
    // The edit gives a bad value, with the reason of the check.
    case refused(SettingsRefusal)
    // The write failed.
    case notSaved(FileError)

    public var message: String {
        switch self {
        case .refused(let refusal): refusal.message
        case .notSaved(let failure): failure.message
        }
    }
}

// The settings store of the app. It holds the settings on the main actor, and the app observes
// them. Each change is an edit: a closure that changes the newest settings. The store checks the
// result (Settings.validated()), writes it with the safe write, then sets the settings. The edits
// run one at a time, in the order of the calls. The copy and the write run off the main actor
// (FileSaver).
@MainActor
@Observable
public final class SettingsStore {
    // The current settings, with the unknown fields of the file.
    public private(set) var settings: Settings
    // nil after a read error: the store does not save.
    @ObservationIgnored private let saver: FileSaver?
    // The log of the store. A failed write goes to it.
    @ObservationIgnored private let log: any StoreLog
    // The task of the last edit. The next edit waits until it ends.
    @ObservationIgnored private var lastEdit: Task<Result<Settings, SettingsError>, Never>?

    // The name of the data of the file in the log (StoreEvent).
    nonisolated static let what = "the settings"

    private init(_ settings: Settings, saver: FileSaver?, log: any StoreLog) {
        self.settings = settings
        self.saver = saver
        self.log = log
    }

    // Open settings.json. The read and the parse run off the main actor.
    // - A missing file or bad JSON gives the defaults, and a save works.
    // - A bad value gets its default, and the other values stay. The log gets one line with
    //   their keys (docs/behaviour/stores.md, settings.json).
    // - If the file cannot be read, the store uses the defaults and does not save. Then it
    //   cannot write over a file that it did not read.
    // - A file of a later version gives the defaults. Before the first write over it, the store
    //   copies it to settings.v<version>.backup.json in the same folder, one time.
    // - A file that does not parse at all gives the defaults. Before the first write over it,
    //   the store copies it to <file>.unreadable, one time, and logs where the copy is
    //   (docs/behaviour/stores.md, Loading a file).
    // - If a copy fails, the store does not save. So the old file stays.
    // A test gives its own log, and the steps of the safe write to hold a write.
    package static func open(
        file: URL, log: any StoreLog = SystemStoreLog(), steps: WriteSteps = .system
    ) async -> SettingsStore {
        let folder = file.deletingLastPathComponent()
        let opened = await FileSaver.open(
            file, default: StoredSettings(), what: what,
            backup: { stored in
                stored.laterVersion.map {
                    folder.appending(path: backupName(version: $0)).path(percentEncoded: false)
                }
            }, steps: steps, log: log)
        let defaulted = opened.value.defaulted
        if !defaulted.isEmpty {
            log.record(.defaulted(file: file.path(percentEncoded: false), keys: defaulted))
        }
        return SettingsStore(opened.value.settings, saver: opened.saver, log: log)
    }

    // Change the settings, for example `try await store.edit { $0.rowFlash = false }`. The
    // result is the new settings.
    // - change runs on the newest settings, after each earlier edit ended. So two quick edits
    //   never start from the same old value.
    // - A bad value throws .refused with the reason of the check, and the settings stay.
    // - An edit that changes nothing writes nothing, and no observer hears of it.
    // - A failed write throws .notSaved with the error of the write, and the settings stay. The
    //   log of the store gets the failure (StoreEvent.saveFailed).
    // - With the save off, the settings change and nothing is written.
    @discardableResult
    public func edit(
        _ change: @escaping (inout Settings) -> Void
    ) async throws(SettingsError) -> Settings {
        let edit = Task { [earlier = lastEdit] in
            _ = await earlier?.value
            return await self.apply(change)
        }
        lastEdit = edit
        return try await edit.value.get()
    }

    // Wait until each edit that runs or waits has ended, also an edit that comes during the
    // wait. With no edit, it ends at once. The quit calls this inside its time limit, so the
    // last change of the settings gets to the file.
    public func waitForWrites() async {
        while let last = lastEdit {
            _ = await last.value
            if lastEdit == last { return }
        }
    }

    // One edit: the change, the check, then the save. The settings change after a good save.
    private func apply(
        _ change: (inout Settings) -> Void
    ) async -> Result<Settings, SettingsError> {
        var next = settings
        change(&next)
        do {
            next = try next.validated()
        } catch {
            return .failure(.refused(error))
        }
        guard next != settings else { return .success(settings) }
        if let saver, case .failed(let failure) = await saver.save(next) {
            log.record(.saveFailed(what: Self.what, error: failure))
            return .failure(.notSaved(failure))
        }
        settings = next
        return .success(next)
    }

    // The name of the copy of a file of a later version. The version is a whole number with no
    // ".0", else the decimal text of the number.
    nonisolated static func backupName(version: Double) -> String {
        let text = Int(exactly: version).map(String.init) ?? version.description
        return "settings.v\(text).backup.json"
    }
}
