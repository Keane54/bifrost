// The Performance monitor (docs/behaviour/health.md, "Performance"). Safety: the process table,
// the Mac state and the health stream are fakes, the monitor has no network sampler and no GitHub
// points, the clock is a manual clock, and the health log goes to a temporary folder.
import BifrostFoundation
import BifrostTestSupport
import CoreFoundation
import Foundation
import Synchronization
import Testing

@testable import BifrostHealth

private let start = wall(2026, 11, 18, 9, 0)

// A process table with only the app. Each read adds 150 ms to the CPU time of the app.
private final class CountingProcesses: ProcessSampling {
    private let state = Mutex<(reads: Int, memory: Double)>((0, 400))

    var reads: Int { state.withLock { $0.reads } }

    func setMemory(_ megabytes: Double) { state.withLock { $0.memory = megabytes } }

    func read() async -> [ProcessSample] {
        let (reads, memory) = state.withLock { s in
            s.reads += 1
            return (s.reads, s.memory)
        }
        return [
            ProcessSample(
                pid: appPID, parent: 1, footprint: mb(memory), cpuTime: .milliseconds(150 * reads))
        ]
    }
}

// The run loop of a thread that ended. It never runs, so its observers never fire.
private func idleRunLoop() -> sending CFRunLoop {
    final class Box: @unchecked Sendable { var loop: CFRunLoop? }
    let box = Box()
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        box.loop = CFRunLoopGetCurrent()
        done.signal()
    }
    thread.start()
    done.wait()
    return box.loop!
}

@MainActor
private final class Fixture {
    let clock = ManualClock()
    let processes = CountingProcesses()
    let temp: TemporaryFolder
    let reporter: HealthReporter
    let monitor: PerformanceMonitor

    init(watch: MainThreadWatch = MainThreadWatch()) throws {
        temp = try TemporaryFolder()
        let (reporter, events) = HealthReporter.make()
        self.reporter = reporter
        let samplers = PerformanceSamplers(
            app: AppUsage(
                processes: processes, app: appPID, terminals: { [] }, rows: { [] },
                chatPanels: { [] }),
            mac: MacState(
                pressure: { nil }, swap: { nil }, cpuTicks: { nil }, thermal: { .nominal },
                battery: { nil }),
            network: nil, disk: DiskState(home: temp.url, clones: nil), github: nil,
            mainThread: watch)
        monitor = PerformanceMonitor(
            events: events, samplers: samplers, log: HealthLog(folder: temp.url), clock: clock,
            now: { start })
    }

    func end() {
        monitor.end()
        temp.remove()
    }

    // Move the clock to the next tick and wait for its end.
    func nextTick(after time: Duration) async {
        await clock.waitForSleepers(exactly: 1)
        clock.advance(by: time)
        await monitor.timerTask?.value
        await monitor.tickTask?.value
    }

    // The lines of the health log.
    var logLines: [String] {
        guard let data = try? Data(contentsOf: temp.url.appending(path: "health.log")) else {
            return []
        }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

@MainActor
@Suite("performance monitor")
struct PerformanceMonitorTests {
    @Test func theTickIs15sAnd2sWhileThePanelShows() async throws {
        let f = try Fixture()
        defer { f.end() }
        #expect(PerformanceMonitor.tick == .seconds(15))
        #expect(PerformanceMonitor.panelTick == .seconds(2))
        f.monitor.start()
        f.monitor.start()
        await f.monitor.tickTask?.value
        #expect(f.processes.reads == 1)
        await f.clock.waitForSleepers(exactly: 1)
        f.clock.advance(by: .seconds(14))
        #expect(f.processes.reads == 1)
        await f.nextTick(after: .seconds(1))
        #expect(f.processes.reads == 2)
        // The panel shows: the next tick comes 2 s after the end of the last one.
        f.monitor.panelShown(true)
        await f.nextTick(after: .seconds(2))
        #expect(f.processes.reads == 3)
        await f.nextTick(after: .seconds(2))
        #expect(f.processes.reads == 4)
        // The panel closed: 15 s again.
        f.monitor.panelShown(false)
        await f.clock.waitForSleepers(exactly: 1)
        f.clock.advance(by: .seconds(14))
        #expect(f.processes.reads == 4)
        await f.nextTick(after: .seconds(1))
        #expect(f.processes.reads == 5)
    }

    @Test func theFirstTickGivesNoValuesAndTheSecondGivesOK() async throws {
        let f = try Fixture()
        defer { f.end() }
        #expect(f.monitor.snapshot.level == nil)
        #expect(f.monitor.snapshot.headline == "Checking Bifrost…")
        f.monitor.start()
        await f.monitor.tickTask?.value
        // The first tick adds no sample, so the monitor still checks.
        #expect(f.monitor.snapshot.level == nil)
        #expect(f.monitor.snapshot.bifrost.use == nil)
        await f.nextTick(after: PerformanceMonitor.tick)
        #expect(f.monitor.snapshot.level == .ok)
        #expect(f.monitor.snapshot.headline == "Bifrost is using 400 MB RAM and 1% CPU.")
        #expect(f.monitor.snapshot.bifrost.use?.app.memory == mb(400))
        #expect(f.monitor.snapshot.bifrost.trend.count == 1)
        // The monitor has no network sampler, so the snapshot has no network values.
        #expect(f.monitor.snapshot.network == nil)
    }

    @Test func aGapAfterASleepGivesCheckingAgain() async throws {
        let f = try Fixture()
        defer { f.end() }
        f.monitor.start()
        await f.monitor.tickTask?.value
        await f.nextTick(after: PerformanceMonitor.tick)
        #expect(f.monitor.snapshot.level == .ok)
        // The Mac slept for 2 minutes: the timer wakes once, and the tick finds the gap.
        await f.nextTick(after: .seconds(120))
        #expect(f.processes.reads == 3)
        #expect(f.monitor.snapshot.level == nil)
        #expect(f.monitor.snapshot.bifrost.trend.isEmpty)
        await f.nextTick(after: PerformanceMonitor.tick)
        #expect(f.monitor.snapshot.level == .ok)
    }

    @Test func eachHealthEventIsCounted() async throws {
        let f = try Fixture()
        defer { f.end() }
        for _ in 0..<3 { f.reporter.record(.poll(.sessions, .failed)) }
        await waitUntil { f.monitor.snapshot.reasons.count == 1 }
        #expect(f.monitor.snapshot.level == .warning)
        #expect(f.monitor.snapshot.headline == "Warning")
        #expect(
            f.monitor.snapshot.reasons.map(\.text) == [
                "Bifrost couldn't check for sessions 3 times in a row."
            ])
        f.reporter.record(.saveFailed(what: "the settings"))
        f.reporter.record(.liveStart(failed: "No socket."))
        await waitUntil { f.monitor.snapshot.reasons.count == 3 }
        #expect(f.monitor.snapshot.clearable)
        // Each past event also goes to the health log.
        await waitUntil { f.logLines.count == 5 }
        #expect(
            f.logLines.map { $0.split(separator: " ", maxSplits: 1).last.map(String.init) } == [
                "poll failed: sessions (1 in a row)", "poll failed: sessions (2 in a row)",
                "poll failed: sessions (3 in a row)", "save failed: the settings",
                "live details did not start: No socket.",
            ])
    }

    // A slow pass of the main thread goes to the health log one time. The next ticks read the same
    // window, so they add no line. A later window with a slow pass adds one line.
    @Test func aSlowMainThreadGoesToTheHealthLogOncePerWindow() async throws {
        let time = Mutex(Duration.seconds(10))
        // The run loop of a thread that ended never runs, so only the passes of the test count.
        let watch = MainThreadWatch(runLoop: idleRunLoop(), elapsed: { time.withLock { $0 } })
        let f = try Fixture(watch: watch)
        defer { f.end() }
        watch.recordPass(.milliseconds(250))
        time.withLock { $0 = .seconds(70) }
        f.monitor.start()
        await f.monitor.tickTask?.value
        await waitUntil { f.logLines.count == 1 }
        #expect(f.logLines.first?.hasSuffix(" main thread slow to respond: up to 250 ms") == true)
        await f.nextTick(after: PerformanceMonitor.tick)
        await f.nextTick(after: PerformanceMonitor.tick)
        #expect(f.processes.reads == 3)
        #expect(f.logLines.count == 1)
        // The next window has a pass that is not slow, and then one that is.
        watch.recordPass(.milliseconds(90))
        time.withLock { $0 = .seconds(130) }
        await f.nextTick(after: PerformanceMonitor.tick)
        watch.recordPass(.milliseconds(1500))
        time.withLock { $0 = .seconds(190) }
        await f.nextTick(after: PerformanceMonitor.tick)
        await waitUntil { f.logLines.count == 2 }
        #expect(f.logLines.last?.hasSuffix(" main thread slow to respond: up to 1500 ms") == true)
    }

    @Test func clearSendsANewSnapshotAtOnce() async throws {
        let f = try Fixture()
        defer { f.end() }
        f.processes.setMemory(1200)
        f.monitor.start()
        await f.monitor.tickTask?.value
        await f.nextTick(after: PerformanceMonitor.tick)
        for _ in 0..<3 { f.reporter.record(.poll(.accountUsage, .failed)) }
        await waitUntil { f.monitor.snapshot.reasons.count == 2 }
        #expect(f.monitor.snapshot.clearable)
        f.monitor.clear()
        // No tick ran: the clear builds the snapshot at once. The live measurement stays.
        #expect(f.processes.reads == 2)
        #expect(
            f.monitor.snapshot.reasons.map(\.text) == [
                "Bifrost's own processes are using 1.2 GB RAM, above the 1 GB limit."
            ])
        #expect(!f.monitor.snapshot.clearable)
        #expect(f.monitor.snapshot.level == .warning)
        await waitUntil { f.logLines.last?.hasSuffix(" cleared by the user") == true }
    }

    @Test func aStopAndStartStillCountsEvents() async throws {
        let f = try Fixture()
        defer { f.end() }
        f.monitor.start()
        await f.monitor.tickTask?.value
        for _ in 0..<2 { f.reporter.record(.poll(.serviceStatus, .failed)) }
        await waitUntil { f.logLines.count == 2 }
        f.monitor.stop()
        // The stop gates only the sampling: the events still count.
        f.reporter.record(.poll(.serviceStatus, .failed))
        await waitUntil { f.monitor.snapshot.reasons.count == 1 }
        #expect(f.monitor.snapshot.level == .warning)
        f.monitor.start()
        await f.monitor.tickTask?.value
        for _ in 0..<7 { f.reporter.record(.poll(.serviceStatus, .failed)) }
        await waitUntil { f.monitor.snapshot.level == .problem }
        #expect(
            f.monitor.snapshot.reasons.map(\.text) == [
                "Bifrost couldn't check Claude's status 10 times in a row."
            ])
    }

    @Test func aDroppedMonitorRemovesTheObserversOfItsWatch() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let clock = ManualClock()
        let watch = MainThreadWatch()
        var monitor: PerformanceMonitor? = PerformanceMonitor(
            events: AsyncStream { _ in },
            samplers: PerformanceSamplers(
                app: AppUsage(
                    processes: CountingProcesses(), app: appPID, terminals: { [] },
                    rows: { [] }, chatPanels: { [] }),
                mac: MacState(
                    pressure: { nil }, swap: { nil }, cpuTicks: { nil }, thermal: { .nominal },
                    battery: { nil }),
                network: nil, disk: DiskState(home: temp.url, clones: nil), github: nil,
                mainThread: watch),
            log: HealthLog(folder: temp.url), clock: clock, now: { start })
        monitor?.start()
        await monitor?.tickTask?.value
        let observers = watch.installedObservers
        #expect(observers.count == 2)
        // The owner drops the monitor with no stop() or end().
        monitor = nil
        #expect(!observers.contains(where: CFRunLoopObserverIsValid))
    }

    @Test func theFrameRateCountsOnlyWhileThePanelShows() async throws {
        let f = try Fixture()
        defer { f.end() }
        f.monitor.frameRate(20)
        f.monitor.frameRate(20)
        #expect(f.monitor.snapshot.reasons.isEmpty)
        f.monitor.panelShown(true)
        f.monitor.frameRate(20)
        #expect(f.monitor.snapshot.bifrost.frameRate == 20)
        f.monitor.frameRate(25)
        #expect(f.monitor.snapshot.reasons.map(\.level) == [.warning])
        // The counter stopped (the window lost the focus): a new count starts.
        f.monitor.frameCountStopped()
        #expect(f.monitor.snapshot.reasons.isEmpty)
        #expect(f.monitor.snapshot.bifrost.frameRate == nil)
    }
}
