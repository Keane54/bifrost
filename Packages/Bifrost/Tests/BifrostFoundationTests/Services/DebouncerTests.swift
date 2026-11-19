import BifrostTestSupport
import Testing

@testable import BifrostFoundation

// The debounce of the shells: one task that sleeps to a deadline, on a manual clock.
@MainActor
@Suite("debouncer", .testTimeLimit)
struct DebouncerTests {
    @Test func aBurstMakesOneRunAfterTheQuietTimeOfTheLastEvent() async {
        let clock = ManualClock()
        let debouncer = Debouncer(clock: clock)
        var fired: [String] = []
        debouncer.schedule(after: .milliseconds(150)) { fired.append("first") }
        #expect(debouncer.isPending)
        await clock.waitForSleepers(1)
        let task = debouncer.task
        clock.advance(by: .milliseconds(100))
        debouncer.schedule(after: .milliseconds(150)) { fired.append("second") }
        // A new event moves the deadline: the task stays the same.
        #expect(debouncer.task == task)
        clock.advance(by: .milliseconds(100))
        // The task woke at the old deadline and sleeps again to the new one.
        await clock.waitForSleepers(1)
        #expect(fired.isEmpty)
        clock.advance(by: .milliseconds(50))
        await waitUntil { fired == ["second"] }
        #expect(!debouncer.isPending)
    }

    // An event with an earlier deadline makes a new task, so the run is not late.
    @Test func anEarlierDeadlineRunsAtItsTime() async {
        let clock = ManualClock()
        let debouncer = Debouncer(clock: clock)
        var fired = 0
        debouncer.schedule(after: .seconds(10)) { fired += 1 }
        await clock.waitForSleepers(1)
        let late = debouncer.task
        debouncer.schedule(after: .milliseconds(100)) { fired += 1 }
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(100))
        await waitUntil { fired == 1 }
        clock.advance(by: .seconds(10))
        await late?.value
        #expect(fired == 1)
    }

    // The task holds no reference to the debouncer while it sleeps, so a dropped debouncer
    // cancels its pending action.
    @Test func aDroppedDebouncerRunsNoAction() async {
        let clock = ManualClock()
        var fired = 0
        weak var weakDebouncer: Debouncer?
        var task: Task<Void, Never>?
        do {
            let debouncer = Debouncer(clock: clock)
            weakDebouncer = debouncer
            debouncer.schedule(after: .milliseconds(100)) { fired += 1 }
            await clock.waitForSleepers(1)
            task = debouncer.task
        }
        #expect(weakDebouncer == nil)
        clock.advance(by: .milliseconds(200))
        await task?.value
        #expect(fired == 0)
    }

    @Test func aCancelMeansTheActionNeverRuns() async {
        let clock = ManualClock()
        let debouncer = Debouncer(clock: clock)
        var fired = 0
        debouncer.schedule(after: .milliseconds(100)) { fired += 1 }
        await clock.waitForSleepers(1)
        let task = debouncer.task
        debouncer.cancel()
        #expect(!debouncer.isPending)
        clock.advance(by: .seconds(1))
        await task?.value
        #expect(fired == 0)
    }

    // The action can schedule the next run.
    @Test func theActionCanScheduleAgain() async {
        let clock = ManualClock()
        let debouncer = Debouncer(clock: clock)
        var fired = 0
        func again() {
            debouncer.schedule(after: .milliseconds(100)) {
                fired += 1
                if fired == 1 { again() }
            }
        }
        again()
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(100))
        await waitUntil { fired == 1 }
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(100))
        await waitUntil { fired == 2 }
    }
}
