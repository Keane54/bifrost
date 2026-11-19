// The kind check of the opener of the app (WorkspaceOpener.kind): a folder, a package (macOS
// treats a folder named x.app as one), a file, a missing path, and the same through a symbolic
// link. A check that does not end in time fails closed. The test only reads items in a temporary
// folder. A failed app check refuses the start and the open. The browser open refuses an address
// that is not https. The tests open, start and show nothing.
import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostWindows

@Suite("the opener of the apps", .timeLimit(.minutes(1)))
@MainActor
struct WorkspaceAppsTests {
    @Test func theKindComesFromTheResolvedPath() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let files = FileManager.default
        // The real path of the folder: the temporary folder of macOS is under a link.
        let realPath = try #require(RealPath.of(folder.path))
        let real = URL(filePath: realPath, directoryHint: .isDirectory)
        let plain = real.appending(path: "plain", directoryHint: .isDirectory)
        let package = real.appending(path: "x.app", directoryHint: .isDirectory)
        let file = real.appending(path: "run.command", directoryHint: .notDirectory)
        try files.createDirectory(at: plain, withIntermediateDirectories: false)
        try files.createDirectory(at: package, withIntermediateDirectories: false)
        #expect(files.createFile(atPath: file.path, contents: Data("#!/bin/sh\n".utf8)))
        let toPackage = real.appending(path: "to-package", directoryHint: .isDirectory)
        let toFile = real.appending(path: "to-file", directoryHint: .isDirectory)
        try files.createSymbolicLink(at: toPackage, withDestinationURL: package)
        try files.createSymbolicLink(at: toFile, withDestinationURL: file)
        let opener = WorkspaceOpener()
        #expect(await opener.kind(plain) == .folder(plain))
        #expect(await opener.kind(package) == .package(package))
        #expect(await opener.kind(file) == .other)
        // A link counts as the item that it points to, and the result is the real path.
        #expect(await opener.kind(toPackage) == .package(package))
        #expect(await opener.kind(toFile) == .other)
        #expect(await opener.kind(real.appending(path: "none")) == .missing)
        // A folder below a folder with no permissions can't be read.
        let closed = real.appending(path: "closed", directoryHint: .isDirectory)
        let inner = closed.appending(path: "inner", directoryHint: .isDirectory)
        try files.createDirectory(at: inner, withIntermediateDirectories: true)
        try files.setAttributes([.posixPermissions: 0o000], ofItemAtPath: closed.path)
        defer { try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: closed.path) }
        #expect(await opener.kind(inner) == .unreadable)
    }

    // A read that does not end in openTimeout gives unknown, so AppActions refuses the open.
    @Test func aKindCheckThatDoesNotEndFailsClosed() async {
        let gate = TestGate()
        defer { gate.openAll() }
        let clock = ManualClock()
        let opener = WorkspaceOpener(clock: clock) { url in
            gate.passBlocking()
            return .folder(url)
        }
        let check = Task { await opener.kind(URL(filePath: "/p", directoryHint: .isDirectory)) }
        await gate.waitUntilHolding()
        await clock.waitForSleepers(1)
        clock.advance(by: AppActions.openTimeout)
        #expect(await check.value == .unknown)
    }

    // A failed app check refuses the start and the open with the text of the check, and nothing
    // starts or opens. The URL is in no folder, so even an open would find no app.
    @Test func aFailedAppCheckOpensAndStartsNothing() async throws {
        let checked = Recorder<String>()
        let opener = WorkspaceOpener(appCheck: { url in
            checked.record(url.path(percentEncoded: false))
            return false
        })
        let app = URL(filePath: "/nonexistent-bifrost-test/Fake.app", directoryHint: .isDirectory)
        let refusal = ActionRefusal.openFailed(WorkspaceOpener.notAnApp)
        await #expect(throws: refusal) { try await opener.activate(app) }
        await #expect(throws: refusal) {
            try await opener.open(URL(filePath: "/nonexistent-bifrost-test/file"), with: app)
        }
        let path = app.path(percentEncoded: false)
        #expect(checked.values == [path, path])
    }

    // An address that is not https throws before the open, so the test opens nothing.
    @Test func theBrowserOpenRefusesAnAddressThatIsNotHttps() async throws {
        let opener = WorkspaceOpener()
        for text in ["http://example.invalid/pr/1", "file:///tmp", "javascript:alert(1)"] {
            let url = try #require(URL(string: text))
            await #expect(throws: ActionRefusal.openFailed(AppActions.httpsOnly)) {
                try await opener.openInBrowser(url)
            }
        }
    }
}
