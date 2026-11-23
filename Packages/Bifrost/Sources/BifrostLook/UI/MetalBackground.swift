// The animated background (docs/behaviour/look.md, "The animated background") in Metal. One
// fragment shader draws the base and the six fields at half the device pixels
// (Motion.canvasScale), with the grain and a dither in the shader. It needs no large images.
//
// The main thread never draws and never waits for a surface. A display link on the main thread
// asks for the frame of each step of the motion, at most 30 times each second (Motion.rate). A
// render thread of its own (BackgroundRenderLoop.swift) draws the frame into an IOSurface, and
// the main thread then puts that surface into the layer. When each surface is busy, for example
// because the window server is slow, the render thread skips the frame.
//
// While the background does not move, the display link stops: the view asks for a frame only
// after a change of its size, of its scale or of the motion. While the window is not visible
// (minimised, or fully covered), the view asks for no frame, and the display link stops. With no
// Metal device, the view shows the plain background colour.
//
// The shader is Background.metal. The app build compiles it into the default library of the
// module bundle. A command-line build (swift build, swift test) compiles no Metal: it copies the
// file into the bundle, and the renderer compiles it at run time.
import AppKit
import Metal
import QuartzCore

public final class MetalBackground: NSView {
    // The frame rates of the display link. The motion moves 30 times each second, so a higher
    // rate gives no change. Under load the system can go down to 15.
    static let frameRates = CAFrameRateRange(
        minimum: Float(Motion.rate / 2), maximum: Float(Motion.rate),
        preferred: Float(Motion.rate))

    // The layer that shows the surfaces of the render thread, or nil when the system has no
    // Metal device or the shader does not build.
    let surfaceLayer: CALayer?
    private let loop: BackgroundRenderLoop?
    private let now: () -> Double
    private var clock = MotionClock()
    private let ticker = BackgroundTicker()
    private var link: CADisplayLink?
    // True while the window shows on the screen: not minimised and not fully covered.
    private(set) var visible = false
    // The size of the surfaces in pixels.
    private(set) var pixels: PixelSize?
    // The newest frame that the view asked for.
    private var requested: BackgroundFrame?
    // The number of frames that the view asked for.
    private(set) var requestedFrames = 0

    // `now` gives the time in seconds on a clock that never goes back. `report` gets each try of
    // the render thread, on that thread. The tests give their own.
    init(
        frame: NSRect, now: @escaping () -> Double,
        report: (@Sendable (BackgroundReport) -> Void)? = nil
    ) {
        self.now = now
        let renderer = MTLCreateSystemDefaultDevice().flatMap { BackgroundRenderer(device: $0) }
        loop = renderer.map { BackgroundRenderLoop(renderer: $0) }
        surfaceLayer = renderer.map { _ in CALayer() }
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = ThemeTokens.bg.cgColor
        guard let surfaceLayer, let loop else { return }
        // The surfaces fill the layer. Core Animation scales them up with no animation.
        surfaceLayer.isOpaque = true
        surfaceLayer.contentsGravity = .resize
        surfaceLayer.actions = [
            "contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull(),
        ]
        surfaceLayer.frame = bounds
        layer?.addSublayer(surfaceLayer)
        ticker.background = self
        loop.start { [weak self] result in
            report?(result)
            guard result.outcome == .drawn else { return }
            Task { @MainActor [weak self] in self?.showFinishedFrame() }
        }
    }

    package convenience override init(frame: NSRect) {
        self.init(frame: frame, now: { CACurrentMediaTime() })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        link?.invalidate()
        loop?.stop()
    }

    // The time of the motion in seconds.
    var motionTime: Double { clock.time(at: now()) }

    // True while the display link asks for a frame at each step of the motion.
    var animating: Bool { visible && clock.running }

    // True while the display link runs: while the background moves, or while a frame waits.
    var linkRunning: Bool { link.map { !$0.isPaused } ?? false }

    // The frame rates of the display link, or nil with no display link.
    var linkFrameRates: CAFrameRateRange? { link?.preferredFrameRateRange }

    // MARK: - The size and the window

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGeometry()
    }

    public override func layout() {
        super.layout()
        updateGeometry()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateGeometry()
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        NotificationCenter.default.removeObserver(self)
        link?.invalidate()
        link = nil
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window, loop != nil {
            let names = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            ]
            for name in names {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(windowStateChanged(_:)), name: name, object: window)
            }
            let link = displayLink(target: ticker, selector: #selector(BackgroundTicker.tick(_:)))
            link.preferredFrameRateRange = Self.frameRates
            link.isPaused = true
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        updateGeometry()
        updateVisibility()
    }

    @objc private func windowStateChanged(_ notification: Notification) {
        updateVisibility()
    }

    // The window is visible when it is not minimised and some part of it shows on the screen.
    private func updateVisibility() {
        let shows = window.map { $0.occlusionState.contains(.visible) && !$0.isMiniaturized }
        let visible = shows ?? false
        guard visible != self.visible else { return }
        self.visible = visible
        update()
    }

    // The surfaces have half the device pixels. Core Animation scales the image up.
    private func updateGeometry() {
        guard let surfaceLayer else { return }
        surfaceLayer.frame = bounds
        let scale = Double(window?.backingScaleFactor ?? 2)
        pixels = Motion.canvasSize(
            width: Double(bounds.width) * scale, height: Double(bounds.height) * scale)
        update()
    }

    // MARK: - The motion

    // Move the layers, or stop them where they are.
    package func setMoving(_ moving: Bool) {
        guard moving != clock.running else { return }
        if moving {
            clock.start(at: now())
        } else {
            clock.stop(at: now())
        }
        update()
    }

    // Show a phase of the motion: moving, paused in place, or the still position (the first
    // step of each cycle).
    public func apply(_ motion: BackgroundMotion) {
        switch motion.phase {
        case .moving: setMoving(true)
        case .paused: setMoving(false)
        case .still:
            clock.reset()
            update()
        }
    }

    // MARK: - The frames

    // Ask the render thread for the frame of now when it differs from the newest request. The
    // display link calls this at each tick. A frame that waits after a skip gets a retry. While
    // the window is not visible, the view asks for no frame.
    func update() {
        if let loop, visible, let pixels {
            let frame = BackgroundFrame(
                time: Motion.step(motionTime), width: Double(bounds.width),
                height: Double(bounds.height), pixels: pixels)
            if frame != requested {
                requested = frame
                requestedFrames += 1
                loop.request(frame)
            } else {
                loop.retry()
            }
        }
        updateLink()
    }

    // The display link runs while the window is visible and the background moves or a frame
    // waits. Else it stops, and the view draws nothing.
    private func updateLink() {
        guard let link else { return }
        let run = visible && (clock.running || loop?.busy == true)
        if link.isPaused == run { link.isPaused = !run }
    }

    // Show the newest surface of the render thread. Only the layer changes on the main thread.
    private func showFinishedFrame() {
        guard let surfaceLayer, let surface = loop?.takeFinished() else { return }
        surfaceLayer.contents = surface
        updateLink()
    }
}

// The target of the display link. The display link keeps its target, so the target keeps only a
// weak reference to the view. With no view, the first tick stops the display link.
@MainActor
private final class BackgroundTicker: NSObject {
    weak var background: MetalBackground?

    @objc func tick(_ link: CADisplayLink) {
        guard let background else {
            link.invalidate()
            return
        }
        background.update()
    }
}
