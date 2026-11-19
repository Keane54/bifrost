// Open project, Copy session ID and Open the worktree (docs/behaviour/actions.md, "Open project,
// Copy session ID and Open the worktree"), and the open of the PR of Show Info
// (docs/behaviour/panels.md, "Show Info"). The callers give a session ID only. These actions find
// the row, the folder and the app themselves. openPR is the one call that also takes another
// value: the PR lookup of Show Info.
import BifrostFoundation
import Foundation

// What is at a path, after its symbolic links are resolved. A folder and a package give the
// resolved URL, which the open uses.
package enum PathKind: Sendable, Equatable {
    case folder(URL)
    // A folder that macOS treats as a package, for example a folder named x.app
    // (NSWorkspace.isFilePackage). Finder starts such a folder when it opens it.
    case package(URL)
    // A file or another item that is not a folder, for example a .command file that Finder or
    // Terminal would run.
    case other
    case missing
    // Something is at the path, but the check could not read it.
    case unreadable
    // The check did not end in AppActions.openTimeout.
    case unknown
}

// The opens of the session actions. The app gives the version with NSWorkspace in a UI folder,
// and a test gives a fake, so no test opens or activates an app. A Launch Services call and a
// read of a path of the conformer run on BlockingExecutor, and a kind check, an open and an
// activate give up after AppActions.openTimeout. A failed open throws openFailed with the text
// of the failure.
@MainActor
package protocol AppOpener: AnyObject {
    // Open the file or the folder in the app at the path of the bundle.
    func open(_ file: URL, with app: URL) async throws(ActionRefusal)
    // Start the app at the path of the bundle, or bring it to the front.
    func activate(_ app: URL) async throws(ActionRefusal)
    // What is at the path, with its links resolved. A read that fails gives unreadable, and a
    // check that does not end in time gives unknown.
    func kind(_ url: URL) async -> PathKind
    // Show the item selected in a Finder window, and never open it
    // (NSWorkspace.activateFileViewerSelecting).
    func reveal(_ url: URL)
    // Open the https address in the default browser (NSWorkspace.open). An address that is not
    // https throws openFailed(AppActions.httpsOnly) and opens nothing. The open gives up after
    // AppActions.openTimeout.
    func openInBrowser(_ url: URL) async throws(ActionRefusal)
}

// The clipboard of the system. The app gives the version with NSPasteboard in a UI folder.
@MainActor
package protocol Clipboard: AnyObject {
    func write(_ text: String)
}

@MainActor
package final class AppActions {
    // The time limit of an open (AppOpener).
    package static let openTimeout = Duration.seconds(10)
    // The refusal text of AppOpener.openInBrowser for an address that is not https.
    nonisolated package static let httpsOnly = "Bifrost only opens https addresses."

    private let rows: () -> [SessionRow]
    private let apps: () -> [InstalledApp]
    private let opener: any AppOpener
    private let clipboard: any Clipboard

    // rows: the rows in their one place. apps: the installed apps of Open project
    // (ProjectApps.projectApps).
    package init(
        rows: @escaping () -> [SessionRow], apps: @escaping () -> [InstalledApp],
        opener: any AppOpener, clipboard: any Clipboard
    ) {
        self.rows = rows
        self.apps = apps
        self.opener = opener
        self.clipboard = clipboard
    }

    // Copy the ID that "claude --resume" needs to continue the session (continueId). Bifrost
    // copies nothing while it does not know the resume ID of a background job.
    package func copySessionId(_ sessionId: String) throws(ActionRefusal) {
        guard let id = try row(sessionId).continueId else { throw .noResumeId }
        clipboard.write(id.text)
    }

    // Open the project folder of the session in an installed app. Only a folder opens: a path
    // that is a file, that is missing or that the check could not read is refused.
    package func openProject(_ sessionId: String, _ app: ProjectAppID) async throws(ActionRefusal) {
        let row = try row(sessionId)
        guard row.cwd.unicodeScalars.first == "/" else { throw .noProjectFolder }
        guard let installed = apps().first(where: { $0.app.id == app }) else {
            throw .unknownApp
        }
        let folder = try await checkedFolder(row.cwd)
        if app == .finder { return try await openInFinder(folder) }
        try await opener.open(folder.url, with: Self.folder(installed.path))
    }

    // Open the PR of the branch of the session in the browser. The address comes from the PR
    // lookup, which runs gh again when its answer is not fresh (PRLookup.urlToOpen), so only an
    // https address from gh opens. A session with no PR opens nothing.
    package func openPR(_ sessionId: String, with lookup: PRLookup) async throws(ActionRefusal) {
        let row = try row(sessionId)
        guard let url = await lookup.urlToOpen(row) else { return }
        try await opener.openInBrowser(url)
    }

    // Open the worktree of the session in Finder, so the user can look at the work before a
    // Delete. Only the Delete of a Bifrost session uses it, so an external session is refused.
    // The worktree comes from the folder of the row, else from the worktree that Bifrost stored
    // while the session ran.
    package func openWorktree(_ sessionId: String) async throws(ActionRefusal) {
        let row = try row(sessionId)
        if row.kind == .external { throw .deleteExternal }
        guard let root = WorktreeRoot(cwd: row.cwd, stored: row.worktree) else {
            throw .noWorktree
        }
        try await openInFinder(checkedFolder(root.worktree))
    }

    // A folder of an open, with its links resolved.
    private struct CheckedFolder {
        var url: URL
        var package: Bool
    }

    // The kind check of the path. Only a folder or a package passes. The check fails closed: a
    // file, a missing path, a path that the check cannot read and a check that does not end in
    // time are refused.
    private func checkedFolder(_ path: String) async throws(ActionRefusal) -> CheckedFolder {
        switch await opener.kind(Self.folder(path)) {
        case .folder(let url): return CheckedFolder(url: url, package: false)
        case .package(let url): return CheckedFolder(url: url, package: true)
        case .other: throw .notAFolder(path)
        case .missing: throw .folderMissing(path)
        case .unreadable: throw .folderUnreadable(path)
        case .unknown: throw .folderUnchecked
        }
    }

    // Open the folder in Finder. Finder starts a folder that macOS treats as a package as an
    // app, so such a folder only shows selected in a Finder window, and never opens.
    private func openInFinder(_ folder: CheckedFolder) async throws(ActionRefusal) {
        if folder.package {
            opener.reveal(folder.url)
            return
        }
        try await opener.open(folder.url, with: Self.folder(ProjectApps.finderPath))
    }

    private func row(_ sessionId: String) throws(ActionRefusal) -> SessionRow {
        guard let row = rows().first(where: { $0.sessionId == sessionId }) else {
            throw .unknownSession
        }
        return row
    }

    // The URL of a folder or of an app bundle, which is a folder too.
    nonisolated package static func folder(_ path: String) -> URL {
        URL(filePath: path, directoryHint: .isDirectory)
    }
}
