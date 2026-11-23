import AppKit
import BifrostTestSupport
import IOSurface
import Metal
import Synchronization
import Testing

@testable import BifrostLook

// The animated background in Metal: the base and the six fields at half the device pixels, at
// most 30 times each second while it moves, drawn on a render thread of its own. The tests never
// order the window front.

// A time source that a test moves.
@MainActor
private final class TestTime {
    var now = 100.0
}

// A window of the tests. It reports the backing scale of the snapshots, and the test sets its
// occlusion state and its minimised state. AppKit tells the view of a change with a
// notification, so the test posts that notification after each change.
@MainActor
private final class TestWindow: NSWindow, SnapshotScaled {
    var shows = true
    var minimised = false

    override var backingScaleFactor: CGFloat { CGFloat(Snapshot.scale) }
    override var occlusionState: NSWindow.OcclusionState { shows ? .visible : [] }
    override var isMiniaturized: Bool { minimised }

    func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: self)
    }
}

@MainActor
private func window(_ view: NSView) -> TestWindow {
    let window = TestWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless],
        backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    return window
}

// The tries of a render thread, in their order.
private final class Reports: Sendable {
    private let list = Mutex<[BackgroundReport]>([])

    var all: [BackgroundReport] { list.withLock { $0 } }
    var outcomes: [BackgroundOutcome] { all.map(\.outcome) }

    func add(_ report: BackgroundReport) { list.withLock { $0.append(report) } }
}

// A value that the test sets and the render thread reads.
private final class Flag: Sendable {
    private let value: Mutex<Bool>

    init(_ value: Bool) { self.value = Mutex(value) }

    var on: Bool {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

// The surface that the layer of the background shows, or nil.
@MainActor
private func shown(_ background: MetalBackground) -> IOSurface? {
    background.surfaceLayer?.contents as? IOSurface
}

// The size of the surfaces of the background at the scale of the test window.
@MainActor
private func pixels(of background: MetalBackground) -> PixelSize {
    let scale = Double(Snapshot.scale)
    return Motion.canvasSize(
        width: Double(background.bounds.width) * scale,
        height: Double(background.bounds.height) * scale)
}

@MainActor
private func shows(_ background: MetalBackground, _ size: PixelSize) -> Bool {
    guard let surface = shown(background) else { return false }
    return surface.width == size.width && surface.height == size.height
}

@MainActor
@Suite("metal background", .serialized, .testTimeLimit, .tags(.window))
struct MetalBackgroundTests {
    init() { UITestApp.prepare() }

    @Test func theBackgroundDrawsAtHalfTheDevicePixelsAt30FramesASecond() async throws {
        let background = MetalBackground(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let host = window(background)
        defer { host.close() }
        _ = try #require(background.surfaceLayer)
        let expected = Motion.canvasSize(width: 800 * 2, height: 500 * 2)
        #expect(background.pixels == expected)
        #expect(background.linkFrameRates?.maximum == 30)
        #expect(background.linkFrameRates?.preferred == 30)
        // The layer behind the surfaces has the background colour, so the first paint has no
        // flash.
        #expect(background.layer?.backgroundColor == ThemeTokens.bg.cgColor)
        // The first frame shows: a surface of that size, with four bytes B, G, R and A.
        #expect(await waitUntil { shows(background, expected) })
        #expect(shown(background)?.pixelFormat == BackgroundRenderer.surfaceFormat)
        #expect(shown(background)?.bytesPerElement == 4)
    }

    // The main test of the fix: the main thread never draws. Each try of the render thread
    // reports its thread.
    @Test func theRenderThreadDrawsTheFramesNotTheMainThread() async throws {
        let reports = Reports()
        let time = TestTime()
        let background = MetalBackground(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300), now: { time.now },
            report: { reports.add($0) })
        let host = window(background)
        defer { host.close() }
        _ = try #require(background.surfaceLayer)
        #expect(await waitUntil { shown(background) != nil })
        let first = shown(background)
        background.setMoving(true)
        time.now = 101
        background.update()
        #expect(await waitUntil { shown(background).map { $0 !== first } ?? false })
        #expect(!reports.all.isEmpty)
        #expect(reports.all.allSatisfy { !$0.onMainThread && $0.outcome == .drawn })
    }

    @Test func theBackgroundMovesOnlyWhileItMovesAndPausesInPlace() async throws {
        let time = TestTime()
        let background = MetalBackground(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300), now: { time.now })
        let host = window(background)
        defer { host.close() }
        _ = try #require(background.surfaceLayer)
        // At the start the background is still: the display link stops after the first frame.
        #expect(!background.animating)
        #expect(background.motionTime == 0)
        #expect(await waitUntil { shown(background) != nil && !background.linkRunning })
        background.setMoving(true)
        #expect(background.animating)
        #expect(background.linkRunning)
        time.now = 107.5
        #expect(background.motionTime == 7.5)
        background.setMoving(false)
        #expect(!background.animating)
        time.now = 200
        #expect(background.motionTime == 7.5)
        // The paused frame shows, then the display link stops.
        #expect(await waitUntil { !background.linkRunning })
        background.setMoving(true)
        time.now = 201
        #expect(background.motionTime == 8.5)
    }

    @Test func eachPhaseOfTheMotionSetsTheBackground() throws {
        let time = TestTime()
        let background = MetalBackground(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300), now: { time.now })
        let host = window(background)
        defer { host.close() }
        _ = try #require(background.surfaceLayer)
        var motion = BackgroundMotion(setting: true, reduceMotion: false)
        motion.setWindowActive(true)
        background.apply(motion)
        #expect(background.animating)
        time.now = 110
        motion.setWindowActive(false)
        background.apply(motion)
        #expect(!background.animating)
        #expect(background.motionTime == 10)
        // Reduced motion gives the still position: the first step of each cycle.
        motion.setReduceMotion(true)
        background.apply(motion)
        #expect(!background.animating)
        #expect(background.motionTime == 0)
    }

    // The test that fails when the main thread waits for the render thread again. The gate holds
    // the render thread in its check of a surface (isInUse), as a slow window server does. While
    // it waits there, the calls of the main thread run to their end: a new request, a retry, the
    // busy state and the take of the finished surface for the layer. A detached task makes these
    // calls, so a defect fails the wait below at its limit and does not stop the main actor.
    @Test func theMainThreadNeverWaitsWhileTheRenderThreadWaits() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try #require(BackgroundRenderer(device: device))
        let gate = TestGate()
        defer { gate.openAll() }
        let loop = BackgroundRenderLoop(
            renderer: renderer,
            inUse: { _ in
                gate.passBlocking()
                return false
            })
        let reports = Reports()
        loop.start { reports.add($0) }
        defer { loop.stop() }
        func frame(_ step: Int) -> BackgroundFrame {
            BackgroundFrame(
                time: Double(step) / 30, width: 100, height: 80,
                pixels: PixelSize(width: 100, height: 80))
        }
        // Frames 1 and 2 make two surfaces. Frame 3 checks the first surface, and waits at the
        // gate.
        loop.request(frame(1))
        #expect(await waitUntil { reports.all.count == 1 })
        loop.request(frame(2))
        #expect(await waitUntil { reports.all.count == 2 })
        loop.request(frame(3))
        #expect(await gate.waitUntilHolding(1))
        let next = frame(4)
        let done = TestSignal()
        let calls = Task.detached {
            loop.request(next)
            loop.retry()
            let busy = loop.busy
            let finished = loop.takeFinished()
            done.send()
            return (busy, finished)
        }
        let ended = await done.wait(for: "end of the calls of the main thread")
        gate.openAll()
        let (busy, finished) = await calls.value
        #expect(ended)
        #expect(busy)
        // The layer gets the surface of frame 2 while the render thread still waits.
        let surface = try #require(finished)
        let layer = CALayer()
        layer.contents = surface
        #expect(!gate.ranOnTheMainThread)
        // After the gate opens, the render thread draws frames 3 and 4.
        #expect(await waitUntil { reports.all.count == 4 })
        #expect(reports.outcomes == [.drawn, .drawn, .drawn, .drawn])
    }

    // With the real check of the window server, the render thread uses its three surfaces in
    // turn: six frames, each one drawn, in three surfaces. The test takes each odd frame for the
    // layer, so the layer shows one surface and another surface waits for its show.
    @Test func theRenderThreadUsesItsThreeSurfacesInTurn() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try #require(BackgroundRenderer(device: device))
        let loop = BackgroundRenderLoop(renderer: renderer)
        let reports = Reports()
        loop.start { reports.add($0) }
        defer { loop.stop() }
        var taken: [IOSurface] = []
        for step in 1...6 {
            loop.request(
                BackgroundFrame(
                    time: Double(step) / 30, width: 100, height: 80,
                    pixels: PixelSize(width: 100, height: 80)))
            #expect(await waitUntil { reports.all.count == step })
            if step % 2 == 1, let surface = loop.takeFinished(),
                !taken.contains(where: { $0 === surface })
            {
                taken.append(surface)
            }
        }
        #expect(reports.outcomes == Array(repeating: .drawn, count: 6))
        #expect(taken.count == BackgroundSurfaces.limit)
    }

    // Each surface is busy, for example because the window server is slow. The render thread
    // skips the frame at once, and a retry draws it when a surface comes free.
    @Test func theRenderThreadSkipsAFrameWhenNoSurfaceIsFreeAndDoesNotWait() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try #require(BackgroundRenderer(device: device))
        let held = Flag(true)
        let loop = BackgroundRenderLoop(renderer: renderer, inUse: { _ in held.on })
        let reports = Reports()
        loop.start { reports.add($0) }
        defer { loop.stop() }
        func frame(_ step: Int) -> BackgroundFrame {
            BackgroundFrame(
                time: Double(step) / 30, width: 100, height: 80,
                pixels: PixelSize(width: 100, height: 80))
        }
        // The first three frames make the three surfaces of the set.
        for step in 1...BackgroundSurfaces.limit {
            loop.request(frame(step))
            #expect(await waitUntil { reports.all.count == step })
        }
        #expect(reports.outcomes == [.drawn, .drawn, .drawn])
        // The window server holds two surfaces, and the third waits for its show.
        loop.request(frame(4))
        #expect(await waitUntil { reports.all.count == 4 })
        #expect(reports.outcomes.last == .skipped)
        #expect(loop.busy)
        // The window server lets the surfaces go. The retry draws the frame that waits.
        held.on = false
        loop.retry()
        #expect(await waitUntil { reports.all.count == 5 })
        #expect(reports.outcomes.last == .drawn)
        #expect(reports.all.allSatisfy { !$0.onMainThread })
    }

    @Test func theBackgroundDrawsNothingWhileTheWindowIsCoveredOrMinimised() async throws {
        let time = TestTime()
        let background = MetalBackground(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300), now: { time.now })
        let host = window(background)
        defer { host.close() }
        _ = try #require(background.surfaceLayer)
        #expect(await waitUntil { shown(background) != nil })
        background.setMoving(true)
        #expect(background.linkRunning)
        let start = background.requestedFrames
        // Fully covered: no frame, and the display link stops.
        host.shows = false
        host.post(NSWindow.didChangeOcclusionStateNotification)
        #expect(!background.visible)
        #expect(!background.linkRunning)
        time.now = 101
        background.update()
        #expect(background.requestedFrames == start)
        // Visible again: the frame of now at once, and the display link runs again.
        host.shows = true
        host.post(NSWindow.didChangeOcclusionStateNotification)
        #expect(background.linkRunning)
        #expect(background.requestedFrames == start + 1)
        // Minimised: the same.
        host.minimised = true
        host.post(NSWindow.didMiniaturizeNotification)
        #expect(!background.linkRunning)
        time.now = 102
        background.update()
        #expect(background.requestedFrames == start + 1)
        host.minimised = false
        host.post(NSWindow.didDeminiaturizeNotification)
        #expect(background.linkRunning)
        #expect(background.requestedFrames == start + 2)
    }

    // 120 ticks in one second, as on a display of 120 Hz, give one frame for each step of the
    // motion: 30 frames.
    @Test func theBackgroundAsksForAtMost30FramesEachSecond() throws {
        let time = TestTime()
        let background = MetalBackground(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300), now: { time.now })
        let host = window(background)
        defer { host.close() }
        _ = try #require(background.surfaceLayer)
        background.setMoving(true)
        #expect(background.linkFrameRates?.maximum == 30)
        let start = background.requestedFrames
        for tick in 0..<120 {
            time.now = 101 + (Double(tick) + 0.5) / 120
            background.update()
        }
        #expect(background.requestedFrames - start == 30)
    }

    // After a resize, the layer shows a new frame with the new size. Until then, Core Animation
    // scales the frame before it, so the layer is never blank.
    @Test func aResizeShowsANewFrameWithTheNewSize() async throws {
        let background = MetalBackground(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let host = window(background)
        defer { host.close() }
        _ = try #require(background.surfaceLayer)
        #expect(await waitUntil { shows(background, pixels(of: background)) })
        background.setFrameSize(NSSize(width: 600, height: 200))
        let expected = Motion.canvasSize(width: 1200, height: 400)
        #expect(pixels(of: background) == expected)
        #expect(background.pixels == expected)
        #expect(background.surfaceLayer?.frame == background.bounds)
        #expect(shown(background) != nil)
        #expect(await waitUntil { shows(background, expected) })
        #expect(await waitUntil { !background.linkRunning })
    }
}
