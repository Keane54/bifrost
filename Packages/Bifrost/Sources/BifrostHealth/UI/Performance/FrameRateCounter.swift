import AppKit
import BifrostFoundation
import QuartzCore

// The target of the display link of the frame counter. The display link keeps its target, so the
// target keeps the counter only weakly: the counter can go, and its deinit stops the link.
@MainActor
private final class FrameLinkTarget: NSObject {
    weak var counter: FrameRateCounter?

    init(_ counter: FrameRateCounter) {
        self.counter = counter
    }

    @objc func displayFrame(_ link: CADisplayLink) {
        counter?.frame()
    }
}

// The frame rate of the Performance panel (docs/behaviour/health.md, "Performance"). While the
// panel shows and its window has the focus, the counter counts the frames of the display link of
// the panel view for 2 s in each 10 s. Each burst gives one value: the frames over the time of the
// burst. Between the bursts the link is paused, so no frame callback runs. A change of the
// active state ends a burst at once, with no value.
//
// The name is not FrameCounter: the debug bench has a type with that name, and the symbol check
// of the Release app refuses each name of the code that only a Debug build has.
@MainActor
package final class FrameRateCounter {
    package static let burst = Duration.seconds(2)
    package static let period = Duration.seconds(10)

    private let timeline: Timeline
    private let report: @MainActor (Double) -> Void
    private let stopped: @MainActor () -> Void
    private var link: CADisplayLink?
    private var bursts: Task<Void, Never>?
    // The frames of the burst that runs, or nil between the bursts.
    private var frames: Int?

    // report gets the value of each burst. stopped runs when the bursts stop, so the next burst
    // starts a new count.
    package init(
        clock: any Clock<Duration>, report: @escaping @MainActor (Double) -> Void,
        stopped: @escaping @MainActor () -> Void
    ) {
        timeline = Timeline(clock)
        self.report = report
        self.stopped = stopped
    }

    isolated deinit {
        bursts?.cancel()
        link?.invalidate()
    }

    // Count the frames of the display of the view. The link stays paused until a burst.
    package func attach(to view: NSView) {
        link?.invalidate()
        let made = view.displayLink(
            target: FrameLinkTarget(self), selector: #selector(FrameLinkTarget.displayFrame(_:)))
        made.isPaused = frames == nil
        made.add(to: .main, forMode: .common)
        link = made
    }

    // Stop the display link of the view.
    package func detach() {
        link?.invalidate()
        link = nil
    }

    // True while the panel shows and its window has the focus. The bursts run only then.
    //
    // The task of the bursts holds the counter only for each step, never during a sleep. So a
    // counter that its owner drops goes at once, and its deinit ends the task and the link.
    package func setActive(_ active: Bool) {
        guard active != (bursts != nil) else { return }
        if active {
            let timeline = timeline
            bursts = Task { [weak self] in
                while !Task.isCancelled {
                    guard let start = self?.beginBurst() else { return }
                    do {
                        try await timeline.sleep(until: start + FrameRateCounter.burst)
                    } catch {
                        return
                    }
                    guard self?.finishBurst(startedAt: start) != nil else { return }
                    do {
                        try await timeline.sleep(until: start + FrameRateCounter.period)
                    } catch {
                        return
                    }
                }
            }
        } else {
            bursts?.cancel()
            bursts = nil
            endBurst()
            stopped()
        }
    }

    // One frame of the display. Only a frame in a burst counts.
    func frame() {
        frames? += 1
    }

    // Start a burst: the count goes to 0 and the link runs. The result is the start time.
    private func beginBurst() -> Duration {
        frames = 0
        link?.isPaused = false
        return timeline.now()
    }

    // End the burst that started at the time, and report the frames over its real time.
    private func finishBurst(startedAt start: Duration) {
        let counted = frames ?? 0
        endBurst()
        let seconds = (timeline.now() - start) / .seconds(1)
        if seconds > 0 { report(Double(counted) / seconds) }
    }

    private func endBurst() {
        frames = nil
        link?.isPaused = true
    }
}
