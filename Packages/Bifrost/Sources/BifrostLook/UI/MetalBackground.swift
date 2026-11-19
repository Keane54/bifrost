// The animated background (docs/behaviour/look.md, "The animated background") in Metal. One
// fragment shader draws the base and the six fields at half the device pixels
// (Motion.canvasScale), 30 times each second while the motion runs, with the grain and a dither
// in the shader. It needs no large images.
//
// While the background does not move, no draw loop runs: the view draws again only after a
// change of its size. With no Metal device, the view shows the plain background colour.
//
// The shader is Background.metal. The app build compiles it into the default library of the
// module bundle. A command-line build (swift build, swift test) compiles no Metal: it copies the
// file into the bundle, and the renderer compiles it at run time.
import AppKit
import BifrostFoundation
import MetalKit
import OSLog
import QuartzCore

// The renderer of the Metal view. It reads the motion time at each draw.
@MainActor
private final class BackgroundRenderer: NSObject, MTKViewDelegate {
    private let pipeline: any MTLRenderPipelineState
    private let queue: any MTLCommandQueue
    var time: () -> Double = { 0 }

    init?(device: any MTLDevice) {
        guard let queue = device.makeCommandQueue(), let library = Self.library(device)
        else { return nil }
        let description = MTLRenderPipelineDescriptor()
        description.vertexFunction = library.makeFunction(name: "vtx")
        description.fragmentFunction = library.makeFunction(name: "frg")
        description.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: description)
        else { return nil }
        self.pipeline = pipeline
        self.queue = queue
    }

    private static let logger = Logger(bifrost: "background")

    // The library that the app build compiled, else the library of the copied source. With
    // neither, the view shows the plain background colour.
    private static func library(_ device: any MTLDevice) -> (any MTLLibrary)? {
        if let built = try? device.makeDefaultLibrary(bundle: .module),
            built.makeFunction(name: "frg") != nil
        {
            return built
        }
        guard let file = Bundle.module.url(forResource: "Background", withExtension: "metal"),
            let source = try? String(contentsOf: file, encoding: .utf8),
            let library = try? device.makeLibrary(source: source, options: nil)
        else {
            logger.error(
                "The background shader has no compiled library and its source did not compile")
            return nil
        }
        return library
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
            let buffer = queue.makeCommandBuffer(),
            let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }
        // The motion moves 30 times each second.
        let t = Motion.step(time())
        let width = Double(view.bounds.width)
        let height = Double(view.bounds.height)
        var data = layerData(at: t, width: width, height: height)
        var stops = Motion.baseIcons.map { SIMD4<Float>(Theme.icon($0).rgb, 1) }
        let drawn = view.drawableSize
        var info = SIMD4<Float>(
            Float(width / max(1, Double(drawn.width))),
            Float(height / max(1, Double(drawn.height))), 0, 0)
        var look = SIMD4<Float>(ThemeTokens.bg.rgb, Float(Motion.noise))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&data, length: data.count * 16, index: 0)
        encoder.setFragmentBytes(&stops, length: stops.count * 16, index: 1)
        encoder.setFragmentBytes(&info, length: 16, index: 2)
        encoder.setFragmentBytes(&look, length: 16, index: 3)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    // The 5 values of each layer at a time, in the paint order: the base, then the fields.
    private func layerData(at t: Double, width: Double, height: Double) -> [SIMD4<Float>] {
        var data: [SIMD4<Float>] = []
        for layer in [Motion.base] + Motion.fields {
            let pose = Motion.state(layer, at: t)
            let w = layer.w * width
            let h = layer.h * height
            let cx = layer.left * width + w / 2 + pose.tx / 100 * w
            let cy = layer.top * height + h / 2 + pose.ty / 100 * h
            let turn = -pose.rot * .pi / 180
            let inverse = 1 / pose.scale
            // The inverse of rotate(rot) scale(scale), as two columns.
            let c = Float(cos(turn) * inverse)
            let s = Float(sin(turn) * inverse)
            data.append(SIMD4(Float(cx), Float(cy), Float(w / 2), Float(h / 2)))
            data.append(SIMD4(c, s, -s, c))
            if let icon = layer.icon {
                let alpha = Motion.glow * layer.weight * pose.opacity
                data.append(SIMD4(Theme.icon(icon).rgb, Float(alpha)))
                data.append(.zero)
                data.append(.zero)
            } else {
                let (x0, y0, x1, y1) = Motion.gradientLine(Motion.baseAngle, w, h)
                let dx = x1 - x0
                let dy = y1 - y0
                let length2 = dx * dx + dy * dy
                data.append(SIMD4(0, 0, 0, Float(Motion.baseAlpha * pose.opacity)))
                data.append(
                    SIMD4(Float(x0), Float(y0), Float(dx / length2), Float(dy / length2)))
                data.append(SIMD4(1, 0, 0, 0))
            }
        }
        return data
    }
}

public final class MetalBackground: NSView {
    // The Metal view, or nil when the system has no Metal device or the shader does not build.
    let metalView: MTKView?
    private let renderer: BackgroundRenderer?
    private let now: () -> Double
    private var clock = MotionClock()

    // `now` gives the time in seconds on a clock that never goes back. The tests give their own.
    init(frame: NSRect, now: @escaping () -> Double) {
        self.now = now
        let device = MTLCreateSystemDefaultDevice()
        let renderer = device.flatMap { BackgroundRenderer(device: $0) }
        self.renderer = renderer
        metalView = renderer.flatMap { _ in MTKView(frame: frame, device: device) }
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = ThemeTokens.bg.cgColor
        guard let metalView, let renderer else { return }
        renderer.time = { [weak self] in self?.motionTime ?? 0 }
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.framebufferOnly = true
        metalView.autoResizeDrawable = false
        metalView.preferredFramesPerSecond = 30
        if let metalLayer = metalView.layer as? CAMetalLayer {
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            metalLayer.isOpaque = true
        }
        metalView.delegate = renderer
        metalView.autoresizingMask = [.width, .height]
        metalView.frame = bounds
        addSubview(metalView)
        stopDrawLoop()
    }

    package convenience override init(frame: NSRect) {
        self.init(frame: frame, now: { CACurrentMediaTime() })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // The time of the motion in seconds.
    var motionTime: Double { clock.time(at: now()) }

    public override func layout() {
        super.layout()
        updateDrawableSize()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    // The drawable has half the device pixels. Core Animation scales the image up.
    private func updateDrawableSize() {
        guard let metalView else { return }
        let scale = Double(window?.backingScaleFactor ?? 2)
        let size = Motion.canvasSize(
            width: Double(bounds.width) * scale, height: Double(bounds.height) * scale)
        let drawable = CGSize(width: size.width, height: size.height)
        if metalView.drawableSize != drawable { metalView.drawableSize = drawable }
        metalView.needsDisplay = true
    }

    // Move the layers, or stop them where they are.
    package func setMoving(_ moving: Bool) {
        guard moving != clock.running else { return }
        if moving {
            clock.start(at: now())
            metalView?.enableSetNeedsDisplay = false
            metalView?.isPaused = false
        } else {
            clock.stop(at: now())
            stopDrawLoop()
        }
    }

    // Show a phase of the motion: moving, paused in place, or the still position (the first
    // step of each cycle).
    public func apply(_ motion: BackgroundMotion) {
        switch motion.phase {
        case .moving: setMoving(true)
        case .paused: setMoving(false)
        case .still:
            clock.reset()
            stopDrawLoop()
        }
    }

    // No draw loop: the view draws one time now, and again after a change of its size.
    private func stopDrawLoop() {
        metalView?.isPaused = true
        metalView?.enableSetNeedsDisplay = true
        metalView?.needsDisplay = true
    }
}
