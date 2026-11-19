import BifrostTestSupport
import Testing

@testable import BifrostFoundation

// The one timer slot of the shells: a generation number, one task, the
// stop, and the check of Task.isCancelled and of the generation after the sleep, on an injected
// clock. The tests move a manual clock.
@MainActor
@Suite("timer slot", .testTimeLimit)
struct TimerSlotTests {
    @Test func theActionRunsAfterTheDurationOneTime() async {
        let clock = ManualClock()
        let slot = TimerSlot(clock: clock)
        var fired = 0
        slot.start(after: .milliseconds(500)) { fired += 1 }
        #expect(slot.isRunning)
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(499))
        // The timer still sleeps, so its action did not run.
        #expect(clock.sleeperCount == 1)
        #expect(fired == 0)
        clock.advance(by: .milliseconds(1))
        await waitUntil { fired == 1 }
        #expect(!slot.isRunning)
        #expect(slot.task == nil)
    }

    // A new start stops the timer that waits: only the new action runs, at its own deadline.
    @Test func aStartStopsTheTimerThatWaits() async {
        let clock = ManualClock()
        let slot = TimerSlot(clock: clock)
        var fired: [String] = []
        slot.start(after: .milliseconds(500)) { fired.append("first") }
        await clock.waitForSleepers(1)
        let first = slot.task
        clock.advance(by: .milliseconds(300))
        slot.start(after: .milliseconds(500)) { fired.append("second") }
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(300))
        await first?.value
        #expect(clock.sleeperCount == 1)
        #expect(fired.isEmpty)
        clock.advance(by: .milliseconds(200))
        await waitUntil { fired == ["second"] }
    }

    @Test func aStopMeansTheActionNeverRuns() async {
        let clock = ManualClock()
        let slot = TimerSlot(clock: clock)
        var fired = 0
        slot.start(after: .milliseconds(100)) { fired += 1 }
        await clock.waitForSleepers(1)
        let task = slot.task
        slot.stop()
        #expect(!slot.isRunning)
        clock.advance(by: .seconds(1))
        await task?.value
        #expect(fired == 0)
    }

    // Carried item 4: the sleep of a timer ended (the clock woke it), and the timer stopped
    // before its task ran. The task must not act, and it must not end a newer timer.
    @Test func aSleepThatEndsAfterTheStopDoesNotAct() async {
        let clock = ManualClock()
        let slot = TimerSlot(clock: clock)
        var fired: [String] = []
        slot.start(after: .milliseconds(100)) { fired.append("old") }
        await clock.waitForSleepers(1)
        let old = slot.task
        // The move wakes the sleeper now, but its task runs only in a later turn of the main
        // actor. The new start comes first.
        clock.advance(by: .milliseconds(100))
        slot.start(after: .milliseconds(100)) { fired.append("new") }
        await old?.value
        #expect(fired.isEmpty)
        #expect(slot.isRunning)
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(100))
        await waitUntil { fired == ["new"] }
    }

    // The deadline is the time of the start plus the duration, so a late start of the task
    // does not make the wait longer: the clock moves before the task sleeps.
    @Test func theDeadlineCountsFromTheStart() async {
        let clock = ManualClock()
        let slot = TimerSlot(clock: clock)
        var fired = 0
        slot.start(after: .milliseconds(100)) { fired += 1 }
        clock.advance(by: .milliseconds(60))
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(40))
        await waitUntil { fired == 1 }
    }

    // The action can start the next timer of the slot.
    @Test func theActionCanStartTheNextTimer() async {
        let clock = ManualClock()
        let slot = TimerSlot(clock: clock)
        var fired = 0
        func again() {
            fired += 1
            if fired < 3 { slot.start(after: .milliseconds(10)) { again() } }
        }
        slot.start(after: .milliseconds(10)) { again() }
        for _ in 0..<3 {
            await clock.waitForSleepers(1)
            let task = slot.task
            clock.advance(by: .milliseconds(10))
            await task?.value
        }
        #expect(fired == 3)
        #expect(!slot.isRunning)
    }
}
