// The body of the Usage HUD panel (docs/behaviour/usage.md, "The Usage HUD"): the values that the
// view shows (UsageHUD), the part that makes the body (UsageHUDPanels) and the host of the body
// (UsageHUDHost).
//
// The HUD reads the session snapshot of the registry and the account values of the poller through
// Observation, so a new value shows at once. The time of the bars is the wall time when the
// canvas makes the body. Then a tick each 30 s on the injected clock gives a new time, until the
// canvas releases the body. A new value does not change the time.
//
// The HUD asks the account poller for a poll each time it shows: when the host comes into a
// window and no view around it is hidden, and when the window shows again after a close. So a
// frame that comes back from the side bar and a tab that becomes the active tab again also ask.
// The poller polls at most one time in a minute (AccountPoller.hudOpened), and a test home has no
// poller.
import AppKit
import BifrostFoundation
import BifrostLayout
import BifrostLook
import Observation
import SwiftUI

// The values of the Usage HUD: the bars and the source line of UsageView.of at the time of the
// HUD, and the metrics of the interface scale.
@MainActor
@Observable
package final class UsageHUD {
    // The time between two ticks.
    nonisolated package static let tick = Duration.seconds(30)

    // The time of the bars, in milliseconds since 1970.
    package private(set) var now: Int

    @ObservationIgnored private let usage: () -> UsageSnapshot?
    @ObservationIgnored private let poller: () -> AccountPoller?
    @ObservationIgnored private let readMetrics: @MainActor () -> CanvasMetrics
    @ObservationIgnored private let wallNow: () -> Date
    @ObservationIgnored private let zone: TimeZone
    @ObservationIgnored private let timer: TimerSlot

    init(
        usage: @escaping () -> UsageSnapshot?, poller: @escaping () -> AccountPoller?,
        metrics: @escaping @MainActor () -> CanvasMetrics, clock: any Clock<Duration>,
        now: @escaping () -> Date, zone: TimeZone
    ) {
        self.usage = usage
        self.poller = poller
        readMetrics = metrics
        wallNow = now
        self.zone = zone
        timer = TimerSlot(clock: clock)
        self.now = now().millisecondsSince1970
    }

    // The bars and the source line.
    package var content: (bars: [UsageBar], source: String) {
        UsageView.of(usage(), now: now, account: poller()?.value, zone: zone)
    }

    package var metrics: CanvasMetrics { readMetrics() }

    #if DEBUG
    // The task of the timer of the next tick, or nil. A test waits for it.
    package var timerTask: Task<Void, Never>? { timer.task }
    #endif

    // Take the time of now, then tick each 30 s.
    func start() {
        advance()
    }

    func stop() {
        timer.stop()
    }

    // The HUD shows. Ask the poller for a poll.
    func shown() {
        poller()?.hudOpened()
    }

    private func advance() {
        now = wallNow().millisecondsSince1970
        timer.start(after: Self.tick) { [weak self] in self?.advance() }
    }
}

// The body of the usage-hud panel: one host while the panel is in a frame.
@MainActor
package final class UsageHUDPanels: PanelBodiesPart {
    package let hud: UsageHUD
    // A click on a usage notification calls these two. The shell sets them: showWindow shows the
    // window, and openPanel opens a panel or brings its frame to the front.
    package var showWindow: () -> Void = {}
    package var openPanel: (PanelID) -> Void = { _ in }
    private var host: UsageHUDHost?

    // usage gives the session snapshot of the registry. poller gives the account poller, or nil
    // (a test home, or before the start of the services). metrics gives the metrics of the
    // interface scale. Each closure reads observed values.
    package init(
        usage: @escaping () -> UsageSnapshot?, poller: @escaping () -> AccountPoller?,
        metrics: @escaping @MainActor () -> CanvasMetrics, clock: any Clock<Duration>,
        now: @escaping () -> Date, zone: TimeZone = .autoupdatingCurrent
    ) {
        hud = UsageHUD(
            usage: usage, poller: poller, metrics: metrics, clock: clock, now: now, zone: zone)
    }

    package func body(for panel: PanelID) -> NSView? {
        guard panel == .usageHud else { return nil }
        if let host { return host }
        hud.start()
        let host = UsageHUDHost(rootView: UsageHUDPanel(hud: hud))
        host.sizingOptions = []
        host.onShow = { [hud] in hud.shown() }
        self.host = host
        return host
    }

    package func releaseBody(for panel: PanelID) {
        guard panel == .usageHud, host != nil else { return }
        host = nil
        hud.stop()
    }

    // A click on a usage notification shows the window, then opens the Usage HUD or brings it to
    // the front.
    package func notificationClicked() {
        showWindow()
        openPanel(.usageHud)
    }

    // The window shows again: the views of a closed window stay in it, so the host gets no new
    // move into a window. A HUD that shows asks for a poll, as at its own show.
    package func windowShown() {
        host?.showIfVisible()
    }
}

// The host of the Usage HUD. It never takes the first responder, and it is not in the Tab loop of
// the window. It calls onShow each time it shows: it comes into a window, or a hidden view around
// it (a minimised frame) shows again, and the host is then in a window with no hidden view around
// it.
package final class UsageHUDHost: PassiveHostingView<UsageHUDPanel> {
    var onShow: () -> Void = {}

    override package func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        showIfVisible()
    }

    override package func viewDidUnhide() {
        super.viewDidUnhide()
        showIfVisible()
    }

    // Call onShow when the host is in a window and no view around it is hidden.
    func showIfVisible() {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return }
        onShow()
    }
}
