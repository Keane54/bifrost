import BifrostTestSupport
import Dispatch
import Foundation
import Testing

@testable import BifrostFoundation

// The blocking executor runs the calls that can wait a long time on its own threads, so they
// never hold the threads of the cooperative pool. A run with a time limit races the clock.
@Suite("the blocking executor", .timeLimit(.minutes(1)))
struct BlockingExecutorTests {
    @Test func theWorkRunsOnTheQueueOfTheExecutor() async {
        let label = await BlockingExecutor.run {
            String(cString: __dispatch_queue_get_label(nil))
        }
        #expect(label == BlockingExecutor.label)
    }

    @Test func theWorkGivesItsResultAndItsError() async {
        struct Refused: Error, Equatable {}
        #expect(await BlockingExecutor.run { 6 * 7 } == 42)
        await #expect(throws: Refused()) {
            try await BlockingExecutor.run { () throws(Refused) -> Int in throw Refused() }
        }
    }

    // A work that ends in the limit gives its value, on a thread of the executor.
    @Test func aWorkWithinTheLimitGivesItsValue() async {
        let clock = ManualClock()
        let label = await BlockingExecutor.run(within: .seconds(2), on: clock, else: "late") {
            String(cString: __dispatch_queue_get_label(nil))
        }
        #expect(label == BlockingExecutor.label)
        #expect(await BlockingExecutor.run(within: .seconds(2), on: clock, else: 0) { 42 } == 42)
    }

    // A work that hangs gives the fallback at the limit on the clock.
    @Test func aWorkThatHangsGivesTheFallbackAtTheLimit() async {
        let gate = TestGate()
        defer { gate.openAll() }
        let clock = ManualClock()
        async let result = BlockingExecutor.run(within: .seconds(2), on: clock, else: -1) {
            gate.passBlocking()
            return 1
        }
        await gate.waitUntilHolding(1)
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(1999))
        #expect(gate.holding == 1)
        clock.advance(by: .milliseconds(1))
        #expect(await result == -1)
    }

    // The limit counts from the start of the work. While the work waits for a thread of its
    // executor, the clock can pass the limit, and the work still gives its value.
    @Test func theLimitCountsFromTheStartOfTheWork() async {
        let executor = HeldExecutor()
        let clock = ManualClock()
        async let result = BlockingExecutor.run(
            executor: executor, within: .seconds(2), on: clock, else: -1
        ) { 42 }
        await waitUntil { executor.heldCount == 1 }
        clock.advance(by: .seconds(5))
        #expect(clock.sleeperCount == 0)
        executor.release()
        #expect(await result == 42)
    }

    // A work that starts late and then hangs gives the fallback at the limit after its start.
    @Test func aWorkThatStartsLateAndHangsGivesTheFallback() async {
        let executor = HeldExecutor()
        let gate = TestGate()
        defer { gate.openAll() }
        let clock = ManualClock()
        async let result = BlockingExecutor.run(
            executor: executor, within: .seconds(2), on: clock, else: -1
        ) {
            gate.passBlocking()
            return 1
        }
        await waitUntil { executor.heldCount == 1 }
        clock.advance(by: .seconds(5))
        executor.release()
        await gate.waitUntilHolding(1)
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(1999))
        #expect(gate.holding == 1)
        clock.advance(by: .milliseconds(1))
        #expect(await result == -1)
    }

    // A cancel of the caller while the work waits for its start gives the fallback at once.
    @Test func aCancelBeforeTheStartGivesTheFallback() async {
        let executor = HeldExecutor()
        let clock = ManualClock()
        let call = Task {
            await BlockingExecutor.run(
                executor: executor, within: .seconds(2), on: clock, else: -1
            ) { 1 }
        }
        await waitUntil { executor.heldCount == 1 }
        call.cancel()
        #expect(await call.value == -1)
        executor.release()
    }

    @Test func aCancelOfTheCallerGivesTheFallback() async {
        let gate = TestGate()
        defer { gate.openAll() }
        let clock = ManualClock()
        let call = Task {
            await BlockingExecutor.run(within: .seconds(2), on: clock, else: -1) {
                await gate.pass()
                return 1
            }
        }
        await gate.waitUntilHolding(1)
        call.cancel()
        #expect(await call.value == -1)
    }

    // More blocked calls than CPU cores. If the calls held threads of the cooperative pool, the
    // other task could not run until a call ends, and the test would hang.
    @Test func blockedCallsDoNotStopTheOtherTasks() async {
        let count = ProcessInfo.processInfo.activeProcessorCount * 2
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let calls = Task {
            await withTaskGroup { group in
                for _ in 0..<count {
                    group.addTask {
                        await BlockingExecutor.run {
                            started.signal()
                            gate.wait()
                        }
                    }
                }
            }
        }
        await BlockingExecutor.run {
            for _ in 0..<count { started.wait() }
        }
        #expect(await Task.detached { 1 + 1 }.value == 2)
        for _ in 0..<count { gate.signal() }
        await calls.value
    }
}

// An executor that holds its jobs until the test releases it, so a test can move the clock while
// a work waits for its start. After the release, it runs each job on a concurrent queue.
private final class HeldExecutor: TaskExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var held: [UnownedJob] = []
    private let queue = DispatchQueue(label: "bifrost.test.held", attributes: .concurrent)

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        lock.lock()
        let runNow = open
        if !runNow { held.append(job) }
        lock.unlock()
        if runNow { run(job) }
    }

    // The count of the jobs that wait for the release.
    var heldCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return held.count
    }

    // Run the held jobs, and each later job at once.
    func release() {
        lock.lock()
        open = true
        let jobs = held
        held = []
        lock.unlock()
        for job in jobs { run(job) }
    }

    private func run(_ job: UnownedJob) {
        let executor = asUnownedTaskExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }
}
