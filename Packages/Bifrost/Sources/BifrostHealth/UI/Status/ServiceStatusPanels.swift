// The body of the Service status panel (docs/behaviour/health.md, "Service status"): the values
// that the view shows (ServiceStatusModel), the part that makes the body (ServiceStatusPanels) and
// the host of the body.
//
// The panel reads the list of the monitor through Observation, so a new check shows at once. The
// time of the incident lines and of the since texts is the wall time when the canvas makes the
// body. Then a tick each 30 s on the injected clock gives a new time, until the canvas releases
// the body. The monitor runs for the whole app, so the panel starts and stops no check.
import AppKit
import BifrostFoundation
import BifrostLayout
import BifrostLook
import Observation
import SwiftUI

@MainActor
@Observable
package final class ServiceStatusModel {
    // The time between two ticks.
    nonisolated package static let tick = Duration.seconds(30)

    // The wall time of the texts.
    package private(set) var now: Date
    #if DEBUG
    // The form that the panel shows now, from its view, for a test. nil before the first layout.
    @ObservationIgnored package var shownForm: ServiceForm?
    #endif

    @ObservationIgnored private let monitor: ServiceStatusMonitor?
    @ObservationIgnored private let readMetrics: @MainActor () -> CanvasMetrics
    @ObservationIgnored private let wallNow: () -> Date
    @ObservationIgnored private let openURL: (URL) -> Void
    @ObservationIgnored package let zone: TimeZone
    @ObservationIgnored private let timer: TimerSlot

    // monitor is nil in a test home, which checks no status page.
    init(
        monitor: ServiceStatusMonitor?, metrics: @escaping @MainActor () -> CanvasMetrics,
        clock: any Clock<Duration>, now: @escaping () -> Date, zone: TimeZone,
        open: @escaping (URL) -> Void
    ) {
        self.monitor = monitor
        readMetrics = metrics
        wallNow = now
        self.zone = zone
        self.openURL = open
        timer = TimerSlot(clock: clock)
        self.now = now()
    }

    // False in a test home: the panel then says so, and shows no service.
    package var isChecking: Bool { monitor != nil }

    package var services: [ServiceStatus] { monitor?.services ?? [] }

    // The time of the newest check, or nil before the first check.
    package var checkedAt: Date? { services.compactMap(\.checkedAt).max() }

    package var metrics: CanvasMetrics { readMetrics() }

    package func openPage(_ id: ServiceID) { openURL(id.page) }

    #if DEBUG
    // The task of the timer of the next tick, or nil. A test waits for it.
    package var timerTask: Task<Void, Never>? { timer.task }
    #endif

    // Take the time of now, then tick each 30 s.
    func start() { advance() }

    func stop() { timer.stop() }

    private func advance() {
        now = wallNow()
        timer.start(after: Self.tick) { [weak self] in self?.advance() }
    }
}

// The body of the service-status panel: one host while the panel is in a frame.
@MainActor
package final class ServiceStatusPanels: PanelBodiesPart {
    package let model: ServiceStatusModel
    private var host: PassiveHostingView<ServiceStatusPanel>?

    // monitor gives the checks, or nil in a test home. open opens a status page: the app opens it
    // in the browser, and a test records it.
    package init(
        monitor: ServiceStatusMonitor?, metrics: @escaping @MainActor () -> CanvasMetrics,
        clock: any Clock<Duration>, now: @escaping () -> Date,
        zone: TimeZone = .autoupdatingCurrent,
        open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        model = ServiceStatusModel(
            monitor: monitor, metrics: metrics, clock: clock, now: now, zone: zone, open: open)
    }

    package func body(for panel: PanelID) -> NSView? {
        guard panel == .serviceStatus else { return nil }
        if let host { return host }
        model.start()
        let host = PassiveHostingView(rootView: ServiceStatusPanel(model: model))
        host.sizingOptions = []
        self.host = host
        return host
    }

    package func releaseBody(for panel: PanelID) {
        guard panel == .serviceStatus, host != nil else { return }
        host = nil
        model.stop()
    }
}
