// The measurement of the debug bench: the frame counter by the gap method, the
// display check of the warm-up and the process usage (proc_pid_rusage). The counter gets synthetic
// frame times, so no test needs a display.
import Darwin
import Testing

@testable import BifrostApp

@MainActor
private let period = 1.0 / 120

@MainActor
@Suite("bench metrics")
struct MetricsTests {
    // A gap of n display periods between two frames counts n - 1 missed frames. The gap is
    // rounded to whole periods, as in the prototype.
    @Test func aGapOfThreePeriodsCountsTwoMissedFrames() {
        var counter = FrameCounter()
        counter.tick(at: 10, period: period)
        counter.tick(at: 10 + period, period: period)
        #expect(counter.missed == 0)
        counter.tick(at: 10 + 4 * period, period: period)
        #expect(counter.frames == 3)
        #expect(counter.missed == 2)
        #expect(counter.excludedSeconds == 0)
        // 1.4 periods round to 1 (no missed frame), and 1.6 periods round to 2 (one).
        counter.tick(at: 10 + 5.4 * period, period: period)
        #expect(counter.missed == 2)
        counter.tick(at: 10 + 7 * period, period: period)
        #expect(counter.missed == 3)
        // The period of the display link replaces the last one. A period of 0 keeps it.
        counter.tick(at: 10 + 7 * period + 1.0 / 60, period: 1.0 / 60)
        #expect(counter.missed == 3)
        #expect(counter.period == 1.0 / 60)
        counter.tick(at: 10 + 7 * period + 2.0 / 60, period: 0)
        #expect(counter.period == 1.0 / 60)
        #expect(counter.missed == 3)
    }

    // A snapshot blocks the main thread, so the next gap comes from the measurement. That gap
    // counts no missed frame, and its time goes to the excluded seconds. Only the next gap.
    @Test func aSnapshotGapIsLeftOut() {
        var counter = FrameCounter()
        counter.tick(at: 0, period: period)
        counter.leaveOutNextGap()
        counter.tick(at: 5 * period, period: period)
        #expect(counter.missed == 0)
        #expect(abs(counter.excludedSeconds - 5 * period) < 1e-12)
        counter.tick(at: 8 * period, period: period)
        #expect(counter.missed == 2)
        #expect(abs(counter.excludedSeconds - 5 * period) < 1e-12)
        #expect(counter.frames == 3)
        // A mark before the first frame stays until the first gap, so the first gap is left out.
        var fresh = FrameCounter()
        fresh.leaveOutNextGap()
        fresh.tick(at: 1, period: period)
        fresh.tick(at: 1 + 3 * period, period: period)
        #expect(fresh.missed == 0)
        #expect(abs(fresh.excludedSeconds - 3 * period) < 1e-12)
    }

    // The warm-up of 2 s must give a display period of 1/120 s within 2 %. The median gap
    // decides, so long gaps (a burst of output at the start) do not fail a display at 120 Hz.
    // The median needs 60 gaps at least.
    @Test func theWarmUpNeedsADisplayAt120Hz() {
        let even = Array(repeating: period, count: 239)
        #expect(DisplayCheck.matches(gaps: even))
        let someLong = even.enumerated().map { $0.offset % 10 == 0 ? 3 * period : $0.element }
        #expect(DisplayCheck.matches(gaps: someLong))
        #expect(DisplayCheck.matches(gaps: even.map { $0 * 1.019 }))
        #expect(!DisplayCheck.matches(gaps: even.map { $0 * 1.021 }))
        #expect(!DisplayCheck.matches(gaps: even.map { $0 * 0.979 }))
        #expect(!DisplayCheck.matches(gaps: Array(repeating: 1.0 / 60, count: 119)))
        // 203 frames with 40 long gaps: the median is still the period of 120 Hz.
        let burst = Array(repeating: period, count: 162) + Array(repeating: 4 * period, count: 40)
        #expect(DisplayCheck.matches(gaps: burst))
        #expect(DisplayCheck.matches(gaps: Array(repeating: period, count: 60)))
        #expect(!DisplayCheck.matches(gaps: Array(repeating: period, count: 59)))
        #expect(DisplayCheck.median([3, 1, 2]) == 2)
        #expect(DisplayCheck.median([4, 1, 2, 3]) == 2.5)
        #expect(DisplayCheck.median([]) == nil)
        // An occluded window gets few frames or none.
        #expect(!DisplayCheck.matches(gaps: []))
        #expect(!DisplayCheck.matches(gaps: Array(repeating: period, count: 10)))
    }

    // The footprint, the instructions and the CPU time of a process by its pid. A pid that does
    // not exist gives nil.
    @Test func theUsageOfAProcessComesFromItsPid() throws {
        let usage = try #require(ProcessMetrics.usage(of: getpid()))
        #expect(usage.footprint > 1_000_000)
        #expect(usage.instructions > 0)
        #expect(usage.cpuSeconds > 0)
        // The CPU time is the CPU time of getrusage (a wrong time base gives a factor of 40).
        var own = rusage()
        getrusage(RUSAGE_SELF, &own)
        let user = Double(own.ru_utime.tv_sec) + Double(own.ru_utime.tv_usec) / 1e6
        let system = Double(own.ru_stime.tv_sec) + Double(own.ru_stime.tv_usec) / 1e6
        let after = try #require(ProcessMetrics.usage(of: getpid()))
        #expect(usage.cpuSeconds <= user + system + 0.05)
        #expect(after.cpuSeconds >= (user + system) * 0.8 - 0.05)
        #expect(ProcessMetrics.usage(of: -1) == nil)
        // The CPU times of proc_pid_rusage are Mach time units. A time base of 125/3 gives
        // 24 million units a second (Apple silicon).
        #expect(ProcessMetrics.seconds(ticks: 24_000_000, numer: 125, denom: 3) == 1)
        #expect(ProcessMetrics.seconds(ticks: 1_500_000_000, numer: 1, denom: 1) == 1.5)
        #expect(ProcessMetrics.seconds(ticks: 5, numer: 1, denom: 0) == 0)
    }
}
