// The draw of one frame of the animated background (MetalBackground.swift). The render thread
// (BackgroundRenderLoop.swift) uses these types. No type here uses AppKit or a view.
//
// The fragment shader draws the base and the six fields into an IOSurface with half the device
// pixels (Motion.canvasSize). The layer of the view shows the surface, and Core Animation scales
// it up. The surface has the sRGB colour space, so the colours are the same on each display.
import BifrostFoundation
import IOSurface
import Metal
import OSLog
import QuartzCore

// The frame that the main thread asks for: the step of the motion and the size of the view.
struct BackgroundFrame: Sendable, Equatable {
    // The motion time of the step in seconds (Motion.step).
    var time: Double
    // The size of the view in points.
    var width: Double
    var height: Double
    // The size of the surface in pixels.
    var pixels: PixelSize
}

// The shader and the command queue. Metal lets each thread use them.
final class BackgroundRenderer: Sendable {
    // The pixel format of the surfaces and of the pipeline.
    static let pixelFormat = MTLPixelFormat.bgra8Unorm
    // The pixel format of the surfaces for IOSurface: four bytes in the order B, G, R, A.
    static let surfaceFormat: UInt32 = 0x4247_5241

    let device: any MTLDevice
    private let pipeline: any MTLRenderPipelineState
    private let queue: any MTLCommandQueue

    init?(device: any MTLDevice) {
        guard let queue = device.makeCommandQueue(), let library = Self.library(device)
        else { return nil }
        let description = MTLRenderPipelineDescriptor()
        description.vertexFunction = library.makeFunction(name: "vtx")
        description.fragmentFunction = library.makeFunction(name: "frg")
        description.colorAttachments[0].pixelFormat = Self.pixelFormat
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: description)
        else { return nil }
        self.device = device
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

    // Draw the frame into the texture, and wait until the GPU completes the draw. Only the
    // render thread calls this function, so the wait never stops the main thread. It gives
    // false when Metal cannot make the commands.
    func draw(_ frame: BackgroundFrame, into texture: any MTLTexture) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let buffer = queue.makeCommandBuffer(),
            let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else { return false }
        var data = Self.layerData(at: frame.time, width: frame.width, height: frame.height)
        var stops = Motion.baseColours.map { SIMD4<Float>($0.rgb, 1) }
        var info = SIMD4<Float>(
            Float(frame.width / max(1, Double(texture.width))),
            Float(frame.height / max(1, Double(texture.height))), 0, 0)
        var look = SIMD4<Float>(ThemeTokens.bg.rgb, Float(Motion.noise))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&data, length: data.count * 16, index: 0)
        encoder.setFragmentBytes(&stops, length: stops.count * 16, index: 1)
        encoder.setFragmentBytes(&info, length: 16, index: 2)
        encoder.setFragmentBytes(&look, length: 16, index: 3)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        return buffer.status == .completed
    }

    // The 5 values of each layer at a time, in the paint order: the base, then the fields.
    private static func layerData(at t: Double, width: Double, height: Double) -> [SIMD4<Float>] {
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
                data.append(SIMD4(ThemeTokens.icon(icon).rgb, Float(alpha)))
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

// A surface and the texture that writes into it.
struct BackgroundTarget {
    let surface: IOSurface
    let texture: any MTLTexture
}

// The surfaces of the render thread. Only the render thread uses a value of this type. A frame
// gets a surface that the layer does not show, that waits for no show, and that no process
// uses (IOSurface.isInUse: for example, the window server still shows it). When each surface is
// busy and the set is full, the frame gets no surface, and the render thread skips the frame.
// The render thread never waits for a surface.
struct BackgroundSurfaces {
    // The result of a pick: a free surface, no free surface, or a new surface that the system
    // could not make.
    enum Pick {
        case target(BackgroundTarget)
        case busy
        case failed
    }

    // The most surfaces of one size: the surface on the screen, the surface that waits for its
    // show, and the surface of the next draw.
    static let limit = 3

    private let device: any MTLDevice
    // True when a process uses the surface. The tests give their own.
    private let inUse: @Sendable (IOSurface) -> Bool
    private var size: PixelSize?
    private var targets: [BackgroundTarget] = []

    init(device: any MTLDevice, inUse: @escaping @Sendable (IOSurface) -> Bool) {
        self.device = device
        self.inUse = inUse
    }

    // The number of surfaces of the current size.
    var count: Int { targets.count }

    // A free surface with this size. `busy` has the surfaces that the layer shows or that wait
    // for their show. A change of the size removes the surfaces of the old size.
    mutating func pick(_ pixels: PixelSize, busy: [IOSurface]) -> Pick {
        if size != pixels {
            size = pixels
            targets = []
        }
        let free = targets.first { target in
            !busy.contains { $0 === target.surface } && !inUse(target.surface)
        }
        if let free { return .target(free) }
        guard targets.count < Self.limit else { return .busy }
        guard let made = make(pixels) else { return .failed }
        targets.append(made)
        return .target(made)
    }

    private func make(_ pixels: PixelSize) -> BackgroundTarget? {
        let properties: [IOSurfacePropertyKey: any Sendable] = [
            .width: pixels.width, .height: pixels.height, .bytesPerElement: 4,
            .pixelFormat: BackgroundRenderer.surfaceFormat,
        ]
        guard let surface = IOSurface(properties: properties) else { return nil }
        // Core Animation uses this colour space to match the colours to the display.
        if let space = CGColorSpace(name: CGColorSpace.sRGB), let list = space.copyPropertyList() {
            IOSurfaceSetValue(surface as IOSurfaceRef, kIOSurfaceColorSpace, list)
        }
        let description = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: BackgroundRenderer.pixelFormat, width: pixels.width,
            height: pixels.height, mipmapped: false)
        description.usage = .renderTarget
        description.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard
            let texture = device.makeTexture(
                descriptor: description, iosurface: surface as IOSurfaceRef, plane: 0)
        else { return nil }
        return BackgroundTarget(surface: surface, texture: texture)
    }
}
