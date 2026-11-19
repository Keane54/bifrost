import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostFoundation

// The one owned worker of a type: its work runs one at a time, in the order of the adds.

@MainActor
@Suite("the serial worker", .timeLimit(.minutes(1)))
struct SerialWorkTests {
    // A work starts only after the work before it ended, also when the work before it waits.
    @Test func eachWorkStartsAfterTheWorkBeforeItEnded() async {
        let work = SerialWork()
        let gate = TestGate()
        let steps = Recorder<String>()
        work.add {
            steps.record("first starts")
            await gate.pass()
            steps.record("first ends")
        }
        work.add { steps.record("second") }
        #expect(await gate.waitUntilHolding())
        #expect(steps.values == ["first starts"])
        gate.openAll()
        await work.idle()
        #expect(steps.values == ["first starts", "first ends", "second"])
    }

    // run gives the result of its work, after the work that the worker took before it.
    @Test func runGivesTheResultInItsTurn() async {
        let work = SerialWork()
        let steps = Recorder<Int>()
        work.add { steps.record(1) }
        let result = await work.run { () -> Int in
            steps.record(2)
            return 42
        }
        #expect(result == 42)
        #expect(steps.values == [1, 2])
    }

    // A cancel of the caller does not reach the work: it runs to its end in the worker.
    @Test func aCancelOfTheCallerDoesNotStopTheWork() async {
        let work = SerialWork()
        let gate = TestGate()
        let caller = Task {
            await work.run { () -> Bool in
                await gate.pass()
                return Task.isCancelled
            }
        }
        #expect(await gate.waitUntilHolding())
        caller.cancel()
        gate.openAll()
        #expect(await caller.value == false)
    }
}
