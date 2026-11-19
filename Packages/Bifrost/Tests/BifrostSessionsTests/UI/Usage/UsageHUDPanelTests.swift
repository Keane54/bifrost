// The Usage HUD panel (docs/behaviour/usage.md, "The Usage HUD"). Safety: the account values come
// from a fake Keychain runner and a fake fetcher, so no test runs security, reads the Keychain or
// reaches the network. The token is fake.
import AppKit
import BifrostFoundation
import BifrostLayout
import BifrostLook
import BifrostSessions
import BifrostTestSupport
import Foundation
import Observation
import SwiftUI
import Synchronization
import Testing

// The wall time at the start of each test: Thursday 12 November 2026, 12:00 UTC.
private let start = utcMs(2026, 11, 12, 12)
private let session = "a1b2c3d4-1111-4111-8111-111111111111"

// A login that ends one day after the start.
private let keychain = ExecResult(
    .exited(0),
    stdout: """
        {"claudeAiOauth":{"accessToken":"fake-access-token-for-tests",\
        "expiresAt":\(start + 86_400_000)}}

        """)

// The account answers: both windows, or the 7-day window only.
private let bothWindows = Data(
    """
    {"five_hour":{"utilization":10,"resets_at":"2026-11-12T13:00:00+00:00"},\
    "seven_day":{"utilization":95,"resets_at":"2026-11-14T13:00:00+00:00"}}
    """.utf8)
private let sevenDayOnly = Data(
    """
    {"seven_day":{"utilization":30,"resets_at":"2026-11-14T13:00:00+00:00"}}
    """.utf8)

// A Keychain read that always gives the login.
private struct FakeKeychain: CommandRunner {
    func run(_ command: Command) async -> ExecResult { keychain }
}

// A fetcher that gives one answer each time and counts the fetches. It records no token.
private final class FakeFetcher: UsageFetcher {
    private let body: Data
    private let count = Mutex(0)

    init(_ body: Data) { self.body = body }

    var fetches: Int { count.withLock { $0 } }

    func fetch(token: String, timeout: Duration) async -> UsageResponse? {
        count.withLock { $0 += 1 }
        return UsageResponse(status: 200, body: body)
    }
}

// What a click on a usage notification asked of the shell.
private enum ShellCall: Equatable {
    case showWindow
    case open(PanelID)
}

// The HUD of a test: a real registry service that is not started, a real account poller with the
// fakes, and a window that is never ordered front. The frame view stands in for a frame of the
// canvas: the canvas puts the body of the active panel in it, removes the body when another tab
// becomes active, and hides the frame while it is minimised.
@MainActor
private final class HUDFixture {
    let clock = ManualClock()
    let fetcher: FakeFetcher
    let poller: AccountPoller
    let registry: RegistryService
    let panels: UsageHUDPanels
    let window: NSWindow
    let frame = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 180))

    init(answer: Data = bothWindows) {
        UITestApp.prepare()
        let wall: @Sendable () -> Date = { [clock] in
            Date(timeIntervalSince1970: Double(start) / 1000 + clock.now.offset / .seconds(1))
        }
        fetcher = FakeFetcher(answer)
        poller = AccountPoller(
            runner: FakeKeychain(), fetcher: fetcher, clock: clock, now: wall,
            log: Recorder<AccountUsageEvent>())
        // The registry keeps the rate limits of a session with a row only, and only when a window
        // resets between its time and 8 days after it. The row of the session comes first, at the
        // start time, so each window of the tests is in range.
        var rows = SessionRegistry(store: RegistryStore(), escalation: .seconds(600))
        rows.applyAgents([bg(id: nil, name: "", sessionId: session)], sampledAt: start)
        let registry = RegistryService(
            registry: rows,
            deps: FixedRegistryDeps(active: []), clock: ManualClock(),
            log: Recorder<SessionsLogEvent>())
        self.registry = registry
        let poller = poller
        panels = UsageHUDPanels(
            usage: { registry.usage }, poller: { poller },
            metrics: { CanvasMetrics(interfaceScale: 100) }, clock: clock, now: wall, zone: .gmt)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(frame)
    }

    var hud: UsageHUD { panels.hud }

    // The body of the HUD, made on the first call.
    func body() throws -> UsageHUDHost {
        try #require(panels.body(for: .usageHud) as? UsageHUDHost)
    }

    // Start the poller and wait for the end of its first poll.
    func startPoller() async {
        poller.start()
        await poller.pollTask?.value
    }

    // Wait for the end of a poll that runs.
    func pollEnded() async {
        await poller.pollTask?.value
    }

    // Move the clock to the next tick of the HUD, and wait for the end of the tick.
    func nextTick() async {
        let tick = hud.timerTask
        clock.advance(by: UsageHUD.tick)
        await tick?.value
    }

    // A usage line of the session with these windows, at the time of now.
    func pushSession(fiveHour: RateWindow?, sevenDay: RateWindow?) {
        let at = start + Int(clock.now.offset / .milliseconds(1))
        let limits = RateLimits(fiveHour: fiveHour, sevenDay: sevenDay)
        registry.pushLive(.usage(sessionId: session, at: at, LiveUsage(rateLimits: limits)))
    }

    func close() {
        panels.releaseBody(for: .usageHud)
        poller.stop()
        registry.stop()
        window.close()
    }
}

@MainActor
@Suite("Usage HUD panel", .serialized, .testTimeLimit, .tags(.window))
struct UsageHUDPanelTests {
    // The bars and the source line come from UsageView.of with the values of now: the session
    // snapshot of the registry, then the account values of the poller. The time of the bars moves
    // each 30 s, and each new time and each new value reaches the view through Observation.
    @Test func theHUDShowsTheBarsAndTheSource() async throws {
        let f = HUDFixture()
        defer { f.close() }
        let host = try f.body()
        #expect(try f.body() === host)
        #expect(f.panels.body(for: .eventLog) == nil)
        #expect(host.rootView.hud === f.hud)
        // No source yet.
        #expect(f.hud.content.bars.map(\.label) == ["5-hour limit", "7-day limit"])
        #expect(f.hud.content.bars.map(\.percentText) == ["-", "-"])
        #expect(f.hud.content.bars.map(\.detail) == ["No data", "No data"])
        #expect(f.hud.content.source == "No usage data yet.")
        // The usage line of a session. Above 70 % is raised, and 90 % and more is high.
        let changes = Mutex(0)
        withObservationTracking { _ = f.hud.content } onChange: { changes.withLock { $0 += 1 } }
        f.pushSession(
            fiveHour: RateWindow(usedPercent: 42.4, resetsAt: start + 7_500_000),
            sevenDay: RateWindow(usedPercent: 91, resetsAt: start + 176_400_000))
        #expect(changes.withLock { $0 } == 1)
        var bars = f.hud.content.bars
        #expect(bars.map(\.percentText) == ["42%", "91%"])
        #expect(bars.map(\.fill) == [0.42, 0.91])
        #expect(bars.map(\.level) == [.normal, .high])
        #expect(bars.map(\.colour) == [ThemeTokens.usage, ThemeTokens.usageHigh])
        #expect(
            bars.map(\.detail) == [
                "Resets in 2 h 05 min (14:05)", "Resets in 2 d 1 h (Sat 13:00)",
            ])
        #expect(f.hud.content.source == "From a1b2c3d4, 0 s ago.")
        // The time moves each 30 s.
        withObservationTracking { _ = f.hud.content } onChange: { changes.withLock { $0 += 1 } }
        await f.nextTick()
        #expect(changes.withLock { $0 } == 2)
        #expect(f.hud.content.source == "From a1b2c3d4, 30 s ago.")
        await f.nextTick()
        #expect(f.hud.content.source == "From a1b2c3d4, 1 min ago.")
        // The account values win over the session values.
        await f.startPoller()
        bars = f.hud.content.bars
        #expect(bars.map(\.percentText) == ["10%", "95%"])
        #expect(bars.map(\.level) == [.normal, .high])
        #expect(f.hud.content.source == "From your Anthropic account, updated 0 s ago.")
        // The HUD lays out in a frame. A released body stops the time, and a new body is a new
        // host.
        f.frame.addSubview(host)
        host.frame = f.frame.bounds
        host.layoutSubtreeIfNeeded()
        f.panels.releaseBody(for: .usageHud)
        #expect(f.hud.timerTask == nil)
        #expect(try f.body() !== host)
        #expect(f.hud.timerTask != nil)
    }

    // A source with a 7-day window and no 5-hour window shows only the 7-day bar: the session
    // values and the account values.
    @Test func aPlanWithNoFiveHourWindowShowsOnlyTheSevenDayBar() async throws {
        let f = HUDFixture(answer: sevenDayOnly)
        defer { f.close() }
        _ = try f.body()
        f.pushSession(
            fiveHour: nil, sevenDay: RateWindow(usedPercent: 12, resetsAt: start + 176_400_000))
        #expect(f.hud.content.bars.map(\.label) == ["7-day limit"])
        #expect(f.hud.content.bars.map(\.percentText) == ["12%"])
        #expect(f.hud.content.source == "From a1b2c3d4, 0 s ago.")
        await f.startPoller()
        #expect(f.hud.content.bars.map(\.label) == ["7-day limit"])
        #expect(f.hud.content.bars.map(\.percentText) == ["30%"])
        #expect(f.hud.content.source == "From your Anthropic account, updated 0 s ago.")
    }

    // The HUD asks the poller for a poll when it comes into a window in a frame that shows. A body
    // that is in no window yet asks nothing. The host never takes the focus.
    @Test func theHUDAsksForAPollWhenItShows() async throws {
        let f = HUDFixture()
        defer { f.close() }
        await f.startPoller()
        #expect(f.fetcher.fetches == 1)
        // More than a minute after the first poll, so the poller polls when the HUD asks.
        f.clock.advance(by: .seconds(61))
        let host = try f.body()
        #expect(f.poller.pollTask == nil)
        f.frame.addSubview(host)
        await f.pollEnded()
        #expect(f.fetcher.fetches == 2)
        #expect(!host.acceptsFirstResponder)
        #expect(!host.canBecomeKeyView)
        _ = f.window.makeFirstResponder(host)
        #expect(f.window.firstResponder !== host)
    }

    // The HUD asks again each time it becomes visible: its minimised frame comes back from the
    // side bar, or its tab becomes the active tab again. A body in a hidden frame asks nothing.
    @Test func theHUDAsksAgainWhenItBecomesVisible() async throws {
        let f = HUDFixture()
        defer { f.close() }
        await f.startPoller()
        // The frame of the HUD is minimised at the start.
        f.frame.isHidden = true
        f.clock.advance(by: .seconds(61))
        let host = try f.body()
        f.frame.addSubview(host)
        #expect(f.poller.pollTask == nil)
        // The frame comes back from the side bar.
        f.frame.isHidden = false
        await f.pollEnded()
        #expect(f.fetcher.fetches == 2)
        // Another tab of the frame becomes active, then the tab of the HUD again.
        f.clock.advance(by: .seconds(61))
        host.removeFromSuperview()
        #expect(f.poller.pollTask == nil)
        f.frame.addSubview(host)
        await f.pollEnded()
        #expect(f.fetcher.fetches == 3)
    }

    // A click on a usage notification shows the window, then opens the Usage HUD. The canvas then
    // shows its body in a frame, so the HUD asks for a poll.
    @Test func aClickOnAUsageNotificationOpensTheUsageHud() async throws {
        let f = HUDFixture()
        defer { f.close() }
        await f.startPoller()
        f.clock.advance(by: .seconds(61))
        let calls = Recorder<ShellCall>()
        f.panels.showWindow = { calls.record(.showWindow) }
        f.panels.openPanel = { [weak f] panel in
            calls.record(.open(panel))
            if let f, let body = f.panels.body(for: panel) { f.frame.addSubview(body) }
        }
        f.panels.notificationClicked()
        #expect(calls.values == [.showWindow, .open(.usageHud)])
        await f.pollEnded()
        #expect(f.fetcher.fetches == 2)
    }

    // A new answer of the poller reaches the view through Observation, also with no change of
    // the session values or of the time.
    @Test func newAccountValuesReachTheViewThroughObservation() async throws {
        let f = HUDFixture()
        defer { f.close() }
        _ = try f.body()
        let changes = Mutex(0)
        withObservationTracking { _ = f.hud.content } onChange: { changes.withLock { $0 += 1 } }
        await f.startPoller()
        #expect(changes.withLock { $0 } == 1)
        #expect(f.hud.content.bars.map(\.percentText) == ["10%", "95%"])
    }

    // With no poller (a test home, or before the start of the services), the HUD shows the
    // session values, and a show asks nothing.
    @Test func withNoPollerTheHUDShowsTheSessionValues() throws {
        let f = HUDFixture()
        defer { f.close() }
        let registry = f.registry
        let panels = UsageHUDPanels(
            usage: { registry.usage }, poller: { nil },
            metrics: { CanvasMetrics(interfaceScale: 100) }, clock: f.clock,
            now: { Date(timeIntervalSince1970: Double(start) / 1000) }, zone: .gmt)
        let host = try #require(panels.body(for: .usageHud) as? UsageHUDHost)
        defer { panels.releaseBody(for: .usageHud) }
        #expect(panels.hud.content.source == "No usage data yet.")
        f.pushSession(
            fiveHour: RateWindow(usedPercent: 42, resetsAt: start + 7_500_000),
            sevenDay: RateWindow(usedPercent: 12, resetsAt: start + 176_400_000))
        #expect(panels.hud.content.bars.map(\.percentText) == ["42%", "12%"])
        f.frame.addSubview(host)
        panels.windowShown()
        #expect(f.poller.pollTask == nil)
    }

    // The views of a closed window stay in it, so a HUD in a frame gets no new move into a window
    // when the window shows again. The show of the window asks for a poll. A HUD in a hidden frame
    // and a HUD with no body ask nothing.
    @Test func aShowOfTheWindowAsksForAPoll() async throws {
        let f = HUDFixture()
        defer { f.close() }
        await f.startPoller()
        f.clock.advance(by: .seconds(61))
        f.panels.windowShown()
        #expect(f.poller.pollTask == nil)
        let host = try f.body()
        f.frame.isHidden = true
        f.frame.addSubview(host)
        f.panels.windowShown()
        #expect(f.poller.pollTask == nil)
        f.frame.isHidden = false
        await f.pollEnded()
        #expect(f.fetcher.fetches == 2)
        f.clock.advance(by: .seconds(61))
        f.panels.windowShown()
        await f.pollEnded()
        #expect(f.fetcher.fetches == 3)
    }
}
