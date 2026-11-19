import BifrostFoundation
import BifrostSessions
import Foundation
import OSLog

// What the one-time import did with each store. The marker file import.json keeps it, with the
// version 1.
package struct ImportReport: Sendable, Equatable, Codable {
    // The time of the import in milliseconds since 1970, the form of the file.
    package var at: Int
    // The file names of the stores that came in, in the order of ImportedStore.
    package var imported: [String]
    // The new names of the earlier development files, for example "ui-state.json.before-import".
    package var kept: [String]
    // The file name of each store that did not come in, and the reason.
    package var skipped: [String: String]
}

// Why a store does not come in. Its development file stays.
package enum ImportSkip: Sendable, Equatable {
    // The Electron folder has no file of the store.
    case missing
    // The read of the Electron file failed.
    case unreadable(FileError)
    // The item at the path of the Electron file is not a regular file: for example a folder or a
    // FIFO.
    case notAFile
    // The Electron file is not JSON.
    case notJSON
    // The JSON of the Electron file is not an object.
    case notAnObject
    // The version of the settings or of the UI state is not 1. The value is the version when it
    // is a whole number.
    case version(Int?)
    // The rename of the development file or the write of the new file failed. The import then
    // writes no marker, so the next start tries again. After a failed write, the development
    // file gets its name back.
    case notWritten(FileError)

    // The reason in the report.
    package var text: String {
        switch self {
        case .missing: "missing"
        case .unreadable(let error): error.message
        case .notAFile: "not a file"
        case .notJSON: "not JSON"
        case .notAnObject: "not an object"
        case .version(let number?): "version \(number)"
        case .version(nil): "not version 1"
        case .notWritten(let error): error.message
        }
    }
}

// An event of the import for the log. Each store gives one event.
package enum ImportEvent: Sendable, Equatable {
    // The Electron file of the store came in. kept is the new name of the earlier development
    // file, or nil when the support folder had no file of the store.
    case imported(ImportedStore, kept: String?)
    // The store did not come in, for the reason.
    case skipped(ImportedStore, ImportSkip)
    // The write of the marker failed, so the import runs again at the next start.
    case markerNotWritten(FileError)
    // The check of the marker failed with an error other than a missing item, so the import does
    // not run.
    case markerNotChecked(FileError)
    // The Electron folder at this path is the support folder of the app, so the import does not
    // run.
    case oneFolder(String)
}

// Where the import sends its events. The app uses SystemImportLog. A test records the events.
package protocol ImportLog: Sendable {
    func record(_ event: ImportEvent)
}

// The log of the import in the unified log of macOS.
package struct SystemImportLog: ImportLog {
    private static let logger = Logger(bifrost: "import")

    package init() {}

    package func record(_ event: ImportEvent) {
        let log = Self.logger
        switch event {
        case .imported(let store, let kept?):
            log.notice(
                """
                Bifrost imported \(store.rawValue, privacy: .public) from the Electron app. The \
                earlier file is now \(kept, privacy: .public).
                """)
        case .imported(let store, nil):
            log.notice(
                "Bifrost imported \(store.rawValue, privacy: .public) from the Electron app.")
        case .skipped(let store, .missing):
            log.notice(
                """
                The Electron app has no \(store.rawValue, privacy: .public), so Bifrost keeps its \
                own file.
                """)
        case .skipped(let store, .notWritten(let error)):
            log.error(
                """
                Bifrost cannot import \(store.rawValue, privacy: .public), so the import runs \
                again at the next start. \(error.message, privacy: .private)
                """)
        case .skipped(let store, let reason):
            // The text of a read error has the path, so the reason is private.
            log.notice(
                """
                Bifrost does not import \(store.rawValue, privacy: .public) and keeps its own \
                file: \(reason.text, privacy: .private)
                """)
        case .markerNotWritten(let error):
            log.error(
                """
                Bifrost cannot save the marker of the import, so the import runs again at the \
                next start. \(error.message, privacy: .private)
                """)
        case .markerNotChecked(let error):
            log.notice(
                """
                Bifrost cannot check the marker of the import, so it does not import the data of \
                the Electron app. \(error.message, privacy: .private)
                """)
        case .oneFolder(let path):
            log.notice(
                """
                The Electron folder \(path, privacy: .private) is the support folder of Bifrost, \
                so Bifrost does not import from it.
                """)
        }
    }
}

// The one-time import of the data of the Electron app into the support folder of the development
// app (the behaviour list is in docs/behaviour/import.md). It reads each file of ImportedStore in
// the Electron folder and writes its bytes as they are into the support folder, so each field
// stays, also a field that this app does not know. The import never opens a file of the Electron
// folder for writing and never makes a file there.
//
// For each store:
// - The development file stays, and the report gives the reason, when the Electron file is
//   missing, is not a regular file, cannot be read, is not JSON, is not an object, or is a
//   settings or UI state file whose version is not 1.
// - Else the development file, when there is one, gets the name <name>.before-import, or
//   <name>.before-import-2 and so on when that name is used. Then the safe write (JSONFile.write)
//   writes the Electron bytes to <name>, with the mode 0600. When the write fails, the
//   development file gets its name back.
// The marker import.json comes last. While it exists, the import does nothing. An import that
// stops before the marker, or in which a rename or a write failed, runs again at the next start.
package enum ElectronImport {
    package static let markerName = "import.json"

    // Run the import when the support folder has no marker, off the main actor. The file work
    // runs on the blocking executor, because each write waits for a full sync. The log gets one
    // event for each store. The result is the report, or nil when no import ran: the marker
    // exists or cannot be checked, or the two folders are one folder. A test gives the steps of
    // the safe write to make a write fail.
    @concurrent package static func runOnce(
        from electron: ElectronStores, to support: URL, now: Date, log: any ImportLog,
        steps: WriteSteps = .system
    ) async -> ImportReport? {
        await BlockingExecutor.run {
            run(from: electron, to: support, now: now, log: log, steps: steps)
        }
    }

    // The import on the current thread.
    private static func run(
        from electron: ElectronStores, to support: URL, now: Date, log: any ImportLog,
        steps: WriteSteps
    ) -> ImportReport? {
        let marker = support.appending(path: markerName, directoryHint: .notDirectory)
        switch MarkerState(marker) {
        case .absent: break
        case .present: return nil
        case .unchecked(let error):
            log.record(.markerNotChecked(error))
            return nil
        }
        // The release app uses the Electron folder as its support folder. StartPlan gives it no
        // import, and this check makes sure that the import never renames a file there.
        guard !isOneFolder(electron.folder, support) else {
            log.record(.oneFolder(electron.folder.path(percentEncoded: false)))
            return nil
        }
        var report = ImportReport(
            at: now.millisecondsSince1970, imported: [], kept: [], skipped: [:])
        var complete = true
        for store in ImportedStore.allCases {
            let event = copy(store, from: electron, to: support, steps: steps, into: &report)
            if case .skipped(_, .notWritten) = event { complete = false }
            log.record(event)
        }
        guard complete else { return report }
        do {
            try JSONFile.write(JSONFile.encode(Marker(report: report)), to: marker, steps: steps)
        } catch {
            let failure = FileError(error, call: .save, path: marker.path(percentEncoded: false))
            log.record(.markerNotWritten(failure))
        }
        return report
    }

    // Copy the Electron file of one store, and add the result to the report. The result is the
    // event of the store for the log.
    private static func copy(
        _ store: ImportedStore, from electron: ElectronStores, to support: URL,
        steps: WriteSteps, into report: inout ImportReport
    ) -> ImportEvent {
        let name = store.rawValue
        func skip(_ reason: ImportSkip) -> ImportEvent {
            report.skipped[name] = reason.text
            return .skipped(store, reason)
        }
        let data: Data
        do {
            switch try electron.read(store) {
            case .missing: return skip(.missing)
            case .notAFile: return skip(.notAFile)
            case .data(let bytes): data = bytes
            }
        } catch {
            return skip(.unreadable(error))
        }
        if let reason = check(data, of: store) { return skip(reason) }
        let file = support.appending(path: name, directoryHint: .notDirectory)
        let kept: String?
        do {
            kept = try keep(file)
        } catch {
            return skip(.notWritten(error))
        }
        do {
            try JSONFile.write(data, to: file, steps: steps)
        } catch {
            // The development file gets its name back, so its store does not open empty. The
            // rename does not replace an item that came at the name. If it fails, the file keeps
            // its before-import name, and the report gives that name.
            if let kept, !restore(kept, to: file) { report.kept.append(kept) }
            let failure = FileError(error, call: .save, path: file.path(percentEncoded: false))
            return skip(.notWritten(failure))
        }
        if let kept { report.kept.append(kept) }
        report.imported.append(name)
        return .imported(store, kept: kept)
    }

    // The reason to skip an Electron file, or nil when the store can use it. The lenient decode
    // of each store (StoredSettings, RegistryStore, UIState, WindowState) refuses only a value
    // that is not an object or that has no JSON form, and the decode of a JSON value refuses the
    // same files. The store decode gives the defaults for a settings or UI state file of another
    // version, so the check reads the version from the JSON. The other stores have no version.
    private static func check(_ data: Data, of store: ImportedStore) -> ImportSkip? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .notJSON
        }
        guard case .object(let fields) = value else { return .notAnObject }
        guard store.hasVersion else { return nil }
        let version = fields["version"]?.wholeNumber
        return version == 1 ? nil : .version(version)
    }

    // Give the development file a free name: <name>.before-import, else
    // <name>.before-import-2, -3 and so on. The rename never replaces a file (RENAME_EXCL), so a
    // name that exists gets the next number. The rename moves a link, not its target. The result
    // is the new name, or nil when the support folder has no file of the store.
    private static func keep(_ file: URL) throws(FileError) -> String? {
        let path = file.path(percentEncoded: false)
        let folder = file.deletingLastPathComponent()
        var number = 1
        while true {
            let suffix = number == 1 ? "" : "-\(number)"
            let name = "\(file.lastPathComponent).before-import\(suffix)"
            let target = folder.appending(path: name, directoryHint: .notDirectory)
                .path(percentEncoded: false)
            if renamex_np(path, target, UInt32(RENAME_EXCL)) == 0 { return name }
            let code = errno
            switch code {
            case ENOENT: return nil
            case EEXIST: number += 1
            default: throw .system(.rename(to: target), path: path, code: code)
            }
        }
    }

    // Give the kept development file its name again. The result is true when the rename worked.
    private static func restore(_ kept: String, to file: URL) -> Bool {
        let source = file.deletingLastPathComponent()
            .appending(path: kept, directoryHint: .notDirectory).path(percentEncoded: false)
        return renamex_np(source, file.path(percentEncoded: false), UInt32(RENAME_EXCL)) == 0
    }

    // True when the two folders are one folder: the same device and inode, after the links. When
    // a folder is missing, it has no inode, and the resolved paths decide, so a missing support
    // folder at the path of the Electron folder counts too.
    private static func isOneFolder(_ first: URL, _ second: URL) -> Bool {
        if let a = identity(of: first), let b = identity(of: second) { return a == b }
        return realPath(first) == realPath(second)
    }

    // The device and the inode of the item at the path, after the links. nil when the stat
    // fails.
    private static func identity(of url: URL) -> (device: dev_t, inode: ino_t)? {
        var info = stat()
        guard stat(url.path(percentEncoded: false), &info) == 0 else { return nil }
        return (info.st_dev, info.st_ino)
    }

    // The path of the folder with no link in it.
    private static func realPath(_ folder: URL) -> String {
        folder.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
    }
}

// The state of the marker file. A link counts as an item.
private enum MarkerState {
    case absent, present
    // The check failed with an error other than a missing item.
    case unchecked(FileError)

    init(_ marker: URL) {
        var info = stat()
        let path = marker.path(percentEncoded: false)
        if lstat(path, &info) == 0 {
            self = .present
            return
        }
        let code = errno
        self = code == ENOENT ? .absent : .unchecked(.system(.check, path: path, code: code))
    }
}

// The marker file: the version 1 and the fields of the report.
private struct Marker: Encodable {
    private enum Key: String, CodingKey {
        case version
    }

    let report: ImportReport

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(1, forKey: .version)
        try report.encode(to: encoder)
    }
}
