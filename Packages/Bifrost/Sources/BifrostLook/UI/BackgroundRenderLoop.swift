// The render thread of the animated background (MetalBackground.swift). It has the same form as
// the render loop of the chat terminals: one thread, one semaphore, and a flag that joins the
// requests that come before the thread wakes. So a flood of requests gives one frame.
//
// The main thread only writes the request and reads the result. Both are in a Mutex, and the
// render thread holds the lock only to read or write these values, never during a draw. Thus the
// main thread never waits for a surface, for the GPU or for the window server.
import BifrostFoundation
import Foundation
import IOSurface
import OSLog
import Synchronization

// The result of one try of the render thread.
enum BackgroundOutcome: Sendable, Equatable {
    // The surface has the frame, and waits for its show.
    case drawn
    // Each surface was busy, so the thread did not draw. A later request or retry tries again.
    case skipped
    // Metal could not make a surface or draw the frame. The thread does not try that request
    // again.
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

    // The number of skips in a row that gives a log line: one second of frames.
    static let skipsToLog = Int(Motion.rate)
    private static let logger = Logger(bifrost: "background")

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
        // The skips since the last drawn frame, and true after a failure with no drawn frame
        // after it. Each gives one log line, so a background that stops leaves evidence.
        var skips = 0
        var failing = false
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
                switch outcome {
                case .drawn:
                    skips = 0
                    failing = false
                case .skipped:
                    skips += 1
                    if skips == Self.skipsToLog {
                        Self.logger.notice(
                            "The background skipped \(skips) frames: no surface is free")
                    }
                case .failed:
                    if !failing { Self.logger.error("The background could not draw a frame") }
                    failing = true
                }
                report(BackgroundReport(outcome: outcome, onMainThread: Thread.isMainThread))
            }
        }
    }

    // Draw the frame into a free surface, or skip it when no surface is free. A skip does not
    // mark the request as tried, so a retry draws it. The lock is not held during the pick or the
    // draw, so the main thread never waits for them.
    private func tryDraw(
        _ frame: BackgroundFrame, number: Int, busy: [IOSurface],
        surfaces: inout BackgroundSurfaces
    ) -> BackgroundOutcome {
        let target: BackgroundTarget
        switch surfaces.pick(frame.pixels, busy: busy) {
        case .target(let free): target = free
        case .busy: return .skipped
        case .failed:
            state.withLock { $0.tried = max($0.tried, number) }
            return .failed
        }
        let drawn = renderer.draw(frame, into: target.texture)
        state.withLock { s in
            s.tried = max(s.tried, number)
            if drawn { s.finished = target.surface }
        }
        return drawn ? .drawn : .failed
    }
}
