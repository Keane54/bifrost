import AppKit
import BifrostDailyUpdate
import BifrostDictation
import BifrostFoundation
import BifrostHealth
import BifrostLayout
import BifrostLook
import BifrostSessions
import BifrostSettings
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostApp
@testable import BifrostWindows

// What's new at the start (docs/behaviour/updates.md, "What's new"): the version is stored at
// once, and the dialog waits for the setup and for a dialog that shows. Safety: the releases come
// from a file of a temporary folder, and no page opens.

private let page = URL(string: "https://github.com/example/bifrost/releases") ?? URL(filePath: "/")

private let releases = """
    [{"tag_name":"v1.1.0","published_at":"2026-11-10T09:00:00Z","draft":false,\
    "prerelease":false,"body":"New window.","html_url":"\(page.absoluteString)/tag/v1.1.0"}]
    """

@MainActor
private struct Parts {
    let folder: TemporaryFolder
    let host: ReleaseNotesHost
    let dialogs: DialogHost
    let store: SettingsStore
    let notesFile: URL

    init(lastSeen: String?, setupDone: Bool) async throws {
        UITestApp.prepare()
        folder = try TemporaryFolder()
        try Data(releases.utf8).write(to: folder.url.appending(path: "github-releases.json"))
        notesFile = folder.url.appending(path: "release-notes.json")
        if let lastSeen {
            try Data(#"{"lastSeenVersion":"\#(lastSeen)"}"#.utf8).write(to: notesFile)
        }
        let source = ReleaseNotesSource(
            fetcher: FileReleasesFetcher(file: folder.url.appending(path: "github-releases.json")),
            releasesPage: page, clock: ManualClock())
        host = ReleaseNotesHost(
            service: ReleaseNotesService(
                source: source, whatsNewFile: notesFile, log: Recorder<StoreEvent>()))
        dialogs = DialogHost(look: PanelLook(), clock: ManualClock())
        store = await SettingsStore.open(
            file: folder.url.appending(path: "settings.json"), log: Recorder<StoreEvent>())
        if setupDone { try await store.edit { $0.setupDone = true } }
    }

    var storedVersion: String? {
        guard let data = try? Data(contentsOf: notesFile),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["lastSeenVersion"] as? String
    }

    var shownView: ReleaseNotesView? {
        guard case .releaseNotes(let model) = dialogs.dialog else { return nil }
        return model.view
    }
}

@MainActor
@Suite("What's new at the start", .serialized, .timeLimit(.minutes(1)), .tags(.window))
struct ReleaseNotesHostTests {
    @Test func anUpdateOpensWhatsNewAfterTheVersionIsStored() async throws {
        let p = try await Parts(lastSeen: "1.0.0", setupDone: true)
        defer { p.folder.remove() }
        p.host.startWhatsNew(version: "1.1.0", settings: p.store, dialogs: p.dialogs)
        await waitUntil { p.shownView != nil }
        let range = WhatsNewRange(
            since: ReleaseVersion("1.0.0"), version: try #require(ReleaseVersion("1.1.0")))
        #expect(p.shownView == .whatsNew(range))
        #expect(p.storedVersion == "1.1.0")
    }

    @Test func theDialogWaitsForTheSetupToBeDone() async throws {
        let p = try await Parts(lastSeen: "1.0.0", setupDone: false)
        defer { p.folder.remove() }
        p.host.startWhatsNew(version: "1.1.0", settings: p.store, dialogs: p.dialogs)
        // The version is stored at once, and the dialog stays shut until the setup is done.
        await waitUntil { p.storedVersion == "1.1.0" }
        #expect(p.shownView == nil)
        try await p.store.edit { $0.setupDone = true }
        await waitUntil { p.shownView != nil }
    }

    @Test func theDialogWaitsForAnotherDialogToClose() async throws {
        let p = try await Parts(lastSeen: "1.0.0", setupDone: true)
        defer { p.folder.remove() }
        let text = ConfirmText(title: "A", body: "B", confirm: "Yes")
        let confirm = Task { await p.dialogs.confirm(text, openFolder: nil, onBusy: {}) }
        await waitUntil { p.dialogs.isOpen }
        p.host.startWhatsNew(version: "1.1.0", settings: p.store, dialogs: p.dialogs)
        await waitUntil { p.storedVersion == "1.1.0" }
        #expect(p.shownView == nil)
        p.dialogs.escape()
        #expect(await confirm.value == false)
        await waitUntil { p.shownView != nil }
    }

    @Test func aFreshInstallStoresTheVersionAndOpensNothing() async throws {
        let p = try await Parts(lastSeen: nil, setupDone: false)
        defer { p.folder.remove() }
        p.host.startWhatsNew(version: "1.1.0", settings: p.store, dialogs: p.dialogs)
        await p.host.whatsNew?.value
        #expect(p.storedVersion == "1.1.0")
        try await p.store.edit { $0.setupDone = true }
        #expect(p.shownView == nil)
    }

    @Test func theSameVersionOpensNothing() async throws {
        let p = try await Parts(lastSeen: "1.1.0", setupDone: true)
        defer { p.folder.remove() }
        p.host.startWhatsNew(version: "1.1.0", settings: p.store, dialogs: p.dialogs)
        await p.host.whatsNew?.value
        #expect(p.shownView == nil)
        // A second start changes nothing: only the first call of the process counts.
        let first = p.host.whatsNew
        p.host.startWhatsNew(version: "1.2.0", settings: p.store, dialogs: p.dialogs)
        #expect(p.host.whatsNew == first)
        #expect(p.storedVersion == "1.1.0")
    }

    @Test func theTestPortStateTellsTheDialog() async throws {
        let p = try await Parts(lastSeen: "1.0.0", setupDone: true)
        defer { p.folder.remove() }
        #expect(p.host.testPortState(of: p.dialogs) == .null)
        p.host.open(in: p.dialogs)
        await waitUntil {
            p.host.testPortState(of: p.dialogs).object?["load"]?.string == "loaded"
        }
        let state = p.host.testPortState(of: p.dialogs)
        #expect(state.object?["view"]?.string == "all")
        #expect(state.object?["title"]?.string == "Release notes")
        #expect(state.object?["versions"]?.array?.compactMap(\.string) == ["1.1.0"])
    }
}
