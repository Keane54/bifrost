import BifrostFoundation
import Foundation
import Observation

// Checks the status pages of the services that Claude Code depends on (docs/behaviour/health.md,
// "Service status"): one check at the start, then one check 60 s after the end of the last check.
// One check reads the three pages, and serves all panels. A check never starts while another
// check runs. A check tells the health log: failed when no page answered, else ok. A stop tells
// it that the poll stopped.
//
// A check runs as one task. A stop cancels it, so an old check changes nothing.
@MainActor
@Observable
package final class ServiceStatusMonitor {
    package static let interval = Duration.seconds(60)

    // The state of each service, in the order of ServiceID.allCases.
    package private(set) var services = ServiceID.allCases.map(ServiceStatus.unchecked)

    private enum Phase {
        case stopped
        // On, and no check runs. The timer waits for the next check.
        case waiting
        // On, and this check runs.
        case checking(Task<Void, Never>)
    }

    @ObservationIgnored private let fetcher: any StatusFetcher
    @ObservationIgnored private let health: HealthReporter
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let timer: TimerSlot
    @ObservationIgnored private var phase = Phase.stopped

    package init(
        fetcher: any StatusFetcher, health: HealthReporter, clock: any Clock<Duration>,
        now: @escaping () -> Date
    ) {
        self.fetcher = fetcher
        self.health = health
        self.now = now
        timer = TimerSlot(clock: clock)
    }

    // The task of the check that runs, or nil. A test waits for it.
    package var checkTask: Task<Void, Never>? {
        if case .checking(let task) = phase { task } else { nil }
    }

    // The task of the timer of the next check, or nil. A test waits for it.
    package var timerTask: Task<Void, Never>? { timer.task }

    // Check now, then each minute. A second call does nothing.
    package func start() {
        guard case .stopped = phase else { return }
        phase = .waiting
        check()
    }

    // End the checks. A check that runs changes nothing more. The list keeps its last values.
    package func stop() {
        if case .stopped = phase { return }
        if case .checking(let task) = phase { task.cancel() }
        phase = .stopped
        timer.stop()
        health.record(.stopped(.serviceStatus))
    }

    private func check() {
        guard case .waiting = phase else { return }
        phase = .checking(Task { [weak self] in await self?.run() })
    }

    private func run() async {
        let list = await readAll()
        // A stop cancelled this check, so it changes nothing.
        guard !Task.isCancelled else { return }
        services = list
        // A check fails only when no page answered.
        let answered = list.contains { $0.level != .unknown }
        health.record(.poll(.serviceStatus, answered ? .ok : .failed))
        phase = .waiting
        timer.start(after: Self.interval) { [weak self] in self?.check() }
    }

    // The three services at once, in the order of ServiceID.allCases.
    private func readAll() async -> [ServiceStatus] {
        let fetcher = fetcher
        let at = now()
        return await withTaskGroup(of: (Int, ServiceStatus).self) { group in
            for (index, id) in ServiceID.allCases.enumerated() {
                group.addTask { (index, await Self.read(id, with: fetcher, at: at)) }
            }
            var list = ServiceID.allCases.map(ServiceStatus.unchecked)
            for await (index, status) in group { list[index] = status }
            return list
        }
    }

    // One service: status.json first. With no answer, the service is unknown and the other two
    // pages stay unread. Else the components and the incidents are read at the same time.
    @concurrent
    nonisolated private static func read(
        _ id: ServiceID, with fetcher: any StatusFetcher, at now: Date
    ) async -> ServiceStatus {
        let urls = StatusPage.urls(id)
        let status = await fetcher.fetch(urls.status)
        guard status != nil else {
            return StatusPage.status(id, status: nil, components: nil, incidents: nil, now: now)
        }
        async let components = Self.fetch(urls.components, with: fetcher)
        async let incidents = Self.fetch(urls.incidents, with: fetcher)
        return StatusPage.status(
            id, status: status, components: await components, incidents: await incidents,
            now: now)
    }

    // One page, or no answer when the service has no such page.
    @concurrent
    nonisolated private static func fetch(_ url: URL?, with fetcher: any StatusFetcher) async
        -> Data?
    {
        guard let url else { return nil }
        return await fetcher.fetch(url)
    }
}
