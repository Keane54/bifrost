// The batcher of the Event log (docs/behaviour/panels.md, The Event log panel). It sends the new
// entries of the log to the panel at most once in each gap of 250 ms, so a flood of events gives
// one change of the panel each 250 ms, not one change for each event.
//
// - A push with no gap that runs sends at once, and the gap starts.
// - A push during the gap waits. At the end of the gap, the entries that wait go as one batch,
//   and the next gap starts. A gap with no entry at its end starts no next gap.
// - stop() drops the entries that wait. After a stop, nothing goes.
// The gap is a TimerSlot on the injected clock, so a test moves the time with a manual clock.
import BifrostFoundation

@MainActor
package final class EventBatcher {
    // The shortest time between two sends.
    package static let gap = Duration.milliseconds(250)

    private let send: ([LogEntry]) -> Void
    private let slot: TimerSlot
    private var waiting: [LogEntry] = []
    private var stopped = false

    package init(clock: any Clock<Duration>, send: @escaping ([LogEntry]) -> Void) {
        self.send = send
        slot = TimerSlot(clock: clock)
    }

    // The task of the gap while it waits or sends, or nil. A test waits for it.
    package var timer: Task<Void, Never>? { slot.task }

    package func push(_ entries: [LogEntry]) {
        guard !stopped, !entries.isEmpty else { return }
        if slot.isRunning {
            waiting.append(contentsOf: entries)
        } else {
            out(entries)
        }
    }

    package func stop() {
        stopped = true
        waiting = []
        slot.stop()
    }

    private func out(_ entries: [LogEntry]) {
        send(entries)
        slot.start(after: Self.gap) { [weak self] in self?.gapEnded() }
    }

    private func gapEnded() {
        guard !stopped, !waiting.isEmpty else { return }
        let batch = waiting
        waiting = []
        out(batch)
    }
}
