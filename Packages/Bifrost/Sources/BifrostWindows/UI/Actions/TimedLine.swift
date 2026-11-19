// A line of text of the actions: the notice line or the error line of the action runner
// (docs/behaviour/actions.md, "Notices and errors"). A text shows for its time, or until a hide
// when it is untilHidden. A new text replaces the last one and gets the full time.
import BifrostFoundation
import Observation

@MainActor
@Observable
package final class TimedLine {
    // The text that shows, or nil.
    package private(set) var text: String?
    // The ID of the text that shows. The owner gives each show an ID, and a hide acts only on the
    // text of its ID.
    @ObservationIgnored private var shownId: Int?
    @ObservationIgnored private let time: Duration
    @ObservationIgnored private let timer: TimerSlot

    package init(time: Duration, clock: any Clock<Duration>) {
        self.time = time
        timer = TimerSlot(clock: clock)
    }

    #if DEBUG
    // The task of the timer that removes the text, or nil. A test waits for it.
    package var timerTask: Task<Void, Never>? { timer.task }
    #endif

    // Show the text with the ID. A text that is not untilHidden goes after the time of the line.
    package func show(_ text: String, id: Int, untilHidden: Bool) {
        timer.stop()
        shownId = id
        self.text = text
        guard !untilHidden else { return }
        timer.start(after: time) { [weak self] in self?.hide(id) }
    }

    // Remove the text when it is still the text of the ID.
    package func hide(_ id: Int) {
        guard shownId == id else { return }
        timer.stop()
        shownId = nil
        text = nil
    }

    // Remove the text that shows now.
    package func clear() {
        if let shownId { hide(shownId) }
    }
}
