import BifrostLook
import BifrostTestSupport
import Foundation
import Synchronization
import Testing

// The tests of the values and the rules of the animated background. The values of Motion are
// the values that the user approved.

// The layers in the paint order: the base under the fields.
private let layers = [Motion.base] + Motion.fields

private func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

private func close(_ a: Double, _ b: Double, _ places: Double = 6) -> Bool {
    (a - b).magnitude < pow(10, -places) / 2
}

@Suite("the background layer", .testTimeLimit)
struct BackgroundLayerTests {
    @Test("the window background colour stays so the first paint has no flash")
    func windowBackground() {
        #expect(ThemeTokens.bg == TokenColour.rgb(0x0a, 0x0a, 0x0a))
    }

    @Test
    func fiveOrSixFields() {
        #expect(Motion.fields.count >= 5)
        #expect(Motion.fields.count <= 6)
    }

    @Test("each field has its own icon colour at a part of the token strength")
    func ownColour() {
        let icons = Motion.fields.compactMap(\.icon)
        #expect(icons.count == Motion.fields.count)
        #expect(Set(icons).count == Motion.fields.count)
        #expect(icons.allSatisfy { (1...6).contains($0) })
        #expect(Motion.glow > 0)
        #expect(Motion.glow <= 0.3)
        #expect(Motion.fields.allSatisfy { $0.weight > 0 && $0.weight <= 1 })
    }

    // User decision, 2026-11-06: no gaps between the fields. So each field is larger than the
    // window.
    @Test
    func largerThanTheWindow() {
        for field in Motion.fields {
            for size in [field.w, field.h] {
                #expect(size >= 1.2)
                #expect(size <= 1.6)
            }
        }
        let fade = Motion.fade
        #expect(fade.count >= 6)
        for index in 1..<fade.count {
            #expect(fade[index].at > fade[index - 1].at)
            #expect(fade[index].part < fade[index - 1].part)
        }
        #expect(fade[fade.count - 2].part <= 0.05)
    }

    @Test("the base layer is a large linear gradient of the icon colours under the fields")
    func baseLayer() {
        let base = Motion.base
        #expect(base.icon == nil)
        #expect(base.w >= 1.8)
        #expect(base.h >= 1.8)
        #expect(base.left == -(base.w - 1) / 2)
        #expect(base.top == -(base.h - 1) / 2)
        #expect(Motion.baseIcons.count >= 4)
        #expect(Motion.baseAlpha > 0)
        #expect(Motion.baseAlpha <= 0.15)
    }

    @Test("one fixed noise layer lies on top at a few percent")
    func noise() {
        #expect(Motion.noise > 0)
        #expect(Motion.noise <= 0.05)
    }
}

@Suite("the motion of the background", .testTimeLimit)
struct BackgroundMotionValueTests {
    // User decision, 2026-11-06: the motion felt a little slow.
    @Test("each field has its own cycle of 17 to 37 s with no common factor below 5")
    func ownCycles() {
        let cycles = Motion.fields.map { Int($0.seconds) }
        #expect(Set(cycles).count == cycles.count)
        #expect(cycles.allSatisfy { $0 >= 17 && $0 <= 37 })
        #expect(Motion.fields.allSatisfy { $0.seconds == $0.seconds.rounded() })
        let all = cycles + [Int(Motion.base.seconds)]
        var bad: [String] = []
        for a in all {
            for b in all where a < b && [2, 3, 4].contains(where: { gcd(a, b) % $0 == 0 }) {
                bad.append("\(a) and \(b)")
            }
        }
        #expect(bad == [])
    }

    @Test
    func baseIsSlower() {
        #expect(Motion.base.seconds > Motion.fields.map(\.seconds).max() ?? .infinity)
        #expect(Motion.base.seconds <= 60)
    }

    // The CSS rule: "<name> <cycle>s ease-in-out infinite alternate".
    @Test
    func forwardsAndBack() {
        for layer in layers {
            for part in [0.1, 0.3, 0.5, 0.77] {
                let time = layer.seconds * part
                let now = Motion.state(layer, at: time)
                // The second cycle runs back: it mirrors the first. Without end: 50 cycle pairs
                // later, the pose is the same.
                for other in [layer.seconds * 2 - time, time + layer.seconds * 2 * 50] {
                    let pose = Motion.state(layer, at: other)
                    #expect(close(pose.at, now.at))
                    #expect(close(pose.tx, now.tx))
                    #expect(close(pose.ty, now.ty))
                    #expect(close(pose.rot, now.rot))
                    #expect(close(pose.scale, now.scale))
                    #expect(close(pose.opacity, now.opacity))
                }
            }
        }
        // ease-in-out is cubic-bezier(0.42, 0, 0.58, 1): slow at both ends, the same shape at
        // each end.
        #expect(Motion.ease(0) == 0)
        #expect(close(Motion.ease(1), 1))
        #expect(close(Motion.ease(0.5), 0.5))
        for x in stride(from: 0.05, through: 0.45, by: 0.05) {
            #expect(close(Motion.ease(x) + Motion.ease(1 - x), 1))
            #expect(Motion.ease(x) < x)
        }
        // Two values of the curve, from the parametric form of the curve at t = 0.25 and 0.75.
        func curve(_ t: Double) -> (x: Double, y: Double) {
            (
                3 * (1 - t) * (1 - t) * t * 0.42 + 3 * (1 - t) * t * t * 0.58 + t * t * t,
                3 * (1 - t) * t * t + t * t * t
            )
        }
        for t in [0.25, 0.75] { #expect(close(Motion.ease(curve(t).x), curve(t).y)) }
    }

    @Test
    func driftScaleTurn() {
        for layer in layers {
            #expect(layer.steps.contains { $0.tx != 0 || $0.ty != 0 })
            #expect(layer.steps.contains { $0.rot != 0 })
            if layer != Motion.base { #expect(layer.steps.contains { $0.scale != 1 }) }
        }
    }

    // User decision: "not with the whole bubbles going up and down".
    @Test
    func noRiseOrSink() {
        for layer in layers {
            #expect(layer.steps.allSatisfy { $0.ty.magnitude <= 10 })
        }
    }

    @Test("each cycle starts at the still position and no layer fades out")
    func startsStill() {
        for layer in layers {
            #expect(layer.steps.first == Motion.still)
            #expect(Motion.still == MotionPose(at: 0, tx: 0, ty: 0, rot: 0, scale: 1, opacity: 1))
            #expect(layer.steps.allSatisfy { $0.opacity >= 0.5 && $0.opacity <= 1 })
            #expect(Motion.state(layer, at: 0) == Motion.still)
        }
    }

    @Test
    func pausesInPlace() {
        var clock = MotionClock()
        clock.start(at: 100)
        #expect(clock.time(at: 107.5) == 7.5)
        clock.stop(at: 107.5)
        #expect(clock.time(at: 500) == 7.5)
        clock.start(at: 500)
        #expect(clock.time(at: 500) == 7.5)
        #expect(clock.time(at: 501) == 8.5)
        clock.reset()
        #expect(clock.time(at: 900) == 0)
        #expect(!clock.running)
    }

    @Test
    func stepsFromOneClock() {
        #expect(Motion.step(0) == 0)
        #expect(Motion.step(0.0333) == 0)
        #expect(Motion.step(1.0 / 30 + 1e-9) == 1.0 / 30)
        #expect(Motion.step(10.05) == 301.0 / 30)
        var clock = MotionClock()
        #expect(clock.time(at: 50) == 0)
        clock.start(at: 50)
        clock.start(at: 60)
        #expect(clock.time(at: 70) == 20)
    }
}

// User decision, 2026-11-10: the motion moves 30 times each second, not at the display rate.
@Suite("the motion steps", .testTimeLimit)
struct MotionStepTests {
    @Test
    func thirtyTimesASecond() {
        #expect(Motion.rate == 30)
        #expect(close(Motion.stepSeconds * 1000, 1000.0 / 30))
    }

    @Test("the motion clock is the start time plus the run time")
    func clockTime() {
        #expect(Motion.time(from: 0, startedAt: 1000, now: 1000) == 0)
        #expect(Motion.time(from: 0, startedAt: 1000, now: 1500) == 500)
        // A run that starts after a pause continues from the paused time.
        #expect(Motion.time(from: 12_345, startedAt: 5000, now: 5100) == 12_445)
    }

    @Test("the motion clock never moves back")
    func neverBack() {
        #expect(Motion.time(from: 800, startedAt: 1000, now: 900) == 800)
    }
}

// User decision, 2026-11-10: the background is drawn at a part of the device pixels and scaled
// up. The stretch stays small, so the grain of the dither stays fine.
@Suite("the canvas size", .testTimeLimit)
struct CanvasSizeTests {
    @Test("each canvas draws at a part of its device pixels, from 1/4 to 1")
    func part() {
        #expect(Motion.canvasScale >= 1.0 / 4)
        #expect(Motion.canvasScale <= 1)
    }

    @Test("the device size is the part times the box, rounded up")
    func roundedUp() {
        #expect(
            Motion.canvasSize(width: 3840, height: 2160, scale: 1.0 / 2)
                == PixelSize(width: 1920, height: 1080))
        #expect(
            Motion.canvasSize(width: 999, height: 1001, scale: 1.0 / 2)
                == PixelSize(width: 500, height: 501))
        #expect(
            Motion.canvasSize(width: 100, height: 100, scale: 1.0 / 3)
                == PixelSize(width: 34, height: 34))
    }

    @Test("the default part applies when no part is given")
    func defaultPart() {
        #expect(
            Motion.canvasSize(width: 2400, height: 1200)
                == PixelSize(
                    width: Int((2400 * Motion.canvasScale).rounded(.up)),
                    height: Int((1200 * Motion.canvasScale).rounded(.up))))
    }

    @Test("each side stays from 1 pixel to the largest side")
    func limits() {
        #expect(
            Motion.canvasSize(width: 0, height: 0, scale: 0.5) == PixelSize(width: 1, height: 1))
        #expect(
            Motion.canvasSize(width: 50_000, height: 40_000, scale: 0.5)
                == PixelSize(width: Motion.maxCanvasSide, height: Motion.maxCanvasSide))
        #expect(Motion.maxCanvasSide >= 4096)
        #expect(Motion.maxCanvasSide <= 16_384)
    }

    @Test
    func notANumber() {
        #expect(
            Motion.canvasSize(width: .infinity, height: .nan, scale: 0.5)
                == PixelSize(width: 1, height: 1))
    }
}

@Suite("the paint of the layers", .testTimeLimit)
struct LayerPaintTests {
    @Test("each field fades from full glow at the centre to zero at the edge")
    func fade() {
        let fade = Motion.fade
        #expect(fade.first.map { [$0.at, $0.part] } == [0, 1])
        #expect(fade.last.map { [$0.at, $0.part] } == [1, 0])
        #expect(fade.count >= 6)
        for index in 1..<fade.count {
            #expect(fade[index].at > fade[index - 1].at)
            #expect(fade[index].part < fade[index - 1].part)
        }
        #expect(fade[fade.count - 2].part <= 0.05)
    }

    // Yellow and orange come only from the fields, because a dark yellow or orange looks brown.
    // The colours of the stops are the icon colours of the stops, in the same order.
    @Test("the base uses icon colours with no yellow or orange")
    func baseColours() {
        #expect(Motion.baseIcons.count >= 4)
        #expect(Motion.baseIcons.allSatisfy { (1...6).contains($0) })
        #expect(!Motion.baseIcons.contains(2))
        #expect(!Motion.baseIcons.contains(3))
        #expect(Motion.baseAngle == 120)
        #expect(Motion.baseColours == Motion.baseIcons.map { ThemeTokens.icons[$0 - 1] })
    }

    @Test("the gradient line of an angle runs through the centre of the box")
    func gradientLine() {
        // Round to 6 places. The + 0 changes -0 to 0.
        func round(_ line: (Double, Double, Double, Double)) -> [Double] {
            [line.0, line.1, line.2, line.3].map { ($0 * 1e6).rounded() / 1e6 + 0 }
        }
        // 90 degrees goes from the left edge to the right edge.
        #expect(round(Motion.gradientLine(90, 200, 100)) == [0, 50, 200, 50])
        // 180 degrees goes from the top edge to the bottom edge.
        #expect(round(Motion.gradientLine(180, 200, 100)) == [100, 0, 100, 100])
        // With an angle, the line is long enough that the corners get the first and the last
        // stop.
        let (x0, y0, x1, y1) = Motion.gradientLine(120, 400, 300)
        let turn = 120 * Double.pi / 180
        let length = 400 * abs(sin(turn)) + 300 * abs(cos(turn))
        #expect(close(hypot(x1 - x0, y1 - y0), length))
        #expect(close((x0 + x1) / 2, 200))
        #expect(close((y0 + y1) / 2, 150))
        // 120 degrees points to the right and down.
        #expect(x1 > x0)
        #expect(y1 > y0)
    }
}

@Suite("the dither", .testTimeLimit)
struct DitherTests {
    @Test("a field fades with its distance from the centre")
    func fieldFade() {
        #expect(Motion.fieldFade(0) == 1)
        #expect(close(Motion.fieldFade(0.2), 0.7, 9))
        #expect(close(Motion.fieldFade(0.1), 0.85, 9))
        #expect(close(Motion.fieldFade(0.9), 0.015, 9))
        #expect(Motion.fieldFade(1) == 0)
        #expect(Motion.fieldFade(1.5) == 0)
    }
}

// MARK: - The cover and the contrast of the background

// One layer for the search of the extremes: the box in parts of the window, and the paint at a
// point. The base is a linear gradient of the stops. A field is an ellipse of one colour.
private struct SearchLayer {
    var layer: MotionLayer
    // The colour of a field, or nil for the base.
    var colour: RGB?
    var weight: Double
}

// The pose of a layer at one step of its motion: the place is a part of the layer size. The
// cosine and the sine of the turn are made one time for each pose, so the search is fast.
private struct Pose {
    var tx, ty, cos, sin, scale, opacity: Double
}

private func fadeAt(_ r: Double) -> Double {
    let fade = Motion.fade
    for index in 1..<fade.count where r <= fade[index].at {
        let (r0, a0) = fade[index - 1]
        let (r1, a1) = fade[index]
        return a0 + (a1 - a0) * (r - r0) / (r1 - r0)
    }
    return 0
}

private let baseStops = Motion.baseIcons.map { RGB(ThemeTokens.icons[$0 - 1]) }
private let baseTurn = Motion.baseAngle * .pi / 180
private let baseSin = sin(baseTurn)
private let baseCos = cos(baseTurn)

private func searchLayers() -> [SearchLayer] {
    [SearchLayer(layer: Motion.base, colour: nil, weight: 1)]
        + Motion.fields.map {
            SearchLayer(
                layer: $0, colour: RGB(ThemeTokens.icons[($0.icon ?? 1) - 1]), weight: $0.weight)
        }
}

// The colour and the alpha at a point of a layer, before the opacity of its pose. The point is
// in pixels from the centre of the layer, before the transform.
private func paint(
    _ search: SearchLayer, _ x: Double, _ y: Double, _ w: Double, _ h: Double
) -> (colour: RGB, alpha: Double) {
    if let colour = search.colour {
        return (colour, Motion.glow * search.weight * fadeAt(hypot(x / (w / 2), y / (h / 2))))
    }
    let length = abs(w * baseSin) + abs(h * baseCos)
    let t = min(1, max(0, 0.5 + (x * baseSin - y * baseCos) / length))
    let at = t * Double(baseStops.count - 1)
    let index = min(baseStops.count - 2, Int(at.rounded(.down)))
    let part = at - Double(index)
    let a = baseStops[index]
    let b = baseStops[index + 1]
    return (
        RGB(a.r + (b.r - a.r) * part, a.g + (b.g - a.g) * part, a.b + (b.b - a.b) * part),
        Motion.baseAlpha
    )
}

// The poses along the path of a layer: each step, and 12 poses between two steps. Each value
// of the transform moves in a straight line from one step to the next. The easing changes only
// the speed, not the path.
private func path(_ layer: MotionLayer) -> [Pose] {
    let keys = layer.steps.map {
        (
            tx: $0.tx / 100, ty: $0.ty / 100, turn: $0.rot * .pi / 180, scale: $0.scale,
            opacity: $0.opacity
        )
    }
    func pose(_ tx: Double, _ ty: Double, _ turn: Double, _ scale: Double, _ opacity: Double)
        -> Pose
    {
        Pose(tx: tx, ty: ty, cos: cos(turn), sin: sin(turn), scale: scale, opacity: opacity)
    }
    var poses = [pose(keys[0].tx, keys[0].ty, keys[0].turn, keys[0].scale, keys[0].opacity)]
    for index in 1..<keys.count {
        let a = keys[index - 1]
        let b = keys[index]
        for k in 1...12 {
            let part = Double(k) / 12
            func between(_ x: Double, _ y: Double) -> Double { x + (y - x) * part }
            poses.append(
                pose(
                    between(a.tx, b.tx), between(a.ty, b.ty), between(a.turn, b.turn),
                    between(a.scale, b.scale), between(a.opacity, b.opacity)))
        }
    }
    return poses
}

// The colour and alpha of a layer at a point of a window of w by h pixels, at one pose.
private func layerAt(
    _ search: SearchLayer, _ at: Pose, _ x: Double, _ y: Double, _ w: Double, _ h: Double
) -> (colour: RGB, alpha: Double) {
    let layer = search.layer
    let lw = layer.w * w
    let lh = layer.h * h
    let dx = x - (layer.left * w + lw / 2 + at.tx * lw)
    let dy = y - (layer.top * h + lh / 2 + at.ty * lh)
    let lx = (dx * at.cos + dy * at.sin) / at.scale
    let ly = (-dx * at.sin + dy * at.cos) / at.scale
    let painted = paint(search, lx, ly, lw, lh)
    return (painted.colour, painted.alpha * at.opacity)
}

// The noise adds its mean, a mid grey, at its opacity.
private let noiseMean = RGB(128, 128, 128)

// The window sizes of the check: the default, the smallest, a square and a wide screen.
private let windows: [(Double, Double)] = [(1440, 900), (800, 500), (1000, 1000), (3440, 1440)]

// The brightest and the darkest point of the background.
// At each point of a grid, each layer in turn takes the pose that makes the mix the brightest
// (or the darkest). The layers paint over the background colour in the paint order, and the
// noise comes last. The luminance of the best mix is kept, so the search does not make it
// again.
private func findExtremes() -> (brightest: RGB, darkest: RGB) {
    let all = searchLayers()
    let paths = all.map { path($0.layer) }
    let bg = RGB(ThemeTokens.bg)
    var brightest = bg
    var darkest = RGB(255, 255, 255)
    for (w, h) in windows {
        for i in 0...32 {
            for j in 0...20 {
                let x = Double(i) / 32 * w
                let y = Double(j) / 20 * h
                for pick in [1.0, -1.0] {
                    var colour = bg
                    for (index, layer) in all.enumerated() {
                        var best = colour
                        var bestLuminance = -Double.infinity
                        var first = true
                        for at in paths[index] {
                            let painted = layerAt(layer, at, x, y, w, h)
                            let next = paintOver(painted.colour, painted.alpha, colour)
                            let nextLuminance = luminance(next)
                            if first || pick * (nextLuminance - bestLuminance) > 0 {
                                best = next
                                bestLuminance = nextLuminance
                                first = false
                            }
                        }
                        colour = best
                    }
                    colour = paintOver(noiseMean, Motion.noise, colour)
                    if pick == 1 && luminance(colour) > luminance(brightest) { brightest = colour }
                    if pick == -1 && luminance(colour) < luminance(darkest) { darkest = colour }
                }
            }
        }
    }
    return (brightest.rounded, darkest.rounded)
}

// The search runs one time, on a thread of its own. The first test that needs the result starts
// the thread. Each test waits as a continuation, not on a thread. So the search holds no thread
// of the shared pool of Swift concurrency and none of Dispatch, and the tests that measure time
// get their threads.
private final class SearchCache: Sendable {
    typealias Extremes = (brightest: RGB, darkest: RGB)

    private struct State {
        var result: Extremes?
        var started = false
        var waiters: [CheckedContinuation<Extremes, Never>] = []
    }

    private let state = Mutex(State())

    func value() async -> Extremes {
        await withCheckedContinuation { (waiter: CheckedContinuation<Extremes, Never>) in
            let (ready, start) = state.withLock { s -> (Extremes?, Bool) in
                if let result = s.result { return (result, false) }
                s.waiters.append(waiter)
                if s.started { return (nil, false) }
                s.started = true
                return (nil, true)
            }
            if let ready { waiter.resume(returning: ready) }
            if start {
                Thread.detachNewThread { [self] in
                    let result = findExtremes()
                    let waiters = state.withLock { s in
                        s.result = result
                        defer { s.waiters = [] }
                        return s.waiters
                    }
                    for waiter in waiters { waiter.resume(returning: result) }
                }
            }
        }
    }
}

private let searchCache = SearchCache()

private func extremes() async -> (brightest: RGB, darkest: RGB) {
    await searchCache.value()
}

// User decision, 2026-11-06: no gaps. The darkest point has a luminance of 0.008 or more (the
// background colour has 0.003).
private let darkestLuminance = 0.008

// The brief of 2026-11-06: at the brightest and the darkest point of the background, under a
// panel at the default Panel transparency, the text stays readable and the boxes stay clearly
// visible. The watch and box colours are in ReadableColours (LookSupport.swift).
@Suite("the cover and the contrast of the background", .testTimeLimit)
struct BackgroundContrastTests {
    private let transparency = ThemeTokens.defaultTransparency

    // The panel and the focused panel over a background colour.
    private func panels(_ back: RGB) -> [(String, RGB)] {
        let panel = ThemeTokens.panel(transparency: transparency)
        let focus = ThemeTokens.panelFocus(transparency: transparency)
        return [
            ("panel", mix(RGB.grey(RGB(panel).r), panel.a, back)),
            ("focused panel", mix(RGB.grey(RGB(focus).r), focus.a, back)),
        ]
    }

    // Each row on a panel: plain, selected, hover, and each watch colour with its own three.
    private func rows(_ panel: RGB) -> [(String, RGB)] {
        var plain: [(String, RGB)] = [("plain", panel)]
        for (name, colour) in ReadableColours.watch {
            plain.append(("watch \(name)", mix(colour, ReadableColours.watchRowOpacity, panel)))
        }
        return plain.flatMap { name, surface in
            [
                (name, surface), ("\(name) selected", mix(RGB(ThemeTokens.accent), 0.15, surface)),
                ("\(name) hover", mix(RGB(255, 255, 255), 0.05, surface)),
            ]
        }
    }

    private func backs() async -> [(String, RGB)] {
        let found = await extremes()
        return [("brightest", found.brightest), ("darkest", found.darkest)]
    }

    @Test
    func noPointNearBlack() async {
        let darkest = await extremes().darkest
        #expect(luminance(darkest) >= darkestLuminance)
        // The darkest point is a colour of the mix, not a grey.
        #expect((darkest.channels.max() ?? 0) - (darkest.channels.min() ?? 0) >= 4)
    }

    // A gentle glow, not a bright rainbow: the brightest point is only a little lighter than the
    // background colour, at less than 1.6:1.
    @Test("the background stays dark with at most a faint glow")
    func staysDark() async {
        let brightest = await extremes().brightest
        let bg = RGB(ThemeTokens.bg)
        #expect(contrast(brightest, bg) < 1.6)
        // Guard: the search finds at least the centre of each field at its full glow.
        for field in Motion.fields {
            let colour = RGB(ThemeTokens.icons[(field.icon ?? 1) - 1])
            let centre = mix(colour, Motion.glow * field.weight, bg)
            #expect(luminance(brightest) >= luminance(centre))
        }
    }

    @Test("panel text keeps a 4.5:1 contrast on each row")
    func panelText() async {
        var bad: [String] = []
        for (place, back) in await backs() {
            for (panel, surface) in panels(back) {
                // The dim text shows on the panel itself, for example the hints of Settings.
                let dim = contrast(RGB(ThemeTokens.textDim), surface)
                if dim < 4.5 { bad.append("text-dim on \(panel) at the \(place) point: \(dim)") }
                for (row, background) in rows(surface) {
                    for (text, token) in [
                        ("text", ThemeTokens.text), ("text-strong", ThemeTokens.textStrong),
                    ] where contrast(RGB(token), background) < 4.5 {
                        bad.append("\(text) on \(row) on \(panel) at the \(place) point")
                    }
                }
            }
        }
        #expect(bad == [])
    }

    @Test("the red box and the yellow box keep a 3:1 contrast on each row")
    func boxColours() async {
        var bad: [String] = []
        for (place, back) in await backs() {
            for (panel, surface) in panels(back) {
                for (row, background) in rows(surface) {
                    let boxes = [
                        ("box-red", ReadableColours.boxRed),
                        ("box-yellow", ReadableColours.boxYellow),
                    ]
                    for box in boxes {
                        let ratio = contrast(box.1, background)
                        if ratio < 3 {
                            bad.append("\(box.0) on \(row) on \(panel) at the \(place) point")
                        }
                    }
                }
            }
        }
        #expect(bad == [])
    }
}
