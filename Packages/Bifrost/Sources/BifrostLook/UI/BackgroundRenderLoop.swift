// The render thread of the animated background (MetalBackground.swift). It has the same form as
// the render loop of the chat terminals: one thread, one semaphore, and a flag that joins the
// requests that come before the thread wakes. So a flood of requests gives one frame.
//
// The main thread only writes the request and reads the result. Both are in a Mutex, and the
// render thread holds the lock only to read or write these values, never during a draw. Thus the
// main thread never waits for a surface, for the GPU or for the window server.
import Foundation
import IOSurface
import Synchronization

// The result of one try of the render thread.
enum BackgroundOutcome: Sendable, Equatable {
    // The surface has the frame, and waits for its show.
    case drawn
    // Each surface was busy, so the thread did not draw. A later request or retry tries again.
    case skipped
    // Metal could not draw the frame.
    case failed
}

// One try of the render thread, for the tests and for the view.
struct BackgroundReport: Sendable {
    let outcome: BackgroundOutcome
    // True when the try ran on the main thread. It is always false.
    let onMainThread: Bool
}

final class BackgroundRenderLoop: Sendable {
    private struct State {
        var started = false
        var stopped = false
        // True while a wake is in the semaphore and the thread did not take it yet.
        var waking = false
        var frame: BackgroundFrame?
        // The number of the newest request, and the number of the newest request that the
        // thread tried.
        var requested = 0
        var tried = 0
        // The newest drawn surface that the layer does not show yet.
        var finished: IOSurface?
        // The surface that the layer shows.
        var shown: IOSurface?

        // True when the caller must post a wake. A wake that waits already takes this request.
        mutating func wake() -> Bool {
            guard !stopped, !waking else { return false }
            waking = true
            return true
        }
    }

    // The work of one wake.
    private enum Job {
        case stop
        case none
        case draw(BackgroundFrame, number: Int, busy: [IOSurface])
    }

    private let state = Mutex(State())
    private let semaphore = DispatchSemaphore(value: 0)
    private let renderer: BackgroundRenderer
    private let inUse: @Sendable (IOSurface) -> Bool

    // `inUse` tells if a process uses a surface. The tests give their own.
    init(
        renderer: BackgroundRenderer,
        inUse: @escaping @Sendable (IOSurface) -> Bool = { $0.isInUse }
    ) {
        self.renderer = renderer
        self.inUse = inUse
    }

    // Start the render thread. `report` runs on the render thread after each try. A second call
    // does nothing.
    func start(report: @escaping @Sendable (BackgroundReport) -> Void) {
        let start = state.withLock { s in
            guard !s.started, !s.stopped else { return false }
            s.started = true
            return true
        }
        guard start else { return }
        let thread = Thread { [self] in run(report) }
        thread.name = "bifrost.background.render"
        // Below the main thread and the render threads of the terminals, so the background never
        // takes time from the keys or from the text.
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    // Ask for a frame. The result is the number of the request.
    @discardableResult
    func request(_ frame: BackgroundFrame) -> Int {
        let (number, wake) = state.withLock { s in
            s.frame = frame
            s.requested += 1
            return (s.requested, s.wake())
        }
        if wake { semaphore.signal() }
        return number
    }

    // Try the newest request again when the thread did not try it yet, or skipped it.
    func retry() {
        let wake = state.withLock { s in s.tried != s.requested && s.wake() }
        if wake { semaphore.signal() }
    }

    // The newest drawn surface that the layer does not show yet. After this call it is the
    // shown surface, so the thread does not draw into it.
    func takeFinished() -> IOSurface? {
        state.withLock { s in
            guard let finished = s.finished else { return nil }
            s.finished = nil
            s.shown = finished
            return finished
        }
    }

    // True while the thread did not try the newest request (it waits, it draws, or it skipped
    // it), or while a drawn surface waits for its show.
    var busy: Bool {
        state.withLock { $0.tried != $0.requested || $0.finished != nil }
    }

    // Stop the render thread for good. The call does not wait: the thread ends after its try.
    func stop() {
        let wake = state.withLock { s in
            guard !s.stopped else { return false }
            s.stopped = true
            return true
        }
        if wake { semaphore.signal() }
    }

    private func run(_ report: @Sendable (BackgroundReport) -> Void) {
        var surfaces = BackgroundSurfaces(device: renderer.device, inUse: inUse)
        while true {
            semaphore.wait()
            let job = state.withLock { s -> Job in
                // Cleared before the try: a request during the try posts the next wake.
                s.waking = false
                if s.stopped { return .stop }
                guard let frame = s.frame, s.tried != s.requested else { return .none }
                let busy = [s.shown, s.finished].compactMap { $0 }
                return .draw(frame, number: s.requested, busy: busy)
            }
            switch job {
            case .stop: return
            case .none: continue
            case .draw(let frame, let number, let busy):
                let outcome = autoreleasepool {
                    tryDraw(frame, number: number, busy: busy, surfaces: &surfaces)
                }
                report(BackgroundReport(outcome: outcome, onMainThread: Thread.isMainThread))
            }
        }
    }

    // Draw the frame into a free surface, or skip it when no surface is free. A skip does not
    // mark the request as tried, so a retry draws it.
    private func tryDraw(
        _ frame: BackgroundFrame, number: Int, busy: [IOSurface],
        surfaces: inout BackgroundSurfaces
    ) -> BackgroundOutcome {
        guard let target = surfaces.free(frame.pixels, busy: busy) else { return .skipped }
        let drawn = renderer.draw(frame, into: target.texture)
        state.withLock { s in
            s.tried = max(s.tried, number)
            if drawn { s.finished = target.surface }
        }
        return drawn ? .drawn : .failed
    }
}
