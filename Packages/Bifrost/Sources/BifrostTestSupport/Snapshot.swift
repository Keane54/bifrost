// The snapshot tests of the panel bodies: a small image compare of our own, so the tests need no
// other package. A test renders a view at scale 2 over a background, and compares the image with
// a PNG in Fixtures/Snapshots/ of its test target (a resource, read through Bundle.module).
//
// - The inputs of the drawing are fixed, so one set of PNGs works on each Mac and on the CI
//   runner: scale 2 for the image and for each layer (drawAtScale), the sRGB colour space, the
//   dark appearance of Bifrost and no window on screen.
// - Two pixels are equal when their colours look the same: no channel differs by more than
//   channelTolerance of 255, or the CIEDE2000 difference is at most perceptualTolerance
//   (ColourDifference). Another GPU or another anti-aliasing changes the pixels a little, below
//   what the eye can see. The images match when at most limit(pixels:) pixels differ: 0.1 % of
//   the pixels, rounded down. So a changed glyph, colour or shape still fails the test.
// - With SNAPSHOT_RECORD=1, the check writes the image into the repo copy of the fixture
//   (Repo.root()) and records an issue, so a recording run never passes by mistake. Run the test
//   again with no variable: the build copies the new PNG into the bundle.
// - A missing PNG, an image of another size or more changed pixels than the limit record an
//   issue with the count of the pixels that differ. A failed compare also saves
//   <name>.actual.png, <name>.expected.png and <name>.diff.png (each changed pixel in red) to
//   .build/check/snapshots/ of the repo, so a failure on the CI runner comes back with the logs
//   of the checks.
// - cacheDisplay does not draw an NSHostingView inside the view, or the rows of a table in a tree
//   with layers. The image draws them again at their places (drawLayeredParts).
// The tests never order the window of the view front.
import AppKit
import CoreGraphics
import Foundation
import Testing

@MainActor
package struct Snapshot {
    // The pixels of one point.
    package static let scale = 2
    // The most pixels that can differ, as a part of all pixels: 0.1 %.
    package static let tolerance = 0.001
    // Two pixels with no channel that differs by more than this, of 255, are equal at once.
    package static let channelTolerance: UInt8 = 2
    // The most CIEDE2000 difference of two equal pixels: just below the difference of about 2.3
    // that the eye can see (perceptualPrecision 0.98 in swift-snapshot-testing).
    package static let perceptualTolerance = 2.0
    // The appearance of each image: Bifrost is dark.
    private static let appearance = NSAppearance(named: .darkAqua)
    // The variable that turns on the recording.
    nonisolated package static let recordVariable = "SNAPSHOT_RECORD"

    private let bundle: Bundle
    private let target: String

    // bundle is the Bundle.module of the test target, and target the name of its folder in
    // Packages/Bifrost/Tests, for the repo copy of a recording.
    package init(bundle: Bundle, target: String) {
        self.bundle = bundle
        self.target = target
    }

    // The most pixels that can differ in an image of this many pixels.
    package static func limit(pixels: Int) -> Int {
        Int((Double(pixels) * tolerance).rounded(.down))
    }

    // Compare the view with <name>.png, or record it when SNAPSHOT_RECORD is 1.
    package func check(
        _ view: NSView, named name: String, background: NSColor,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let image = Self.image(of: view, background: background, sourceLocation) else {
            return
        }
        check(image, named: name, sourceLocation: sourceLocation)
    }

    // Compare an image with <name>.png, or record it when SNAPSHOT_RECORD is 1. LayerImage gives
    // the image of a layer tree.
    package func check(
        _ image: CGImage, named name: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        if ProcessInfo.processInfo.environment[Self.recordVariable] == "1" {
            record(image, name, sourceLocation)
            return
        }
        guard
            let url = bundle.url(
                forResource: name, withExtension: "png", subdirectory: "Snapshots"),
            let stored = Self.image(at: url)
        else {
            Issue.record(
                "No snapshot \(name).png. Record it with \(Self.recordVariable)=1.",
                sourceLocation: sourceLocation)
            return
        }
        guard let mask = Self.differenceMask(image, stored) else {
            let text =
                "The image of \(name) is \(image.width) by \(image.height) pixels, and the "
                + "snapshot is \(stored.width) by \(stored.height)."
            Issue.record(Comment(rawValue: text), sourceLocation: sourceLocation)
            Self.saveFailure(name, actual: image, expected: stored, mask: nil)
            return
        }
        let differ = mask.count(where: \.self)
        let limit = Self.limit(pixels: image.width * image.height)
        if differ > limit {
            let text = "\(differ) pixels of \(name) differ from the snapshot (at most \(limit))."
            Issue.record(Comment(rawValue: text), sourceLocation: sourceLocation)
            Self.saveFailure(name, actual: image, expected: stored, mask: mask)
        }
    }

    // Save the images of a failed compare to .build/check/snapshots/ of the repo. The diff image
    // shows each changed pixel in red over the expected image at a quarter of its brightness. A
    // save that fails records nothing: the issue of the compare is there already.
    private static func saveFailure(
        _ name: String, actual: CGImage, expected: CGImage, mask: [Bool]?
    ) {
        guard
            let folder = try? Repo.root().appending(path: ".build/check/snapshots"),
            (try? FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true)) != nil
        else { return }
        var images = [("actual", actual), ("expected", expected)]
        if let mask, let diff = diffImage(expected, mask: mask) { images.append(("diff", diff)) }
        for (kind, image) in images {
            try? png(image)?.write(to: folder.appending(path: "\(name).\(kind).png"))
        }
    }

    // The expected image at a quarter of its brightness, with each pixel of the mask in red.
    private static func diffImage(_ expected: CGImage, mask: [Bool]) -> CGImage? {
        var bytes = pixels(expected)
        guard bytes.count == mask.count * 4,
            let context = context(width: expected.width, height: expected.height),
            let data = context.data
        else { return nil }
        for (pixel, changed) in mask.enumerated() {
            let start = pixel * 4
            if changed {
                (bytes[start], bytes[start + 1], bytes[start + 2]) = (255, 0, 0)
            } else {
                for channel in start..<(start + 3) { bytes[channel] /= 4 }
            }
            bytes[start + 3] = 255
        }
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            data.copyMemory(from: base, byteCount: buffer.count)
        }
        return context.makeImage()
    }

    private func record(_ image: CGImage, _ name: String, _ sourceLocation: SourceLocation) {
        do {
            let folder = try Repo.root().appending(
                path: "Packages/Bifrost/Tests/\(target)/Fixtures/Snapshots")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: "\(name).png")
            guard let data = Self.png(image) else {
                Issue.record("Cannot make the PNG of \(name).", sourceLocation: sourceLocation)
                return
            }
            try data.write(to: file)
            Issue.record(
                "Recorded \(file.path). Run the test again with no \(Self.recordVariable).",
                sourceLocation: sourceLocation)
        } catch {
            Issue.record(error, "Cannot record \(name).", sourceLocation: sourceLocation)
        }
    }

    // MARK: - The images

    // The sRGB colour space of each image, so the colours do not depend on the display.
    private static let space =
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    // A context of RGBA pixels of 8 bits in sRGB.
    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    // The image of the bounds of the view at scale 2, over the background, in the dark appearance
    // of Bifrost. The view draws itself and its subviews (the draw methods of AppKit), so the
    // image does not need a window on screen. When the bitmap cannot be made, the call records an
    // issue and gives nil.
    package static func image(
        of view: NSView, background: NSColor,
        _ sourceLocation: SourceLocation = #_sourceLocation
    ) -> CGImage? {
        guard let appearance else {
            Issue.record("No dark appearance.", sourceLocation: sourceLocation)
            return nil
        }
        view.appearance = appearance
        var image: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            image = drawn(view, background: background, sourceLocation)
        }
        return image
    }

    // The drawing of image(of:background:), in the current drawing appearance.
    private static func drawn(
        _ view: NSView, background: NSColor, _ sourceLocation: SourceLocation
    ) -> CGImage? {
        view.layoutSubtreeIfNeeded()
        drawAtScale(view)
        let size = view.bounds.size
        let width = max(1, Int((size.width * CGFloat(scale)).rounded()))
        let height = max(1, Int((size.height * CGFloat(scale)).rounded()))
        guard let rep = bitmap(size), let context = context(width: width, height: height) else {
            Issue.record(
                "Cannot make a bitmap of \(width) by \(height) pixels.",
                sourceLocation: sourceLocation)
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        drawLayeredParts(of: view, into: rep)
        let whole = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(background.usingColorSpace(.sRGB)?.cgColor ?? background.cgColor)
        context.fill(whole)
        if let drawn = rep.cgImage { context.draw(drawn, in: whole) }
        guard let image = context.makeImage() else {
            Issue.record("Cannot make the image of the view.", sourceLocation: sourceLocation)
            return nil
        }
        return image
    }

    // An RGBA bitmap in sRGB at scale 2 for a size in points, or nil.
    private static func bitmap(_ size: NSSize) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: max(1, Int((size.width * CGFloat(scale)).rounded())),
            pixelsHigh: max(1, Int((size.height * CGFloat(scale)).rounded())), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)?.retagging(with: .sRGB)
        rep?.size = size
        return rep
    }

    // cacheDisplay of a view does not draw two kinds of view inside it: an NSHostingView, and the
    // document of a clip view that has a layer. SwiftUI gives the views of its tree layers, as the
    // canvas of the app does, so in a tree with an NSHostingView the rows of a table do not draw.
    // Each such view draws when it is itself the view of cacheDisplay. So each one draws its
    // visible part again here, at its place in the view, over the first image, in the order of
    // the tree. A view inside an NSHostingView draws with it, and a tree with no NSHostingView
    // draws in the first image.
    // Limits: a later sibling that covers a part draws below it, not above it. The pass does not
    // apply the opacity, the clip or the transform of an ancestor of a part, only its place. So a
    // snapshot must not depend on these cases.
    private static func drawLayeredParts(of root: NSView, into rep: NSBitmapImageRep) {
        guard !isHostingView(root) else { return }
        var parts: [(view: NSView, rect: NSRect)] = []
        func walk(_ view: NSView) {
            for child in view.subviews where !child.isHidden {
                if isHostingView(child) {
                    parts.append((child, child.bounds))
                    continue
                }
                if let clip = child as? NSClipView, clip.layer != nil,
                    let document = clip.documentView
                {
                    parts.append((document, clip.documentVisibleRect))
                }
                walk(child)
            }
        }
        walk(root)
        guard parts.contains(where: { isHostingView($0.view) }),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        for (view, rect) in parts where !rect.isEmpty {
            guard let part = bitmap(rect.size) else { continue }
            view.cacheDisplay(in: rect, to: part)
            // The context of the bitmap has its origin at the bottom left.
            let place = root.convert(rect, from: view)
            let y = root.isFlipped ? root.bounds.height - place.maxY : place.minY
            part.draw(
                in: NSRect(x: place.minX, y: y, width: place.width, height: place.height),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false,
                hints: nil)
        }
    }

    // True for an NSHostingView of any content. The class is generic, so the check reads the
    // names of the classes of the view.
    private static func isHostingView(_ view: NSView) -> Bool {
        var current: AnyClass? = type(of: view)
        while let type = current {
            if NSStringFromClass(type).contains("NSHostingView") { return true }
            current = class_getSuperclass(type)
        }
        return false
    }

    // The image of a PNG file, or nil when the file cannot be read.
    package static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    package static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    // Draw each layer of the views at the scale of the snapshots (drawAtScale of a layer).
    package static func drawAtScale(_ view: NSView) {
        if let layer = view.layer {
            drawAtScale(layer)
        } else {
            view.subviews.forEach(drawAtScale)
        }
    }

    // Draw each layer of the tree at the scale of the snapshots. A layer draws its text and its
    // images at its contentsScale, which macOS takes from the screen: 2 on a Retina Mac, 1 on the
    // virtual screen of a CI runner. At 1, the image scales the drawing up, and each glyph is
    // soft. A layer at another scale gets the scale of the snapshots, and a layer that draws
    // itself (a view, text, a shape or a gradient) draws again. A layer with contents that its
    // code set keeps them. On a Retina Mac nothing changes.
    package static func drawAtScale(_ layer: CALayer) {
        let target = CGFloat(scale)
        if layer.contentsScale != target {
            layer.contentsScale = target
            if layer.delegate != nil || layer is CATextLayer || layer is CAShapeLayer
                || layer is CAGradientLayer
            {
                layer.setNeedsDisplay()
            }
        }
        layer.sublayers?.forEach(drawAtScale)
        layer.displayIfNeeded()
    }

    // The RGBA bytes of the image in sRGB, the top row first.
    package static func pixels(_ image: CGImage) -> [UInt8] {
        guard let context = context(width: image.width, height: image.height) else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data else { return [] }
        let count = image.width * image.height * 4
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: count))
    }

    // The number of pixels that differ, or nil when the sizes differ. A pixel differs when its
    // alpha differs by more than channelTolerance, or when its colour differs by more than
    // perceptualTolerance (CIEDE2000). The colour difference runs only for a pixel with a channel
    // over channelTolerance.
    package static func differingPixels(_ one: CGImage, _ two: CGImage) -> Int? {
        differenceMask(one, two)?.count(where: \.self)
    }

    // For each pixel, the top row first: true when it differs (differingPixels). nil when the
    // sizes differ.
    package static func differenceMask(_ one: CGImage, _ two: CGImage) -> [Bool]? {
        guard one.width == two.width, one.height == two.height else { return nil }
        let a = pixels(one)
        let b = pixels(two)
        let count = one.width * one.height
        guard a.count == count * 4, b.count == count * 4 else { return nil }
        return (0..<count).map { pixel in
            let start = pixel * 4
            if !(start..<(start + 4)).contains(where: { far(a[$0], b[$0]) }) { return false }
            return far(a[start + 3], b[start + 3]) || !looksEqual(a, b, at: start)
        }
    }

    // True when the two values of a channel differ by more than channelTolerance.
    private static func far(_ one: UInt8, _ two: UInt8) -> Bool {
        max(one, two) - min(one, two) > channelTolerance
    }

    // True when the colours of the two pixels at the start differ by at most perceptualTolerance.
    private static func looksEqual(_ a: [UInt8], _ b: [UInt8], at start: Int) -> Bool {
        let one = ColourDifference.lab(red: a[start], green: a[start + 1], blue: a[start + 2])
        let two = ColourDifference.lab(red: b[start], green: b[start + 1], blue: b[start + 2])
        return ColourDifference.deltaE00(one, two) <= perceptualTolerance
    }
}
