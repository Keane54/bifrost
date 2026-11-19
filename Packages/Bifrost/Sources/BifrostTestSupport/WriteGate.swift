import BifrostFoundation
import Synchronization
import Testing

// The steps of a safe write that wait at a gate before the sync, so a test can hold a write until
// it opens the gate. The UI state store, the window state store and the settings store tests use
// it. The store runs its writes on the blocking executor, so a held write holds no thread of the
// cooperative pool. Each open lets one write through. The gate counts the writes that end with
// the rename.
package final class WriteGate: Sendable {
    private let gate = TestGate()
    private let done = Mutex(0)

    package init() {}

    package var steps: WriteSteps {
        let system = WriteSteps.system
        return WriteSteps(
            sync: { [gate] handle in
                gate.passBlocking()
                try system.sync(handle)
            },
            rename: { [self] from, to in
                try system.rename(from, to)
                done.withLock { $0 += 1 }
            })
    }

    // True after a write came to the gate.
    package var isWriting: Bool { gate.arrivals > 0 }

    // The writes that ended with the rename.
    package var writes: Int { done.withLock { $0 } }

    // Let one write through.
    package func open() { gate.open() }

    // Let each write through, now and later. A test calls it in a defer.
    package func openAll() { gate.openAll() }

    // Wait until a write waits at the gate, for at most 30 s. At the limit the wait records an
    // issue and gives false.
    @discardableResult
    package func waitUntilWriting(sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        await gate.waitUntilHolding(sourceLocation: sourceLocation)
    }
}
