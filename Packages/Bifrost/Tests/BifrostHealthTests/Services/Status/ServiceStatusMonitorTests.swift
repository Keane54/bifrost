// The monitor of the status pages (docs/behaviour/health.md, "Service status"). Safety: the
// fetcher is a fake that answers from the files of Fixtures, so no test reaches the network. The
// clock is a manual clock.
import BifrostFoundation
import BifrostLayout
import BifrostLook
import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostHealth

private let start = wall(2026, 11, 18, 10, 5)

// Answers each URL with one file, or with no answer, and counts the requests.
private final class FakeFetcher: StatusFetcher {
    private let state = Mutex<(answering: Bool, urls: [URL])>((true, []))

    var requests: [URL] { state.withLock { $0.urls } }
    func setAnswering(_ on: Bool) { state.withLock { $0.answering = on } }

    func fetch(_ url: URL) async -> Data? {
        let on = state.withLock { s in
            s.urls.append(url)
            return s.answering
        }
        guard on else { return nil }
        let name =
            url.lastPathComponent == "status.json"
            ? "status-minor.json"
            : url.lastPathComponent == "components.json"
                ? "components-all-operational.json" : "incidents-none.json"
        return try? fixture(name)
    }
}

// A fetcher that waits on its own clock until a cancel, so a check can still run at a stop.
private struct HangingFetcher: StatusFetcher {
    let clock: ManualClock

    func fetch(_ url: URL) async -> Data? {
        try? await clock.sleep(for: .seconds(1000))
        return nil
    }
}

@MainActor
private struct Fixture {
    let clock = ManualClock()
    let fetcher = FakeFetcher()
    let events: AsyncStream<HealthEvent>
    let monitor: ServiceStatusMonitor

    init(fetcher: (any StatusFetcher)? = nil) {
        let (reporter, events) = HealthReporter.make()
        self.events = events
        monitor = ServiceStatusMonitor(
            fetcher: fetcher ?? self.fetcher, health: reporter, clock: clock, now: { start })
    }

    // The requests of one check: status, components (not for Sentry) and incidents of each
    // service.
    static let requestsOfOneCheck = 3 + 3 + 2
}

@MainActor
@Suite("service status monitor")
struct ServiceStatusMonitorTests {
    @Test func oneCheckEachMinuteServesAllPanels() async throws {
        let f = Fixture()
        // Two panels read the one monitor.
        let metrics: @MainActor () -> CanvasMetrics = { CanvasMetrics(interfaceScale: 100) }
        let first = ServiceStatusPanels(
            monitor: f.monitor, metrics: metrics, clock: f.clock, now: { start })
        let second = ServiceStatusPanels(
            monitor: f.monitor, metrics: metrics, clock: f.clock, now: { start })
        #expect(f.monitor.services.allSatisfy { $0.level == .unknown && $0.checkedAt == nil })
        f.monitor.start()
        f.monitor.start()
        await f.monitor.checkTask?.value
        #expect(f.fetcher.requests.count == Fixture.requestsOfOneCheck)
        #expect(f.monitor.services.map(\.id) == ServiceID.allCases)
        // The components of Claude and GitHub are fine, so they replace the minor indicator.
        #expect(f.monitor.services.map(\.level) == [.none, .none, .minor])
        #expect(f.monitor.services.allSatisfy { $0.checkedAt == start })
        #expect(first.model.services == second.model.services)
        #expect(first.model.checkedAt == start)
        // The next check comes 60 s after the end of this check, not before.
        await f.clock.waitForSleepers(exactly: 1)
        f.clock.advance(by: .seconds(59))
        #expect(f.fetcher.requests.count == Fixture.requestsOfOneCheck)
        f.clock.advance(by: .seconds(1))
        await f.monitor.timerTask?.value
        await f.monitor.checkTask?.value
        #expect(f.fetcher.requests.count == 2 * Fixture.requestsOfOneCheck)
        f.monitor.stop()
    }

    @Test func eachCheckReachesTheHealthStream() async {
        let f = Fixture()
        var events = f.events.makeAsyncIterator()
        f.fetcher.setAnswering(false)
        f.monitor.start()
        await f.monitor.checkTask?.value
        #expect(await events.next() == .poll(.serviceStatus, .failed))
        // A check with no answer asks only for status.json of each service.
        #expect(f.fetcher.requests.count == 3)
        #expect(f.monitor.services.allSatisfy { $0.level == .unknown && $0.checkedAt == start })
        f.fetcher.setAnswering(true)
        await f.clock.waitForSleepers(exactly: 1)
        f.clock.advance(by: ServiceStatusMonitor.interval)
        await f.monitor.timerTask?.value
        await f.monitor.checkTask?.value
        #expect(await events.next() == .poll(.serviceStatus, .ok))
        f.monitor.stop()
    }

    @Test func aStopEndsTheChecks() async {
        let f = Fixture()
        var events = f.events.makeAsyncIterator()
        f.monitor.start()
        await f.monitor.checkTask?.value
        #expect(await events.next() == .poll(.serviceStatus, .ok))
        await f.clock.waitForSleepers(exactly: 1)
        f.monitor.stop()
        #expect(await events.next() == .stopped(.serviceStatus))
        await f.clock.waitUntilNoSleepers()
        f.clock.advance(by: .seconds(600))
        #expect(f.monitor.timerTask == nil)
        #expect(f.fetcher.requests.count == Fixture.requestsOfOneCheck)
        // A second stop tells nothing. A new start checks again.
        f.monitor.stop()
        f.monitor.start()
        await f.monitor.checkTask?.value
        #expect(f.fetcher.requests.count == 2 * Fixture.requestsOfOneCheck)
        #expect(await events.next() == .poll(.serviceStatus, .ok))
        f.monitor.stop()
    }

    @Test func aStopDuringACheckChangesNothing() async {
        let fetchClock = ManualClock()
        let f = Fixture(fetcher: HangingFetcher(clock: fetchClock))
        var events = f.events.makeAsyncIterator()
        f.monitor.start()
        await fetchClock.waitForSleepers(3)
        let task = f.monitor.checkTask
        f.monitor.stop()
        #expect(await events.next() == .stopped(.serviceStatus))
        await task?.value
        // The cancelled check did not set the list, tell the health log or start a timer.
        #expect(f.monitor.services.allSatisfy { $0.checkedAt == nil })
        #expect(f.monitor.timerTask == nil)
        #expect(f.monitor.checkTask == nil)
    }
}
