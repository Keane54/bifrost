// The preload of the speech engine (the analyzer of the next session), with a gated fake load in
// place of the Speech framework. Each load waits until the test ends it.
import BifrostTestSupport
import Synchronization
import Testing

@testable import BifrostDictation

private struct LoadFailed: Error {}

// A load that waits for the test. The value of a load is its number: 1 for the first load.
private final class GatedLoads: Sendable {
    private struct State {
        var calls = 0
        var waiting: [(call: Int, wake: CheckedContinuation<Int, any Error>)] = []
    }

    private let state = Mutex(State())

    var calls: Int { state.withLock { $0.calls } }
    var waiting: Int { state.withLock { $0.waiting.count } }

    func load(_ key: String) async throws -> Int {
        try await withCheckedThrowingContinuation { wake in
            state.withLock { s in
                s.calls += 1
                s.waiting.append((s.calls, wake))
            }
        }
    }

    // End the oldest load that waits: with its number, or with a failure.
    func finish(failing: Bool = false) {
        let first = state.withLock { s in s.waiting.isEmpty ? nil : s.waiting.removeFirst() }
        guard let first else { return }
        if failing {
            first.wake.resume(throwing: LoadFailed())
        } else {
            first.wake.resume(returning: first.call)
        }
    }
}

@Suite("preload of the next analyzer", .testTimeLimit)
@MainActor
struct PreloadTests {
    private let loads = GatedLoads()
    private let preload: Preload<String, Int>

    init() {
        let loads = loads
        preload = Preload { try await loads.load($0) }
    }

    // A prepare loads the value one time. A take uses it, and the next take loads again.
    @Test func aTakeUsesTheLoadedValueOneTime() async throws {
        let prepare = Task { try await preload.prepare("en-US") }
        await waitUntil { loads.waiting == 1 }
        loads.finish()
        try await prepare.value
        #expect(try await preload.take("en-US", epoch: preload.epoch) == 1)
        let next = Task { try await preload.take("en-US", epoch: preload.epoch) }
        await waitUntil { loads.waiting == 1 }
        loads.finish()
        #expect(try await next.value == 2)
        #expect(loads.calls == 2)
    }

    // A release during a load drops its result. The take of the new epoch gets a new load.
    @Test func aReleaseDuringALoadDropsItsResult() async throws {
        let prepare = Task { try await preload.prepare("en-US") }
        await waitUntil { loads.waiting == 1 }
        preload.release()
        loads.finish()
        _ = await prepare.result
        let take = Task { try await preload.take("en-US", epoch: preload.epoch) }
        await waitUntil { loads.waiting == 1 }
        loads.finish()
        #expect(try await take.value == 2)
    }

    // A load that fails runs again, three loads at most. Then the take fails.
    @Test func aFailedLoadRunsAtMostThreeTimes() async throws {
        let take = Task { try await preload.take("en-US", epoch: preload.epoch) }
        for call in 1...3 {
            await waitUntil { loads.calls == call && loads.waiting == 1 }
            loads.finish(failing: true)
        }
        await #expect(throws: Preload<String, Int>.Failure.loadFailed) { try await take.value }
        #expect(loads.calls == 3)
        // A failed load gets a good load at the next try.
        let next = Task { try await preload.take("en-US", epoch: preload.epoch) }
        await waitUntil { loads.waiting == 1 }
        loads.finish(failing: true)
        await waitUntil { loads.waiting == 1 }
        loads.finish()
        #expect(try await next.value == 5)
    }

    // Two failed loads, then a good one: the take gets the value of the third load.
    @Test func theThirdLoadOfATakeGivesItsValue() async throws {
        let take = Task { try await preload.take("en-US", epoch: preload.epoch) }
        for call in 1...2 {
            await waitUntil { loads.calls == call && loads.waiting == 1 }
            loads.finish(failing: true)
        }
        await waitUntil { loads.calls == 3 && loads.waiting == 1 }
        loads.finish()
        #expect(try await take.value == 3)
        #expect(loads.calls == 3)
    }

    // After a release, a loadNext of the old epoch loads nothing. A loadNext of the new epoch
    // loads one value, and a second one does nothing while it loads.
    @Test func afterAReleaseALoadNextLoadsNothing() async {
        let old = preload.epoch
        preload.release()
        #expect(!preload.loadNext("en-US", epoch: old))
        #expect(preload.loadNext("en-US", epoch: preload.epoch))
        #expect(!preload.loadNext("en-US", epoch: preload.epoch))
        await waitUntil { loads.waiting == 1 }
        loads.finish()
        #expect(loads.calls == 1)
    }

    // A take of an older epoch fails, also when a value is ready.
    @Test func aTakeOfAnOldEpochFails() async throws {
        let old = preload.epoch
        preload.release()
        #expect(preload.loadNext("en-US", epoch: preload.epoch))
        await waitUntil { loads.waiting == 1 }
        loads.finish()
        try await preload.prepare("en-US")
        await #expect(throws: Preload<String, Int>.Failure.released) {
            try await preload.take("en-US", epoch: old)
        }
        #expect(try await preload.take("en-US", epoch: preload.epoch) == 1)
    }
}
