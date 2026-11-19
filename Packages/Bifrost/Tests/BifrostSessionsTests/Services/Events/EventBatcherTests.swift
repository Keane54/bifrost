import BifrostSessions
import BifrostTestSupport
import Testing

// The batcher of the Event log (docs/behaviour/panels.md, The Event log panel): it sends the
// first entries at once, then at most one batch each 250 ms. The tests move a manual clock.

private func entry(_ seq: Int) -> LogEntry {
    LogEntry(seq: seq, at: seq, sessionId: "s1", name: .stop)
}

// A batcher on a manual clock that records each send.
@MainActor
private struct Batching {
    let clock = ManualClock()
    let sent = Recorder<[LogEntry]>()
    let batcher: EventBatcher

    init() {
        let sent = sent
        batcher = EventBatcher(clock: clock) { sent.record($0) }
    }

    // Move the clock, then wait until the timer of the batcher ends or sleeps again.
    func advance(_ duration: Duration) async {
        clock.advance(by: duration)
        await batcher.timer?.value
    }
}

@MainActor
@Suite("event batcher")
struct EventBatcherTests {
    @Test func theBatcherSendsAtOnceThenAtMostOnceEach250ms() async {
        #expect(EventBatcher.gap == .milliseconds(250))
        let test = Batching()
        test.batcher.push([entry(1)])
        #expect(test.sent.values == [[entry(1)]])
        await test.clock.waitForSleepers(1)
        test.clock.advance(by: .milliseconds(100))
        test.batcher.push([entry(2)])
        test.clock.advance(by: .milliseconds(100))
        test.batcher.push([entry(3)])
        test.clock.advance(by: .milliseconds(49))
        // The timer of the gap still sleeps: 249 ms passed.
        #expect(test.clock.sleeperCount == 1)
        #expect(test.sent.values.count == 1)
        test.clock.advance(by: .milliseconds(1))
        await test.clock.waitForSleepers(1)
        #expect(test.sent.values == [[entry(1)], [entry(2), entry(3)]])
    }

    @Test func aPushAfterAQuietGapSendsAtOnceAgain() async {
        let test = Batching()
        test.batcher.push([entry(1)])
        await test.clock.waitForSleepers(1)
        await test.advance(.milliseconds(300))
        #expect(test.batcher.timer == nil)
        test.batcher.push([entry(2)])
        #expect(test.sent.values == [[entry(1)], [entry(2)]])
    }

    @Test func stopDropsTheWaitingEntries() async {
        let test = Batching()
        test.batcher.push([entry(1)])
        test.batcher.push([entry(2)])
        test.batcher.stop()
        await test.advance(.seconds(1))
        test.batcher.push([entry(3)])
        #expect(test.sent.values == [[entry(1)]])
        #expect(test.batcher.timer == nil)
    }

    @Test func anEmptyPushSendsNothingAndStartsNoTimer() {
        let test = Batching()
        test.batcher.push([])
        #expect(test.sent.values.isEmpty)
        #expect(test.batcher.timer == nil)
    }

    // A flood of single pushes during one gap gives one batch with all of them, in order.
    @Test func aFloodInOneGapGivesOneBatch() async {
        let test = Batching()
        for seq in 1...20_000 { test.batcher.push([entry(seq)]) }
        #expect(test.sent.values.count == 1)
        await test.clock.waitForSleepers(1)
        test.clock.advance(by: EventBatcher.gap)
        await test.clock.waitForSleepers(1)
        #expect(test.sent.values.count == 2)
        #expect(test.sent.values.last?.map(\.seq) == Array(2...20_000))
    }
}
