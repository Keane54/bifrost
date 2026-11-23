import CoreFoundation
import Synchronization

// The longest pass of a run loop in each 60 s window. The windows start at the time 0 and follow
// each other. The longest pass of the last full window counts until the next window ends. A
// window with no pass gives nothing: the run loop slept for the whole window.
package struct PassWindow: Sendable {
    package static let length = Duration.seconds(60)

    private var start = Duration.zero
    private(set) var current: Duration?
    private var last: Duration?
    // The number of the windows that ended. It names the window of `last`.
    private(set) var ended = 0

    package init() {}

    package mutating func record(_ pass: Duration, at now: Duration) {
        roll(to: now)
        current = max(current ?? .zero, pass)
    }

    // The longest pass of the last full window, or nil before the end of the first window.
    package mutating func longest(at now: Duration) -> Duration? {
        roll(to: now)
        return last
    }

    private mutating func roll(to now: Duration) {
        guard now - start >= Self.length else { return }
        let windows = Int(((now - start) / Self.length).rounded(.down))
        ended += windows
        // Only the window just before the current one counts. An older window is too old.
        last = windows == 1 ? current : nil
        current = nil
        start += Self.length * windows
    }
}

// The delay of the main thread (docs/behaviour/health.md, "Performance"). Two observers on the
// main run loop measure each pass: from the end of a wait (afterWaiting, the first observer) to
// the start of the next wait (beforeWaiting, the last observer). Thus the pass has all the work of
// the main thread, also the layout, the drawing, the updates of the SwiftUI views and the commit
// of Core Animation, which run in beforeWaiting observers too. That is the time in which the main
// thread could not answer a new event. The watch keeps the longest pass in each 60 s window
// (PassWindow). The clock stops while the Mac sleeps, so a sleep during a pass adds nothing to
// the pass. The observers run on the thread of the run loop that the watch observes, the main
// run loop as a default. A test gives it the run loop of its own thread. The state is behind a
// lock, so the monitor can read it from any thread. A watch that goes removes its observers.
package final class MainThreadWatch: Sendable {
    private struct State {
        var window = PassWindow()
        // The start of the pass that runs, or nil while the run loop waits.
        var passStart: Duration?
    }

    // The time since the start of the watch. The clock stops while the Mac sleeps. A test gives
    // its own time.
    private let elapsed: @Sendable () -> Duration
    private let state = Mutex(State())
    // The run loop to observe, and the observers of the start and of the end of a pass while the
    // watch runs. The run loop is not Sendable, so it stays in the lock.
    private struct Hooks {
        var runLoop: CFRunLoop
        var observers: [CFRunLoopObserver] = []
    }
    private let hooks: Mutex<Hooks>

    package init(
        runLoop: sending CFRunLoop = CFRunLoopGetMain(),
        elapsed: (@Sendable () -> Duration)? = nil
    ) {
        hooks = Mutex(Hooks(runLoop: runLoop))
        let clock = SuspendingClock()
        let origin = clock.now
        self.elapsed = elapsed ?? { origin.duration(to: clock.now) }
    }

    deinit {
        removeObservers()
    }

    // Add the two observers to the run loop, in the common modes, so a pass of the event
    // tracking of a menu or a drag also counts. A second start does nothing.
    package func start() {
        hooks.withLock { hooks in
            guard hooks.observers.isEmpty,
                let first = CFRunLoopObserverCreateWithHandler(
                    kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue, true,
                    CFIndex.min, { [weak self] _, _ in self?.passStarted() }),
                let last = CFRunLoopObserverCreateWithHandler(
                    kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true,
                    CFIndex.max, { [weak self] _, _ in self?.passEnded() })
            else { return }
            for observer in [first, last] {
                CFRunLoopAddObserver(hooks.runLoop, observer, .commonModes)
            }
            hooks.observers = [first, last]
        }
    }

    // Remove the observers. The windows keep their values.
    package func stop() {
        removeObservers()
        state.withLock { $0.passStart = nil }
    }

    // The longest pass of the last full 60 s window, or nil.
    package func longest() -> Duration? {
        let now = elapsed()
        return state.withLock { $0.window.longest(at: now) }
    }

    // The longest pass of the last full window, with the number of that window. The number tells
    // two reads of the same window from two windows.
    package func longestWindow() -> (delay: Duration?, window: Int) {
        let now = elapsed()
        return state.withLock { ($0.window.longest(at: now), $0.window.ended) }
    }

    // Record a pass that ended now. A test uses it, with no run loop.
    func recordPass(_ pass: Duration) {
        let now = elapsed()
        state.withLock { $0.window.record(pass, at: now) }
    }

    // The observers on the run loop. A test reads them.
    var installedObservers: [CFRunLoopObserver] { hooks.withLock { $0.observers } }

    // The longest pass of the window that runs now. A test reads it.
    var longestInThisWindow: Duration? { state.withLock { $0.window.current } }

    private func removeObservers() {
        hooks.withLock { hooks in
            for observer in hooks.observers { CFRunLoopObserverInvalidate(observer) }
            hooks.observers = []
        }
    }

    private func passStarted() {
        let now = elapsed()
        state.withLock { $0.passStart = now }
    }

    private func passEnded() {
        let now = elapsed()
        state.withLock { s in
            guard let start = s.passStart else { return }
            s.window.record(now - start, at: now)
            s.passStart = nil
        }
    }
}
