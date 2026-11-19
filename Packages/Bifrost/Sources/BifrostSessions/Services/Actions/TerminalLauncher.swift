// Open in terminal (docs/behaviour/actions.md, "Open in terminal"). An owned session attaches in
// a terminal app of the user. An external session brings its own terminal app to the front. The
// callers give a session ID only.
import BifrostFoundation
import Darwin
import Foundation
import OSLog

// How Bifrost starts the attach command in a terminal app. commandFile: the terminal app opens a
// shell script that runs the attach. clipboard: Bifrost copies the attach command, brings the
// terminal app to the front, and the user pastes the command.
package enum LaunchMethod: Sendable, Equatable {
    case commandFile, clipboard
}

extension TerminalAppID {
    // The launch method of the terminal app.
    package var launch: LaunchMethod {
        switch self {
        case .warp, .terminal: .commandFile
        case .ghostty, .iterm2: .clipboard
        }
    }
}

@MainActor
package final class TerminalLauncher {
    // The command file stays this long. Then Bifrost removes it.
    package static let scriptKeep = Duration.seconds(30)

    private static let logger = Logger(bifrost: "actions")

    private let rows: () -> [SessionRow]
    private let apps: () -> [InstalledApp]
    private let terminalOf: (String) -> TerminalApp?
    private let claudePath: () -> String?
    private let runFolder: URL
    private let opener: any AppOpener
    private let clipboard: any Clipboard
    private let clock: any Clock<Duration>
    // The timer that removes each command file, by the path of the file.
    private var removals: [String: TimerSlot] = [:]
    // The removal of the files of an earlier run of the app (removeOldFiles), or nil. A write of
    // a command file waits for its end.
    private var oldFiles: Task<Void, Never>?

    // rows: the rows in their one place. apps: the installed apps of Open project
    // (ProjectApps.projectApps), with one terminal app. terminalOf: the terminal app of an
    // external session (RegistryService.terminalOf). claudePath: the path of claude, or nil
    // when Bifrost cannot find it. runFolder: the run folder in the own dot folder of the app
    // (StartPlan.runFolder), which holds the command files.
    package init(
        rows: @escaping () -> [SessionRow], apps: @escaping () -> [InstalledApp],
        terminalOf: @escaping (String) -> TerminalApp?, claudePath: @escaping () -> String?,
        runFolder: URL, opener: any AppOpener, clipboard: any Clipboard,
        clock: any Clock<Duration>
    ) {
        self.rows = rows
        self.apps = apps
        self.terminalOf = terminalOf
        self.claudePath = claudePath
        self.runFolder = runFolder
        self.opener = opener
        self.clipboard = clipboard
        self.clock = clock
    }

    // Open the session in a terminal. The result is the notice for the user, or nil.
    package func openInTerminal(_ sessionId: String) async throws(ActionRefusal) -> String? {
        guard let row = rows().first(where: { $0.sessionId == sessionId }) else {
            throw .unknownSession
        }
        if row.state == .parked { throw .parked }
        if row.kind == .owned { return try await openOwned(row) }
        guard let terminal = terminalOf(row.sessionId) else { throw .terminalUnknown }
        try await opener.activate(AppActions.folder(terminal.bundle))
        return nil
    }

    // The shell script of the command file. The claude path goes in single quotes, and each
    // quote in it becomes '\''. The escape reads Unicode scalars, so a quote with a combining
    // mark after it is also escaped: the shell reads bytes, not Characters. The script takes a
    // ShortID, so only 8 hex digits can follow "attach".
    nonisolated package static func attachScript(claudePath: String, shortId: ShortID) -> String {
        var quoted = String.UnicodeScalarView()
        for scalar in claudePath.unicodeScalars {
            if scalar == "'" {
                quoted.append(contentsOf: #"'\''"#.unicodeScalars)
            } else {
                quoted.append(scalar)
            }
        }
        return "#!/bin/sh\nexec '\(String(quoted))' attach \(shortId.text)\n"
    }

    // The command that the user pastes into a terminal app with the clipboard launch method.
    nonisolated package static func attachCommand(_ shortId: ShortID) -> String {
        "claude attach \(shortId.text)"
    }

    // The task of the timer that removes the command file at the path, or nil. A test waits for
    // it.
    package func removal(of file: String) -> Task<Void, Never>? {
        removals[file]?.task
    }

    // Remove the files that an earlier run of the app left in the run folder: each command file
    // (attach-<short id>.command) and each temporary file of a write that did not end
    // (.attach-<short id>.command.<UUID>.tmp). The app calls this one time at the start. A
    // second call does nothing. The removal reads the folder off the main actor, with the checks
    // of the removal of one file, and a write of a command file waits for its end. So the
    // removal never removes a new file. The result is the task of the removal. hold runs before
    // the removal: a test holds the removal on a gate.
    @discardableResult
    package func removeOldFiles(
        hold: @escaping @Sendable () async -> Void = {}
    ) -> Task<Void, Never> {
        if let oldFiles { return oldFiles }
        let folder = Self.withoutLastSlashes(runFolder.path(percentEncoded: false))
        let task = Task {
            await hold()
            await Self.removeOldFiles(in: folder)
        }
        oldFiles = task
        return task
    }

    // True for the name of a command file or of a temporary file of a write.
    nonisolated package static func isOldFile(_ name: String) -> Bool {
        if let command = commandShortId(name) { return ShortID(command) != nil }
        guard name.hasPrefix("."), name.hasSuffix(".tmp") else { return false }
        let middle = name.dropFirst().dropLast(4)
        guard let dot = middle.lastIndex(of: "."),
            UUID(uuidString: String(middle[middle.index(after: dot)...])) != nil,
            let command = commandShortId(String(middle[..<dot]))
        else { return false }
        return ShortID(command) != nil
    }

    // The text between "attach-" and ".command" of the name of a command file, or nil.
    nonisolated private static func commandShortId(_ name: String) -> Substring? {
        let start = "attach-"
        let end = ".command"
        guard name.hasPrefix(start), name.hasSuffix(end),
            name.utf8.count > start.utf8.count + end.utf8.count
        else { return nil }
        return name.dropFirst(start.count).dropLast(end.count)
    }

    private func openOwned(_ row: SessionRow) async throws(ActionRefusal) -> String? {
        guard let shortId = row.shortId else { throw .badSessionId }
        // The first installed app of the terminal order.
        let installed = apps()
        let first = TerminalAppID.allCases.lazy.compactMap { id in
            installed.first { $0.app.id.terminal == id }
        }.first
        guard let app = first, let terminal = app.app.id.terminal else { throw .noTerminal }
        let bundle = AppActions.folder(app.path)
        switch terminal.launch {
        case .commandFile:
            // The removal of the old files must not remove the new file.
            await oldFiles?.value
            // The path goes to exec. A path that is not absolute can start with "-", and exec
            // reads such a word as an option.
            guard let claude = claudePath(), claude.unicodeScalars.first == "/",
                !claude.unicodeScalars.contains("\0")
            else { throw .claudeNotFound }
            let name = "attach-\(shortId.text).command"
            let folder = Self.withoutLastSlashes(runFolder.path(percentEncoded: false))
            let file = runFolder.appending(path: name, directoryHint: .notDirectory)
            let path = file.path(percentEncoded: false)
            // No old timer may remove the file between the write and the open.
            removals[path]?.stop()
            let text = Self.attachScript(claudePath: claude, shortId: shortId)
            let failure = await Self.writeCommandFile(text, name: name, in: folder)
            // The file of an earlier open also goes when this write fails.
            removeLater(path, name: name, in: folder)
            if let failure {
                Self.logger.error(
                    """
                    Bifrost cannot write the command file \
                    (error \(failure.code, privacy: .public)). \(path, privacy: .private)
                    """)
                throw .commandFileFailed
            }
            try await opener.open(file, with: bundle)
            return nil
        case .clipboard:
            let command = Self.attachCommand(shortId)
            clipboard.write(command)
            try await opener.activate(bundle)
            return "Copied \"\(command)\". Paste it into \(app.app.label) to open the session."
        }
    }

    // Remove the file after scriptKeep. A new timer for the same file replaces the old one. The
    // removal runs on the main actor with no wait, so no open of the same session runs between
    // the removal and the end of the timer.
    private func removeLater(_ path: String, name: String, in folder: String) {
        let slot = removals[path] ?? TimerSlot(clock: clock)
        removals[path] = slot
        slot.start(after: Self.scriptKeep) { [weak self] in
            Self.removeCommandFile(name, in: folder)
            self?.removals[path] = nil
        }
    }

    // The error number of a step of the write that failed.
    private struct WriteFailure: Error {
        var code: Int32
    }

    // Write the command file with mode 0700, or give the failure. The text goes to a new file with
    // a temporary name in the run folder, and a rename puts it at the name. Thus a link, a hard
    // link or a named pipe at the name never gets the write: the rename replaces the entry.
    @concurrent private static func writeCommandFile(
        _ text: String, name: String, in folder: String
    ) async -> WriteFailure? {
        let dir: Int32
        do {
            dir = try openRunFolder(folder)
        } catch {
            return error
        }
        defer { Darwin.close(dir) }
        let temp = ".\(name).\(UUID().uuidString).tmp"
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        let fd = Darwin.openat(dir, temp, flags, 0o700)
        guard fd >= 0 else { return WriteFailure(code: errno) }
        // The mode of the open goes through the umask, so the file gets its mode again.
        var failure = fchmod(fd, 0o700) == 0 ? writeAll(Array(text.utf8), to: fd) : errno
        if Darwin.close(fd) != 0 && failure == nil { failure = errno }
        if failure == nil && renameat(dir, temp, dir, name) != 0 { failure = errno }
        guard let failure else { return nil }
        unlinkat(dir, temp, 0)
        return WriteFailure(code: failure)
    }

    // Write each byte. The result is nil, or the error number of the write. A write that writes
    // no byte also fails, so the loop always ends.
    nonisolated private static func writeAll(_ bytes: [UInt8], to fd: Int32) -> Int32? {
        var done = 0
        while done < bytes.count {
            let count = bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(fd, base + done, bytes.count - done)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return errno
            }
            if count == 0 { return EIO }
            done += count
        }
        return nil
    }

    // Open the run folder, and make it with mode 0700 when it is missing. The folder must be a
    // real folder, not a link, and the user must own it. A folder that other users can use gets
    // mode 0700. The checks read the open folder, so a change of the path after the checks
    // cannot move the write.
    nonisolated private static func openRunFolder(_ folder: String) throws(WriteFailure) -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var dir = Darwin.open(folder, flags)
        if dir < 0 && errno == ENOENT {
            let parent = URL(filePath: folder).deletingLastPathComponent()
            try? FileManager.default.createDirectory(
                at: parent, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            guard mkdir(folder, 0o700) == 0 || errno == EEXIST else {
                throw WriteFailure(code: errno)
            }
            dir = Darwin.open(folder, flags)
        }
        guard dir >= 0 else { throw WriteFailure(code: errno) }
        do throws(WriteFailure) {
            let mode = try ownedFolderMode(dir)
            if mode & 0o077 != 0 && fchmod(dir, 0o700) != 0 { throw WriteFailure(code: errno) }
            return dir
        } catch {
            Darwin.close(dir)
            throw error
        }
    }

    // The mode of the open folder, when it is a real folder that the user owns. Else the
    // failure: the error number of fstat, or EPERM.
    nonisolated private static func ownedFolderMode(_ dir: Int32) throws(WriteFailure) -> mode_t {
        var info = stat()
        guard fstat(dir, &info) == 0 else { throw WriteFailure(code: errno) }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw WriteFailure(code: EPERM)
        }
        return info.st_mode
    }

    // Remove the command file. The removal uses the same checks of the run folder as the write:
    // the folder must be a real folder that the user owns, not a link. So a link at the place of
    // the run folder cannot point the removal at another folder. The removal does not change the
    // mode of the folder.
    private static func removeCommandFile(_ name: String, in folder: String) {
        let dir = Darwin.open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { return }
        defer { Darwin.close(dir) }
        guard (try? ownedFolderMode(dir)) != nil else { return }
        unlinkat(dir, name, 0)
    }

    // Remove the old files of the run folder. The folder must be a real folder that the user
    // owns, not a link, as for the removal of one file. A folder that is not there, or that the
    // removal cannot read, has nothing to remove. The names come first, then the removals.
    @concurrent private static func removeOldFiles(in folder: String) async {
        let dir = Darwin.open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { return }
        guard (try? ownedFolderMode(dir)) != nil, let stream = fdopendir(dir) else {
            Darwin.close(dir)
            return
        }
        // closedir closes dir too.
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if isOldFile(name) { names.append(name) }
        }
        for name in names { unlinkat(dirfd(stream), name, 0) }
    }

    // The path with no "/" at the end. A "/" at the end makes the system follow a link at the
    // last part of the path.
    private static func withoutLastSlashes(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
