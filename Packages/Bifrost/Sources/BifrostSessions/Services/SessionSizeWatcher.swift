import BifrostFoundation
import Darwin

// Reads the session size of a view after a poke and emits it when it changed (behaviour list:
// docs/behaviour/pty.md). A poke starts one read, debounce after the last poke of the view. One
// read runs at a time for each view, and a poke during a read gives one more read after it. The
// view is the key of the watcher: a PTY view in the app.
@MainActor
package final class SessionSizeWatcher<View: Hashable & Sendable> {
    // The state of one view. forget removes it, so a read of a forgotten view finds another
    // state, or none, and has no effect.
    @MainActor
    private final class ViewState {
        // The reads of the view: none runs, one runs, or one runs and a poke came during it, so
        // one more read follows.
        enum Reads {
            case idle, reading, readAgain
        }

        let timer: Debouncer
        var reads = Reads.idle
        var last: TerminalSize?

        init(clock: any Clock<Duration>) {
            timer = Debouncer(clock: clock)
        }
    }

    private let read: (pid_t) async -> TerminalSize?
    private let pidOf: (View) -> pid_t?
    private let emit: (View, TerminalSize) -> Void
    private let clock: any Clock<Duration>
    private let debounce: Duration
    private var views: [View: ViewState] = [:]

    package init(
        read: @escaping (pid_t) async -> TerminalSize?, pidOf: @escaping (View) -> pid_t?,
        emit: @escaping (View, TerminalSize) -> Void, clock: any Clock<Duration>,
        debounce: Duration = .milliseconds(150)
    ) {
        self.read = read
        self.pidOf = pidOf
        self.emit = emit
        self.clock = clock
        self.debounce = debounce
    }

    // Start one read, debounce after the last poke of this view.
    package func poke(_ view: View) {
        let state = stateOf(view)
        state.timer.schedule(after: debounce) { await self.run(view, state) }
    }

    // The timer task of the view, or nil. A test waits for its end.
    package func task(of view: View) -> Task<Void, Never>? { views[view]?.timer.task }

    // True when the time of a read came, and the read did not start yet (Debouncer.isDue).
    package var isDue: Bool { views.values.contains { $0.timer.isDue } }

    // Forget the view: stop its timer and drop its last size, so a new window gets the size
    // again.
    package func forget(_ view: View) {
        guard let state = views.removeValue(forKey: view) else { return }
        state.timer.cancel()
    }

    private func stateOf(_ view: View) -> ViewState {
        if let state = views[view] { return state }
        let state = ViewState(clock: clock)
        views[view] = state
        return state
    }

    private func run(_ view: View, _ state: ViewState) async {
        guard state.reads == .idle else {
            state.reads = .readAgain
            return
        }
        guard let pid = pidOf(view) else { return }
        state.reads = .reading
        let size = await read(pid)
        // A nil read keeps the last size: a window keeps the old size after the session ends.
        if views[view] === state, let size, size != state.last {
            state.last = size
            emit(view, size)
        }
        let again = state.reads == .readAgain
        state.reads = .idle
        if again && views[view] === state { poke(view) }
    }
}
