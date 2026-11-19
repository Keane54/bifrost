import AppKit
import BifrostTestSupport
import MetalKit
import Testing

@testable import BifrostLook

// The animated background in Metal: the base and the six fields at half the device pixels, 30
// times each second while it moves. The tests never order the window front.

// A time source that a test moves.
@MainActor
private final class TestTime {
    var now = 100.0
}

@MainActor
private func window(_ view: NSView) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless],
        backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    return window
}

@MainActor
@Suite("metal background", .serialized, .tags(.window))
struct MetalBackgroundTests {
    init() { UITestApp.prepare() }

    @Test func theBackgroundDrawsAtHalfTheDevicePixelsAt30FramesASecond() throws {
        let background = MetalBackground(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let host = window(background)
        defer { host.close() }
        let metal = try #require(background.metalView)
        let scale = host.backingScaleFactor
        let expected = Motion.canvasSize(width: 800 * scale, height: 500 * scale)
        #expect(metal.drawableSize == CGSize(width: expected.width, height: expected.height))
        #expect(metal.preferredFramesPerSecond == 30)
        #expect(metal.colorPixelFormat == .bgra8Unorm)
        // The layer behind the Metal view has the background colour, so the first paint has no
        // flash.
        #expect(background.layer?.backgroundColor == ThemeTokens.bg.cgColor)
    }

    @Test func theBackgroundMovesOnlyWhileItMovesAndPausesInPlace() throws {
        let time = TestTime()
        let background = MetalBackground(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300), now: { time.now })
        let host = window(background)
        defer { host.close() }
        let metal = try #require(background.metalView)
        // At the start the background is still: no draw loop runs.
        #expect(metal.isPaused)
        #expect(background.motionTime == 0)
        background.setMoving(true)
        #expect(!metal.isPaused)
        time.now = 107.5
        #expect(background.motionTime == 7.5)
        background.setMoving(false)
        #expect(metal.isPaused)
        time.now = 200
        #expect(background.motionTime == 7.5)
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
        let metal = try #require(background.metalView)
        var motion = BackgroundMotion(setting: true, reduceMotion: false)
        motion.setWindowActive(true)
        background.apply(motion)
        #expect(!metal.isPaused)
        time.now = 110
        motion.setWindowActive(false)
        background.apply(motion)
        #expect(metal.isPaused)
        #expect(background.motionTime == 10)
        // Reduced motion gives the still position: the first step of each cycle.
        motion.setReduceMotion(true)
        background.apply(motion)
        #expect(metal.isPaused)
        #expect(background.motionTime == 0)
    }
}
