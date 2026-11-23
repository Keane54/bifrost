// The AppKit and Core Graphics colours of the tokens of the look (ThemeTokens). The values are in
// the model of the look, so this file holds only the conversion. The SwiftUI colour is in
// Controls.swift.
import AppKit

@MainActor
extension TokenColour {
    // The colour in the sRGB colour space.
    package var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    package var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    // The red, green and blue for a shader, with no alpha. The render thread of the background
    // uses it, so it has no isolation.
    nonisolated var rgb: SIMD3<Float> { SIMD3(Float(r), Float(g), Float(b)) }
}
