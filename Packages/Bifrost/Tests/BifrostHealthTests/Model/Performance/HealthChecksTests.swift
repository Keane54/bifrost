// The checks of the Performance monitor (docs/behaviour/health.md, "Performance"): one test for
// each check at its limits.
import BifrostFoundation
import Foundation
import Testing

@testable import BifrostHealth

private let utc = TimeZone(identifier: "UTC") ?? .current
private let start = wall(2026, 11, 18, 9, 0)

// The input at a time: the wall time follows the time of the timeline.
private func input(
    at seconds: Int = 3615, history: SampleHistory = SampleHistory(), frameRates: [Double] = [],
    delay: Duration? = nil, events: PastEvents = PastEvents(), online: Bool = true,
    orphans: Int = 0
) -> HealthInput {
    HealthInput(
        now: .seconds(seconds), wall: start.addingTimeInterval(Double(seconds)),
        history: history, frameRates: frameRates, mainThreadDelay: delay, events: events,
        online: online, orphans: orphans)
}

private func reasons(_ input: HealthInput) -> [HealthReason] {
    HealthChecks.reasons(input, zone: utc)
}

// The reasons of a history whose app memory stays at the value.
private func memoryReasons(_ megabytes: Double) -> [HealthReason] {
    reasons(input(at: 30, history: history(until: 30) { _ in megabytes }))
}

// The reasons of a history with one chat terminal of the size.
private func terminalReasons(_ megabytes: Double) -> [HealthReason] {
    var samples = SampleHistory()
    for at in [0, 15] {
        samples.add(
            tableRead(at: at, app: (300, 0), terminals: [(terminalPID, megabytes, 0)]),
            app: appPID, terminals: [terminalPID])
    }
    return reasons(input(at: 15, history: samples))
}

private func warning(_ text: String, past: Bool = false) -> HealthReason {
    HealthReason(level: .warning, text: text, past: past)
}

private func problem(_ text: String, past: Bool = false) -> HealthReason {
    HealthReason(level: .problem, text: text, past: past)
}

@Suite("performance health checks")
struct HealthChecksTests {
    @Test func bifrostsOwnMemoryWarnsAbove1GBAndIsAProblemAbove1Point5GB() {
        #expect(memoryReasons(1024).isEmpty)
        #expect(
            memoryReasons(1024 + 1) == [
                warning("Bifrost's own processes are using 1.01 GB RAM, above the 1 GB limit.")
            ])
        #expect(
            memoryReasons(1536)
                == [warning("Bifrost's own processes are using 1.5 GB RAM, above the 1 GB limit.")])
        #expect(
            memoryReasons(1843)
                == [
                    problem("Bifrost's own processes are using 1.8 GB RAM, above the 1.5 GB limit.")
                ])
    }

    @Test func theChatTerminalsDoNotCountForTheMemoryLimits() {
        // Bifrost uses 300 MB and three terminals 400 MB each: 1.5 GB in all, and no reason.
        var samples = SampleHistory()
        let terminals: [(pid: pid_t, memory: Double, cpu: Double)] = [
            (20, 400, 0), (21, 400, 0), (22, 400, 0),
        ]
        for at in [0, 15] {
            samples.add(
                tableRead(at: at, app: (300, 0), terminals: terminals), app: appPID,
                terminals: [20, 21, 22])
        }
        #expect(reasons(input(at: 15, history: samples)).isEmpty)
    }

    @Test func aChatTerminalAbove500MBWarns() {
        #expect(terminalReasons(500).isEmpty)
        // 500.3 MB shows as 500 MB, so it gives no reason: a text never shows its limit.
        #expect(terminalReasons(500.3).isEmpty)
        #expect(
            terminalReasons(500.6)
                == [warning("A chat terminal is using 501 MB RAM, above the 500 MB limit.")])
        #expect(
            terminalReasons(1612)
                == [warning("A chat terminal is using 1,612 MB RAM, above the 500 MB limit.")])
    }

    @Test func theGrowthWarnsAbove300AndIsAProblemAbove800MBAnHour() {
        func growthReasons(_ perHour: Double) -> [HealthReason] {
            let samples = history(until: 3615) { 200 + perHour * Double($0) / 3600 }
            return reasons(input(at: 3615, history: samples))
        }
        #expect(growthReasons(300).isEmpty)
        #expect(
            growthReasons(301) == [warning("Bifrost's memory is growing by about 301 MB an hour.")])
        #expect(
            growthReasons(800) == [warning("Bifrost's memory is growing by about 800 MB an hour.")])
        #expect(
            growthReasons(801) == [problem("Bifrost's memory is growing by about 801 MB an hour.")])
    }

    @Test func theCPUWarnsAbove50AndIsAProblemAbove100PercentOfOneCore() {
        func cpuReasons(_ cpu: Double) -> [HealthReason] {
            reasons(input(at: 135, history: history(until: 135, cpu: cpu)))
        }
        #expect(cpuReasons(50).isEmpty)
        #expect(
            cpuReasons(51)
                == [warning("Bifrost is using 51% CPU on average over the last 2 minutes.")])
        #expect(
            cpuReasons(100)
                == [warning("Bifrost is using 100% CPU on average over the last 2 minutes.")])
        #expect(
            cpuReasons(101)
                == [problem("Bifrost is using 101% CPU on average over the last 2 minutes.")])
        // Before the samples cover 2 minutes, the CPU gives no reason.
        #expect(reasons(input(at: 120, history: history(until: 120, cpu: 200))).isEmpty)
        // With no fresh sample, the CPU and the growth give no reason.
        #expect(reasons(input(at: 3700, history: history(until: 3615, cpu: 200))).isEmpty)
    }

    @Test func aLowFrameRateNeedsTwoBurstsInARow() {
        let low = [warning("The Performance panel ran below 30 fps for 10 seconds.")]
        #expect(reasons(input(frameRates: [12])).isEmpty)
        #expect(reasons(input(frameRates: [31, 29])).isEmpty)
        #expect(reasons(input(frameRates: [30, 29])).isEmpty)
        #expect(reasons(input(frameRates: [29.9, 29])) == low)
    }

    @Test func theMainThreadDelayWarnsAbove200msAndIsAProblemAbove1s() {
        #expect(reasons(input(delay: .milliseconds(200))).isEmpty)
        #expect(
            reasons(input(delay: .milliseconds(201)))
                == [warning("Bifrost's main process was slow to respond (up to 201 ms).")])
        #expect(
            reasons(input(delay: .seconds(1)))
                == [warning("Bifrost's main process was slow to respond (up to 1000 ms).")])
        #expect(
            reasons(input(delay: .milliseconds(1001)))
                == [problem("Bifrost's main process was slow to respond (up to 1001 ms).")])
    }

    @Test func aFailedStartOfLiveDetailsWarnsUntilAGoodStart() {
        var events = PastEvents()
        let time = EventTime(at: .seconds(10), wall: start)
        let line = events.record(
            .liveStart(failed: "The socket is in use."), online: true, at: time)
        #expect(line == "live details did not start: The socket is in use.")
        let failed = [warning("Bifrost couldn't start the Live details link.", past: true)]
        #expect(reasons(input(events: events)) == failed)
        #expect(events.record(.liveStart(failed: nil), online: true, at: time) == nil)
        #expect(reasons(input(events: events)).isEmpty)
    }

    @Test func aTerminalWithNoChatWindowWarns() {
        #expect(reasons(input(orphans: 0)).isEmpty)
        #expect(
            reasons(input(orphans: 1))
                == [warning("1 chat terminal is running with no chat window.")])
        #expect(
            reasons(input(orphans: 2))
                == [warning("2 chat terminals are running with no chat window.")])
    }

    @Test func aFailedSaveWarnsForAnHour() {
        var events = PastEvents()
        let failedAt = EventTime(at: .seconds(100), wall: start.addingTimeInterval(180))
        let line = events.record(.saveFailed(what: "the settings"), online: true, at: failedAt)
        #expect(line == "save failed: the settings")
        _ = events.record(.saveFailed(what: "the Daily update state"), online: true, at: failedAt)
        #expect(
            reasons(input(at: 3699, events: events)) == [
                warning("Bifrost couldn't save your settings at 09:03.", past: true),
                warning("Bifrost couldn't save the Daily update state at 09:03.", past: true),
            ])
        #expect(reasons(input(at: 3700, events: events)).isEmpty)
    }

    @Test func noDataGivesCheckingNeverOK() {
        // No sample and no reason: Bifrost cannot know yet.
        #expect(reasons(input()).isEmpty)
        #expect(HealthChecks.level(of: [], measured: input().hasFreshSample) == nil)
        // A sample that is older than 60 s is no data either.
        let old = input(at: 91, history: history(until: 30) { _ in 2000 })
        #expect(!old.hasFreshSample)
        #expect(reasons(old).isEmpty)
        #expect(HealthChecks.level(of: reasons(old), measured: old.hasFreshSample) == nil)
        let fresh = input(at: 90, history: history(until: 30))
        #expect(fresh.hasFreshSample)
        #expect(HealthChecks.level(of: reasons(fresh), measured: true) == .ok)
        // A reason gives its level also with no sample.
        #expect(HealthChecks.level(of: reasons(input(orphans: 1)), measured: false) == .warning)
    }

    @Test func problemReasonsComeFirst() {
        let found = reasons(
            input(
                at: 30, history: history(until: 30) { _ in 1843 }, delay: .milliseconds(300),
                orphans: 1))
        #expect(found.map(\.level) == [.problem, .warning, .warning])
        #expect(found.first?.text.hasPrefix("Bifrost's own processes") == true)
        #expect(HealthChecks.level(of: found, measured: true) == .problem)
    }
}
