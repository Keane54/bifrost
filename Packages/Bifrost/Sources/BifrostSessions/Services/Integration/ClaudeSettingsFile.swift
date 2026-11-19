import BifrostFoundation
import Darwin
import Foundation

// Why an edit of the Claude Code settings file did not run. Each refusal leaves the settings file
// as it was. message is the text that the user reads.
package enum IntegrationFailure: MessageError, Sendable, Equatable {
    // The file is not UTF-8 JSON, is not an object, or has too many levels.
    case notJSON(file: String)
    case notObject(file: String)
    case tooDeep(file: String)
    // The file has more than ClaudeSettingsFile.maxBytes.
    case tooLarge(file: String)
    // The path has a folder, a FIFO or another file that is not a regular file.
    case notAFile(file: String)
    // Another program changed the file during the edit.
    case changed(file: String)
    // The statusLine is the wrapper, but the saved original is missing or not usable. The text
    // names the newest backup, or says that there is none.
    case missingOriginal(newestBackup: String?)
    // A call of the system failed.
    case system(FileError)

    // The refusal of a parse of the file.
    init(_ error: ClaudeSettingsDocument.ParseError, file: String) {
        switch error {
        case .notJSON: self = .notJSON(file: file)
        case .notObject: self = .notObject(file: file)
        case .tooDeep: self = .tooDeep(file: file)
        }
    }

    package var message: String {
        switch self {
        case .notJSON(let file):
            "The file \(file) is not valid JSON (or not valid UTF-8). Bifrost did not change it."
        case .notObject(let file):
            "Unexpected type in \(file). Expect a JSON object. Bifrost did not change it."
        case .tooDeep(let file):
            """
            The file \(file) has more than \(ClaudeSettingsDocument.maxDepth) levels of nested \
            values. Bifrost did not change it.
            """
        case .tooLarge(let file):
            """
            The file \(file) is larger than \(ClaudeSettingsFile.maxBytes / (1024 * 1024)) MB. \
            Bifrost did not change it.
            """
        case .notAFile(let file):
            "\(file) is not a regular file. Bifrost did not change it."
        case .changed(let file):
            "The file \(file) changed while Bifrost worked. Bifrost did not change it. Try again."
        case .missingOriginal(let backup):
            """
            Bifrost cannot find your original statusLine setting. Restore it from the newest \
            backup: \(backup ?? "no backup found").
            """
        case .system(let error):
            error.message
        }
    }
}

// The edit of the settings file of Claude Code (docs/behaviour/live.md, "The edit of the Claude
// Code settings file"). The file belongs to the user, so the edit never loses or breaks it:
// - A missing file is an empty object. A file that is not UTF-8 JSON, or not an object, is
//   refused, and Bifrost changes nothing.
// - The read takes only a regular file of at most maxBytes, and it does not wait on a FIFO.
// - The new text goes to a temporary file with a unique name in the folder of the real path of
//   the file, so a link at the path stays a link and its target gets the new text. The temporary
//   file gets the mode of the old file and a full sync.
// - Then the backup gets the exact old bytes. If the backup fails, the temporary file goes.
// - Just before the rename, the edit reads the file again. If the bytes changed (for example
//   Claude Code wrote the file), the edit refuses, removes the temporary file and keeps the file.
// The file work runs on the blocking executor, because a full sync can take a long time.
package enum ClaudeSettingsFile {
    // The largest settings file that Bifrost reads: 4 MB. A settings file of Claude Code has a
    // few kilobytes. A parse needs many times the size of the file in memory (a file of 16 MB
    // took up to 550 MB), so the limit keeps that memory small.
    package static let maxBytes = 4 * 1024 * 1024

    // Look for the old hook install in the settings: a Bifrost hook under any event and any
    // matcher, or the wrapper (SettingsPlan.hasBifrostEntry). It only reads. The result is true
    // for an old install, or the refusal of a file that Bifrost cannot read.
    @concurrent package static func oldInstall(
        _ paths: SharedClaudeState
    ) async -> Result<Bool, IntegrationFailure> {
        await BlockingExecutor.run { () -> Result<Bool, IntegrationFailure> in
            do throws(IntegrationFailure) {
                let settings = try readSettings(paths.claudeSettings)
                return .success(SettingsPlan.hasBifrostEntry(settings.document))
            } catch {
                return .failure(error)
            }
        }
    }

    // Remove the old hook install from the settings (SettingsPlan.planUninstall), with the saved
    // original statusLine of the user in place of the wrapper. The saved original stays.
    // - With no Bifrost entry, or with no file, nothing changes and no backup is made.
    // - The wrapper with no usable saved original refuses and names the newest backup, because
    //   the edit would lose the statusLine of the user.
    // beforeRename runs after the backup and before the last check, so a test can change the file
    // there.
    @concurrent package static func uninstall(
        _ paths: SharedClaudeState, now: Date, beforeRename: (@Sendable () async -> Void)? = nil,
        log: any IntegrationLog = SystemIntegrationLog()
    ) async throws(IntegrationFailure) {
        let edit = try await BlockingExecutor.run { () throws(IntegrationFailure) -> Edit? in
            try prepareUninstall(paths, now: now)
        }
        guard let edit else { return }
        await beforeRename?()
        try await BlockingExecutor.run { () throws(IntegrationFailure) in try edit.commit() }
        log.record(.oldInstallRemoved(file: edit.file, backup: edit.backup))
    }

    // True when the bin folder of the old hook data must stay: old hook entries in the settings
    // still run its scripts, and settings that Bifrost cannot read can have such entries too.
    // Without bin, a person who still has the wrapper loses the status line.
    package static func keepOldScripts(_ status: Result<Bool, IntegrationFailure>) -> Bool {
        (try? status.get()) != false
    }

    // MARK: - The steps

    // Read the settings and the saved original, plan the edit, write the temporary file, then
    // write the backup. nil when the edit changes nothing.
    private static func prepareUninstall(_ paths: SharedClaudeState, now: Date)
        throws(IntegrationFailure) -> Edit?
    {
        let settings = try readSettings(paths.claudeSettings)
        // Only the wrapper needs the saved original. So a removal of hooks only never reads it,
        // and a folder or a FIFO at its path cannot stop that removal.
        var original: ClaudeSettingsDocument?
        if SettingsPlan.checkInstall(settings.document).statusLineInstalled {
            switch try readSavedStatusLine(paths.savedStatusLine) {
            case .unusable: throw .missingOriginal(newestBackup: newestBackup(in: paths.backups))
            case .none: original = nil
            case .setting(let setting): original = setting
            }
        }
        let next = SettingsPlan.planUninstall(settings.document, original: original)
        guard let current = settings.current, next != settings.document else { return nil }
        let temporary = try writeTemporary(
            Data(next.text.utf8), besides: current.path, mode: current.mode, shown: settings.file)
        let backup: String
        do {
            backup = try writeBackup(current.bytes, in: paths.backups, now: now)
        } catch {
            unlink(temporary)
            throw error
        }
        return Edit(
            file: settings.file, temporary: temporary, target: current.path,
            oldBytes: current.bytes, backup: backup)
    }

    // A staged edit: the temporary file with the new text, the real path of the settings file,
    // its old bytes and the backup. file is the path in the texts.
    private struct Edit: Sendable {
        let file: String
        let temporary: String
        let target: String
        let oldBytes: Data
        let backup: String

        // Read the file again. When it still has the old bytes, rename the temporary file to the
        // real path. Else, or on a failure, remove the temporary file: the file stays as it is.
        func commit() throws(IntegrationFailure) {
            let same: Bool
            do {
                same = try ClaudeSettingsFile.hasBytes(target, oldBytes, shown: file)
            } catch {
                unlink(temporary)
                throw error
            }
            guard same else {
                unlink(temporary)
                throw .changed(file: file)
            }
            if Darwin.rename(temporary, target) != 0 {
                let code = errno
                unlink(temporary)
                throw .system(.system(.save, path: file, code: code))
            }
        }
    }

    // MARK: - The reads

    // A regular file that the edit read: its path (the real path, for a read that resolves it),
    // its bytes and its permission bits.
    private struct RegularFile: Sendable {
        let path: String
        let bytes: Data
        let mode: mode_t
    }

    // The settings and the file that holds them. current is nil when no file is at the path.
    private struct SettingsRead: Sendable {
        let file: String
        let document: ClaudeSettingsDocument
        let current: RegularFile?
    }

    // The saved original statusLine of the user (statusline-original.json).
    private enum SavedStatusLine: Sendable {
        // The file is missing, or it is not null and not an object with a command text.
        case unusable
        // The file has null: the user had no statusLine.
        case none
        case setting(ClaudeSettingsDocument)
    }

    // Read the settings, and the real path of the file that the open found. So the edit writes
    // the file that a link names, and the path is the path of the bytes that it read.
    private static func readSettings(_ url: URL) throws(IntegrationFailure) -> SettingsRead {
        let file = url.path(percentEncoded: false)
        guard let current = try readRegular(file, shown: file, resolve: true) else {
            return SettingsRead(file: file, document: ClaudeSettingsDocument(), current: nil)
        }
        do {
            let document = try ClaudeSettingsDocument.parse(current.bytes)
            return SettingsRead(file: file, document: document, current: current)
        } catch {
            throw IntegrationFailure(error, file: file)
        }
    }

    // A byte of the saved original that is not UTF-8 becomes U+FFFD, and a byte order mark at the
    // start is skipped, as in the settings file. A read error throws.
    private static func readSavedStatusLine(_ url: URL) throws(IntegrationFailure)
        -> SavedStatusLine
    {
        let file = url.path(percentEncoded: false)
        guard let saved = try readRegular(file, shown: file) else { return .unusable }
        let text = Data(String(decoding: saved.bytes, as: UTF8.self).utf8)
        switch try? ClaudeSettingsDocument.parseValue(text) {
        case .null?: return .none
        case .object(let setting)? where setting["command"]?.text != nil: return .setting(setting)
        default: return .unusable
        }
    }

    // Read the regular file at the path. The open follows a link, and it does not wait
    // (O_NONBLOCK), so a FIFO at the path cannot hold the edit. A missing file, also a link that
    // names no file, gives nil. With resolve, the result has the real path of the open file
    // (F_GETPATH), and a failure of that call refuses: the edit never writes beside a link. shown
    // is the path in the texts.
    private static func readRegular(_ path: String, shown: String, resolve: Bool = false)
        throws(IntegrationFailure) -> RegularFile?
    {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT { return nil }
            throw .system(.system(.read, path: shown, code: code))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw .system(.system(.check, path: shown, code: errno))
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw .notAFile(file: shown) }
        guard info.st_size <= off_t(maxBytes) else { throw .tooLarge(file: shown) }
        var realPath = path
        if resolve {
            var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(descriptor, F_GETPATH, &buffer) != -1 else {
                // F_GETPATH gives ENOSPC when the real path has more than MAXPATHLEN bytes. The
                // text of ENAMETOOLONG gives the user that reason, so the edit reports it.
                let code = errno
                throw .system(
                    .system(.check, path: shown, code: code == ENOSPC ? ENAMETOOLONG : code))
            }
            realPath = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        let bytes: Data
        do {
            bytes = try handle.read(upToCount: maxBytes + 1) ?? Data()
        } catch {
            throw .system(FileError(error, call: .read, path: shown))
        }
        // The file can grow after the check of its size.
        guard bytes.count <= maxBytes else { throw .tooLarge(file: shown) }
        return RegularFile(path: realPath, bytes: bytes, mode: info.st_mode & 0o777)
    }

    // True when the regular file at the path has these bytes. A missing file, a file of another
    // type and a file that is too large give false.
    private static func hasBytes(_ path: String, _ bytes: Data, shown: String)
        throws(IntegrationFailure) -> Bool
    {
        do {
            return try readRegular(path, shown: shown)?.bytes == bytes
        } catch {
            switch error {
            case .notAFile, .tooLarge: return false
            default: throw error
            }
        }
    }

    // MARK: - The writes

    // Write the data to a new temporary file beside the path, with the mode and a full sync. The
    // name is unique, and the open fails when a file (also a link) has the name (O_EXCL). The
    // result is the path of the temporary file. On a failure the temporary file goes, and the
    // text names shown.
    private static func writeTemporary(
        _ data: Data, besides path: String, mode: mode_t, shown: String
    ) throws(IntegrationFailure) -> String {
        let temporary = WriteSteps.uniqueTemporaryPath(path)
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard descriptor >= 0 else { throw .system(.system(.save, path: shown, code: errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            try handle.write(contentsOf: data)
            // The open applies the umask, so the mode is set again.
            if fchmod(descriptor, mode) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try WriteSteps.system.sync(handle)
            try handle.close()
        } catch {
            try? handle.close()
            unlink(temporary)
            throw .system(FileError(error, call: .save, path: shown))
        }
        return temporary
    }

    // Write the old bytes to backups/settings-<UTC time>.json with the mode 0600 and a full sync.
    // A name that exists, also a link, gets the next number: -1, -2 and so on. The rename never
    // replaces a file (RENAME_EXCL), so a backup is never written over. A missing folder and each
    // missing parent get the mode 0700. The result is the path of the backup.
    private static func writeBackup(_ bytes: Data, in folder: URL, now: Date)
        throws(IntegrationFailure) -> String
    {
        // The path of a folder URL ends with "/", and the text has no "/" at the end.
        var folderPath = folder.path(percentEncoded: false)
        if folderPath.count > 1, folderPath.hasSuffix("/") { folderPath.removeLast() }
        do {
            try FileManager.default.createDirectory(
                atPath: folderPath, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw .system(FileError(error, call: .createFolder, path: folderPath))
        }
        let base = folder.appending(path: "settings-\(stamp(now))", directoryHint: .notDirectory)
            .path(percentEncoded: false)
        let temporary = try writeTemporary(
            bytes, besides: "\(base).json", mode: 0o600, shown: "\(base).json")
        var number = 0
        while true {
            let target = number == 0 ? "\(base).json" : "\(base)-\(number).json"
            if renamex_np(temporary, target, UInt32(RENAME_EXCL)) == 0 { return target }
            let code = errno
            guard code == EEXIST else {
                unlink(temporary)
                throw .system(.system(.save, path: target, code: code))
            }
            number += 1
        }
    }

    // MARK: - The backup names

    // The UTC time of a backup name, in whole seconds: for example 20261104T153000Z.
    static func stamp(_ now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let whole = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: whole)
        func digits(_ value: Int?, _ count: Int) -> String {
            let text = String(value ?? 0)
            return String(repeating: "0", count: max(0, count - text.count)) + text
        }
        return digits(parts.year, 4) + digits(parts.month, 2) + digits(parts.day, 2) + "T"
            + digits(parts.hour, 2) + digits(parts.minute, 2) + digits(parts.second, 2) + "Z"
    }

    // The path of the newest backup in the folder, or nil when it has none. The time in the name
    // gives the order, and the number gives the order in the same second. A name in another form
    // is not a backup.
    private static func newestBackup(in folder: URL) -> String? {
        let path = folder.path(percentEncoded: false)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return nil
        }
        var best: (name: String, time: [UInt8], number: [UInt8])?
        for name in names {
            guard let (time, number) = backupParts(name) else { continue }
            if let current = best {
                let newer =
                    current.time.lexicographicallyPrecedes(time)
                    || (current.time == time && isLarger(number, than: current.number))
                guard newer else { continue }
            }
            best = (name, time, number)
        }
        return best.map {
            folder.appending(path: $0.name, directoryHint: .notDirectory)
                .path(percentEncoded: false)
        }
    }

    // The time and the number of a backup name: settings-<8 digits>T<6 digits>Z.json, or the
    // same with -<digits> after the time. The number of a name with no number is empty (0).
    private static func backupParts(_ name: String) -> (time: [UInt8], number: [UInt8])? {
        let bytes = Array(name.utf8)
        let prefix = Array("settings-".utf8)
        let suffix = Array(".json".utf8)
        guard bytes.count >= prefix.count + 16 + suffix.count, bytes.starts(with: prefix),
            bytes.reversed().starts(with: suffix.reversed())
        else { return nil }
        let middle = bytes[prefix.count..<(bytes.count - suffix.count)]
        let time = Array(middle.prefix(16))
        for (offset, byte) in time.enumerated() {
            let fits =
                switch offset {
                case 8: byte == UInt8(ascii: "T")
                case 15: byte == UInt8(ascii: "Z")
                default: isDigit(byte)
                }
            guard fits else { return nil }
        }
        let rest = middle.dropFirst(16)
        guard !rest.isEmpty else { return (time, []) }
        guard rest.count >= 2, rest.first == UInt8(ascii: "-"), rest.dropFirst().allSatisfy(isDigit)
        else { return nil }
        return (time, Array(rest.dropFirst()))
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    // True when the first number is larger than the second. Each is ASCII digits of any length.
    private static func isLarger(_ first: [UInt8], than second: [UInt8]) -> Bool {
        let zero = UInt8(ascii: "0")
        let first = first.drop { $0 == zero }
        let second = second.drop { $0 == zero }
        guard first.count == second.count else { return first.count > second.count }
        return second.lexicographicallyPrecedes(first)
    }
}
