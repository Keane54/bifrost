import BifrostFoundation

// The new reads of the Live details status while a warning shows (docs/behaviour/live.md, "The
// warning dot"). The first read at the start of the app can give a short failure. Without a new
// read, the side bar then shows the warning dot until Settings opens. Each read runs claude
// plugin list, so the reads follow a back-off (user decision, 2026-11-10):
// - A new warning starts the steps. The reads come 1, 2, 5 and 10 minutes after that start. No
//   timer runs after the last step, and no timer runs while there is no warning.
// - A read that ended less than 30 s before a step counts as that step. The step then does not
//   read.
// - A focus of the window reads again only when the last read ended 5 minutes or more ago.
// - Each kind of read counts, from its end: the first read, a read of Settings, the read of an
//   action and a read of this class (readEnded()).
// After the last step, the warning stays until a focus read, a read of Settings or an action
// clears it.
//
// A read of this class calls read and readVersion at the same time. The owner gives the rules of
// the two: read does nothing while an action runs, and readVersion reads the version only when it
// is not good. One read of this class runs at a time. A read that the owner skips while an action
// runs still counts here as a read that ended. This has no effect that a user can see, because
// the action also counts as a read when it ends (readEnded()).
@MainActor
package final class LiveRetry {
    // The times of the reads from the start of a warning.
    package static let steps: [Duration] = [
        .seconds(60), .seconds(120), .seconds(300), .seconds(600),
    ]
    // The minimum time from the end of the last read to a read at a focus of the window.
    package static let focusGap = Duration.seconds(300)
    // A read that ended less than this time before a step counts as the step.
    package static let recentRead = Duration.seconds(30)

    private let timeline: Timeline
    private let timer: TimerSlot
    private let read: @MainActor () async -> Void
    private let readVersion: @MainActor () async -> Void
    private var warning = false
    private var stopped = false
    // The start of the steps on the timeline, and the index of the next step.
    private var startedAt = Duration.zero
    private var step = 0
    // The end of the last read, or nil before the first read ends.
    private var lastEnd: Duration?
    // True while a read of this class runs. Then a second read does not start.
    private var reading = false

    package init(
        clock: any Clock<Duration>, read: @escaping @MainActor () async -> Void,
        readVersion: @escaping @MainActor () async -> Void
    ) {
        timeline = Timeline(clock)
        timer = TimerSlot(clock: clock)
        self.read = read
        self.readVersion = readVersion
    }

    // True while the timer of the next step waits.
    package var isWaiting: Bool { timer.isRunning }
    // The task of the timer of the next step, or nil. A test waits for it.
    package var timerTask: Task<Void, Never>? { timer.task }
    // The task of the last read of this class, or nil. A test waits for it.
    package private(set) var readTask: Task<Void, Never>?

    // Give the warning state. A new warning starts the steps, and no warning stops them.
    package func warn(_ on: Bool) {
        guard !stopped, on != warning else { return }
        warning = on
        timer.stop()
        guard on else { return }
        startedAt = timeline.now()
        step = 0
        schedule()
    }

    // The window got the focus. The result is the task of the read, or nil when nothing reads.
    @discardableResult
    package func focus() -> Task<Void, Never>? {
        guard warning, let lastEnd, timeline.now() - lastEnd >= Self.focusGap else { return nil }
        return startRead()
    }

    // A read of the owner ended: the first read, a read of Settings or the read of an action.
    package func readEnded() {
        lastEnd = timeline.now()
    }

    // The owner stops. No timer runs after this, no later warning starts the steps, and a read
    // that runs gets a cancel.
    package func stop() {
        stopped = true
        warning = false
        timer.stop()
        readTask?.cancel()
    }

    // Start the timer of the next step. The step starts the next timer before it reads, because
    // the read can end the warning and stop the timer.
    private func schedule() {
        guard warning, step < Self.steps.count else { return }
        let wait = max(.zero, startedAt + Self.steps[step] - timeline.now())
        timer.start(after: wait) { [weak self] in self?.stepCame() }
    }

    private func stepCame() {
        step += 1
        schedule()
        if !endedWithin(Self.recentRead) { startRead() }
    }

    private func endedWithin(_ time: Duration) -> Bool {
        lastEnd.map { timeline.now() - $0 < time } ?? false
    }

    // Start a read in a task of its own, or nothing while a read runs. A read counts from its end.
    @discardableResult
    private func startRead() -> Task<Void, Never>? {
        guard !reading else { return nil }
        reading = true
        let (read, readVersion) = (self.read, self.readVersion)
        let task = Task { [weak self] in
            async let status: Void = read()
            async let version: Void = readVersion()
            _ = await (status, version)
            self?.readDone()
        }
        readTask = task
        return task
    }

    private func readDone() {
        reading = false
        lastEnd = timeline.now()
    }
}
