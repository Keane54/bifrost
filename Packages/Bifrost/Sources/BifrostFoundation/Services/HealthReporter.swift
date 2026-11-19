// Gives the health events of the app to one reader. A reporter is a value that anyone can copy and
// call from any thread: record is one yield on the stream.
package struct HealthReporter: Sendable {
    // The stream keeps this number of the newest events when no reader takes them.
    package static let kept = 256

    private let continuation: AsyncStream<HealthEvent>.Continuation?

    private init(_ continuation: AsyncStream<HealthEvent>.Continuation?) {
        self.continuation = continuation
    }

    // One reporter and its stream. With no reader, the stream keeps the newest events.
    package static func make() -> (reporter: HealthReporter, events: AsyncStream<HealthEvent>) {
        let (events, continuation) = AsyncStream.makeStream(
            of: HealthEvent.self, bufferingPolicy: .bufferingNewest(kept))
        return (HealthReporter(continuation), events)
    }

    // Drops each event. A test that does not read health uses it.
    package static let none = HealthReporter(nil)

    package func record(_ event: HealthEvent) {
        continuation?.yield(event)
    }
}

// A store log that also tells the health log about each failed save.
package struct HealthStoreLog: StoreLog {
    private let base: any StoreLog
    private let health: HealthReporter

    package init(base: any StoreLog = SystemStoreLog(), health: HealthReporter) {
        self.base = base
        self.health = health
    }

    package func record(_ event: StoreEvent) {
        base.record(event)
        if case .saveFailed(let what, _) = event { health.record(.saveFailed(what: what)) }
    }
}
