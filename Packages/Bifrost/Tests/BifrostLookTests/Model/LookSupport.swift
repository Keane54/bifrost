import BifrostLook
import Foundation

// The colours of the chat and the rows that the readability tests use, with the values that the
// user approved: the watch colours of a row, the opacity of a watch row and the box colours.
enum ReadableColours {
    static let watch: [(name: String, colour: RGB)] = [
        ("dark-red", RGB(0x7f, 0x1d, 0x1d)), ("red", RGB(0xdc, 0x26, 0x26)),
        ("amber", RGB(0xd4, 0x73, 0x0a)), ("yellow", RGB(0xfe, 0xf0, 0x8a)),
        ("green", RGB(0x22, 0xc5, 0x5e)), ("light-blue", RGB(0x7d, 0xd3, 0xfc)),
        ("dark-blue", RGB(0x25, 0x63, 0xeb)), ("white", RGB(0xf2, 0xf2, 0xf2)),
    ]
    static let watchRowOpacity = 0.12
    static let boxRed = RGB(0xf5, 0x76, 0x6d)
    static let boxYellow = RGB(0xe2, 0xb9, 0x3b)
}

// A colour of three 8-bit channels (0 to 255), as a hex colour of the theme gives them. Each mix
// rounds to whole channels.
struct RGB: Equatable, Sendable, CustomStringConvertible {
    var r, g, b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    // The channels of a token colour, rounded as the hex value of a CSS colour.
    init(_ token: TokenColour) {
        self.init((token.r * 255).rounded(), (token.g * 255).rounded(), (token.b * 255).rounded())
    }

    static func grey(_ level: Double) -> RGB { RGB(level, level, level) }

    var channels: [Double] { [r, g, b] }

    // The colour with whole channels.
    var rounded: RGB { RGB(r.rounded(), g.rounded(), b.rounded()) }

    var description: String {
        "#" + channels.map { String(format: "%02x", Int($0.rounded())) }.joined()
    }
}

// The colour over the background at the opacity, with whole channels.
func mix(_ over: RGB, _ opacity: Double, _ under: RGB) -> RGB {
    paintOver(over, opacity, under).rounded
}

// The colour over the background at the opacity, with no rounding.
func paintOver(_ colour: RGB, _ alpha: Double, _ under: RGB) -> RGB {
    RGB(
        colour.r * alpha + under.r * (1 - alpha), colour.g * alpha + under.g * (1 - alpha),
        colour.b * alpha + under.b * (1 - alpha))
}

// The linear value of each 8-bit channel, for the WCAG relative luminance. A table gives the
// same values as the sum, and the search of the extremes is much faster with it.
private let linearChannels: [Double] = (0...255).map { channel in
    let value = Double(channel) / 255
    return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
}

private func linear(_ channel: Double) -> Double {
    linearChannels[min(255, max(0, Int(channel.rounded())))]
}

// The WCAG relative luminance of a colour, with whole channels.
func luminance(_ colour: RGB) -> Double {
    0.2126 * linear(colour.r) + 0.7152 * linear(colour.g) + 0.0722 * linear(colour.b)
}

// The WCAG contrast of two colours.
func contrast(_ a: RGB, _ b: RGB) -> Double {
    let high = max(luminance(a), luminance(b))
    let low = min(luminance(a), luminance(b))
    return (high + 0.05) / (low + 0.05)
}
