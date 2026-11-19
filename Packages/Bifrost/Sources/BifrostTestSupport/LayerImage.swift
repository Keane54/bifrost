// The image of a layer tree as Core Animation draws it on the screen: with the gradients, the
// shadows and the filters, which cacheDisplay does not draw. A CARenderer draws the tree into a
// Metal texture at the scale of the snapshots (Snapshot.scale). The image has the top row first.
// The tests never order a window front, and the render needs no window. The view of the layer
// is in a SnapshotWindow, so its text and icons draw at the scale of the image.
import AppKit
import Metal
import QuartzCore
import Testing

@MainActor
package enum LayerImage {
    // The image of the frame of the layer and the margins around it, in points. A margin shows
    // what the layer draws out of its bounds, for example a glow above it. With no background the
    // image keeps the alpha of each pixel. The render puts the layer in a layer of its own for
    // the time of the call, then puts it back in its superlayer at the same place. AppKit makes
    // the layers of the subviews of a view only in a window, so the view of a layer must be in a
    // window (never ordered front). When the render cannot start, the call records an issue and
    // gives nil.
    package static func image(
        of layer: CALayer, margins: NSEdgeInsets = NSEdgeInsets(), background: NSColor? = nil,
        _ sourceLocation: SourceLocation = #_sourceLocation
    ) -> CGImage? {
        // The area in the coordinates of Core Animation, with y up.
        let frame = layer.frame
        let area = CGRect(
            x: frame.minX - margins.left, y: frame.minY - margins.bottom,
            width: frame.width + margins.left + margins.right,
            height: frame.height + margins.top + margins.bottom)
        let scale = CGFloat(Snapshot.scale)
        let width = max(1, Int((area.width * scale).rounded()))
        let height = max(1, Int((area.height * scale).rounded()))
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue()
        else {
            Issue.record("No Metal device for the render.", sourceLocation: sourceLocation)
            return nil
        }
        let description = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        description.usage = [.shaderRead, .renderTarget]
        description.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: description) else {
            Issue.record("Cannot make the texture.", sourceLocation: sourceLocation)
            return nil
        }
        // The root has the pixels of the texture. The stage scales the points to pixels and
        // moves the area to the origin.
        let root = CALayer()
        root.frame = CGRect(x: 0, y: 0, width: width, height: height)
        if let background { root.backgroundColor = background.usingColorSpace(.sRGB)?.cgColor }
        let stage = CALayer()
        stage.anchorPoint = .zero
        stage.bounds = area
        stage.position = .zero
        stage.transform = CATransform3DMakeScale(scale, scale, 1)
        root.addSublayer(stage)
        let superlayer = layer.superlayer
        let index = superlayer?.sublayers?.firstIndex(of: layer).map { UInt32($0) }
        stage.addSublayer(layer)
        defer {
            layer.removeFromSuperlayer()
            if let superlayer, let index {
                superlayer.insertSublayer(layer, at: index)
                CATransaction.flush()
            }
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let renderer = CARenderer(
            mtlTexture: texture,
            options: [kCARendererColorSpace: space, kCARendererMetalCommandQueue: queue])
        renderer.layer = root
        renderer.bounds = root.bounds
        // The renderer draws the committed state of the tree.
        CATransaction.flush()
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        // The renderer sends its work to the queue. An empty buffer after it ends after that work.
        guard let buffer = queue.makeCommandBuffer() else {
            Issue.record("Cannot wait for the render.", sourceLocation: sourceLocation)
            return nil
        }
        buffer.commit()
        buffer.waitUntilCompleted()
        return image(of: texture, space: space, sourceLocation)
    }

    // The image of the BGRA pixels of the texture. The texture has the bottom row first.
    private static func image(
        of texture: any MTLTexture, space: CGColorSpace, _ sourceLocation: SourceLocation
    ) -> CGImage? {
        let width = texture.width
        let height = texture.height
        let row = width * 4
        var bytes = [UInt8](repeating: 0, count: row * height)
        texture.getBytes(
            &bytes, bytesPerRow: row, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        var flipped = [UInt8](repeating: 0, count: bytes.count)
        for y in 0..<height {
            let from = (height - 1 - y) * row
            flipped.replaceSubrange(y * row..<(y + 1) * row, with: bytes[from..<(from + row)])
        }
        let info =
            CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let provider = CGDataProvider(data: Data(flipped) as CFData),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: row, space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else {
            Issue.record("Cannot make the image of the render.", sourceLocation: sourceLocation)
            return nil
        }
        return image
    }
}
