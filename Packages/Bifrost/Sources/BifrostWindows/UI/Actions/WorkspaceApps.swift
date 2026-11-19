// The opens and the clipboard of the session actions with NSWorkspace and NSPasteboard
// (docs/behaviour/actions.md, "The apps of a session"). AppActions and TerminalLauncher take them
// as AppOpener and Clipboard, and the tests give fakes, so no test opens or starts an app.
//
// - Each read of a path and each Launch Services call runs on BlockingExecutor, and a kind check,
//   an open and a start each give up after AppActions.openTimeout.
// - The kind of a path comes from the path with its symbolic links resolved, so a link to x.app
//   is x.app, and a link to a file is a file.
// - The kind check fails closed: a read that fails gives unreadable, a check that does not end in
//   time gives unknown, and AppActions refuses the open.
// - Only an application bundle with an executable opens a file or starts: a folder that is not
//   an app never runs. The check of the app runs inside the time limit too.
import AppKit
import BifrostChat
import BifrostFoundation
import BifrostSessions
import UniformTypeIdentifiers

@MainActor
package final class WorkspaceOpener: AppOpener {
    private let clock: any Clock<Duration>
    // The read of the kind of a path. A test gives one that waits, to prove the time limit.
    private let inspect: @Sendable (URL) -> PathKind
    // The check that a URL is an application bundle with an executable. A test gives one that
    // fails, to prove that no open or start comes after a failed check.
    private let appCheck: @Sendable (URL) -> Bool

    package init(
        clock: any Clock<Duration> = ContinuousClock(),
        inspect: @escaping @Sendable (URL) -> PathKind = WorkspaceOpener.inspect,
        appCheck: @escaping @Sendable (URL) -> Bool = WorkspaceOpener.isApplication
    ) {
        self.clock = clock
        self.inspect = inspect
        self.appCheck = appCheck
    }

    // Open the file or the folder in the application at the path, and bring the application to
    // the front. The application starts when it does not run.
    package func open(_ file: URL, with app: URL) async throws(ActionRefusal) {
        try await limited(app: app) { done in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([file], withApplicationAt: app, configuration: configuration) {
                _, error in done(error)
            }
        }
    }

    // Bring the application at the path to the front. An application that does not run starts:
    // the clipboard launch of Open in terminal needs the terminal app. A URL that is not an
    // application bundle, for example a folder named x.app, never starts.
    package func activate(_ app: URL) async throws(ActionRefusal) {
        try await limited(app: app) { done in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) {
                _, error in done(error)
            }
        }
    }

    // What is at the path, with its links resolved. A check that does not end in openTimeout
    // gives unknown.
    package func kind(_ url: URL) async -> PathKind {
        let inspect = inspect
        return await race({ await BlockingExecutor.run { inspect(url) } }, timeout: .unknown)
    }

    // Show the item selected in a Finder window. Finder never opens it. The call runs off the
    // main actor.
    package func reveal(_ url: URL) {
        Task {
            await BlockingExecutor.run {
                NSWorkspace.shared.activateFileViewerSelecting([url.resolvingSymlinksInPath()])
            }
        }
    }

    // Open the https address in the default browser. An address that is not https opens nothing
    // and throws openFailed(AppActions.httpsOnly). The open gives up after openTimeout.
    package func openInBrowser(_ url: URL) async throws(ActionRefusal) {
        guard url.scheme?.lowercased() == "https" else { throw .openFailed(AppActions.httpsOnly) }
        try await limited(app: nil) { done in
            NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) {
                _, error in done(error)
            }
        }
    }

    // The kind of the path from its real path (FileFacts): a folder, a package or another item.
    // A path where nothing is gives missing, and a path that the reads cannot read (for example a
    // folder with no read permission above it) gives unreadable.
    nonisolated package static func inspect(_ url: URL) -> PathKind {
        let path = url.path(percentEncoded: false)
        guard let facts = FileFacts(atPath: path) else {
            var info = stat()
            if lstat(path, &info) == 0 { return .unreadable }
            return errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable
        }
        guard facts.isFolder else { return .other }
        let real = URL(filePath: facts.realPath, directoryHint: .isDirectory)
        return facts.isPackage ? .package(real) : .folder(real)
    }

    // MARK: - Private

    package static let notAnApp = "Bifrost can only open an app that macOS knows as an app."
    private static let tooSlow = "The app didn't open in time. Try again."

    // The check of the app (when the open names one), then the open with its completion handler,
    // both raced against openTimeout. An error of the open gives its text.
    private func limited(
        app: URL?,
        _ start: @escaping @MainActor (@escaping @Sendable ((any Error)?) -> Void) -> Void
    ) async throws(ActionRefusal) {
        typealias Continuation = CheckedContinuation<String?, Never>
        let appCheck = appCheck
        let failure: String? = await race(
            {
                if let app, !(await BlockingExecutor.run { appCheck(app) }) {
                    return Self.notAnApp
                }
                // The time limit ended during the check: the app never opens after the text of
                // the time limit shows.
                guard !Task.isCancelled else { return Self.tooSlow }
                return await withCheckedContinuation { (continuation: Continuation) in
                    start { error in continuation.resume(returning: error.map(Self.text)) }
                }
            }, timeout: Self.tooSlow)
        if let failure { throw .openFailed(failure) }
    }

    nonisolated private static func text(_ error: any Error) -> String {
        error.localizedDescription
    }

    // The value of the work, or the timeout value when the work does not end in openTimeout. A
    // work that does not end keeps its task until it ends, and its value goes nowhere.
    private func race<Value: Sendable>(
        _ work: @escaping @MainActor () async -> Value, timeout: Value
    ) async -> Value {
        let (first, input) = AsyncStream<Value>.makeStream()
        let run = Task {
            input.yield(await work())
        }
        let limit = Task { [clock] in
            do {
                try await clock.sleep(for: AppActions.openTimeout)
                input.yield(timeout)
            } catch {}
        }
        var values = first.makeAsyncIterator()
        let value = await values.next() ?? timeout
        input.finish()
        run.cancel()
        limit.cancel()
        return value
    }

    // True when the resolved URL is an application bundle with an executable. The check reads
    // the file system, so the opener runs it on BlockingExecutor.
    nonisolated package static func isApplication(_ app: URL) -> Bool {
        let resolved = app.resolvingSymlinksInPath()
        let values = try? resolved.resourceValues(forKeys: [.contentTypeKey])
        guard values?.contentType?.conforms(to: .applicationBundle) == true else { return false }
        return Bundle(url: resolved)?.executableURL != nil
    }
}

// The clipboard of the system.
@MainActor
package final class WorkspaceClipboard: Clipboard {
    package init() {}

    package func write(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }
}
