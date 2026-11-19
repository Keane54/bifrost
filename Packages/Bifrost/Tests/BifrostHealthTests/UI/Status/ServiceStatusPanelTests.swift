// The Service status panel (docs/behaviour/health.md, "Service status"). Safety: the answers come
// from a fake fetcher, so no test reaches the network. The clock is a manual clock, and the
// panels open a status page through a recorder, so no test opens a browser.
import AppKit
import BifrostFoundation
import BifrostLayout
import BifrostLook
import BifrostTestSupport
import Foundation
import Synchronization
import SwiftUI
import Testing

@testable import BifrostHealth

private let start = wall(2026, 11, 18, 10, 5)

// Answers each URL from a table, and gives no answer for a URL that the table lacks.
private struct TableFetcher: StatusFetcher {
    let answers: [String: Data]

    func fetch(_ url: URL) async -> Data? { answers[url.absoluteString] }
}

@MainActor
private final class PanelFixture {
    let clock = ManualClock()
    let monitor: ServiceStatusMonitor
    let panels: ServiceStatusPanels
    let opened = Recorder<URL>()
    let window: NSWindow
    private(set) var host: PassiveHostingView<ServiceStatusPanel>?

    // Claude has a major outage since 09:03 (or is operational), GitHub is operational and Sentry
    // gives no answer. The first incident of Claude has the name.
    init(incident: String = "Elevated errors on the API", claudeDown: Bool = true) async throws {
        var answers: [String: Data] = [:]
        let claude = StatusPage.urls(.claude)
        answers[claude.status.absoluteString] = try fixture("status-none.json")
        answers[try #require(claude.components).absoluteString] = try fixture(
            claudeDown ? "components-api-partial.json" : "components-all-operational.json")
        let incidents = String(data: try fixture("incidents-major.json"), encoding: .utf8) ?? ""
        answers[claude.incidents.absoluteString] =
            claudeDown
            ? Data(
                incidents.replacingOccurrences(of: "Elevated errors on the API", with: incident)
                    .utf8)
            : try fixture("incidents-none.json")
        let github = StatusPage.urls(.github)
        answers[github.status.absoluteString] = try fixture("status-none.json")
        answers[try #require(github.components).absoluteString] = try fixture(
            "components-all-operational.json")
        answers[github.incidents.absoluteString] = try fixture("incidents-none.json")
        let (reporter, _) = HealthReporter.make()
        monitor = ServiceStatusMonitor(
            fetcher: TableFetcher(answers: answers), health: reporter, clock: clock,
            now: { start })
        let opened = opened
        panels = ServiceStatusPanels(
            monitor: monitor, metrics: { CanvasMetrics(interfaceScale: 100) }, clock: clock,
            now: { start }, zone: .gmt, open: { opened.record($0) })
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        monitor.start()
        await monitor.checkTask?.value
    }

    func close() {
        monitor.stop()
        panels.releaseBody(for: .serviceStatus)
        window.close()
    }

    var model: ServiceStatusModel { panels.model }

    // The host of the panel, in the window at the width.
    func show(width: Double) throws {
        let host =
            try self.host
            ?? #require(panels.body(for: .serviceStatus) as? PassiveHostingView<ServiceStatusPanel>)
        self.host = host
        if host.superview == nil { window.contentView?.addSubview(host) }
        host.frame = NSRect(x: 0, y: 0, width: width, height: 300)
        host.layoutSubtreeIfNeeded()
    }

    // Lay out at the width, and wait until the panel shows the form. False after the limit.
    // SwiftUI makes the layout in the turns of the wait.
    func shows(
        _ form: ServiceForm, at width: Double, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> Bool {
        try show(width: width)
        return await waitUntil(sourceLocation: sourceLocation) {
            host?.layoutSubtreeIfNeeded()
            return model.shownForm == form
        }
    }
}

// The widths of the panel in the tests. The full form of the widest row needs about 415 points,
// and the form with the icon button needs about 305 points (the font is the UI font at the scale
// 100). Each width below is 40 points or more from a limit.
private let wide = 480.0
private let middle = 360.0
private let narrow = 250.0

@MainActor
@Suite("service status panel")
struct ServiceStatusPanelTests {
    // The panel has one form for all rows: the form that the widest row needs. The row of Claude
    // (major outage since 09:03) is wider than each other row. With it, the panel at the middle
    // width has the icon button form for all rows. When Claude is operational, the widest row is
    // shorter, and the same width has the full form.
    @Test func oneFormForAllRows() async throws {
        let down = try await PanelFixture()
        defer { down.close() }
        #expect(try await down.shows(.iconButton, at: middle))
        let up = try await PanelFixture(claudeDown: false)
        defer { up.close() }
        #expect(try await up.shows(.full, at: middle))
    }

    @Test func aNarrowPanelHidesTheButtonTextFirst() async throws {
        let f = try await PanelFixture()
        defer { f.close() }
        #expect(try await f.shows(.full, at: wide))
        // The button first loses its text, then the level text goes too.
        #expect(try await f.shows(.iconButton, at: middle))
        #expect(try await f.shows(.squareOnly, at: narrow))
    }

    @Test func aWiderPanelGoesBackToTheFullForm() async throws {
        let f = try await PanelFixture()
        defer { f.close() }
        #expect(try await f.shows(.squareOnly, at: narrow))
        #expect(try await f.shows(.iconButton, at: middle))
        #expect(try await f.shows(.full, at: wide))
    }

    // An incident line wraps, so its length gives no reason for a narrower form.
    @Test func aLongIncidentLineAsksForNoWidth() async throws {
        let f = try await PanelFixture(incident: String(repeating: "Slow answers. ", count: 40))
        defer { f.close() }
        #expect(try await f.shows(.full, at: wide))
    }

    @Test func theServicesAndTheCheckShowInTheModel() async throws {
        let f = try await PanelFixture()
        defer { f.close() }
        #expect(f.model.isChecking)
        #expect(f.model.services.map(\.id) == ServiceID.allCases)
        #expect(f.model.services.map(\.level) == [.major, .none, .unknown])
        #expect(f.model.checkedAt == start)
        #expect(StatusText.checked(f.model.checkedAt, zone: .gmt) == "Checked at 10:05.")
    }

    @Test func theButtonOpensTheStatusPageOfItsService() async throws {
        let f = try await PanelFixture()
        defer { f.close() }
        f.model.openPage(.claude)
        f.model.openPage(.github)
        f.model.openPage(.sentry)
        #expect(
            f.opened.values.map(\.absoluteString) == [
                "https://status.claude.com", "https://www.githubstatus.com",
                "https://status.sentry.io",
            ])
    }

    @Test func aTestHomePanelChecksNothing() {
        let clock = ManualClock()
        let panels = ServiceStatusPanels(
            monitor: nil, metrics: { CanvasMetrics(interfaceScale: 100) }, clock: clock,
            now: { start })
        #expect(!panels.model.isChecking)
        #expect(panels.model.services.isEmpty)
        #expect(panels.model.checkedAt == nil)
        #expect(panels.body(for: .serviceStatus) != nil)
        panels.releaseBody(for: .serviceStatus)
    }

    // The time of the texts moves each 30 s while the body is in a frame.
    @Test func theTimeMovesWhileTheBodyIsInAFrame() async throws {
        let f = try await PanelFixture()
        defer { f.close() }
        #expect(f.panels.body(for: .usageHud) == nil)
        _ = f.panels.body(for: .serviceStatus)
        #expect(f.model.timerTask != nil)
        f.panels.releaseBody(for: .serviceStatus)
        #expect(f.model.timerTask == nil)
    }

    @Test func eachLevelHasItsOwnColourAndUnknownHasNone() {
        let levels: [ServiceLevel] = [.none, .minor, .major, .critical, .maintenance]
        let colours = levels.compactMap(ServiceColours.colour(of:))
        #expect(colours.count == levels.count)
        for (index, colour) in colours.enumerated() {
            #expect(!colours[(index + 1)...].contains(colour))
            // Not grey: the channels differ.
            #expect(max(colour.r, colour.g, colour.b) - min(colour.r, colour.g, colour.b) > 0.2)
        }
        #expect(ServiceColours.colour(of: .unknown) == nil)
    }
}
