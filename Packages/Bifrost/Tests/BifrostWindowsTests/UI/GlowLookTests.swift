import AppKit
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostDictation
@testable import BifrostLayout
@testable import BifrostLook
@testable import BifrostWindows

// The glows as Core Animation draws them (LayerImage): the cyan glow of the top frame, and the
// green shadow and glow of a frame while its chat listens. Each light must fall off at the ends
// and away from the edge, with no hard side, as in the approved look. The expected values come
// from a Gaussian blur: the shadow of a strip along the edge, with the inset and the softness of
// the look. A render of the approved CSS look at scale 2 gives values within 2 of 255 of them.
@Suite("glow look", .serialized, .tags(.window))
@MainActor
struct GlowLookTests {
    private let metrics = CanvasMetrics(interfaceScale: 100)
    private let snapshots = Snapshot(bundle: .module, target: "BifrostWindowsTests")
    // The space around the frame in the images, in points: room for the light above the edge and
    // past the ends.
    private static let margins = NSEdgeInsets(top: 24, left: 16, bottom: 0, right: 16)

    init() { UITestApp.prepare() }

    // The top frame of this size, in a window that is never ordered front. AppKit makes the
    // layers of the parts of the frame only in a window. The caller closes the window.
    private func topFrame(
        width: Double = 600, height: Double = 80
    ) -> (view: FrameView, window: NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width + 100, height: height + 100),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width + 100, height: height + 100))
        host.wantsLayer = true
        window.contentView = host
        let view = FrameView(
            id: FrameID(number: 1), blur: .none, metrics: metrics, transparency: 15)
        view.frame = CGRect(x: 50, y: 20, width: width, height: height)
        host.addSubview(view)
        let layout = LayoutFrame(
            id: FrameID(number: 1), panels: [.settings], active: .settings,
            rect: LayoutRect(x: 0, y: 0, w: width, h: height), minimised: false, locked: false)
        view.update(layout, titles: [.settings: "Settings"], top: true, animated: false)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return (view, window)
    }

    // The part of a Gaussian blur of the standard deviation sigma that lies past the distance d.
    private func tail(_ d: Double, _ sigma: Double) -> Double {
        erfc(d / (sigma * 2.0.squareRoot())) / 2
    }

    // The alpha (0 to 255) of the light of a strip from x0 to x1 along the edge, with the alpha a
    // and the softness sigma, at x and at the distance d above the edge.
    private func light(
        x: Double, d: Double, from x0: Double, to x1: Double, alpha a: Double, sigma: Double
    ) -> Double {
        255 * a * tail(d, sigma) * (tail(x0 - x, sigma) - tail(x1 - x, sigma))
    }

    // The alpha of the pixel of the image at the point (x, y) in points, from its top left.
    private func alpha(_ pixels: [UInt8], _ image: CGImage, x: Double, y: Double) -> Int {
        let scale = Double(Snapshot.scale)
        let px = Int(x * scale)
        let py = Int(y * scale)
        return Int(pixels[(py * image.width + px) * 4 + 3])
    }

    // The centre of the pixel at a value in points, in points.
    private func centre(_ value: Double) -> Double {
        let scale = Double(Snapshot.scale)
        return ((value * scale).rounded(.down) + 0.5) / scale
    }

    // The light above the top edge of a frame of width w, in an image with the margins: each
    // sample against the Gaussian blur at the centre of its pixel, within 2 of 255.
    private func checkLight(
        _ image: CGImage, width w: Double, inset: Double, sigma: Double, alpha a: Double,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let pixels = Snapshot.pixels(image)
        let left = Self.margins.left
        let edge = Self.margins.top
        let xs = [-sigma * 2, -sigma, 0, inset, inset + sigma, w / 2, w - inset, w, w + sigma]
        for x in xs {
            for d in [0.25, sigma / 2 + 0.25, sigma + 0.25, sigma * 2 + 0.25] {
                let px = centre(left + x)
                let py = centre(edge - d)
                let shown = alpha(pixels, image, x: px, y: py)
                let expected = light(
                    x: px - left, d: edge - py, from: inset, to: w - inset, alpha: a,
                    sigma: sigma)
                #expect(
                    abs(Double(shown) - expected) <= 2,
                    "x \(x), d \(d): \(shown), expected \(expected)",
                    sourceLocation: sourceLocation)
            }
        }
    }

    // The glow clips the light at the edge, so no light falls on the frame.
    @Test func theLightStaysAboveTheEdge() throws {
        let glow = EdgeGlow(colour: ThemeTokens.watchGreen)
        let area = glow.layout(edgeWidth: 200, inset: 12, softness: 6)
        #expect(area == CGRect(x: -6, y: -18, width: 212, height: 18))
        // A layer of Core Animation has y up, so the edge is the bottom of the area.
        glow.layer.frame = CGRect(origin: .zero, size: area.size)
        let below = NSEdgeInsets(top: 0, left: 0, bottom: 10, right: 0)
        let image = try #require(LayerImage.image(of: glow.layer, margins: below))
        let pixels = Snapshot.pixels(image)
        let at = { (y: Double) in
            (0..<Int(area.width)).map { self.alpha(pixels, image, x: Double($0) + 0.25, y: y) }
        }
        #expect(at(area.height + 0.25).allSatisfy { $0 == 0 })
        #expect(at(area.height + 5.25).allSatisfy { $0 == 0 })
        #expect(at(area.height - 0.25).max() ?? 0 > 0)
    }

    // The image of the top frame with the margins, while its chat listens at the level, or with
    // no chat that listens for nil. The level is smoothed to its target first.
    private func image(listening level: Double?, background: NSColor? = nil) throws -> CGImage {
        let (view, window) = topFrame()
        defer {
            view.setDictation(nil)
            window.close()
        }
        if let level {
            view.setDictation(level)
            for _ in 0..<240 { view.smoothDictation(seconds: 1.0 / 60) }
            window.displayIfNeeded()
        }
        let layer = try #require(view.layer)
        return try #require(
            LayerImage.image(of: layer, margins: Self.margins, background: background))
    }

    @Test("the glow of the top frame falls off upwards and at both ends")
    func theFocusGlowIsSoft() throws {
        let image = try image(listening: nil)
        let a = ThemeTokens.accentGlow.a
        checkLight(image, width: 600, inset: 6, sigma: 6, alpha: a)
        let pixels = Snapshot.pixels(image)
        let edge = Self.margins.top
        let middle = alpha(pixels, image, x: Self.margins.left + 300.25, y: edge - 0.25)
        let end = alpha(pixels, image, x: Self.margins.left + 0.25, y: edge - 0.25)
        let past = alpha(pixels, image, x: Self.margins.left - 11.75, y: edge - 0.25)
        // The middle has half the alpha of the glow token, the left end of the frame less than a
        // fifth of it, and 12 points past the end nothing.
        #expect(abs(Double(middle) - 255 * a / 2) <= 2)
        #expect(Double(end) < Double(middle) / 5)
        #expect(past == 0)
        // The light goes 3 softness lengths up, and no further.
        #expect(alpha(pixels, image, x: Self.margins.left + 300.25, y: edge - 18.25) == 0)
    }

    @Test(
        "the green shadow of the top border falls off upwards and at both ends",
        arguments: [1.0, 0.5, 0.15])
    func theDictationShadowIsSoft(level: Double) throws {
        let image = try image(listening: level)
        let look = DictationLook.of(level: level)
        let b = look.borderShadowBlur
        checkLight(image, width: 600, inset: b, sigma: b / 2, alpha: look.borderShadowAlpha)
    }

    // The glow below the top border, from the same parts as the frame: a flipped layer with the
    // glow layer at its rect.
    private func glowImage(level: Double, width: Double) throws -> CGImage {
        let look = DictationLook.of(level: level)
        let root = CALayer()
        root.isGeometryFlipped = true
        root.frame = CGRect(x: 0, y: 0, width: width, height: 120)
        let glow = DictationGlow.makeGlowLayer()
        DictationGlow.apply(
            look, glow: glow, shadow: DictationGlow.makeShadow(), metrics: metrics)
        glow.frame = DictationGlow.glowRect(
            width: width, border: 1, look: look, metrics: metrics)
        root.addSublayer(glow)
        return try #require(LayerImage.image(of: root))
    }

    @Test("the glow below the top border is a soft central hump", arguments: [1.0, 0.5, 0.15])
    func theDictationGlowIsAHump(level: Double) throws {
        let w = 602.0
        let image = try glowImage(level: level, width: w)
        let pixels = Snapshot.pixels(image)
        let look = DictationLook.of(level: level)
        // The centre column: the peak is near the top, and the light ends before the height of the
        // glow plus three blur lengths.
        let column = (2..<120).map { alpha(pixels, image, x: w / 2, y: Double($0) + 0.25) }
        let peak = try #require(column.max())
        let peakY = 2 + (column.firstIndex(of: peak) ?? 0)
        #expect(peak > 0)
        #expect(Double(peakY) < 2 + look.glowHeight / 2)
        let end = Int(2 + look.glowHeight + 3 * look.glowBlur)
        if end < 120 { #expect(alpha(pixels, image, x: w / 2, y: Double(end) + 0.25) <= 1) }
        // Each row falls off from the middle to both ends, and is near nothing at 2 % and 98 % of
        // the width of the frame.
        for y in [2.25, 2 + look.glowHeight / 4, 2 + look.glowHeight / 2] {
            let row = stride(from: 0.0, through: w / 2, by: 6).map {
                alpha(pixels, image, x: $0 + 0.25, y: y)
            }
            #expect(zip(row, row.dropFirst()).allSatisfy { $0 <= $1 + 1 }, "row \(y)")
            for x in [w * 0.02, w * 0.98] {
                #expect(alpha(pixels, image, x: x, y: y) <= 2, "x \(x), y \(y)")
            }
            #expect(alpha(pixels, image, x: w / 2, y: y) >= Int(Double(peak) * 0.4))
        }
    }

    // The glow grows with the voice: it reaches further down, and it is wider 6 below the border
    // (the width where the light is at least half of the light at the middle).
    @Test("the glow below the top border grows higher and wider with the voice")
    func theDictationGlowGrowsWithTheVoice() throws {
        let w = 602.0
        var last: (reach: Double, width: Double)?
        for level in [0.15, 0.5, 1.0] {
            let image = try glowImage(level: level, width: w)
            let pixels = Snapshot.pixels(image)
            let y = 8.25
            let middle = alpha(pixels, image, x: w / 2, y: y)
            let width = Double(
                stride(from: 0.25, to: w, by: 1).filter {
                    alpha(pixels, image, x: $0, y: y) * 2 >= middle
                }.count)
            let reach =
                stride(from: 2.25, to: 120, by: 1).filter {
                    alpha(pixels, image, x: w / 2, y: $0) > 2
                }.last ?? 0
            if let last {
                #expect(width > last.width, "level \(level)")
                #expect(reach > last.reach, "level \(level)")
            }
            last = (reach, width)
        }
    }

    // The frame with each glow on the background of the app, compared with an image: the top
    // frame, and the frame while its chat listens at the levels 100, 50 and 15.
    @Test("each glow matches its snapshot")
    func eachGlowMatchesItsSnapshot() throws {
        let bg = ThemeTokens.bg.nsColor
        snapshots.check(try image(listening: nil, background: bg), named: "glow-focus")
        for level in [100, 50, 15] {
            let image = try image(listening: Double(level) / 100, background: bg)
            snapshots.check(image, named: "glow-dictation-\(level)")
        }
    }
}
