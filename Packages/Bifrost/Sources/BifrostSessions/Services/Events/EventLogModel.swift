// The one Event log of the app (docs/behaviour/panels.md, The Event log). The model keeps the log
// (EventLog) in memory, and the panel shows its entries.
//
// - read(_:) reads the state events of the registry (RegistryService.events) in one task and
//   adds each one to the log. The stream has one reader: this task. With no reader, the stream
//   keeps the newest 1000 events, so the first read can give old events.
// - notice(_:) and line(_:) add the lines of Bifrost for the user, at the time of now.
// - entries is the log at the last send of the batcher (EventBatcher). It changes at most once
//   each 250 ms, so the panel that follows it does no work for each single event of a flood.
import BifrostFoundation
import Foundation
import Observation

@MainActor
@Observable
package final class EventLogModel {
    // The entries of the log at the last send of the batcher, the oldest first.
    package private(set) var entries: [LogEntry] = []
    @ObservationIgnored private var log: EventLog
    @ObservationIgnored private let now: () -> Date
    // The batcher has a closure with self, so it comes after the other values.
    @ObservationIgnored private var batcher: EventBatcher?
    @ObservationIgnored private var reading: Task<Void, Never>?

    // now gives the wall time of a notice or a line.
    package init(
        clock: any Clock<Duration>, now: @escaping () -> Date = Date.init,
        max: Int = EventLog.max
    ) {
        log = EventLog(max: max)
        self.now = now
        batcher = EventBatcher(clock: clock) { [weak self] _ in self?.publish() }
    }

    isolated deinit {
        reading?.cancel()
    }

    // Read the events of the stream until it ends or until stop(). A second call does nothing.
    package func read(_ events: AsyncStream<HookEvent>) {
        guard reading == nil else { return }
        reading = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.append([event])
            }
        }
    }

    // The task that reads the events, or nil. A test waits for it.
    package var readTask: Task<Void, Never>? { reading }

    // The task of the gap of the batcher while it waits or sends, or nil. A test waits for the
    // end of the gap, so a second batch would be in the entries.
    package var batchTimer: Task<Void, Never>? { batcher?.timer }

    package func append(_ events: [HookEvent]) {
        batcher?.push(log.append(events))
    }

    // Add a line for the user one time for each text, for example the line of a refused
    // notification.
    package func notice(_ text: String) {
        guard let entry = log.notice(text, at: now().millisecondsSince1970) else { return }
        batcher?.push([entry])
    }

    // Add a line for the user each time.
    package func line(_ text: String) {
        batcher?.push([log.line(text, at: now().millisecondsSince1970)])
    }

    // Stop the read and the batcher. The entries do not change after a stop.
    package func stop() {
        reading?.cancel()
        batcher?.stop()
    }

    // The batcher sent: the panel gets the log of now. The log has each entry of the batch.
    private func publish() {
        entries = log.entries
    }
}
