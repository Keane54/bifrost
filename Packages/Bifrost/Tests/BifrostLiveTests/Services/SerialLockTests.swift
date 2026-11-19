import BifrostLive
import BifrostTestSupport
import Testing

// The lock of the plugin changes: one change at a time, the starts first, and the status reads
// after the starts without the lock. A gate holds the work of a call, so a test knows that the
// call runs.

@MainActor
@Suite struct SerialLockTests {
    let lock = SerialLock()
    let gate = TestGate()
    let order = Recorder<String>()

    @Test func theBusyTextIsTheTextThatTheAppShows() {
        #expect(SerialLock.busyText == "Another change is still running. Try again in a moment.")
    }

    @Test func aSecondCallDuringACallIsBusyAndTheFirstCallEnds() async throws {
        defer { gate.openAll() }
        let one = Task { [lock, gate] in
            try await lock.run {
                await gate.pass()
                return "one"
            }
        }
        await gate.waitUntilHolding()
        await #expect(throws: PluginFailure.busy) {
            try await lock.run { order.record("two") }
        }
        #expect(order.values.isEmpty)
        gate.open()
        #expect(try await one.value == "one")
    }

    @Test func aNewCallRunsAfterTheFirstCallEnds() async throws {
        #expect(try await lock.run { "one" } == "one")
        #expect(try await lock.run { "next" } == "next")
    }

    @Test func aFailedCallFreesTheLockAndKeepsItsError() async throws {
        await #expect(throws: PluginFailure.refused("bad settings")) {
            try await lock.run { () throws(PluginFailure) in throw .refused("bad settings") }
        }
        #expect(try await lock.run { "next" } == "next")
    }

    @Test func aCallDuringAStartWaitsForItThenRuns() async throws {
        defer { gate.openAll() }
        let starting = Task { [lock, gate, order] in
            try await lock.runFirst {
                await gate.pass()
                order.record("first")
            }
        }
        await gate.waitUntilHolding()
        let two = Task { [lock, order] in
            try await lock.run {
                order.record("two")
                return "two"
            }
        }
        await waitUntil { lock.waiting == 1 }
        #expect(order.values.isEmpty)
        gate.open()
        #expect(try await two.value == "two")
        try await starting.value
        #expect(order.values == ["first", "two"])
    }

    @Test func ofTwoCallsThatWaitForTheStartTheFirstRunsAndTheSecondIsBusy() async throws {
        let later = TestGate()
        defer {
            gate.openAll()
            later.openAll()
        }
        let starting = Task { [lock, gate] in try await lock.runFirst { await gate.pass() } }
        await gate.waitUntilHolding()
        let one = Task { [lock] in
            try await lock.run {
                await later.pass()
                return "one"
            }
        }
        await waitUntil { lock.waiting == 1 }
        let two = Task { [lock] in try await lock.run { "two" } }
        await waitUntil { lock.waiting == 2 }
        gate.open()
        await #expect(throws: PluginFailure.busy) { try await two.value }
        later.open()
        #expect(try await one.value == "one")
        try await starting.value
    }

    // The first call that waits for the start gets the lock at the end of the start, before its
    // task runs again. So a call in the same turn of the main actor as the end of the start is
    // busy. The order in which the tasks of the waiting calls run again has no effect.
    @Test func theFirstCallThatWaitsForTheStartHoldsTheLockFromTheEndOfTheStart() async throws {
        let later = TestGate()
        defer {
            gate.openAll()
            later.openAll()
        }
        let starting = Task { @MainActor [lock, gate] in
            try await lock.runFirst { await gate.pass() }
            return try await lock.run { "three" }
        }
        await gate.waitUntilHolding()
        let one = Task { [lock] in
            try await lock.run {
                await later.pass()
                return "one"
            }
        }
        await waitUntil { lock.waiting == 1 }
        let two = Task { [lock] in try await lock.run { "two" } }
        await waitUntil { lock.waiting == 2 }
        gate.open()
        await #expect(throws: PluginFailure.busy) { try await starting.value }
        await #expect(throws: PluginFailure.busy) { try await two.value }
        later.open()
        #expect(try await one.value == "one")
    }

    @Test func aStartTakesItsTurnAfterTheCallThatHoldsTheLock() async throws {
        defer { gate.openAll() }
        let one = Task { [lock, gate, order] in
            try await lock.run {
                await gate.pass()
                order.record("one")
            }
        }
        await gate.waitUntilHolding()
        let starting = Task { [lock, order] in try await lock.runFirst { order.record("start") } }
        await waitUntil { lock.waiting == 1 }
        let two = Task { [lock, order] in try await lock.run { order.record("two") } }
        await waitUntil { lock.waiting == 2 }
        gate.open()
        try await one.value
        try await starting.value
        try await two.value
        #expect(order.values == ["one", "start", "two"])
    }

    @Test func twoStartsRunInTheirOrderAndACallWaitsForBoth() async throws {
        let second = TestGate()
        defer {
            gate.openAll()
            second.openAll()
        }
        let live = Task { [lock, gate, order] in
            try await lock.runFirst {
                await gate.pass()
                order.record("live")
            }
        }
        await gate.waitUntilHolding()
        let skills = Task { [lock, order] in
            try await lock.runFirst {
                await second.pass()
                order.record("skills")
            }
        }
        await waitUntil { lock.waiting == 1 }
        let read = Task { [lock, order] in
            await lock.afterFirst {
                order.record("read")
                return "read"
            }
        }
        await waitUntil { lock.waiting == 2 }
        gate.open()
        await second.waitUntilHolding()
        #expect(order.values == ["live"])
        second.open()
        #expect(await read.value == "read")
        try await live.value
        try await skills.value
        #expect(order.values == ["live", "skills", "read"])
    }

    // A start of first counts from the call, so a status read and a change in the same turn wait
    // for it, before its task ran.
    @Test func aStartOfFirstCountsFromItsCall() async throws {
        let starting = lock.first { [order] in order.record("start") }
        let read = await lock.afterFirst { [order] in
            order.record("read")
            return "read"
        }
        #expect(try await lock.run { "two" } == "two")
        await starting.value
        #expect(read == "read")
        #expect(order.values == ["start", "read"])
    }

    @Test func afterFirstWithNoStartRunsAtOnce() async throws {
        #expect(await lock.afterFirst { "read" } == "read")
    }

    @Test func afterFirstWaitsForTheStartThenRuns() async throws {
        defer { gate.openAll() }
        let starting = Task { [lock, gate, order] in
            try await lock.runFirst {
                await gate.pass()
                order.record("first")
            }
        }
        await gate.waitUntilHolding()
        let read = Task { [lock, order] in
            await lock.afterFirst {
                order.record("read")
                return "read"
            }
        }
        await waitUntil { lock.waiting == 1 }
        #expect(order.values.isEmpty)
        gate.open()
        #expect(await read.value == "read")
        try await starting.value
        #expect(order.values == ["first", "read"])
    }

    @Test func afterFirstTakesNoLock() async throws {
        let reading = TestGate()
        defer {
            gate.openAll()
            reading.openAll()
        }
        let one = Task { [lock, gate] in
            try await lock.run {
                await gate.pass()
                return "one"
            }
        }
        await gate.waitUntilHolding()
        #expect(await lock.afterFirst { "read" } == "read")
        gate.open()
        #expect(try await one.value == "one")

        let read = Task { [lock] in
            await lock.afterFirst {
                await reading.pass()
                return "read"
            }
        }
        await reading.waitUntilHolding()
        #expect(try await lock.run { "two" } == "two")
        reading.open()
        #expect(await read.value == "read")
    }

    @Test func aWaitForAStartIgnoresACancel() async throws {
        defer { gate.openAll() }
        let starting = Task { [lock, gate, order] in
            try await lock.runFirst {
                await gate.pass()
                order.record("first")
            }
        }
        await gate.waitUntilHolding()
        let two = Task { [lock, order] in
            try await lock.run {
                order.record("two")
                return "two"
            }
        }
        await waitUntil { lock.waiting == 1 }
        two.cancel()
        gate.open()
        #expect(try await two.value == "two")
        try await starting.value
        #expect(order.values == ["first", "two"])
    }

    @Test func aStatusReadInsideTheWorkThatHoldsTheLockRunsAtOnce() async throws {
        try await lock.runFirst {
            order.record(await lock.afterFirst { "start read" })
        }
        try await lock.run {
            order.record(await lock.afterFirst { "action read" })
        }
        #expect(order.values == ["start read", "action read"])
    }

    // A status read inside the work of a change runs at once, also while a start waits for the
    // lock. A wait for the starts there would wait for itself: the start waits for the change.
    @Test func aNestedStatusReadRunsAtOnceWhileAStartWaits() async throws {
        defer { gate.openAll() }
        let one = Task { [lock, gate] in
            try await lock.run {
                await gate.pass()
                return await lock.afterFirst { "read" }
            }
        }
        await gate.waitUntilHolding()
        let starting = Task { [lock, order] in try await lock.runFirst { order.record("start") } }
        await waitUntil { lock.waiting == 1 }
        gate.open()
        #expect(try await one.value == "read")
        try await starting.value
        #expect(order.values == ["start"])
    }

    // A task that the work makes and that runs after the end of the work is not nested: it takes
    // the lock as a new change.
    @Test func aTaskThatOutlivesTheWorkIsNotNested() async throws {
        let misuses = Recorder<String>()
        let lock = SerialLock(misuse: { misuses.record($0) })
        let later = TestGate()
        defer { later.openAll() }
        let made = try await lock.run {
            Task { [lock] in
                await later.pass()
                return try await lock.run { "later" }
            }
        }
        await later.waitUntilHolding()
        later.open()
        #expect(try await made.value == "later")
        #expect(misuses.values.isEmpty)
    }

    @Test func aNestedChangeOrStartIsBusy() async throws {
        let misuses = Recorder<String>()
        let lock = SerialLock(misuse: { misuses.record($0) })
        try await lock.runFirst {
            await #expect(throws: PluginFailure.busy) { try await lock.run { order.record("x") } }
            await #expect(throws: PluginFailure.busy) {
                try await lock.runFirst { order.record("x") }
            }
        }
        try await lock.run {
            await #expect(throws: PluginFailure.busy) { try await lock.run { order.record("x") } }
            await #expect(throws: PluginFailure.busy) {
                try await lock.runFirst { order.record("x") }
            }
        }
        #expect(order.values.isEmpty)
        #expect(misuses.values.count == 4)
        #expect(try await lock.run { "next" } == "next")
    }
}
