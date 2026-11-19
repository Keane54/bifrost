// The runner of the debug bench: one run of a plan in the window of the app, with the measurement
// method of the prototype gate (Metrics.swift of this module). The test port starts a run (the
// request "bench") and reads its status. tools/bench/run.sh drives the port.
//
// Safety: a runner exists only with a test home and only when the claude of the app resolves to the
// fake claude (scripts/fake-claude/claude). So a run never attaches to a real session. The results
// go only to <test home>/bench/<name>.jsonl. Only a Debug build has this code (#if DEBUG), and the
// release check of scripts/check.sh refuses the symbol BenchRunner in the Release app.
//
// A run:
// 1. Puts the window on the main display: the visible frame of the screen, above the windows of the
//    other apps (the floating level), with no activation and no key focus.
// 2. Opens the chats of the first rows of the session list in the slots of the prototype layout (8
//    frames of 520 x 500 that overlap their neighbours), over the session list (overview:1), and
//    applies the variant: the renderer and the scrollback of each chat, the minimised chats, the
//    blur and the motion of the background. The bench counts the window as focused, so the
//    background moves. Then it waits until each chat is attached and shows its first output, and
//    stops the stream of each quiet chat with Ctrl+C. The fake claude prints its first output only
//    after "stty raw", so the Ctrl+C is a byte of its input, not a SIGINT.
// 3. Checks the display: the window shows on the main display, and a warm-up of 2 s gives a display
//    period of 1/120 s within 2 %. A failed check gives no result.
// 4. Runs each phase of the plan at the display frames, and records one BenchSample for each. At
//    the end of each phase, the window must still show, and each chat must still be attached and
//    not ended.
// 5. Writes the samples, one JSON line each, to the results file in one write.
// A failed step stops the run with a reason and writes no results file. A failed check of the
// display or of the window is a check failure: the run gives no result, and the step can run again
// later. Each other failure is a failure of the harness.
#if DEBUG
import AppKit
import BifrostChat
import BifrostFoundation
import BifrostKeyboard
import BifrostLayout
import BifrostLook
import BifrostSessions
import BifrostWindows
import QuartzCore
import SwiftTerm

// The parts of the window that a run drives. The shell of the app gives them.
@MainActor
public struct BenchStage {
    package var window: NSWindow
    package var canvas: CanvasView
    package var layout: WindowLayoutModel
    package var chats: ChatTerminals
    // The PTY manager of the chats, after the services found claude.
    package var ptys: () -> PTYManager?
    // The session IDs of the rows of the session list, sorted.
    package var sessionIds: () -> [String]
    // The motion of the background: true counts the window as focused, so the background moves;
    // false keeps the background still; nil gives back the normal rule.
    package var setMotion: (Bool?) -> Void

    public init(
        window: NSWindow, canvas: CanvasView, layout: WindowLayoutModel, chats: ChatTerminals,
        ptys: @escaping () -> PTYManager?, sessionIds: @escaping () -> [String],
        setMotion: @escaping (Bool?) -> Void
    ) {
        self.window = window
        self.canvas = canvas
        self.layout = layout
        self.chats = chats
        self.ptys = ptys
        self.sessionIds = sessionIds
        self.setMotion = setMotion
    }
}

// The status of a run: waiting before its start, the phase of a run (nil during the preparation
// and the warm-up), done after the write of the results, or failed with a reason. check is true
// when a check of the display or of the window failed (no result), and false for a failure of
// the harness.
@MainActor
public enum BenchStatus: Sendable, Equatable {
    case waiting
    case running(BenchPhase?)
    case done
    case failed(reason: String, check: Bool)
}

// The reason why a run stopped, and if a check of the display or of the window failed.
struct BenchFailure: Error, Equatable {
    var reason: String
    var check: Bool

    // A failure of the harness.
    init(_ reason: String) {
        self.reason = reason
        check = false
    }

    // A failed check of the display or of the window.
    init(check reason: String) {
        self.reason = reason
        check = true
    }
}

// The target of the display link. The display link keeps its target, so the target keeps the
// runner only weakly.
@MainActor
private final class BenchTicker: NSObject {
    weak var runner: BenchRunner?

    init(_ runner: BenchRunner) {
        self.runner = runner
    }

    @objc func displayFrame(_ link: CADisplayLink) {
        runner?.displayFrame(link)
    }
}

// The main actor is explicit. The default isolation gives the same, but an optimised build of the
// app (run.sh --optimised) then refuses the isolated deinit of this class.
@MainActor
public final class BenchRunner {
    // The limits of the waits of the preparation, and the margin of the watchdog of a run.
    static let rowsLimit = Duration.seconds(30)
    static let attachLimit = Duration.seconds(30)
    static let pollInterval = Duration.milliseconds(100)
    static let watchdogMargin = Duration.seconds(30)
    // The slots of the prototype layout: 8 frames of 520 x 500 points in two rows of 4, 440 and
    // 454 points apart. Each frame overlaps its neighbours, so 7 of the 8 frames get the blur.
    static let slotCount = 8
    static let slotSize = (w: 520.0, h: 500.0)
    static let slotStep = (x: 440.0, y: 454.0)
    static let slotMargin = 16.0
    // The slot of the drag chat and of the typing chat in the prototype (frame 5).
    static let targetSlot = 5
    // The anchor of the drag in the title bar: 60 by 14 points from the top-left corner.
    static let titleAnchor = (x: 60.0, y: 14.0)
    static let ctrlC: [UInt8] = [0x03]
    static let enter: [UInt8] = [0x0d]
    static let warmUpSeconds = DisplayCheck.warmUpSeconds
    // A memory sample each 0.5 s, as in the prototype.
    static let sampleInterval = 0.5

    public private(set) var status = BenchStatus.waiting

    private let testHome: URL
    private let clock: any Clock<Duration>
    // The wall time of the start of each phase (BenchSample.startDate).
    private let wallClock: () -> Date
    private let watchdog: TimerSlot

    // The state of a run.
    private var stage: BenchStage?
    private var link: CADisplayLink?
    private var counter = FrameCounter()
    private var mode = Mode.off
    // The warm-up: its start, the time stamp of the last frame and the gaps of the frames.
    private var warmUpStart = 0.0
    private var lastStamp: Double?
    private var gaps: [Double] = []
    private var waiter: CheckedContinuation<Result<Void, BenchFailure>, Never>?
    private var chats: [String] = []
    private var streaming: [String] = []
    private var target = ""
    private var steps: [BenchPlan.Step] = []
    private var samples: [BenchSample] = []
    private var phase = PhaseState()
    private var drag: DragState?
    private var typing = TypingState()
    private var blurChanged = false

    @MainActor
    private enum Mode {
        case off, warmUp, phases
    }

    // The counters at the start of a phase and the highest footprints in it.
    @MainActor
    private struct PhaseState {
        var index = 0
        var start = 0.0
        var startDate = 0.0
        var usage = ProcessUsage(footprint: 0, instructions: 0, cpuSeconds: 0)
        var frames = 0
        var missed = 0
        var excluded = 0.0
        var highestApp: UInt64 = 0
        var highestChildren: UInt64 = 0
        var nextSample = 0.0
    }

    // The frame of a drag or a resize, its rect at the start and the point of the start.
    @MainActor
    private struct DragState {
        var frame: FrameID
        var rect: LayoutRect
        var start: LayoutPoint
        var resize: Bool
    }

    // The keys that the typing sent, the time of the next key and the last clear of the line.
    @MainActor
    private struct TypingState {
        var sent = 0
        var next = 0.0
        var clearedAt = -1
    }

    // nil (refused) with no test home, and when the claude of the app does not resolve to the
    // fake claude. Each path resolves its links first, so a link to the fake is the fake, and a
    // copy of the fake in another folder is not.
    public init?(
        testHome: URL?, claudePath: String, fakeClaudePath: String,
        clock: any Clock<Duration> = ContinuousClock(), wallClock: @escaping () -> Date = Date.init
    ) {
        guard let testHome, let claude = Self.resolved(claudePath),
            let fake = Self.resolved(fakeClaudePath), claude == fake
        else { return nil }
        self.testHome = testHome
        self.clock = clock
        self.wallClock = wallClock
        watchdog = TimerSlot(clock: clock)
    }

    isolated deinit {
        link?.invalidate()
    }

    // True for <test home>/bench/<name>.jsonl, with a name of the form of the test port.
    func allows(_ output: URL) -> Bool {
        let folder = testHome.appending(path: "bench").standardizedFileURL.path
        let file = output.standardizedFileURL
        let name = file.lastPathComponent
        let parent = file.deletingLastPathComponent().standardizedFileURL.path
        guard parent == folder, name.hasSuffix(".jsonl") else {
            return false
        }
        return TestPortMessage.isBenchName(String(name.dropLast(".jsonl".count)))
    }

    // One run of the plan with the chats and the variant. A runner makes one run. The status
    // gives the result.
    public func run(
        _ plan: BenchPlan, chats count: Int, variant: BenchVariant = BenchVariant(),
        output: URL, stage: BenchStage
    ) async {
        guard status == .waiting else { return }
        status = .running(nil)
        self.stage = stage
        do throws(BenchFailure) {
            guard allows(output) else {
                throw BenchFailure("The results file is not in the bench folder of the test home.")
            }
            try await prepare(stage, chats: count, variant: variant)
            try await warmUp(stage)
            try await measure(plan, stage)
            status = .running(nil)
            try await Self.save(samples, to: output)
            status = .done
        } catch {
            status = .failed(reason: error.reason, check: error.check)
        }
        finish(stage)
    }

    // MARK: - The preparation

    private func prepare(_ stage: BenchStage, chats count: Int, variant: BenchVariant)
        async throws(BenchFailure)
    {
        guard stage.ptys() != nil else { throw BenchFailure("claude not found") }
        let ids = try await rows(stage, count)
        guard let screen = NSScreen.screens.first else {
            throw BenchFailure(check: "The Mac has no display.")
        }
        let window = stage.window
        window.level = .floating
        window.setFrame(screen.visibleFrame, display: true)
        window.orderFrontRegardless()
        // The canvas gets its new size in the next layout pass.
        await pause(.milliseconds(500))
        let slots = Self.slots(in: stage.layout.layout.bounds)
        chats = ids
        target = ids[min(Self.targetSlot, ids.count - 1)]
        streaming = Array(ids.prefix(variant.streaming ?? ids.count))
        openLayout(stage, slots: slots, variant: variant)
        applyEffects(stage, variant)
        try await waitForAttach(stage)
        let quiet = ids.filter { !streaming.contains($0) }
        write(Self.ctrlC, to: quiet)
        try checkWindow(stage)
    }

    // The first session IDs of the list, after the rows came.
    private func rows(_ stage: BenchStage, _ count: Int) async throws(BenchFailure) -> [String] {
        var waited = Duration.zero
        while stage.sessionIds().count < count {
            guard waited < Self.rowsLimit else {
                let found = stage.sessionIds().count
                throw BenchFailure("The session list has \(found) sessions, not \(count).")
            }
            await pause(Self.pollInterval)
            waited += Self.pollInterval
        }
        return Array(stage.sessionIds().prefix(count))
    }

    // Each frame closes. Then the session list opens at its default rect, and each chat opens in
    // its slot with its renderer and its scrollback. Then the minimised chats go to the side bar.
    private func openLayout(_ stage: BenchStage, slots: [LayoutRect], variant: BenchVariant) {
        let layout = stage.layout
        for panel in layout.layout.frames.flatMap(\.panels) {
            layout.apply(.close(panel))
        }
        if variant.list {
            open(.overview(1), at: WindowLayoutModel.overviewRect, in: layout)
        }
        let metal = variant.metal ?? chats.count
        for (slot, id) in chats.enumerated() {
            guard let session = SessionID(id) else { continue }
            stage.chats.benchRenderers[id] = slot < metal ? .metal : .cg
            open(.chat(session), at: slots[slot], in: layout)
            if let lines = variant.scrollback {
                stage.chats.terminal(id)?.view.changeScrollback(lines)
            }
        }
        let minimised = chats.filter { $0 != target }.prefix(variant.minimised)
        for id in minimised {
            guard let session = SessionID(id), let frame = layout.layout.frame(of: .chat(session))
            else { continue }
            layout.apply(.minimise(frame.id))
        }
    }

    private func open(_ panel: PanelID, at rect: LayoutRect, in layout: WindowLayoutModel) {
        layout.apply(.open(panel))
        if let frame = layout.layout.frame(of: panel) {
            layout.apply(.setRect(frame.id, rect))
        }
    }

    // The slots in layout units. They scale down to fit a smaller canvas.
    static func slots(in bounds: LayoutSize) -> [LayoutRect] {
        let width = 2 * slotMargin + 3 * slotStep.x + slotSize.w
        let height = 2 * slotMargin + slotStep.y + slotSize.h
        let scale = max(0.1, min(1, bounds.w / width, bounds.h / height))
        return (0..<slotCount).map { slot in
            let x = slotMargin + Double(slot % 4) * slotStep.x
            let y = slotMargin + Double(slot / 4) * slotStep.y
            return LayoutRect(
                x: (x * scale).rounded(), y: (y * scale).rounded(),
                w: (slotSize.w * scale).rounded(), h: (slotSize.h * scale).rounded())
        }
    }

    private func applyEffects(_ stage: BenchStage, _ variant: BenchVariant) {
        var settings = stage.canvas.settings
        settings.blur = variant.blur ? .backdrop : .none
        blurChanged = settings != stage.canvas.settings
        if blurChanged { stage.canvas.apply(settings) }
        stage.setMotion(variant.background)
    }

    // Wait until each chat is attached and shows its first output.
    private func waitForAttach(_ stage: BenchStage) async throws(BenchFailure) {
        var waited = Duration.zero
        while true {
            let ready = chats.filter { id in
                let terminal = stage.chats.terminal(id)
                return Self.isReady(terminal?.state, output: terminal?.benchOutput ?? 0)
            }
            if ready.count == chats.count { return }
            guard waited < Self.attachLimit else {
                throw BenchFailure(
                    "\(ready.count) of \(chats.count) chats attached and showed output.")
            }
            await pause(Self.pollInterval)
            waited += Self.pollInterval
        }
    }

    // A chat is ready for the input of the bench after its attach and its first output. The
    // fake claude prints its first output only after "stty raw": before it, the terminal has
    // ISIG, and a Ctrl+C would end the fake with SIGINT.
    static func isReady(_ state: ChatTerminalState?, output: Int) -> Bool {
        guard let state else { return false }
        return state.attached && !state.ended && output > 0
    }

    // The reason when a chat is not usable at the end of a phase, or nil. Each chat must have
    // its terminal, be attached and not be ended.
    static func lostChat(_ chats: [(id: String, state: ChatTerminalState?)], phase: BenchPhase)
        -> String?
    {
        for (index, chat) in chats.enumerated() {
            let name = "Chat \(index + 1) of \(chats.count)"
            guard let state = chat.state else {
                return "\(name) has no terminal at the end of the phase \(phase)."
            }
            if state.ended { return "\(name) ended in the phase \(phase)." }
            if !state.attached {
                return "\(name) is not attached at the end of the phase \(phase)."
            }
        }
        return nil
    }

    // The window must show on the main display, and no other window may cover all of it.
    private func checkWindow(_ stage: BenchStage) throws(BenchFailure) {
        let window = stage.window
        guard window.occlusionState.contains(.visible), window.isOnActiveSpace,
            let screen = window.screen, screen == NSScreen.screens.first
        else { throw BenchFailure(check: "The bench window is not visible on the main display.") }
    }

    // MARK: - The warm-up and the phases

    private func warmUp(_ stage: BenchStage) async throws(BenchFailure) {
        startLink(stage)
        warmUpStart = CACurrentMediaTime()
        lastStamp = nil
        gaps = []
        mode = .warmUp
        try await wait(for: .seconds(Self.warmUpSeconds))
        try checkWindow(stage)
    }

    private func measure(_ plan: BenchPlan, _ stage: BenchStage) async throws(BenchFailure) {
        steps = plan.steps
        samples = []
        guard !steps.isEmpty else { return }
        begin(0)
        mode = .phases
        try await wait(for: plan.total)
    }

    // Wait until the display frames end the warm-up or the last phase. The watchdog stops a run
    // whose display link stopped, for example in a window that another window covers.
    private func wait(for duration: Duration) async throws(BenchFailure) {
        watchdog.start(after: duration + Self.watchdogMargin) { [weak self] in
            self?.resume(.failure(BenchFailure(check: "The display frames stopped.")))
        }
        let result = await withCheckedContinuation { waiter = $0 }
        watchdog.stop()
        try result.get()
    }

    private func resume(_ result: Result<Void, BenchFailure>) {
        if case .failure = result { mode = .off }
        waiter?.resume(returning: result)
        waiter = nil
    }

    private func startLink(_ stage: BenchStage) {
        guard link == nil else { return }
        let made = stage.canvas.displayLink(
            target: BenchTicker(self), selector: #selector(BenchTicker.displayFrame(_:)))
        made.add(to: .main, forMode: .common)
        link = made
    }

    // One display frame: the counter, then the warm-up or the step of the phase.
    fileprivate func displayFrame(_ link: CADisplayLink) {
        counter.tick(at: link.timestamp, period: link.duration)
        switch mode {
        case .off:
            break
        case .warmUp:
            if let lastStamp { gaps.append(link.timestamp - lastStamp) }
            lastStamp = link.timestamp
            guard link.timestamp - warmUpStart >= Self.warmUpSeconds else { return }
            mode = .off
            if DisplayCheck.matches(gaps: gaps) {
                resume(.success(()))
            } else {
                resume(.failure(Self.displayFailure(gaps)))
            }
        case .phases:
            step(now: CACurrentMediaTime())
        }
    }

    static func displayFailure(_ gaps: [Double]) -> BenchFailure {
        guard gaps.count >= DisplayCheck.leastGaps, let median = DisplayCheck.median(gaps) else {
            return BenchFailure(check: "The window got \(gaps.count + 1) display frames in 2 s.")
        }
        let text = String(format: "%.2f", median * 1000)
        return BenchFailure(check: "The display period is \(text) ms, not 8.33 ms within 2 %.")
    }

    // The start of a phase: its action, then the counters.
    private func begin(_ index: Int) {
        guard let stage else { return }
        let step = steps[index]
        status = .running(step.phase)
        switch step.phase {
        case .quiet: write(Self.ctrlC, to: streaming)
        case .warm: write(Self.enter, to: streaming)
        case .drag: beginDrag(stage, resize: false)
        case .resize: beginDrag(stage, resize: true)
        case .typeprep: prepareTyping(stage)
        case .typing: typing = TypingState()
        case .start, .idle, .stream: break
        }
        let usage = snapshot()
        phase = PhaseState(
            index: index, start: CACurrentMediaTime(),
            startDate: wallClock().timeIntervalSince1970, usage: usage.app,
            frames: counter.frames, missed: counter.missed, excluded: counter.excludedSeconds,
            highestApp: usage.app.footprint, highestChildren: usage.children,
            nextSample: Self.sampleInterval)
    }

    private func step(now: Double) {
        guard let stage else { return }
        let time = now - phase.start
        if time >= phase.nextSample {
            phase.nextSample = time + Self.sampleInterval
            _ = snapshot(leaveOut: false)
        }
        let step = steps[phase.index]
        switch step.phase {
        case .drag, .resize: moveDrag(stage, at: time)
        case .typing: type(stage, at: time)
        default: break
        }
        guard time >= Self.seconds(step.time) else { return }
        end(stage, now: CACurrentMediaTime())
    }

    // The end of a phase: its sample. Then the next phase, or the end of the run.
    private func end(_ stage: BenchStage, now: Double) {
        let step = steps[phase.index]
        if step.phase == .drag || step.phase == .resize { endDrag(stage) }
        let seconds = now - phase.start
        let end = snapshot()
        samples.append(
            BenchSample(
                phase: step.phase.rawValue, seconds: seconds, frames: counter.frames - phase.frames,
                missed: counter.missed - phase.missed,
                excludedSeconds: counter.excludedSeconds - phase.excluded,
                appFootprint: phase.highestApp, childFootprint: phase.highestChildren,
                appInstructions: end.app.instructions &- phase.usage.instructions,
                appCPUSeconds: end.app.cpuSeconds - phase.usage.cpuSeconds,
                start: phase.start, startDate: phase.startDate))
        do throws(BenchFailure) {
            try checkWindow(stage)
        } catch {
            resume(
                .failure(BenchFailure(check: "\(error.reason) The phase \(step.phase) ended so.")))
            return
        }
        let states = chats.map { (id: $0, state: stage.chats.terminal($0)?.state) }
        if let lost = Self.lostChat(states, phase: step.phase) {
            resume(.failure(BenchFailure(lost)))
            return
        }
        let next = phase.index + 1
        guard next < steps.count else {
            mode = .off
            resume(.success(()))
            return
        }
        begin(next)
    }

    // The usage of the app and the footprint of each PTY child of the manager: the attach of
    // each chat and a hidden attach of the session input. Each value also goes into the highest
    // values of the phase. A snapshot for the counters leaves out the next frame gap.
    private func snapshot(leaveOut: Bool = true) -> (app: ProcessUsage, children: UInt64) {
        let app =
            ProcessMetrics.usage(of: getpid())
            ?? ProcessUsage(footprint: 0, instructions: 0, cpuSeconds: 0)
        let pids = stage?.ptys()?.list().map(\.pid) ?? []
        let children = pids.compactMap { ProcessMetrics.usage(of: $0)?.footprint }.reduce(0, +)
        phase.highestApp = max(phase.highestApp, app.footprint)
        phase.highestChildren = max(phase.highestChildren, children)
        if leaveOut { counter.leaveOutNextGap() }
        return (app, children)
    }

    // MARK: - The drag, the resize and the typing

    private func beginDrag(_ stage: BenchStage, resize: Bool) {
        guard let session = SessionID(target),
            let frame = stage.layout.layout.frame(of: .chat(session))
        else { return }
        stage.layout.apply(.focus(frame.id))
        let rect = frame.rect
        let units = 100 / Double(stage.canvas.metrics.interfaceScale)
        let start =
            resize
            ? LayoutPoint(x: rect.x + rect.w, y: rect.y + rect.h)
            : LayoutPoint(
                x: rect.x + Self.titleAnchor.x * units, y: rect.y + Self.titleAnchor.y * units)
        let mode: DragMode = resize ? .resize(.se) : .move
        guard stage.layout.beginDrag(frame: frame.id, mode: mode, at: start) else { return }
        drag = DragState(frame: frame.id, rect: rect, start: start, resize: resize)
    }

    // One step of the drag at each display frame: the same calls as a pointer step.
    private func moveDrag(_ stage: BenchStage, at time: Double) {
        guard let drag else { return }
        let offset = drag.resize ? BenchPath.resize(at: time) : BenchPath.drag(at: time)
        let units = 100 / Double(stage.canvas.metrics.interfaceScale)
        stage.canvas.moveDrag(
            to: LayoutPoint(x: drag.start.x + offset.x * units, y: drag.start.y + offset.y * units))
    }

    // A cancel of the drag, then the frame goes back to its rect, so each phase starts from the
    // same layout.
    private func endDrag(_ stage: BenchStage) {
        guard let drag else { return }
        self.drag = nil
        stage.layout.endDrag(at: nil)
        stage.layout.apply(.setRect(drag.frame, drag.rect))
    }

    // Ctrl+C in the typing chat. Then its frame comes to the front and its terminal gets the
    // focus, so the keys of the window go to it.
    private func prepareTyping(_ stage: BenchStage) {
        write(Self.ctrlC, to: [target])
        guard let session = SessionID(target),
            let frame = stage.layout.layout.frame(of: .chat(session))
        else { return }
        stage.layout.apply(.focus(frame.id))
        if let view = stage.chats.terminal(target)?.view {
            stage.window.makeFirstResponder(view)
        }
    }

    // The keys of the typing, as the keys of a person through the window: the letters of the
    // prototype in turn, 10 a second, and Ctrl+U after each 40 keys. The time of each key comes
    // from the plan, not from the time of the last key, so a late frame does not slow the rate.
    private func type(_ stage: BenchStage, at time: Double) {
        guard typing.sent < BenchPath.keyLimit, time >= typing.next else { return }
        let sent = typing.sent
        if sent > 0, sent % BenchPath.keysBeforeClear == 0, typing.clearedAt != sent {
            typing.clearedAt = sent
            press("u", control: true, in: stage.window)
            typing.next += 3 * BenchPath.keyInterval
            return
        }
        let letters = Array("asdfhgzxcvbqwerytouipljknm")
        press(String(letters[sent % letters.count]), control: false, in: stage.window)
        typing.sent += 1
        typing.next += BenchPath.keyInterval
    }

    // One key down and up through the window. Control goes down before the key and up after it,
    // as on a keyboard.
    private func press(_ id: String, control: Bool, in window: NSWindow) {
        let mods: Set<USKeyboard.Mod> = control ? [.ctrl] : []
        var events: [NSEvent?] = []
        if control {
            events.append(USKeyboard.modifierEvent(id: "Control", mods: mods, window: window))
        }
        for down in [true, false] {
            events.append(
                USKeyboard.keyEvent(
                    down: down, id: id, mods: mods, isRepeat: false, window: window))
        }
        if control {
            events.append(USKeyboard.modifierEvent(id: "Control", mods: [], window: window))
        }
        for event in events.compactMap(\.self) { window.sendEvent(event) }
    }

    private func write(_ bytes: [UInt8], to ids: [String]) {
        guard let ptys = stage?.ptys() else { return }
        for session in ids.compactMap(SessionID.init) {
            _ = ptys.attach(.chat(session))?.write(bytes)
        }
    }

    // MARK: - The end

    private func finish(_ stage: BenchStage) {
        watchdog.stop()
        link?.invalidate()
        link = nil
        mode = .off
        endDrag(stage)
        stage.setMotion(nil)
        if blurChanged {
            var settings = stage.canvas.settings
            settings.blur = .backdrop
            stage.canvas.apply(settings)
        }
        stage.window.level = .normal
        self.stage = nil
    }

    // The samples, one JSON line each with the keys in order, in one write to a new file. The
    // bench folder gets mode 0700.
    @concurrent private static func save(_ samples: [BenchSample], to url: URL)
        async throws(BenchFailure)
    {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        do {
            for sample in samples {
                data.append(try encoder.encode(sample))
                data.append(0x0a)
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
        } catch {
            throw BenchFailure("The results file cannot be written. \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func pause(_ duration: Duration) async {
        try? await clock.sleep(for: duration)
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    // The path with each link resolved, or nil when no file is at the path.
    private static func resolved(_ path: String) -> String? {
        RealPath.of(path)
    }
}
#endif
