import BifrostFoundation
import Foundation
import Observation

// The samplers of the Performance monitor. A test home has no network sampler and no GitHub
// points, so it makes no request and starts no gh.
package struct PerformanceSamplers: Sendable {
    package var app: AppUsage
    package var mac: MacState
    package var network: NetworkState?
    package var disk: DiskState
    package var github: GitHubLimit?
    package var mainThread: MainThreadWatch

    package init(
        app: AppUsage, mac: MacState, network: NetworkState?, disk: DiskState,
        github: GitHubLimit?, mainThread: MainThreadWatch
    ) {
        self.app = app
        self.mac = mac
        self.network = network
        self.disk = disk
        self.github = github
        self.mainThread = mainThread
    }
}

// The values of the section "Bifrost" of the panel.
package struct BifrostSection: Sendable, Equatable {
    // The use of the fresh sample, or nil while the monitor has no data.
    package var use: BifrostUse?
    // The samples of the last 10 minutes, the oldest first.
    package var trend: [Sample]
    // The value of the last burst of the frame counter of this count, while the panel shows.
    package var frameRate: Double?
    // The longest pass of the main run loop in the last full 60 s window.
    package var mainThreadDelay: Duration?
}

// The values of the section "Limits and disk" of the panel.
package struct LimitsSection: Sendable, Equatable {
    package var github: Result<GitHubPoints, GitHubLimitError>?
    // The free space of the volume of the home in bytes.
    package var freeSpace: UInt64?
    // The size of the Reviews clones in bytes.
    package var clones: UInt64?
}

// What the Performance panel shows (docs/behaviour/health.md, "Performance"). A value is nil
// while it is not measured. The sections other than "Bifrost" never change the level: they help
// the user find the cause.
package struct PerformanceSnapshot: Sendable, Equatable {
    // nil while the monitor has no data and no reason: the headline says "Checking Bifrost…".
    package var level: HealthLevel?
    // The problems first, then the warnings.
    package var reasons: [HealthReason]
    // True when a reason comes from a past event, so Clear can remove it.
    package var clearable: Bool
    package var headline: String
    package var bifrost: BifrostSection
    package var sessions: SessionsUse?
    // nil until the panel showed: only the panel reads the Mac.
    package var mac: MacValues?
    // nil with no network sampler (a test home).
    package var network: NetworkValues?
    package var limits: LimitsSection

    package static let checking = PerformanceSnapshot(
        level: nil, reasons: [], clearable: false, headline: HealthText.checking,
        bifrost: BifrostSection(use: nil, trend: [], frameRate: nil, mainThreadDelay: nil),
        sessions: nil, mac: nil, network: nil, limits: LimitsSection())
}

// The Performance monitor (docs/behaviour/health.md, "Performance"). One task samples Bifrost and
// the Claude sessions at each tick: each 15 s, and each 2 s while the panel shows. The ticks run
// also while the panel is closed, so the side bar dot is correct. While the panel shows, the tick
// also reads the Mac and the network, and slower reads (the response times, the GitHub points, the
// free disk and the size of the clones) run in their own tasks at their own intervals. After each
// tick and each event, the monitor builds the snapshot again.
//
// The monitor reads `events` in one task for the life of the app: a cancelled reader would end the
// stream for good, and later records would drop. start() and stop() gate only the sampling; the
// reader ends in end(). The Performance parts of the shell own the monitor, and the quit calls
// end() (PerformanceParts.stop(), from Shell.detach()).
@MainActor
@Observable
package final class PerformanceMonitor {
    package static let tick = Duration.seconds(15)
    package static let panelTick = Duration.seconds(2)
    // While the panel shows, the response times, the GitHub points and the free disk are read at
    // most this often, and the battery too.
    package static let slowRead = Duration.seconds(60)
    // The size of the clones, at most this often while the panel shows.
    package static let clonesRead = Duration.seconds(600)

    package private(set) var snapshot = PerformanceSnapshot.checking

    private enum Phase {
        case stopped
        // The sampling is on, and no tick runs. The timer waits for the next tick.
        case waiting
        // The sampling is on, and this tick runs.
        case ticking(Task<Void, Never>)
    }

    // The reads that run in their own tasks while the panel shows.
    private enum SideRead: Hashable {
        case probes, points, freeSpace, clones
    }

    // The values that only the panel shows.
    private struct PanelValues {
        var mac: MacValues?
        var ticks: CPUTicks?
        var battery: BatteryState?
        // The interface of the last byte count, and the count.
        var bytes: (interface: String, count: ByteCount)?
        var rates: ByteRates?
        var probes: ProbeTimes?
        var points: Result<GitHubPoints, GitHubLimitError>?
        var freeSpace: UInt64?
        var clones: UInt64?
        var batteryAt: Duration?
    }

    // The values of one read of the Mac and the byte counters, off the main actor.
    private struct SystemRead: Sendable {
        var pressure: MemoryPressure?
        var swap: SwapUse?
        var ticks: CPUTicks?
        var thermal: ProcessInfo.ThermalState
        // nil when the battery was not read this time.
        var battery: BatteryState??
        var bytes: ByteCount?
    }

    private struct LogLine: Sendable {
        var text: String
        var time: Date
    }

    @ObservationIgnored private let samplers: PerformanceSamplers
    @ObservationIgnored private let timeline: Timeline
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let timer: TimerSlot
    @ObservationIgnored private let lines: AsyncStream<LogLine>.Continuation
    @ObservationIgnored private var phase = Phase.stopped
    @ObservationIgnored private var lastTickEnd: Duration?
    @ObservationIgnored private var history = SampleHistory()
    @ObservationIgnored private var sessions: SessionsUse?
    @ObservationIgnored private var orphanWatch = OrphanWatch()
    @ObservationIgnored private var orphans = 0
    @ObservationIgnored private var mainThreadDelay: Duration?
    @ObservationIgnored private var slowMainLog = SlowMainLog()
    @ObservationIgnored private var past = PastEvents()
    @ObservationIgnored private var showing = false
    // The burst values of the frame counter in this count, the newest last.
    @ObservationIgnored private var frameRates: [Double] = []
    // The network path, or nil before the first path (and with no network sampler).
    @ObservationIgnored private var path: NetworkPath?
    @ObservationIgnored private var panel = PanelValues()
    @ObservationIgnored private var sideTasks: [SideRead: Task<Void, Never>] = [:]
    @ObservationIgnored private var sideReadAt: [SideRead: Duration] = [:]
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var writer: Task<Void, Never>?
    @ObservationIgnored private var pathFollow: Task<Void, Never>?

    package init(
        events: AsyncStream<HealthEvent>, samplers: PerformanceSamplers, log: HealthLog,
        clock: any Clock<Duration>, now: @escaping () -> Date
    ) {
        self.samplers = samplers
        self.now = now
        timeline = Timeline(clock)
        timer = TimerSlot(clock: clock)
        let (stream, lines) = AsyncStream.makeStream(of: LogLine.self)
        self.lines = lines
        // One writer keeps the lines of the health log in their order.
        writer = Task {
            for await line in stream { await log.write(line.text, at: line.time) }
        }
        reader = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.record(event)
            }
        }
        if let network = samplers.network {
            pathFollow = Task { [weak self] in
                for await path in network.paths() {
                    guard let self else { return }
                    self.path = path
                    self.rebuild()
                }
            }
        }
    }

    // An owner that drops the monitor with no end() leaves no observer on the main run loop.
    isolated deinit {
        if case .ticking(let task) = phase { task.cancel() }
        samplers.mainThread.stop()
        for task in sideTasks.values { task.cancel() }
        reader?.cancel()
        pathFollow?.cancel()
        lines.finish()
    }

    // The task of the tick that runs, or nil. A test waits for it.
    package var tickTask: Task<Void, Never>? {
        if case .ticking(let task) = phase { task } else { nil }
    }

    // The task of the timer of the next tick, or nil. A test waits for it.
    package var timerTask: Task<Void, Never>? { timer.task }

    // The panel opened or closed. The tick is 2 s while the panel shows. A change starts a new
    // count of the frame rate. A close stops the rates of the network and the load of the Mac,
    // so the next open starts them again.
    package func panelShown(_ shown: Bool) {
        guard shown != showing else { return }
        showing = shown
        frameRates = []
        if !shown {
            panel.bytes = nil
            panel.rates = nil
            panel.ticks = nil
            panel.mac?.load = nil
        }
        schedule()
        rebuild()
    }

    // The value of one burst of the frame counter (FrameRateCounter). It counts only while the
    // panel shows.
    package func frameRate(_ fps: Double) {
        guard showing, fps.isFinite, fps >= 0 else { return }
        frameRates = Array((frameRates + [fps]).suffix(2))
        rebuild()
    }

    // The frame counter stopped: the panel closed or its window lost the focus. The next burst
    // starts a new count.
    package func frameCountStopped() {
        frameRates = []
        rebuild()
    }

    // Remove the past events (PastEvents.clear) and build the snapshot again at once. The live
    // measurements stay. The health log gets one line.
    package func clear() {
        let line = past.clear()
        lines.yield(LogLine(text: line, time: now()))
        rebuild()
    }

    // Start the sampling: a tick now, then on the timer. A second call does nothing.
    package func start() {
        guard case .stopped = phase else { return }
        phase = .waiting
        samplers.mainThread.start()
        runTick()
    }

    // Stop the sampling and forget the samples. The events still count.
    package func stop() {
        if case .stopped = phase { return }
        if case .ticking(let task) = phase { task.cancel() }
        phase = .stopped
        timer.stop()
        for task in sideTasks.values { task.cancel() }
        sideTasks = [:]
        sideReadAt = [:]
        samplers.mainThread.stop()
        lastTickEnd = nil
        history.clear()
        sessions = nil
        orphanWatch = OrphanWatch()
        orphans = 0
        mainThreadDelay = nil
        panel = PanelValues()
        rebuild()
    }

    // The end of the app: stop, and end the reader of the events, the follow of the network path
    // and the writer of the health log (after its last line).
    package func end() {
        stop()
        reader?.cancel()
        reader = nil
        pathFollow?.cancel()
        pathFollow = nil
        lines.finish()
    }

    // MARK: - The events

    private func record(_ event: HealthEvent) {
        let time = EventTime(at: timeline.now(), wall: now())
        if let line = past.record(event, online: online, at: time) {
            lines.yield(LogLine(text: line, time: time.wall))
        }
        rebuild()
    }

    // True while the network path is online, and with no network sampler.
    private var online: Bool { path?.online ?? true }

    // MARK: - The ticks

    private func runTick() {
        guard case .waiting = phase else { return }
        phase = .ticking(Task { [weak self] in await self?.tick() })
    }

    // The next tick comes the tick time after the end of the last tick, or at once.
    private func schedule() {
        guard case .waiting = phase else { return }
        let interval = showing ? Self.panelTick : Self.tick
        let wait = lastTickEnd.map { max(.zero, $0 + interval - timeline.now()) } ?? .zero
        timer.start(after: wait) { [weak self] in self?.runTick() }
    }

    // One tick. A stop cancels it, so after each wait an old tick changes nothing.
    private func tick() async {
        let at = timeline.now()
        let reading = await samplers.app.read(at: at, since: history.lastRead)
        guard !Task.isCancelled else { return }
        // A read with no app process failed: the sessions keep their values.
        if let found = reading.sessions { sessions = found }
        history.add(
            reading.table, app: samplers.app.app, terminals: reading.terminals.map(\.pid))
        orphans = orphanWatch.count(reading.terminals, chatPanels: reading.chatPanels, at: at)
        let main = samplers.mainThread.longestWindow()
        mainThreadDelay = main.delay
        // A slow pass leaves a line in the health log, so a freeze leaves a trace.
        if let line = slowMainLog.line(delay: main.delay, window: main.window) {
            lines.yield(LogLine(text: line, time: now()))
        }
        if showing {
            await readPanel(at: at)
            guard !Task.isCancelled else { return }
        }
        rebuild()
        lastTickEnd = timeline.now()
        phase = .waiting
        schedule()
    }

    // The values that only the panel shows: the Mac and the byte counters at each tick, and the
    // slower reads in their own tasks when they are due.
    private func readPanel(at now: Duration) async {
        let batteryDue = due(panel.batteryAt, every: Self.slowRead, at: now)
        let read = await Self.readSystem(
            samplers.mac, battery: batteryDue, network: samplers.network,
            interface: path?.interface, at: now)
        guard !Task.isCancelled, showing else { return }
        let load = panel.ticks.flatMap { earlier in
            read.ticks.flatMap { MacState.load(from: earlier, to: $0) }
        }
        panel.ticks = read.ticks
        if let battery = read.battery {
            panel.battery = battery
            panel.batteryAt = now
        }
        panel.mac = MacValues(
            pressure: read.pressure, swap: read.swap, load: load, thermal: read.thermal,
            battery: panel.battery)
        applyBytes(read.bytes)
        startSlowReads(at: now)
    }

    // A new count of the same interface gives the rates. A new interface starts the rates again.
    private func applyBytes(_ count: ByteCount?) {
        guard let count, let interface = path?.interface else {
            panel.bytes = nil
            panel.rates = nil
            return
        }
        if let earlier = panel.bytes, earlier.interface == interface {
            panel.rates = NetworkState.rates(from: earlier.count, to: count)
        } else {
            panel.rates = nil
        }
        panel.bytes = (interface, count)
    }

    private func startSlowReads(at now: Duration) {
        let disk = samplers.disk
        side(.freeSpace, every: Self.slowRead, at: now) {
            await disk.freeSpace()
        } apply: { $0.panel.freeSpace = $1 }
        side(.clones, every: Self.clonesRead, at: now) {
            await disk.clonesSize()
        } apply: { $0.panel.clones = $1 }
        if let network = samplers.network {
            side(.probes, every: Self.slowRead, at: now) {
                await network.responseTimes()
            } apply: { $0.panel.probes = $1 }
        }
        if let github = samplers.github {
            side(.points, every: Self.slowRead, at: now) {
                await github.read()
            } apply: { $0.panel.points = $1 }
        }
    }

    // Start the read in its own task when it is due and does not run. Its value applies only
    // while the sampling is on: a stop cancels the task.
    private func side<Value: Sendable>(
        _ kind: SideRead, every interval: Duration, at now: Duration,
        read: @escaping @Sendable () async -> Value,
        apply: @escaping @MainActor (PerformanceMonitor, Value) -> Void
    ) {
        guard sideTasks[kind] == nil, due(sideReadAt[kind], every: interval, at: now) else {
            return
        }
        sideReadAt[kind] = now
        sideTasks[kind] = Task { [weak self] in
            let value = await read()
            guard !Task.isCancelled, let self else { return }
            self.sideTasks[kind] = nil
            apply(self, value)
            self.rebuild()
        }
    }

    private func due(_ last: Duration?, every interval: Duration, at now: Duration) -> Bool {
        last.map { now - $0 >= interval } ?? true
    }

    // The reads of the Mac and of the byte counters: system calls that do not wait, off the main
    // actor.
    @concurrent private static func readSystem(
        _ mac: MacState, battery: Bool, network: NetworkState?, interface: String?,
        at now: Duration
    ) async -> SystemRead {
        SystemRead(
            pressure: mac.pressure(), swap: mac.swap(), ticks: mac.cpuTicks(),
            thermal: mac.thermal(), battery: battery ? .some(mac.battery()) : nil,
            bytes: interface.flatMap { network?.bytes(of: $0, at: now) })
    }

    // MARK: - The snapshot

    private func rebuild() {
        let at = timeline.now()
        let input = HealthInput(
            now: at, wall: now(), history: history, frameRates: frameRates,
            mainThreadDelay: mainThreadDelay, events: past, online: online, orphans: orphans)
        let reasons = HealthChecks.reasons(input)
        let fresh = input.freshSample
        let level = HealthChecks.level(of: reasons, measured: fresh != nil)
        let network = samplers.network.map { _ in
            NetworkValues(
                online: online, kind: path?.kind, rates: panel.rates,
                anthropic: panel.probes?.anthropic, github: panel.probes?.github)
        }
        let next = PerformanceSnapshot(
            level: level, reasons: reasons, clearable: reasons.contains(where: \.past),
            headline: HealthText.headline(level, use: fresh?.use.total),
            bifrost: BifrostSection(
                use: fresh?.use, trend: history.trend(at: at),
                frameRate: showing ? frameRates.last : nil, mainThreadDelay: mainThreadDelay),
            sessions: sessions, mac: panel.mac, network: network,
            limits: LimitsSection(
                github: panel.points, freeSpace: panel.freeSpace, clones: panel.clones))
        if next != snapshot { snapshot = next }
    }
}
