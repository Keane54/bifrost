// The motion and the paint values of the animated background (docs/behaviour/look.md, "The
// animated background"): the boxes, the cycles and the steps of the layers, the strengths, the
// fade, the base gradient, the motion clock and the drawable size. Each step eases on the
// ease-in-out curve, and each cycle runs forwards and then back. The values are the values that
// the user approved.
// Pure value code.
import Foundation

// The pose of a layer at one step of its cycle: the place of the step in the cycle (0 to 1),
// the translation in percent of the layer box, the turn in degrees, the scale and the opacity.
package struct MotionPose: Sendable, Equatable {
    package var at, tx, ty, rot, scale, opacity: Double

    package init(at: Double, tx: Double, ty: Double, rot: Double, scale: Double, opacity: Double) {
        self.at = at
        self.tx = tx
        self.ty = ty
        self.rot = rot
        self.scale = scale
        self.opacity = opacity
    }
}

// One layer of the background: the base or a colour field.
package struct MotionLayer: Sendable, Equatable {
    // The box in parts of the window: left, top, width and height.
    package var left, top, w, h: Double
    // The time of one cycle in seconds.
    package var seconds: Double
    package var steps: [MotionPose]
    // The number of the icon colour (1 to 6) of a field. Nil for the base.
    package var icon: Int?
    // The part of the glow strength of a field, from 0 to 1. The base has 1.
    package var weight: Double
}

// The size of a drawable in pixels.
package struct PixelSize: Sendable, Equatable {
    package var width, height: Int

    package init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

package enum Motion {
    // The motion moves 30 times each second, not at the refresh rate of the display.
    package static let rate = 30.0
    // The time between two steps of the motion, in seconds.
    package static let stepSeconds = 1 / rate
    // The strengths: glow (the alpha of an icon colour at the centre of its field), baseAlpha
    // (the alpha of the stops of the base) and noise (the opacity of the fixed fine grain on top,
    // a mid grey on average).
    package static let glow = 0.15
    package static let baseAlpha = 0.10
    package static let noise = 0.0075
    // The base is a linear gradient at this angle: 0 degrees points up, 90 to the right.
    package static let baseAngle = 120.0
    // The icon colours of the stops of the base, from the first stop to the last.
    // Yellow and orange come only from the fields, because a dark yellow or orange looks brown.
    package static let baseIcons = [4, 5, 6, 1, 6]
    // The fade of a field from its centre (0) to its edge (1): the place and the part of the
    // glow. The fade is almost zero before the edge, so the edge shows no line.
    package static let fade: [(at: Double, part: Double)] = [
        (0, 1), (0.2, 0.7), (0.4, 0.38), (0.6, 0.14), (0.8, 0.03), (1, 0),
    ]
    // The drawable has this part of the device pixels in each direction.
    package static let canvasScale = 0.5
    // The largest side of a drawable in pixels. A GPU texture has a limit on its size.
    package static let maxCanvasSide = 8192

    private static func pose(
        _ at: Double, _ tx: Double, _ ty: Double, _ rot: Double, _ scale: Double,
        _ opacity: Double
    ) -> MotionPose {
        MotionPose(at: at, tx: tx, ty: ty, rot: rot, scale: scale, opacity: opacity)
    }

    // The first step of each cycle: the still position.
    package static let still = MotionPose(at: 0, tx: 0, ty: 0, rot: 0, scale: 1, opacity: 1)

    // The six fields, in their paint order. The base paints first, under the fields.
    package static let fields: [MotionLayer] = [
        MotionLayer(
            left: -0.15, top: 0.25, w: 1.25, h: 1.2, seconds: 37,
            steps: [
                still, pose(0.35, -14, -5, 22, 1.12, 0.8), pose(0.7, 10, 4, -12, 0.92, 0.95),
                pose(1, -6, -8, 30, 1.06, 0.7),
            ], icon: 6, weight: 1),
        MotionLayer(
            left: 0.22, top: -0.55, w: 1.25, h: 1.2, seconds: 29,
            steps: [
                still, pose(0.3, -16, 5, -18, 0.9, 0.75), pose(0.65, -6, 8, 14, 1.14, 0.9),
                pose(1, -20, -3, -28, 1, 0.8),
            ], icon: 5, weight: 1),
        MotionLayer(
            left: -0.52, top: -0.05, w: 1.2, h: 1.25, seconds: 31,
            steps: [
                still, pose(0.4, 16, -6, 26, 1.1, 0.85), pose(0.75, 24, 3, -8, 0.9, 0.7),
                pose(1, 10, -8, 18, 1.16, 0.95),
            ], icon: 4, weight: 0.85),
        MotionLayer(
            left: -0.28, top: -0.55, w: 1.2, h: 1.2, seconds: 17,
            steps: [
                still, pose(0.33, -22, 7, -24, 1.18, 0.7), pose(0.66, 18, -6, 16, 0.88, 0.85),
                pose(1, -8, -9, -32, 1.08, 0.6),
            ], icon: 3, weight: 0.4),
        MotionLayer(
            left: 0.40, top: -0.08, w: 1.2, h: 1.25, seconds: 23,
            steps: [
                still, pose(0.38, -14, -7, 20, 0.9, 0.8), pose(0.72, -24, 4, -14, 1.12, 0.95),
                pose(1, -10, 8, 28, 1.04, 0.7),
            ], icon: 2, weight: 0.55),
        MotionLayer(
            left: 0.28, top: 0.45, w: 1.25, h: 1.2, seconds: 19,
            steps: [
                still, pose(0.3, -18, -4, -20, 1.1, 0.75), pose(0.68, 8, -8, 12, 0.92, 0.9),
                pose(1, -12, 5, -26, 1.14, 0.8),
            ], icon: 1, weight: 0.75),
    ]

    // The base: two times the window in each direction, centred, so its motion never shows an
    // edge.
    package static let base = MotionLayer(
        left: -0.5, top: -0.5, w: 2, h: 2, seconds: 41,
        steps: [
            still, pose(0.33, 8, 3, 10, 1.05, 1), pose(0.67, -6, -4, -8, 0.96, 1),
            pose(1, 10, -2, 14, 1.02, 1),
        ], icon: nil, weight: 1)

    // The ease-in-out curve: the cubic Bezier curve with the control points (0.42, 0) and
    // (0.58, 1). A search finds the parameter of the curve at x, then the result is the y of
    // that parameter.
    package static func ease(_ x: Double) -> Double {
        // The ends are exact. The search alone gives a value near 0 at 0.
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let x1 = 0.42
        let x2 = 0.58
        func bx(_ t: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * x1 + 3 * (1 - t) * t * t * x2 + t * t * t
        }
        func by(_ t: Double) -> Double { 3 * (1 - t) * t * t + t * t * t }
        var low = 0.0
        var high = 1.0
        var t = x
        for _ in 0..<30 {
            t = (low + high) / 2
            if bx(t) < x { low = t } else { high = t }
        }
        return by(t)
    }

    // The pose of a layer at a time in seconds. Each cycle runs forwards and then back, and the
    // curve eases each step. The `at` of the result is the place in the cycle.
    package static func state(_ layer: MotionLayer, at time: Double) -> MotionPose {
        let cycle = (time / layer.seconds).rounded(.down)
        var place = (time - cycle * layer.seconds) / layer.seconds
        if cycle.truncatingRemainder(dividingBy: 2) == 1 { place = 1 - place }
        var index = 1
        while index < layer.steps.count - 1 && place > layer.steps[index].at { index += 1 }
        let a = layer.steps[index - 1]
        let b = layer.steps[index]
        let local = b.at > a.at ? ease(min(1, max(0, (place - a.at) / (b.at - a.at)))) : 1
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * local }
        return MotionPose(
            at: place, tx: mix(a.tx, b.tx), ty: mix(a.ty, b.ty), rot: mix(a.rot, b.rot),
            scale: mix(a.scale, b.scale), opacity: mix(a.opacity, b.opacity))
    }

    // The fade of a field (0 to 1) at a distance from its centre. The distance is 0
    // at the centre and 1 at the edge of the ellipse. The fade is linear between the steps.
    package static func fieldFade(_ distance: Double) -> Double {
        if distance >= 1 { return 0 }
        if distance <= 0 { return 1 }
        for index in 1..<fade.count where distance <= fade[index].at {
            let (from, start) = fade[index - 1]
            let (to, end) = fade[index]
            return start + (end - start) * (distance - from) / (to - from)
        }
        return 0
    }

    // The two ends of the line of a linear gradient at the angle, in a box of w by h, from the
    // top-left corner. The line goes through the centre. It is long enough that the corners get
    // the first and the last stop.
    package static func gradientLine(
        _ angle: Double, _ w: Double, _ h: Double
    ) -> (x0: Double, y0: Double, x1: Double, y1: Double) {
        let turn = angle * .pi / 180
        let dx = sin(turn)
        let dy = -cos(turn)
        let half = (abs(w * dx) + abs(h * dy)) / 2
        return (w / 2 - dx * half, h / 2 - dy * half, w / 2 + dx * half, h / 2 + dy * half)
    }

    // The time of the motion clock: the time at the start of a run plus the time
    // since the start. The clock never goes back.
    package static func time(from: Double, startedAt: Double, now: Double) -> Double {
        from + max(0, now - startedAt)
    }

    // The time of the last step of the motion at a time in seconds. The motion moves only 30
    // times each second.
    package static func step(_ time: Double) -> Double {
        (time * rate).rounded(.down) / rate
    }

    // The size of the drawable of a view with this size in device pixels: the part
    // of each side, up to the next whole pixel. Each side is from 1 pixel to maxCanvasSide. A
    // side that is not a finite number gives 1 pixel.
    package static func canvasSize(
        width: Double, height: Double, scale: Double = canvasScale
    ) -> PixelSize {
        func side(_ pixels: Double) -> Int {
            let value = (pixels * scale).rounded(.up)
            if !value.isFinite { return 1 }
            return Int(min(Double(maxCanvasSide), max(1, value)))
        }
        return PixelSize(width: side(width), height: side(height))
    }
}

// The clock of the motion. It moves only while the motion runs. A stop keeps its time, so the
// layers stop where they are and continue from there. A reset gives the still position.
package struct MotionClock: Sendable, Equatable {
    // The time in seconds at the start of the run, or the time of a stopped clock.
    package private(set) var from = 0.0
    // The time of the start of the run on the time source, or nil when the clock does not run.
    package private(set) var startedAt: Double?

    package init() {}

    package var running: Bool { startedAt != nil }

    // The time of the clock at a time of the time source, in seconds.
    package func time(at now: Double) -> Double {
        guard let startedAt else { return from }
        return Motion.time(from: from, startedAt: startedAt, now: now)
    }

    // Start a run. A clock that runs keeps its run.
    package mutating func start(at now: Double) {
        if startedAt == nil { startedAt = now }
    }

    // Stop the run. The clock keeps its time.
    package mutating func stop(at now: Double) {
        from = time(at: now)
        startedAt = nil
    }

    // Stop the clock and go back to the still position (time 0).
    package mutating func reset() {
        from = 0
        startedAt = nil
    }
}
