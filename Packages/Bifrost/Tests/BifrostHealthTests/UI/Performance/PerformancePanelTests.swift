// The Performance panel (docs/behaviour/health.md, "The panel"). Safety: the snapshots are values
// of the test, the UI state is in a temporary folder, and Stop goes to a recorder, so no test
// stops a session or reads a process.
import AppKit
import BifrostFoundation
import BifrostLayout
import BifrostLook
import BifrostSessions
import BifrostTestSupport
import Foundation
import SwiftUI
import Testing

@testable import BifrostHealth

private let okText = "Bifrost is using 712 MB RAM and 2% CPU."

private func snapshot(
    _ level: HealthLevel?, reasons: [HealthReason] = [], clearable: Bool = false,
    headline: String = HealthText.checking
) -> PerformanceSnapshot {
    var value = PerformanceSnapshot.checking
    value.level = level
    value.reasons = reasons
    value.clearable = clearable
    value.headline = headline
    return value
}

// A sample at the time in seconds since the start of the timeline.
private func sample(at seconds: Int, memory: Double = 400, cpu: Double = 2) -> Sample {
    let use = Use(memory: mb(memory), cpu: cpu)
    return Sample(
        at: .seconds(seconds),
        use: BifrostUse(app: use, terminals: .zero, terminalCount: 0, largestTerminal: 0),
        span: .seconds(15))
}

// The model of the panel with a snapshot that the test changes, the clear and stop calls in
// recorders, and the UI state in a temporary folder.
@MainActor
private final class Fixture {
    var shown = PerformanceSnapshot.checking
    let stops = Recorder<String>()
    let clears = Recorder<Bool>()
    let folder: TemporaryFolder
    let store: UIStateStore
    private(set) var model: PerformancePanelModel?

    init() async throws {
        folder = try TemporaryFolder()
        store = await UIStateStore.open(
            file: folder.url.appending(path: "ui-state.json"), clock: ManualClock(),
            log: Recorder<StoreEvent>())
        model = makeModel()
    }

    // A new model on the same UI state, as a new body of the panel has.
    func makeModel() -> PerformancePanelModel {
        PerformancePanelModel(
            snapshot: { [unowned self] in shown },
            clear: { [clears] in clears.record(true) },
            stop: { [stops] in stops.record($0.sessionId) }, uiState: store,
            style: { PanelStyle(metrics: CanvasMetrics(interfaceScale: 100), transparency: 15) },
            zone: .gmt)
    }

    var panel: PerformancePanelModel {
        guard let model else { preconditionFailure("the fixture has no model") }
        return model
    }

    func finish() async {
        await store.saveNow()
        folder.remove()
    }
}

// The height that the panel asks for in a window of 520 points.
@MainActor
private func panelHeight(_ model: PerformancePanelModel) -> Double {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 520, height: 460), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = PassiveHostingView(rootView: PerformancePanel(model: model))
    window.contentView?.addSubview(host)
    host.frame = NSRect(x: 0, y: 0, width: 520, height: 460)
    host.layoutSubtreeIfNeeded()
    return host.fittingSize.height
}

// The height of one line of the text of the panel (the UI font at 12 units).
@MainActor
private func lineHeight() -> Double {
    let style = PanelStyle(metrics: CanvasMetrics(interfaceScale: 100), transparency: 15)
    return NSHostingView(rootView: Text("B").font(style.font(12))).fittingSize.height
}

@MainActor
@Suite("performance panel")
struct PerformancePanelTests {
    // Checking with no data, OK with the measured values, and Warning or Problem with one item
    // for each reason. The square and the word have the colour of the level.
    @Test func theHeadlineStates() async throws {
        let f = try await Fixture()
        #expect(f.panel.headline == .checking)
        #expect(PerformanceText.checking == "Checking Bifrost…")
        f.shown = snapshot(.ok, headline: okText)
        #expect(f.panel.headline == .ok(okText))
        let warning = HealthReason(level: .warning, text: "Bifrost's memory is growing.")
        f.shown = snapshot(.warning, reasons: [warning], headline: "Warning")
        #expect(
            f.panel.headline
                == .reasons(
                    .warning, [ReasonItem(text: warning.text, colour: ThemeTokens.ctxMid)]))
        let problem = HealthReason(level: .problem, text: "Bifrost couldn't check for sessions.")
        f.shown = snapshot(.problem, reasons: [problem, warning], headline: "Problem")
        guard case .reasons(let level, let items) = f.panel.headline else {
            Issue.record("no reasons in the headline")
            return
        }
        #expect(level == .problem)
        #expect(items.map(\.text) == [problem.text, warning.text])
        #expect([HealthLevel.ok, .warning, .problem].map(PerformanceText.word)
            == ["OK", "Warning", "Problem"])
        #expect(
            [HealthLevel.ok, .warning, .problem].map(PerformanceColours.level)
                == [ThemeTokens.ctxLow, ThemeTokens.ctxMid, ThemeTokens.ctxHigh])
        await f.finish()
    }

    // Each reason is its own item with a square in the colour of its level: red for a problem,
    // amber for a warning. The items are 6 units apart (user decision, 2026-11-09).
    @Test func eachReasonHasItsSquareAndGap() async throws {
        let f = try await Fixture()
        let reasons = [
            HealthReason(level: .problem, text: "A"), HealthReason(level: .problem, text: "B"),
            HealthReason(level: .warning, text: "C"),
        ]
        f.shown = snapshot(.problem, reasons: reasons, headline: "Problem")
        guard case .reasons(_, let items) = f.panel.headline else {
            Issue.record("no reasons in the headline")
            return
        }
        #expect(items.map(\.text) == ["A", "B", "C"])
        let colours = [ThemeTokens.ctxHigh, ThemeTokens.ctxHigh, ThemeTokens.ctxMid]
        #expect(items.map(\.colour) == colours)
        #expect(PerformancePanelModel.reasonGap == 6)
        // Each more reason adds one line and the gap of 6 points to the panel.
        let three = panelHeight(f.panel)
        f.shown = snapshot(.problem, reasons: Array(reasons.prefix(2)), headline: "Problem")
        let two = panelHeight(f.panel)
        f.shown = snapshot(.problem, reasons: Array(reasons.prefix(1)), headline: "Problem")
        let one = panelHeight(f.panel)
        #expect(abs((two - one) - (lineHeight() + 6)) < 1)
        #expect(abs((three - two) - (two - one)) < 1)
        await f.finish()
    }

    // Clear shows only while a reason comes from a past event, and a click asks the monitor to
    // clear them.
    @Test func clearShowsOnlyWhenClearable() async throws {
        let f = try await Fixture()
        let live = HealthReason(level: .warning, text: "Live")
        f.shown = snapshot(.warning, reasons: [live], headline: "Warning")
        #expect(!f.panel.showsClear)
        let past = HealthReason(level: .warning, text: "Past", past: true)
        f.shown = snapshot(.warning, reasons: [live, past], clearable: true, headline: "Warning")
        #expect(f.panel.showsClear)
        f.panel.clear()
        #expect(f.clears.values == [true])
        #expect(PerformanceText.clear == "Clear")
        await f.finish()
    }

    // The Details row starts closed. A click opens it, the UI state keeps the choice in its
    // performance value (the Electron form), and a new body of the panel opens it again. Another
    // field of the value stays.
    @Test func theDetailsStayClosedByDefaultAndRememberTheChoice() async throws {
        let f = try await Fixture()
        #expect(!f.panel.detailsOpen)
        #expect(f.store.state.performance == nil)
        f.store.change { $0.performance = ["later": 1] }
        f.panel.toggleDetails()
        #expect(f.panel.detailsOpen)
        #expect(f.store.state.performance == ["later": 1, "detailsOpen": true])
        #expect(f.makeModel().detailsOpen)
        // The file keeps the choice.
        await f.store.saveNow()
        let reopened = await UIStateStore.open(
            file: f.folder.url.appending(path: "ui-state.json"), clock: ManualClock(),
            log: Recorder<StoreEvent>())
        #expect(PerformanceDetails.isOpen(reopened.state.performance))
        f.panel.toggleDetails()
        #expect(!f.panel.detailsOpen)
        #expect(f.store.state.performance == ["later": 1, "detailsOpen": false])
        // A value of another form is closed.
        #expect(!PerformanceDetails.isOpen(.bool(true)))
        #expect(!PerformanceDetails.isOpen(["detailsOpen": "yes"]))
        await f.finish()
    }

    // Stop shows only for a session that Bifrost owns and that runs. A parked session and an
    // external session (for example one in Warp) show no Stop.
    @Test func stopShowsOnlyForAnOwnedRunningSession() async throws {
        let f = try await Fixture()
        #expect(f.panel.showsStop(.test(state: .idle)))
        #expect(f.panel.showsStop(.test(state: .working)))
        #expect(f.panel.showsStop(.test(state: .needsYou)))
        #expect(!f.panel.showsStop(.test(state: .parked)))
        #expect(!f.panel.showsStop(.test(kind: .external)))
        #expect(!f.panel.showsStop(.test(kind: .external, state: .working)))
        await f.finish()
    }

    // The key of the trend line: "Last N min" while the samples cover less than 10 minutes, with
    // the minutes up to the next whole minute, then "Last 10 minutes".
    @Test func theTrendKeyIsLastNMinBeforeTenMinutes() {
        #expect(PerformanceText.trendKey([]) == "Last 1 min")
        #expect(PerformanceText.trendKey([sample(at: 15)]) == "Last 1 min")
        #expect(PerformanceText.trendKey([sample(at: 15), sample(at: 75)]) == "Last 1 min")
        #expect(PerformanceText.trendKey([sample(at: 0), sample(at: 130)]) == "Last 3 min")
        #expect(PerformanceText.trendKey([sample(at: 0), sample(at: 540)]) == "Last 9 min")
        #expect(PerformanceText.trendKey([sample(at: 0), sample(at: 541)]) == "Last 10 minutes")
        #expect(PerformanceText.trendKey([sample(at: 30), sample(at: 630)]) == "Last 10 minutes")
    }

    // The trend line goes from the oldest sample at the left edge to the newest at the right
    // edge. The memory line shows at least 64 MB of range, and the CPU line starts at 0 with a
    // top of at least 100 %. One sample is one point at the right edge.
    @Test func theTrendLineFillsTheWidthFromTheOldestSample() {
        let size = CGSize(width: 200, height: 34)
        let lines = TrendGeometry.lines(
            [sample(at: 100, memory: 400, cpu: 0), sample(at: 160, memory: 400, cpu: 50)],
            in: size, padding: 2)
        #expect(lines.memory.map(\.x) == [0, 200])
        // A flat memory line is in the middle of its range of 64 MB.
        #expect(lines.memory.map(\.y) == [17, 17])
        #expect(lines.cpu.map(\.y) == [32, 17])
        let one = TrendGeometry.lines([sample(at: 100)], in: size, padding: 2)
        #expect(one.memory.map(\.x) == [200])
        #expect(TrendGeometry.lines([], in: size, padding: 2).memory.isEmpty)
    }

    // Stop calls the Stop action of the app with the row of the session. A session that shows no
    // Stop calls nothing.
    @Test func stopCallsTheClosureWithTheRow() async throws {
        let f = try await Fixture()
        let use = Use(memory: mb(300), cpu: 1)
        f.panel.stop(SessionUse(row: .test(sessionId: "owned-1", pid: 101), use: use))
        #expect(f.stops.values == ["owned-1"])
        f.panel.stop(SessionUse(row: .test(sessionId: "external-1", kind: .external), use: use))
        f.panel.stop(SessionUse(row: .test(sessionId: "parked-1", state: .parked), use: use))
        #expect(f.stops.values == ["owned-1"])
        await f.finish()
    }

    // The body lays out with the Details row open and each section filled, and the part makes
    // one body for the Performance panel only, until its release.
    @Test func theBodyLaysOutEachSection() async throws {
        let f = try await Fixture()
        let use = Use(memory: mb(300), cpu: 1)
        var full = snapshot(.problem, reasons: [
            HealthReason(level: .problem, text: "A problem."),
            HealthReason(level: .warning, text: "A warning.", past: true),
        ], clearable: true, headline: "Problem")
        full.bifrost = BifrostSection(
            use: sample(at: 30).use, trend: [sample(at: 15), sample(at: 30)], frameRate: 60,
            mainThreadDelay: .milliseconds(12))
        full.sessions = SessionsUse(
            total: use + use,
            top: [
                SessionUse(row: .test(sessionId: "s1", pid: 101), use: use),
                SessionUse(row: .test(sessionId: "s2", kind: .external, pid: 102), use: use),
            ],
            more: SessionGroup(count: 2, use: use))
        full.mac = MacValues(
            pressure: .warning, swap: SwapUse(used: mb(10), total: mb(1024)), load: 0.4,
            thermal: .fair, battery: BatteryState(percent: 50, power: .onBattery))
        full.network = NetworkValues(
            online: true, kind: .ethernet, rates: ByteRates(down: 1200, up: 30),
            anthropic: .answered(.milliseconds(80)), github: .noAnswer)
        full.limits = LimitsSection(github: .failure(.noGH), freeSpace: 1 << 40, clones: mb(50))
        f.shown = full
        f.panel.setDetailsOpen(true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = PassiveHostingView(rootView: PerformancePanel(model: f.panel))
        window.contentView?.addSubview(host)
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 460)
        host.layoutSubtreeIfNeeded()
        let open = host.fittingSize.height
        // The sections add to the height, and a test home (no network values) has no Network
        // section, so its panel is shorter.
        f.panel.setDetailsOpen(false)
        let closed = panelHeight(f.panel)
        f.panel.setDetailsOpen(true)
        #expect(open > closed + 4 * lineHeight())
        f.shown.network = nil
        let testHome = panelHeight(f.panel)
        #expect(testHome < open - 3 * lineHeight())
        f.shown = full
        let panels = PerformancePanels(
            monitor: nil, uiState: f.store, stop: { _ in },
            style: { PanelStyle(metrics: CanvasMetrics(interfaceScale: 100), transparency: 15) },
            clock: ManualClock())
        #expect(panels.body(for: .serviceStatus) == nil)
        let body = try #require(panels.body(for: .performance))
        #expect(panels.body(for: .performance) === body)
        // The window never shows, so the panel does not count as shown.
        window.contentView?.addSubview(body)
        #expect(!panels.shows)
        panels.releaseBody(for: .performance)
        #expect(panels.body(for: .performance) !== body)
        panels.stop()
        await f.finish()
    }

    // The texts of the values of the sections, and "-" for a value that is not measured.
    @Test func theSectionsGiveTheirValuesInWords() {
        #expect(PerformanceText.total(Use(memory: mb(712), cpu: 2.4)) == "712 MB · CPU 2%")
        #expect(PerformanceText.terminals(2) == "Chat terminals (2)")
        #expect(PerformanceText.frameRate(nil) == "-")
        #expect(PerformanceText.frameRate(59.6) == "60 fps")
        #expect(PerformanceText.delay(.milliseconds(212)) == "212 ms")
        #expect(PerformanceText.pressure(.warning) == "Medium")
        #expect(PerformanceText.swap(SwapUse(used: 0, total: 0)) == "None")
        #expect(PerformanceText.swap(SwapUse(used: mb(512), total: mb(2048))) == "512 MB of 2.0 GB")
        #expect(PerformanceText.load(0.344) == "34%")
        #expect(PerformanceText.thermal(.nominal) == "Normal")
        #expect(PerformanceText.battery(BatteryState(percent: 82, power: .pluggedIn))
            == "82%, plugged in")
        #expect(PerformanceText.battery(nil) == "-")
        let wifi = NetworkValues(online: true, kind: .wifi, rates: nil, anthropic: nil, github: nil)
        #expect(PerformanceText.link(wifi) == "Online · Wi-Fi")
        var offline = wifi
        offline.online = false
        #expect(PerformanceText.link(offline) == "Offline")
        #expect([999.4, 12_300, 1_260_000].map(PerformanceText.rate)
            == ["999 B/s", "12 KB/s", "1.3 MB/s"])
        #expect(PerformanceText.responseTime(.noAnswer) == "No answer")
        #expect(PerformanceText.responseTime(.unreachable) == "Can't reach")
        let points = GitHubPoints(
            remaining: 4321, limit: 5000, reset: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(
            PerformanceText.points(.success(points), zone: .gmt)
                == "4,321 of 5,000 left · resets 22:13")
        #expect(
            PerformanceText.points(.failure(.loggedOut), zone: .gmt)
                == "Not available - GitHub CLI isn't signed in")
        #expect(PerformanceText.disk(123_400_000_000) == "123 GB")
        #expect(PerformanceText.attention(.ok) == nil)
        #expect(PerformanceText.attention(.problem) == "Performance - Problem")
    }
}
