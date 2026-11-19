// The AppKit and Core Graphics colours of the tokens of the look (ThemeTokens). The values are in
// the model of the look, so this file holds only the conversion. The SwiftUI colour is in
// Controls.swift.
import AppKit

@MainActor
extension TokenColour {
    // The colour in the sRGB colour space.
    package var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    package var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    // The red, green and blue for a shader, with no alpha.
    var rgb: SIMD3<Float> { SIMD3(Float(r), Float(g), Float(b)) }
}

@MainActor
package enum Theme {
    // The colour of an icon colour of the app icon, 1 to 6.
    static func icon(_ number: Int) -> TokenColour {
        ThemeTokens.icons[min(max(number, 1), ThemeTokens.icons.count) - 1]
    }
}
