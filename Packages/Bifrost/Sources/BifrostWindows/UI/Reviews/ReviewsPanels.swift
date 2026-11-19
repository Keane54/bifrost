// The body of the Reviews panel (docs/behaviour/reviews.md, "The panel"). There is one Reviews
// panel, so the part has at most one body: a host of the SwiftUI panel with its model. The body
// runs its display clock while it is in a frame, and a release stops it. The part also holds the
// trust panel (TrustPanels), which the Trust buttons of the panel open, and gives the bodies of
// the Review panel (ReviewDraftPanels), which Comment and Request changes open, and of the Answer
// panel (AnswerPanels), which Answer Claude opens. When Reviews stops, the part closes these three
// panels.
import AppKit
import BifrostFoundation
import BifrostLayout
import BifrostLook
import BifrostReviews
import BifrostSessions
import SwiftUI

@MainActor
package final class ReviewsPanels: PanelBodiesPart {
    // The values of the services and the calls of the panel. The shell sets the links that need
    // the window after its init.
    package let links: ReviewsPanelLinks
    // The trust panel. The shell adds it to the panel bodies.
    package let trust: TrustPanels
    // The Review panel and the Answer panel. This part gives their bodies.
    package let draft: ReviewDraftPanels
    package let answer: AnswerPanels
    private let opener: any AppOpener
    private let look: PanelLook
    private let menu: @MainActor () -> BifrostMenu?
    private let clock: any Clock<Duration>
    private let now: () -> Date
    private let zone: TimeZone
    private var host: ReviewsHost?

    // opener opens a PR in the browser, and menu gives the Bifrost menu of the window. The clock
    // runs the display clock of the body, and now gives the wall time.
    package init(
        links: ReviewsPanelLinks, opener: any AppOpener, look: PanelLook,
        menu: @escaping @MainActor () -> BifrostMenu?, clock: any Clock<Duration>,
        now: @escaping () -> Date, zone: TimeZone = .current
    ) {
        self.links = links
        self.opener = opener
        self.look = look
        self.menu = menu
        self.clock = clock
        self.now = now
        self.zone = zone
        trust = TrustPanels(links: links, look: look, clock: clock)
        draft = ReviewDraftPanels(links: links, look: look)
        answer = AnswerPanels(links: links, opener: opener, look: look)
        links.openDraft = { [weak draft] in draft?.open($0) }
        links.openAnswer = { [weak answer] in answer?.open($0) }
    }

    package func body(for panel: PanelID) -> NSView? {
        if let body = draft.body(for: panel) ?? answer.body(for: panel) { return body }
        guard panel == .reviews else { return nil }
        if let host { return host }
        let model = ReviewsPanelModel(
            links: links, opener: opener, look: look, menu: menu, clock: clock, now: now,
            zone: zone, openTrust: { [weak trust = self.trust] in trust?.open($0) })
        model.start()
        let host = ReviewsHost(rootView: ReviewsPanel(model: model))
        host.sizingOptions = []
        self.host = host
        return host
    }

    package func titleSuffix(for panel: PanelID) -> String? {
        draft.titleSuffix(for: panel) ?? answer.titleSuffix(for: panel)
    }

    // Reviews stopped (Watch GitHub off, a stop or the quit): the trust panel, the Review panel
    // and the Answer panel close.
    package func reviewsStopped() {
        trust.reviewsStopped()
        draft.reviewsStopped()
        answer.reviewsStopped()
    }

    // The panel is in no frame now: its body stops its clock and goes.
    package func releaseBody(for panel: PanelID) {
        draft.releaseBody(for: panel)
        answer.releaseBody(for: panel)
        guard panel == .reviews, let host else { return }
        host.rootView.model.stop()
        self.host = nil
    }

    // The model of the body while the panel is in a frame, or nil.
    package var shown: ReviewsPanelModel? { host?.rootView.model }
}

// The host of the Reviews panel. It never takes the first responder, and it is not in the Tab
// loop of the window. A right-click on a row, or a Control-click, opens the row menu at the click
// point. A Cmd+click on a row opens its PR on GitHub. The host never gives a system menu.
package final class ReviewsHost: PassiveHostingView<ReviewsPanel> {
    override package func rightMouseDown(with event: NSEvent) {
        if !showMenu(event) { super.rightMouseDown(with: event) }
    }

    override package func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags
        if flags.contains(.control), showMenu(event) { return }
        if flags.contains(.command), let pr = row(at: event) {
            rootView.model.click(pr, command: true)
            return
        }
        super.mouseDown(with: event)
    }

    override package func menu(for event: NSEvent) -> NSMenu? { nil }

    // The PR of the row under the event, or nil.
    package func row(at event: NSEvent) -> PRKey? {
        var point = convert(event.locationInWindow, from: nil)
        if !isFlipped { point.y = bounds.height - point.y }
        return rootView.frames.row(at: point)
    }

    // Show the row menu of the row under the event. False when no row is there.
    @discardableResult
    package func showMenu(_ event: NSEvent) -> Bool {
        guard let window, let pr = row(at: event) else { return false }
        rootView.model.showMenu(
            pr, at: window.convertPoint(toScreen: event.locationInWindow), in: window)
        return true
    }
}
