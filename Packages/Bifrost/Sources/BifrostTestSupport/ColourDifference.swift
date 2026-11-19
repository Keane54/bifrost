import Foundation

// The difference of two colours as the eye sees it: CIEDE2000 (ΔE00) in CIELAB, with the D65
// white point of sRGB (Sharma, Wu and Dalal, "The CIEDE2000 color-difference formula", 2005).
// A ΔE00 of about 2.3 is the smallest difference that most people can see. The snapshot check
// uses it, so the noise of another GPU or another anti-aliasing does not count as a change, but a
// changed colour still does.
package enum ColourDifference {
    // A colour in CIELAB.
    package struct Lab: Equatable, Sendable {
        package var l: Double
        package var a: Double
        package var b: Double

        package init(l: Double, a: Double, b: Double) {
            self.l = l
            self.a = a
            self.b = b
        }
    }

    // The linear value of each 8-bit sRGB value, once.
    private static let linear: [Double] = (0...255).map { value in
        let c = Double(value) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    // The CIELAB colour of an sRGB pixel of 8 bits for each channel.
    package static func lab(red: UInt8, green: UInt8, blue: UInt8) -> Lab {
        let (r, g, b) = (linear[Int(red)], linear[Int(green)], linear[Int(blue)])
        let x = (0.412_456_4 * r + 0.357_576_1 * g + 0.180_437_5 * b) / 0.950_47
        let y = 0.212_672_9 * r + 0.715_152_2 * g + 0.072_175_0 * b
        let z = (0.019_333_9 * r + 0.119_192_0 * g + 0.950_304_1 * b) / 1.088_83
        let (fx, fy, fz) = (f(x), f(y), f(z))
        return Lab(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    private static func f(_ t: Double) -> Double {
        let delta = 6.0 / 29
        return t > delta * delta * delta ? cbrt(t) : t / (3 * delta * delta) + 4.0 / 29
    }

    // ΔE00 of two CIELAB colours, with the weights kL, kC and kH of 1.
    package static func deltaE00(_ one: Lab, _ two: Lab) -> Double {
        let seventh: Double = pow(25.0, 7.0)
        let chroma1 = hypot(one.a, one.b)
        let chroma2 = hypot(two.a, two.b)
        let meanChroma: Double = pow((chroma1 + chroma2) / 2, 7.0)
        let g = 0.5 * (1 - (meanChroma / (meanChroma + seventh)).squareRoot())
        let a1 = (1 + g) * one.a
        let a2 = (1 + g) * two.a
        let c1 = hypot(a1, one.b)
        let c2 = hypot(a2, two.b)
        let h1: Double = hue(a1, one.b)
        let h2: Double = hue(a2, two.b)

        let deltaL: Double = two.l - one.l
        let deltaC: Double = c2 - c1
        var deltaHue: Double = 0
        if c1 * c2 != 0 {
            deltaHue = h2 - h1
            if deltaHue > 180 { deltaHue -= 360 } else if deltaHue < -180 { deltaHue += 360 }
        }
        let deltaH: Double = 2 * (c1 * c2).squareRoot() * sin(radians(deltaHue / 2))

        let meanL: Double = (one.l + two.l) / 2
        let meanC: Double = (c1 + c2) / 2
        var meanHue: Double = h1 + h2
        if c1 * c2 != 0 {
            if abs(h1 - h2) <= 180 {
                meanHue = (h1 + h2) / 2
            } else if h1 + h2 < 360 {
                meanHue = (h1 + h2 + 360) / 2
            } else {
                meanHue = (h1 + h2 - 360) / 2
            }
        }
        let t: Double =
            1 - 0.17 * cos(radians(meanHue - 30)) + 0.24 * cos(radians(2 * meanHue))
            + 0.32 * cos(radians(3 * meanHue + 6)) - 0.20 * cos(radians(4 * meanHue - 63))
        let deltaTheta: Double = 30 * exp(-pow((meanHue - 275) / 25, 2.0))
        let meanC7: Double = pow(meanC, 7.0)
        let rotation: Double = 2 * (meanC7 / (meanC7 + seventh)).squareRoot()
        let lightness: Double = pow(meanL - 50, 2.0)
        let sl: Double = 1 + 0.015 * lightness / (20 + lightness).squareRoot()
        let sc: Double = 1 + 0.045 * meanC
        let sh: Double = 1 + 0.015 * meanC * t
        let rt: Double = -sin(radians(2 * deltaTheta)) * rotation
        let (l, c, h) = (deltaL / sl, deltaC / sc, deltaH / sh)
        return (l * l + c * c + h * h + rt * c * h).squareRoot()
    }

    // The hue angle in degrees, from 0 up to 360. A grey has the hue 0.
    private static func hue(_ a: Double, _ b: Double) -> Double {
        if a == 0 && b == 0 { return 0 }
        let degrees = atan2(b, a) * 180 / .pi
        return degrees >= 0 ? degrees : degrees + 360
    }

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
}
