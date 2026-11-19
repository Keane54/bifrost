import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostWindows

// The quit waits for the last write of the window bounds, for 2 s at most. The work waits at a
// gate. The work records its end as its last step: the reply of its end runs in the same turn,
// so a test that sees the end also sees that reply.
@Suite("quit wait", .serialized, .timeLimit(.minutes(1)), .tags(.window))
@MainActor
struct QuitWaitTests {
    @Test func theQuitRepliesWhenTheWriteEnds() async {
        let clock = ManualClock()
        let gate = TestGate()
        defer { gate.openAll() }
        let replies = Recorder<Void>()
        QuitWait.run(clock: clock, work: { await gate.pass() }, done: { replies.record(()) })
        await gate.waitUntilHolding()
        await clock.waitForSleepers(1)
        #expect(replies.values.isEmpty)
        gate.open()
        await waitUntil { replies.values.count == 1 }
        // The end of the work stops the timer, so the time limit gives no second reply.
        await clock.waitUntilNoSleepers()
        clock.advance(by: .seconds(2))
        #expect(replies.values.count == 1)
    }

    @Test func theQuitRepliesAfter2sWhenTheWriteDoesNotEnd() async {
        let clock = ManualClock()
        let gate = TestGate()
        defer { gate.openAll() }
        let replies = Recorder<Void>()
        let ended = Recorder<Void>()
        QuitWait.run(
            clock: clock,
            work: {
                await gate.pass()
                ended.record(())
            }, done: { replies.record(()) })
        await gate.waitUntilHolding()
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(1999))
        // The time limit still sleeps, so no reply went.
        #expect(clock.sleeperCount == 1)
        #expect(replies.values.isEmpty)
        clock.advance(by: .milliseconds(1))
        await waitUntil { replies.values.count == 1 }
        // A write that ends after the time limit gives no second reply.
        gate.open()
        await waitUntil { ended.values.count == 1 }
        #expect(replies.values.count == 1)
    }

    // The quit of the test port calls terminate inside a block of the main queue, and
    // terminateLater runs a nested run loop there. The main queue cannot drain inside its own
    // block, so the work (a task on the main actor) never starts. The time limit still gives the
    // reply: through the main run loop, in the nested loop of the block.
    @Test func theLimitHoldsInsideABlockOfTheMainQueue() async {
        let clock = ManualClock()
        let gate = TestGate()
        defer { gate.openAll() }
        var replies = 0
        let ended = Recorder<Void>()
        var workRanInTheBlock = false
        var repliedInTheBlock = false
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    QuitWait.run(
                        clock: clock,
                        work: {
                            await gate.pass()
                            ended.record(())
                        }, done: { replies += 1 })
                    // The time limit ends while the main queue runs this block.
                    DispatchQueue.global().async {
                        let end = Date().addingTimeInterval(10)
                        while clock.sleeperCount == 0 && Date() < end { usleep(1000) }
                        clock.advance(by: .seconds(2))
                    }
                    // The nested run loop of terminateLater, for 10 s at most.
                    let end = Date().addingTimeInterval(10)
                    while replies == 0 && Date() < end {
                        CFRunLoopRunInMode(.defaultMode, 0.01, false)
                    }
                    workRanInTheBlock = gate.arrivals > 0
                    repliedInTheBlock = replies == 1
                }
                finished.resume()
            }
        }
        #expect(!workRanInTheBlock)
        #expect(repliedInTheBlock)
        // The work starts after the block. Its end gives no second reply.
        await gate.waitUntilHolding()
        gate.open()
        await waitUntil { ended.values.count == 1 }
        #expect(replies == 1)
    }
}
