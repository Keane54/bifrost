import AppKit
import BifrostLook
import SwiftUI
import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostWindows

// The release notes dialog (docs/behaviour/updates.md, "Release notes"): the loading, failed,
// empty and list states, the two views, the buttons that open a page, and the open and close in
// the dialog host. Safety: the fetcher is a fake, and the page opens only through a recorder.

private final class FakeFetcher: ReleasesFetcher {
    private let answer = Mutex<Data?>(nil)
    let gate = TestGate()

    init(_ data: Data?) { answer.withLock { $0 = data } }

    func fetch() async -> Data? {
        await gate.pass()
        return answer.withLock { $0 }
    }
}

private let manyReleases = releasesAnswer(
    releaseJSON(tag: "v1.3.0", body: fullBody), releaseJSON(tag: "v1.2.0", body: "Two."),
    releaseJSON(tag: "v1.1.0", body: nil), releaseJSON(tag: "v1.0.0", body: "One."))

@MainActor
private final class Opened {
    var pages: [URL] = []
}

@MainActor
@Suite("release notes dialog", .timeLimit(.minutes(1)))
struct ReleaseNotesDialogTests {
    private func make(
        _ view: ReleaseNotesView, _ data: Data?, opened: Opened = Opened()
    ) -> (model: ReleaseNotesDialogModel, fetcher: FakeFetcher) {
        let fetcher = FakeFetcher(data)
        let source = ReleaseNotesSource(
            fetcher: fetcher, releasesPage: releasesPage, clock: ManualClock())
        let model = ReleaseNotesDialogModel(
            view: view, source: source, openURL: { opened.pages.append($0) })
        return (model, fetcher)
    }

    @Test func theTitleFollowsTheView() {
        let range = WhatsNewRange(since: nil, version: version("1.0.0"))
        #expect(make(.whatsNew(range), nil).model.title == "What's new")
        #expect(make(.all, nil).model.title == "Release notes")
    }

    @Test func theDialogLoadsWhileItWaits() async {
        let (model, fetcher) = make(.all, manyReleases)
        defer { fetcher.gate.openAll() }
        #expect(model.load == .loading)
        model.start()
        await fetcher.gate.waitUntilHolding()
        #expect(model.load == .loading)
        #expect(model.shown.isEmpty)
        #expect(!model.isEmpty)
        fetcher.gate.open()
        await model.loading?.value
        #expect(model.shown.count == 4)
    }

    @Test func aFailedLoadShowsTheFailedState() async {
        let (model, fetcher) = make(.all, nil)
        fetcher.gate.openAll()
        model.start()
        await model.loading?.value
        #expect(model.load == .failed)
        #expect(model.shown.isEmpty)
        #expect(!model.isEmpty)
        #expect(ReleaseNotesText.failed == "Couldn't load the release notes.")
    }

    @Test func aListWithNoReleaseToShowIsEmpty() async {
        let range = WhatsNewRange(since: nil, version: version("9.0.0"))
        let (model, fetcher) = make(.whatsNew(range), manyReleases)
        fetcher.gate.openAll()
        model.start()
        await model.loading?.value
        #expect(model.isEmpty)
        #expect(ReleaseNotesText.empty == "There are no release notes to show yet.")
        let none = make(.all, Data("[]".utf8))
        none.fetcher.gate.openAll()
        none.model.start()
        await none.model.loading?.value
        #expect(none.model.isEmpty)
    }

    @Test func releaseNotesShowsAllReleasesNewestFirst() async {
        let (model, fetcher) = make(.all, manyReleases)
        fetcher.gate.openAll()
        model.start()
        await model.loading?.value
        #expect(model.shown.map(\.version.description) == ["1.3.0", "1.2.0", "1.1.0", "1.0.0"])
        // A release with no summary and no shown section has the small internal text.
        #expect(model.shown[2].isInternalOnly)
        #expect(ReleaseNotesText.internal == "Small internal changes.")
    }

    @Test func whatsNewShowsTheReleasesSinceTheLastSeenVersion() async {
        let range = WhatsNewRange(since: version("1.0.0"), version: version("1.2.0"))
        let (model, fetcher) = make(.whatsNew(range), manyReleases)
        fetcher.gate.openAll()
        model.start()
        await model.loading?.value
        #expect(model.shown.map(\.version.description) == ["1.2.0", "1.1.0"])
    }

    @Test func theButtonsOpenOnlyAKnownPage() async {
        let opened = Opened()
        let (model, fetcher) = make(.all, manyReleases, opened: opened)
        // Before an answer, the Releases page opens, and no release page does.
        model.openPage(of: version("1.2.0"))
        #expect(opened.pages.isEmpty)
        model.openPage(of: nil)
        #expect(opened.pages == [releasesPage])
        fetcher.gate.openAll()
        model.start()
        await model.loading?.value
        model.openPage(of: version("1.2.0"))
        model.openPage(of: version("7.7.7"))
        #expect(opened.pages.map(\.absoluteString) == [
            releasesPage.absoluteString, releasePage("v1.2.0"),
        ])
    }

    @Test func theCloseCallsTheHostOnce() async {
        let (model, fetcher) = make(.all, manyReleases)
        defer { fetcher.gate.openAll() }
        await confirmation("the host hears the close", expectedCount: 1) { closed in
            model.onClose = { _ in closed() }
            model.start()
            model.close()
        }
    }

    // Each state draws: the list is taller than the loading line, and none of them is empty.
    @Test func eachStateDrawsItsBox() async {
        UITestApp.prepare()
        let style = PanelStyle(look: PanelLook())
        func height(_ model: ReleaseNotesDialogModel) -> CGFloat {
            let host = NSHostingView(rootView: ReleaseNotesDialogView(model: model, style: style))
            host.frame = NSRect(x: 0, y: 0, width: 560, height: 800)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        let loaded = make(.all, manyReleases)
        loaded.fetcher.gate.openAll()
        let failed = make(.all, nil)
        failed.fetcher.gate.openAll()
        let empty = make(.all, Data("[]".utf8))
        empty.fetcher.gate.openAll()
        let loading = height(loaded.model)
        for made in [loaded, failed, empty] {
            made.model.start()
            await made.model.loading?.value
        }
        #expect(loading > 0)
        #expect(height(failed.model) > loading)
        #expect(height(empty.model) > loading)
        #expect(height(loaded.model) > height(failed.model))
    }

    // The host shows the dialog, and Esc and a click on the backdrop close it.
    @Test func theHostOpensAndClosesTheDialog() async {
        UITestApp.prepare()
        let host = DialogHost(look: PanelLook(), clock: ManualClock())
        let opened = Opened()
        host.openURL = { opened.pages.append($0) }
        let fetcher = FakeFetcher(manyReleases)
        fetcher.gate.openAll()
        let source = ReleaseNotesSource(
            fetcher: fetcher, releasesPage: releasesPage, clock: ManualClock())
        #expect(host.releaseNotes(.all, source: source))
        guard case .releaseNotes(let shown) = host.dialog else {
            Issue.record("The release notes dialog does not show.")
            return
        }
        // A second dialog does not open over it.
        #expect(!host.releaseNotes(.all, source: source))
        await shown.loading?.value
        shown.openPage(of: nil)
        #expect(opened.pages == [releasesPage])
        host.escape()
        #expect(host.dialog == nil)
        #expect(host.releaseNotes(.all, source: source))
        host.backdropClick()
        #expect(host.dialog == nil)
    }
}
