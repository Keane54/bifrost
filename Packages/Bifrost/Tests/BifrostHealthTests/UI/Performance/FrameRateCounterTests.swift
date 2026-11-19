// The frame counter of the Performance panel: 2 s bursts of frames in each 10 s, only while the
// panel shows and its window has the focus. The test gives the frames by hand, so it needs no
// display.
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostHealth

@MainActor
private final class Reports {
    var rates: [Double] = []
    var stops = 0
}

@MainActor
@Suite("performance frame counter")
struct FrameRateCounterTests {
    @Test func noFramesAreCountedBetweenBursts() async {
        let clock = ManualClock()
        let reports = Reports()
        let counter = FrameRateCounter(
            clock: clock, report: { reports.rates.append($0) }, stopped: { reports.stops += 1 })
        // No burst runs before the counter is active.
        for _ in 0..<10 { counter.frame() }
        counter.setActive(true)
        await clock.waitForSleepers(exactly: 1)
        for _ in 0..<60 { counter.frame() }
        clock.advance(by: FrameRateCounter.burst)
        await clock.waitForSleepers(exactly: 1)
        #expect(reports.rates == [30])
        // Between the bursts, a frame does not count.
        for _ in 0..<100 { counter.frame() }
        clock.advance(by: FrameRateCounter.period - FrameRateCounter.burst)
        await clock.waitForSleepers(exactly: 1)
        for _ in 0..<40 { counter.frame() }
        clock.advance(by: FrameRateCounter.burst)
        await clock.waitForSleepers(exactly: 1)
        #expect(reports.rates == [30, 20])
        // The panel closed during a burst: the burst ends with no value.
        clock.advance(by: FrameRateCounter.period - FrameRateCounter.burst)
        await clock.waitForSleepers(exactly: 1)
        for _ in 0..<50 { counter.frame() }
        counter.setActive(false)
        counter.setActive(false)
        await clock.waitUntilNoSleepers()
        #expect(reports.stops == 1)
        clock.advance(by: FrameRateCounter.period)
        #expect(reports.rates == [30, 20])
    }

    @Test func aDroppedActiveCounterEndsItsBursts() async {
        let clock = ManualClock()
        let reports = Reports()
        var counter: FrameRateCounter? = FrameRateCounter(
            clock: clock, report: { reports.rates.append($0) }, stopped: { reports.stops += 1 })
        weak let gone = counter
        counter?.setActive(true)
        await clock.waitForSleepers(exactly: 1)
        // The owner drops the counter while a burst runs, with no setActive(false).
        counter = nil
        #expect(gone == nil)
        await clock.waitUntilNoSleepers()
        clock.advance(by: FrameRateCounter.period * 3)
        #expect(reports.rates.isEmpty)
    }
}
