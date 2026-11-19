// Open project, Copy session ID and Open the worktree (docs/behaviour/actions.md, "Open project,
// Copy session ID and Open the worktree"), and the open of the PR of Show Info
// (docs/behaviour/panels.md). The tests give a fake opener and a fake clipboard, so no test opens
// an app or a browser, or writes the real clipboard.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostSessions

private let rowId = "0f8fad5b-d9cb-469f-a165-70867728950e"
private let jobId = "7c9e6679-7425-40de-944b-e07fc1f90ae7"
private let newId = "16fd2706-8baf-433b-82eb-8c7fada847da"
private let wt = "/r/.claude/worktrees/fix-a"

private let zed = InstalledApp(
    app: ProjectApp(id: .zed, label: "Zed"), path: "/Applications/Zed.app")
private let finder = InstalledApp(
    app: ProjectApp(id: .finder, label: "Finder"),
    path: "/System/Library/CoreServices/Finder.app")

private func row(
    cwd: String = "/Users/u/p q", kind: SessionKind = .owned, state: SessionState = .idle
) -> SessionRow {
    SessionRow.test(sessionId: rowId, kind: kind, cwd: cwd, state: state)
}

@MainActor
private final class Harness {
    let opener: FakeOpener
    let clipboard = FakeClipboard()
    let actions: AppActions

    init(
        _ rows: [SessionRow], failure: ActionRefusal? = nil, packages: Set<String> = [],
        kinds: [String: FakeOpener.Kind] = [:]
    ) {
        opener = FakeOpener(failure: failure, packages: packages, kinds: kinds)
        actions = AppActions(
            rows: { rows }, apps: { [finder, zed] }, opener: opener, clipboard: clipboard)
    }

    func openProject(_ id: String = rowId, _ app: ProjectAppID = .zed) async -> ActionRefusal? {
        do throws(ActionRefusal) {
            try await actions.openProject(id, app)
            return nil
        } catch {
            return error
        }
    }

    func openWorktree(_ id: String = rowId) async -> ActionRefusal? {
        do throws(ActionRefusal) {
            try await actions.openWorktree(id)
            return nil
        } catch {
            return error
        }
    }

    func copy(_ id: String = rowId) -> ActionRefusal? {
        do throws(ActionRefusal) {
            try actions.copySessionId(id)
            return nil
        } catch {
            return error
        }
    }
}

@MainActor
@Suite("Open project")
struct OpenProjectTests {
    @Test func openProjectOpensTheFolderOfTheRowInTheApp() async {
        let h = Harness([row()])
        #expect(await h.openProject() == nil)
        #expect(h.opener.calls == [.open(file: "/Users/u/p q", app: "/Applications/Zed.app")])
    }

    @Test func openProjectWithFinderOpensAPlainFolderInFinder() async {
        let h = Harness([row()])
        #expect(await h.openProject(rowId, .finder) == nil)
        #expect(
            h.opener.calls == [
                .open(file: "/Users/u/p q", app: "/System/Library/CoreServices/Finder.app")
            ])
    }

    // Finder starts a folder that macOS treats as a package, so the folder only shows in Finder.
    @Test func openProjectWithFinderShowsAPackageFolderAndNeverOpensIt() async {
        let h = Harness([row(cwd: "/p/Tool.app")], packages: ["/p/Tool.app"])
        #expect(await h.openProject(rowId, .finder) == nil)
        #expect(h.opener.calls == [.reveal("/p/Tool.app")])
    }

    // Another app opens the folder itself, so the package rule is only for Finder.
    @Test func openProjectWithAnotherAppOpensAPackageFolderInThatApp() async {
        let h = Harness([row(cwd: "/p/Tool.app")], packages: ["/p/Tool.app"])
        #expect(await h.openProject() == nil)
        #expect(h.opener.calls == [.open(file: "/p/Tool.app", app: "/Applications/Zed.app")])
    }

    @Test func openProjectRefusesAnUnknownSession() async {
        let h = Harness([row()])
        #expect(await h.openProject("nope") == .unknownSession)
        #expect(h.opener.calls.isEmpty)
    }

    @Test(arguments: ["", "rel/p", " /p"])
    func openProjectNeedsAnAbsoluteFolder(cwd: String) async {
        let h = Harness([row(cwd: cwd)])
        #expect(await h.openProject() == .noProjectFolder)
        #expect(h.opener.calls.isEmpty)
    }

    @Test func openProjectRefusesAnAppThatIsNotInstalled() async {
        let h = Harness([row()])
        #expect(await h.openProject(rowId, .warp) == .unknownApp)
        #expect(h.opener.calls.isEmpty)
    }

    @Test func aFailedOpenGivesItsText() async {
        let h = Harness([row()], failure: .openFailed("No such app."))
        #expect(await h.openProject() == .openFailed("No such app."))
        #expect(ActionRefusal.openFailed("No such app.").message == "No such app.")
    }
}

// The copy is the ID that claude --resume needs to continue the session.
@MainActor
@Suite("Copy session ID")
struct CopySessionIdTests {
    @Test func theCopyOfAnOwnedRowIsItsResumeId() {
        var owned = row()
        owned.currentId = newId
        owned.resumeId = jobId
        let h = Harness([owned])
        #expect(h.copy() == nil)
        #expect(h.clipboard.texts == [jobId])
    }

    @Test func theCopyOfAnExternalRowIsItsCurrentId() {
        var external = row(kind: .external)
        external.currentId = newId
        let h = Harness([external])
        #expect(h.copy() == nil)
        #expect(h.clipboard.texts == [newId])
    }

    @Test func theCopyOfAnExternalRowWithNoClearIsItsRowId() {
        let h = Harness([row(kind: .external)])
        #expect(h.copy() == nil)
        #expect(h.clipboard.texts == [rowId])
    }

    // A resume by another ID starts a second job, so Bifrost copies nothing until it knows it.
    @Test func anOwnedRowWithNoResumeIdCopiesNothing() {
        var owned = row()
        owned.currentId = newId
        let h = Harness([owned])
        #expect(h.copy() == .noResumeId)
        #expect(h.clipboard.texts.isEmpty)
    }

    @Test func anUnknownSessionCopiesNothing() {
        let h = Harness([row()])
        #expect(h.copy("nope") == .unknownSession)
        #expect(h.clipboard.texts.isEmpty)
    }
}

// The Delete dialog can open the worktree of the session, so the user can look at the work.
@MainActor
@Suite("Open the worktree")
struct OpenWorktreeTests {
    @Test func theWorktreeOfTheRowOpensInFinder() async {
        let h = Harness([row(cwd: "\(wt)/src")])
        #expect(await h.openWorktree() == nil)
        #expect(
            h.opener.calls == [
                .open(file: wt, app: "/System/Library/CoreServices/Finder.app")
            ])
    }

    // Finder starts a worktree that macOS treats as a package, so it only shows in Finder.
    @Test func aWorktreeThatIsAPackageShowsInFinderAndNeverOpens() async {
        let app = "/r/.claude/worktrees/x.app"
        let h = Harness([row(cwd: app)], packages: [app])
        #expect(await h.openWorktree() == nil)
        #expect(h.opener.calls == [.reveal(app)])
    }

    // A stopped session reports its start folder. Then the stored worktree opens.
    @Test func theStoredWorktreeOfAStoppedSessionOpens() async {
        var parked = row(cwd: "/p", state: .parked)
        parked.worktree = wt
        let h = Harness([parked])
        #expect(await h.openWorktree() == nil)
        #expect(h.opener.calls.map(\.file) == [wt])
    }

    @Test func aRowWithNoWorktreeIsRefused() async {
        let h = Harness([row(cwd: "/r")])
        #expect(await h.openWorktree() == .noWorktree)
        #expect(h.opener.calls.isEmpty)
    }

    @Test func anUnknownSessionIsRefused() async {
        let h = Harness([row(cwd: wt)])
        #expect(await h.openWorktree("nope") == .unknownSession)
        #expect(h.opener.calls.isEmpty)
    }

    // The worktree actions are for the Delete of a Bifrost session.
    @Test(arguments: [SessionState.idle, .parked])
    func anExternalSessionIsRefused(state: SessionState) async {
        let h = Harness([row(cwd: wt, kind: .external, state: state)])
        #expect(await h.openWorktree() == .deleteExternal)
        #expect(h.opener.calls.isEmpty)
    }

    @Test func aFailedOpenGivesItsText() async {
        let h = Harness([row(cwd: wt)], failure: .openFailed("The folder isn't there."))
        #expect(await h.openWorktree() == .openFailed("The folder isn't there."))
    }

    // Only a folder opens. A worktree path that is a file, that is missing, or whose check failed
    // is refused, and nothing opens.
    @Test func aWorktreePathThatIsNotAFolderIsRefused() async {
        for (kind, refusal) in [
            (FakeOpener.Kind.other, ActionRefusal.notAFolder(wt)), (.missing, .folderMissing(wt)),
            (.unreadable, .folderUnreadable(wt)), (.unknown, .folderUnchecked),
        ] {
            let h = Harness([row(cwd: wt)], kinds: [wt: kind])
            #expect(await h.openWorktree() == refusal)
            #expect(h.opener.calls.isEmpty)
        }
    }
}

@MainActor
@Suite("the kind check of an open")
struct OpenKindTests {
    // A project path that is a file, for example a .command file that Finder or Terminal would
    // run, never opens, in Finder or in another app.
    @Test(arguments: [ProjectAppID.finder, .zed])
    func aProjectPathThatIsAFileIsRefused(app: ProjectAppID) async {
        let file = "/p/run.command"
        let h = Harness([row(cwd: file)], kinds: [file: .other])
        #expect(await h.openProject(rowId, app) == .notAFolder(file))
        #expect(h.opener.calls.isEmpty)
    }

    @Test func aMissingProjectFolderAndAFailedCheckAreRefused() async {
        let h = Harness([row(cwd: "/p")], kinds: ["/p": .missing])
        #expect(await h.openProject() == .folderMissing("/p"))
        let slow = Harness([row(cwd: "/p")], kinds: ["/p": .unknown])
        #expect(await slow.openProject() == .folderUnchecked)
        #expect(h.opener.calls.isEmpty && slow.opener.calls.isEmpty)
    }

    // The open uses the folder with its links resolved, so a link opens its own folder.
    @Test func theOpenUsesTheResolvedFolder() async {
        let h = Harness([row(cwd: "/p/link")], kinds: ["/p/link": .link("/q/real")])
        #expect(await h.openProject() == nil)
        #expect(h.opener.calls == [.open(file: "/q/real", app: "/Applications/Zed.app")])
        #expect(await h.openProject(rowId, .finder) == nil)
        #expect(h.opener.calls.last?.file == "/q/real")
    }
}

// A click on the PR of Show Info opens the address of the PR lookup in the browser.
@MainActor
@Suite("Open the PR")
struct OpenPRTests {
    private static let json =
        #"{"number":12,"title":"Fix","url":"https://github.com/o/r/pull/12","state":"OPEN"}"#

    private func lookup(_ result: ExecResult) -> PRLookup {
        PRLookup(
            runner: FakeRunner(result), environment: [:], skipRoots: [], clock: ManualClock(),
            fileKind: { _ in .dir })
    }

    private func branched() -> SessionRow {
        var branched = row()
        branched.branch = "fix-a"
        return branched
    }

    private func openPR(_ h: Harness, _ lookup: PRLookup, _ id: String = rowId) async
        -> ActionRefusal?
    {
        do throws(ActionRefusal) {
            try await h.actions.openPR(id, with: lookup)
            return nil
        } catch {
            return error
        }
    }

    @Test func thePROpensInTheBrowser() async {
        let h = Harness([branched()])
        #expect(await openPR(h, lookup(ExecResult(.exited(0), stdout: Self.json))) == nil)
        #expect(h.opener.calls == [.browse("https://github.com/o/r/pull/12")])
    }

    @Test func aBranchWithNoPROpensNothing() async {
        let h = Harness([branched()])
        let none = lookup(ExecResult(.exited(1), stderr: "no pull requests found"))
        #expect(await openPR(h, none) == nil)
        #expect(h.opener.calls.isEmpty)
    }

    @Test func anUnknownSessionIsRefused() async {
        let h = Harness([branched()])
        let refusal = await openPR(
            h, lookup(ExecResult(.exited(0), stdout: Self.json)), "nope")
        #expect(refusal == .unknownSession)
        #expect(h.opener.calls.isEmpty)
    }

    @Test func aFailedOpenGivesItsText() async {
        let h = Harness([branched()], failure: .openFailed("No browser."))
        let refusal = await openPR(h, lookup(ExecResult(.exited(0), stdout: Self.json)))
        #expect(refusal == .openFailed("No browser."))
    }
}

extension FakeOpener.Call {
    // The file of an open, or nil for an activate.
    fileprivate var file: String? {
        if case .open(let file, _) = self { return file }
        return nil
    }
}
