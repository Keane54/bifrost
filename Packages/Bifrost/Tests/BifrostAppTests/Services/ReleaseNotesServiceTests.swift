import BifrostFoundation
import BifrostHealth
import BifrostTestSupport
import BifrostWindows
import Foundation
import Testing

@testable import BifrostApp

// The release notes service: the source of the plan (the file of a test home, or GitHub) and
// What's new at the start. Safety: no request goes out. The source of the app is made and not
// used, and a test home reads a file.

private let page = URL(string: "https://github.com/example/bifrost/releases") ?? URL(filePath: "/")

private func development() throws -> AppIdentity {
    try #require(AppIdentity(bundleID: "com.example.app.native-dev"))
}

private func release() throws -> AppIdentity {
    try #require(AppIdentity(bundleID: "com.example.app"))
}

private func plan(_ identity: AppIdentity, home: URL, testHome: Bool) -> StartPlan {
    StartPlan(
        identity: identity, home: home, realHome: home, testHome: testHome,
        folders: DataFolders(identity: identity, home: home))
}

@MainActor
@Suite("release notes service", .testTimeLimit)
struct ReleaseNotesServiceTests {
    private func service(source: ReleaseNotesSource, file: URL?) -> ReleaseNotesService {
        ReleaseNotesService(source: source, whatsNewFile: file, log: Recorder<StoreEvent>())
    }

    @Test func noPageGivesNoSource() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let plan = plan(try development(), home: folder.url, testHome: true)
        #expect(
            ReleaseNotesService.source(plan: plan, releasesPage: nil, clock: ManualClock())
                == nil)
    }

    // A test home reads github-releases.json of the home, so a test run reaches no network.
    @Test func aTestHomeReadsItsFile() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let body = """
            [{"tag_name":"v1.2.0","published_at":"2026-11-10T09:00:00Z","draft":false,\
            "prerelease":false,"body":"Fixture.",\
            "html_url":"\(page.absoluteString)/tag/v1.2.0"}]
            """
        try Data(body.utf8).write(to: folder.url.appending(path: "github-releases.json"))
        let plan = plan(try development(), home: folder.url, testHome: true)
        let source = try #require(
            ReleaseNotesService.source(plan: plan, releasesPage: page, clock: ManualClock())
        )
        let releases = await source.list()
        #expect(releases?.map(\.version.description) == ["1.2.0"])
        #expect(releases?.first?.summary == "Fixture.")
    }

    @Test func aMissingFileOfATestHomeCouldNotLoad() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let plan = plan(try development(), home: folder.url, testHome: true)
        let source = try #require(
            ReleaseNotesService.source(plan: plan, releasesPage: page, clock: ManualClock())
        )
        #expect(await source.list() == nil)
    }

    @Test func theReleaseAppMakesTheSourceOfGitHub() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let plan = plan(try release(), home: folder.url, testHome: false)
        #expect(
            ReleaseNotesService.source(plan: plan, releasesPage: page, clock: ManualClock())
                != nil)
        // A page of another form has no API address.
        let other = URL(string: "https://example.invalid/releases") ?? page
        #expect(
            ReleaseNotesService.source(plan: plan, releasesPage: other, clock: ManualClock())
                == nil)
    }

    @Test func whatsNewNeedsAFile() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = folder.url.appending(path: "release-notes.json")
        let source = ReleaseNotesSource(
            fetcher: FileReleasesFetcher(file: folder.url.appending(path: "none.json")),
            releasesPage: page, clock: ManualClock())
        // No file: Bifrost Dev never opens it by itself, and nothing is written.
        let dev = service(source: source, file: nil)
        #expect(await dev.whatsNew(current: "1.0.0", setupDone: true) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }

    @Test func whatsNewDecidesOnceAndStoresTheVersion() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = folder.url.appending(path: "release-notes.json")
        try Data(#"{"lastSeenVersion":"1.0.0"}"#.utf8).write(to: file)
        let source = ReleaseNotesSource(
            fetcher: FileReleasesFetcher(file: folder.url.appending(path: "none.json")),
            releasesPage: page, clock: ManualClock())
        let notes = service(source: source, file: file)
        let range = await notes.whatsNew(current: "1.1.0", setupDone: true)
        #expect(range?.version.description == "1.1.0")
        #expect(range?.since?.description == "1.0.0")
        #expect(await notes.whatsNew(current: "1.1.0", setupDone: true) == nil)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("1.1.0"))
    }

    // The file of What's new reports a failed save to its log, as each store does. The app gives
    // the health log of its stores (AppServices).
    @Test func aFailedSaveOfWhatsNewReachesTheLog() async throws {
        let folder = try TemporaryFolder()
        let file = folder.url.appending(path: "release-notes.json")
        try Data(#"{"lastSeenVersion":"1.0.0"}"#.utf8).write(to: file)
        // The folder refuses each new file, so the safe write fails.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: folder.url.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: folder.url.path(percentEncoded: false))
            folder.remove()
        }
        let source = ReleaseNotesSource(
            fetcher: FileReleasesFetcher(file: folder.url.appending(path: "none.json")),
            releasesPage: page, clock: ManualClock())
        let log = Recorder<StoreEvent>()
        let notes = ReleaseNotesService(source: source, whatsNewFile: file, log: log)
        _ = await notes.whatsNew(current: "1.1.0", setupDone: true)
        let failed = log.values.contains { if case .saveFailed = $0 { true } else { false } }
        #expect(failed)
    }
}
