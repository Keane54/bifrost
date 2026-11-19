import BifrostLive
import Synchronization

// A Live details log that records each event, in the order of the events.
final class LiveLogRecorder: LiveLog {
    private let recorded = Mutex<[LiveLogEvent]>([])

    var events: [LiveLogEvent] { recorded.withLock { $0 } }

    func record(_ event: LiveLogEvent) { recorded.withLock { $0.append(event) } }
}
