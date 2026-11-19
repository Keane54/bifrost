import BifrostTestSupport
import Testing

@testable import BifrostFoundation

// The race of a task against a time limit on the clock (firstResult). The race never cancels the
// task, so the work goes on after the limit and after a cancel of the caller.
@Suite("the race of a task against its limit", .timeLimit(.minutes(1)))
struct DeadlineTests {
    @Test func aTaskThatEndsFirstGivesItsValue() async {
        let clock = ManualClock()
        let work = Task { 42 }
        #expect(await firstResult(of: work, within: .seconds(5), on: clock) == 42)
        await clock.waitUntilNoSleepers()
    }

    // At the limit the race gives nil, and the task still runs to its end.
    @Test func theLimitGivesNilAndTheTaskGoesOn() async {
        let gate = TestGate()
        defer { gate.openAll() }
        let clock = ManualClock()
        let work = Task {
            await gate.pass()
            return 7
        }
        async let result = firstResult(of: work, within: .seconds(5), on: clock)
        await gate.waitUntilHolding(1)
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(5) - .milliseconds(1))
        #expect(gate.holding == 1)
        clock.advance(by: .milliseconds(1))
        #expect(await result == nil)
        #expect(!work.isCancelled)
        gate.open()
        #expect(await work.value == 7)
    }

    // A cancel of the caller gives nil at once, and the task is not cancelled.
    @Test func aCancelOfTheCallerGivesNilAndKeepsTheTask() async {
        let gate = TestGate()
        defer { gate.openAll() }
        let clock = ManualClock()
        let work = Task {
            await gate.pass()
            return 7
        }
        let call = Task { await firstResult(of: work, within: .seconds(5), on: clock) }
        await gate.waitUntilHolding(1)
        await clock.waitForSleepers(1)
        call.cancel()
        #expect(await call.value == nil)
        #expect(!work.isCancelled)
        await clock.waitUntilNoSleepers()
        gate.open()
        #expect(await work.value == 7)
    }
}
