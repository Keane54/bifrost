// The body of the Performance panel (docs/behaviour/health.md, "The panel"): the values that the
// view shows (PerformancePanelModel), the host of the body that tells when the panel shows, and
// the part that makes the body (PerformancePanels).
//
// The panel reads the snapshot of the monitor through Observation, so each new snapshot shows at
// once. The panel shows while its body is in a window that is on the screen, in a frame that is
// not minimised, as the active tab. While it shows, the monitor ticks each 2 s and reads the Mac
// and the network. While it shows in the key window, the frame counter counts the frames of the
// body. The release of the body and the quit stop both.
import AppKit
import BifrostFoundation
import BifrostLayout
import BifrostLook
import BifrostSessions
import Observation
import SwiftUI

@MainActor
@Observable
package final class PerformancePanelModel {
    // The space between two reasons of the headline, in layout units (user decision, 2026-11-09).
    package static let reasonGap = 6.0

    @ObservationIgnored private let readSnapshot: @MainActor () -> PerformanceSnapshot
    @ObservationIgnored private let clearPast: @MainActor () -> Void
    @ObservationIgnored private let stopSession: @MainActor (SessionRow) -> Void
    @ObservationIgnored private let uiState: UIStateStore?
    @ObservationIgnored private let readStyle: @MainActor () -> PanelStyle
    // The time zone of the reset time of the GitHub points.
    @ObservationIgnored package let zone: TimeZone

    // snapshot reads the snapshot of the monitor, an observed value. clear removes the past
    // events. stop runs the Stop action of the app on the row, with its checks. uiState keeps the
    // choice of the Details row, or nil: then the row starts closed each time. style gives the
    // look at the Interface scale.
    package init(
        snapshot: @escaping @MainActor () -> PerformanceSnapshot,
        clear: @escaping @MainActor () -> Void,
        stop: @escaping @MainActor (SessionRow) -> Void, uiState: UIStateStore?,
        style: @escaping @MainActor () -> PanelStyle, zone: TimeZone = .autoupdatingCurrent
    ) {
        readSnapshot = snapshot
        clearPast = clear
        stopSession = stop
        self.uiState = uiState
        readStyle = style
        self.zone = zone
    }

    package var snapshot: PerformanceSnapshot { readSnapshot() }

    package var style: PanelStyle { readStyle() }

    package var headline: PerformanceHeadline { PerformanceHeadline(snapshot) }

    // Clear shows only while a reason comes from a past event.
    package var showsClear: Bool { snapshot.clearable }

    // Remove the past events. The monitor builds a new snapshot at once.
    package func clear() {
        clearPast()
    }

    // MARK: - The Details row

    // True while the Details row is open. Closed is the default.
    package var detailsOpen: Bool { PerformanceDetails.isOpen(uiState?.state.performance) }

    package func toggleDetails() {
        setDetailsOpen(!detailsOpen)
    }

    // Open or close the Details row. The UI state keeps the choice.
    package func setDetailsOpen(_ open: Bool) {
        guard let uiState, open != detailsOpen else { return }
        uiState.change { $0.performance = PerformanceDetails.value(open, in: $0.performance) }
    }

    // MARK: - Stop

    // Stop shows only for a session that Bifrost owns and that runs: an owned row that is not
    // parked. An external session never shows Stop.
    package func showsStop(_ row: SessionRow) -> Bool {
        ActionModel.rowClass(row) == .owned
    }

    // Run the Stop action of the app on the row of the session. The action does its own checks
    // with the row of now, and asks first.
    package func stop(_ session: SessionUse) {
        guard showsStop(session.row) else { return }
        stopSession(session.row)
    }
}

// The host of the body. It tells its owner each change that can change whether the body shows (a
// move to a window or out of it, a hide or an unhide of the body or of a frame above it, and a
// change of the occlusion of the window) and each change of the key state of the window.
@MainActor
final class PerformanceHost: PassiveHostingView<PerformancePanel> {
    var onChange: (@MainActor () -> Void)?
    // The task that follows the notifications of the window.
    private var windowFollow: Task<Void, Never>?

    // True while the body is in a window that is on the screen, with no hidden view above it. A
    // back tab is in no window, and a minimised frame is hidden.
    var shows: Bool {
        guard let window, !isHiddenOrHasHiddenAncestor else { return false }
        return window.isVisible && window.occlusionState.contains(.visible)
    }

    // True while the window of the body is the key window.
    var focused: Bool { window?.isKeyWindow ?? false }

    // A host that goes with no release leaves no follow of its window.
    isolated deinit {
        windowFollow?.cancel()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        followWindow()
        onChange?()
    }

    override func viewDidHide() {
        super.viewDidHide()
        onChange?()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        onChange?()
    }

    // End the follow of the window. The owner calls it when it releases the body.
    func stopFollowing() {
        endFollow()
        onChange = nil
    }

    // Follow the key state and the occlusion of the window of now, until the body moves to
    // another window or the owner stops it. One task follows the three notifications: a child
    // task of its group reads each of them.
    private func followWindow() {
        endFollow()
        guard let window, onChange != nil else { return }
        let center = NotificationCenter.default
        let streams = [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ].map { center.notifications(named: $0, object: window) }
        let report: @MainActor () -> Void = { [weak self] in self?.onChange?() }
        windowFollow = Task {
            await withDiscardingTaskGroup { group in
                for stream in streams {
                    group.addTask {
                        for await _ in stream { await report() }
                    }
                }
            }
        }
    }

    private func endFollow() {
        windowFollow?.cancel()
        windowFollow = nil
    }
}

// The body of the Performance panel: one host while the panel is in a frame.
@MainActor
package final class PerformancePanels: PanelBodiesPart {
    package let model: PerformancePanelModel
    private let monitor: PerformanceMonitor?
    private let counter: FrameRateCounter
    private var host: PerformanceHost?
    // True while the body shows, and true while it shows in the key window.
    private(set) var shows = false
    private(set) var counting = false

    // monitor gives the snapshots, or nil when the app has no monitor (a test of another part).
    // The other values go to the model (PerformancePanelModel.init). The frame counter runs on
    // the clock.
    package init(
        monitor: PerformanceMonitor?, uiState: UIStateStore?,
        stop: @escaping @MainActor (SessionRow) -> Void,
        style: @escaping @MainActor () -> PanelStyle, clock: any Clock<Duration>,
        zone: TimeZone = .autoupdatingCurrent
    ) {
        self.monitor = monitor
        model = PerformancePanelModel(
            snapshot: { monitor?.snapshot ?? .checking }, clear: { monitor?.clear() },
            stop: stop, uiState: uiState, style: style, zone: zone)
        counter = FrameRateCounter(
            clock: clock, report: { monitor?.frameRate($0) },
            stopped: { monitor?.frameCountStopped() })
    }

    package func body(for panel: PanelID) -> NSView? {
        guard panel == .performance else { return nil }
        if let host { return host }
        let host = PerformanceHost(rootView: PerformancePanel(model: model))
        host.sizingOptions = []
        host.onChange = { [weak self] in self?.viewChanged() }
        counter.attach(to: host)
        self.host = host
        viewChanged()
        return host
    }

    package func releaseBody(for panel: PanelID) {
        guard panel == .performance, let host else { return }
        host.stopFollowing()
        self.host = nil
        apply(shows: false, focused: false)
        counter.detach()
    }

    // The quit: the frame counter and its display link stop, and the host follows no window.
    package func stop() {
        releaseBody(for: .performance)
    }

    private func viewChanged() {
        apply(shows: host?.shows ?? false, focused: host?.focused ?? false)
    }

    // The monitor ticks each 2 s while the panel shows, and the frame counter counts while the
    // panel shows in the key window.
    private func apply(shows: Bool, focused: Bool) {
        if shows != self.shows {
            self.shows = shows
            monitor?.panelShown(shows)
        }
        let counting = shows && focused
        if counting != self.counting {
            self.counting = counting
            counter.setActive(counting)
        }
    }
}
