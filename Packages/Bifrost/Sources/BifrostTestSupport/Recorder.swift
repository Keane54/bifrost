import BifrostFoundation
import BifrostReviews
import BifrostSessions
import Observation
import Synchronization

// The values that a test records, in their order: the events of a log, the calls of a callback,
// or the values of an observation. A value can come from any thread.
package final class Recorder<Value: Sendable>: Sendable {
    private let recorded = Mutex<[Value]>([])
    private let follow = Mutex<Task<Void, Never>?>(nil)

    package init() {}

    // Record the values of an observation, as the shell follows the services: the value of now,
    // then the value after each change. stop() or the end of the recorder ends the observation.
    @MainActor
    package convenience init(following changes: Observations<Value, Never>) {
        self.init()
        let task = Task { [weak self] in
            for await value in changes { self?.record(value) }
        }
        follow.withLock { $0 = task }
    }

    deinit { stop() }

    package func record(_ value: Value) { recorded.withLock { $0.append(value) } }

    package var values: [Value] { recorded.withLock { $0 } }

    // End the observation that the recorder follows.
    package func stop() { follow.withLock { $0?.cancel() } }
}

// The log of a store in a test.
extension Recorder: StoreLog where Value == StoreEvent {}

// The log of the sessions in a test.
extension Recorder: SessionsLog where Value == SessionsLogEvent {}

// The log of the account usage poller in a test.
extension Recorder: AccountUsageLog where Value == AccountUsageEvent {}

// The log of a notifier in a test.
extension Recorder: NotifierLog where Value == NotifierEvent {}

// The log of the integration (the settings edit and the old hook data) in a test.
extension Recorder: IntegrationLog where Value == IntegrationLogEvent {}

// The log of the Reviews watcher in a test.
extension Recorder: ReviewsLog where Value == ReviewsLogEvent {}
