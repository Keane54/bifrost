import AppKit
import BifrostTestSupport
import CoreText
import Testing

@testable import BifrostLook

// The UI font of Bifrost is Geist Mono 400, 500 and 600 (app.css: --font-ui). The app has the OTF
// files of the Geist Mono 1.8.0 release. The fallbacks are those of the CSS font family:
// ui-monospace (SF Mono on macOS), then Menlo.

// The font of the first glyph run of a text.
@MainActor
private func runFont(_ text: String, _ font: NSFont) -> CTFont? {
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: [.font: font]))
    guard let run = (CTLineGetGlyphRuns(line) as? [CTRun])?.first else { return nil }
    let attributes = CTRunGetAttributes(run) as NSDictionary
    // CTFont and NSFont are the same type (toll-free bridged).
    return (attributes[kCTFontAttributeName] as? NSFont).map { $0 as CTFont }
}

@MainActor
private func fileName(_ font: CTFont?) -> String? {
    guard let font else { return nil }
    return (CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)?.lastPathComponent
}

@MainActor
@Suite("fonts", .tags(.window))
struct FontsTests {
    init() { UITestApp.prepare() }

    @Test func geistMonoRegistersAndLoads() {
        #expect(Fonts.register())
        // A second call is not an error.
        #expect(Fonts.register())
        let faces: [(NSFont.Weight, String)] = [
            (.regular, "GeistMono-Regular"), (.medium, "GeistMono-Medium"),
            (.semibold, "GeistMono-SemiBold"),
        ]
        for (weight, name) in faces {
            let font = Fonts.ui(12, weight: weight)
            #expect(font.fontName == name)
            // Each weight has its own file of the release.
            #expect(fileName(font as CTFont) == "\(name).otf")
            // The files of 500 and 600 name their family "Geist Mono Medium" and "Geist Mono
            // SemiBold". In CSS the @font-face rules give each face the family Geist Mono.
            #expect(font.familyName?.hasPrefix("Geist Mono") == true)
            #expect(font.pointSize == 12)
            #expect(font.isFixedPitch)
        }
    }

    // The folder has one OTF file for each weight and the licence (OFL), and no other file.
    @Test func theFontFolderHasOneFileForEachWeight() throws {
        let folder = try #require(Fonts.folder)
        let files = try FileManager.default.contentsOfDirectory(
            atPath: folder.path(percentEncoded: false))
        #expect(
            files.sorted() == [
                "GeistMono-Medium.otf", "GeistMono-Regular.otf", "GeistMono-SemiBold.otf",
                "LICENSE",
            ])
    }

    // The metrics and the widths of the release files are those of the web font: 1,000 units per
    // em, the ascender 1005, the descender -295, no line gap, and an advance of 600 for each
    // character. CoreText gives the ascender and the descender with a
    // small float error (1005.005 and 294.998 at 1,000 points).
    @Test func theMetricsAreThoseOfTheWebFont() {
        #expect(Fonts.register())
        for weight in [NSFont.Weight.regular, .medium, .semibold] {
            let font = Fonts.ui(1000, weight: weight) as CTFont
            #expect(CTFontGetUnitsPerEm(font) == 1000)
            #expect(abs(CTFontGetAscent(font) - 1005) < 0.01)
            #expect(abs(CTFontGetDescent(font) - 295) < 0.01)
            #expect(CTFontGetLeading(font) == 0)
            let text = "a M 0 \u{0142}\u{0436}\u{1EA1}\u{2500}"
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [.font: font]))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            #expect(width == Double(text.count) * 600)
        }
    }

    // The CSS rule of the font weight: a weight under 400 takes 400, and a weight over 600 takes
    // 600, because the app has only these three faces.
    @Test func eachWeightTakesTheNearestFaceAsCSSDoes() {
        #expect(Fonts.register())
        #expect(Fonts.ui(11, weight: .ultraLight).fontName == "GeistMono-Regular")
        #expect(Fonts.ui(11, weight: .light).fontName == "GeistMono-Regular")
        #expect(Fonts.ui(11, weight: .bold).fontName == "GeistMono-SemiBold")
        #expect(Fonts.ui(11, weight: .black).fontName == "GeistMono-SemiBold")
    }

    @Test("the UI font falls back to Geist Mono")
    func fallbacks() {
        #expect(Fonts.register())
        let font = Fonts.ui(13, weight: .regular)
        // The letters of each script come from the one file of the weight: Latin, Latin
        // Extended, Cyrillic, Vietnamese, the box lines, and an arrow and a key symbol that the
        // web subsets did not have.
        for text in ["a", "\u{0142}", "\u{0436}", "\u{1EA1}", "\u{2500}", "\u{2190}", "\u{23CE}"] {
            #expect(fileName(runFont(text, font)) == "GeistMono-Regular.otf", "\(text)")
        }
        // A character that Geist Mono does not have comes from SF Mono or a later fallback,
        // never from Geist Mono.
        let other = runFont("\u{2318}", font)
        #expect(other.map { CTFontCopyFamilyName($0) as String } != "Geist Mono")
        let cascade = font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor]
        let names = (cascade ?? []).compactMap { $0.object(forKey: .name) as? String }
        let monospaced = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).fontName
        #expect(names == [monospaced, "Menlo-Regular"])
    }

    // The registration is for this process only. It
    // never writes the font registration of the user. The registration scope of each face is
    // the process scope. The test only reads the attribute.
    @Test func theFontsRegisterOnlyForThisProcess() throws {
        #expect(Fonts.register())
        #expect(Fonts.scope == .process)
        for name in ["GeistMono-Regular", "GeistMono-Medium", "GeistMono-SemiBold"] {
            let font = try #require(NSFont(name: name, size: 12))
            let scope = CTFontDescriptorCopyAttribute(
                font.fontDescriptor as CTFontDescriptor, kCTFontRegistrationScopeAttribute)
            #expect((scope as? NSNumber)?.uint32Value == CTFontManagerScope.process.rawValue)
        }
    }

    // ui() makes each font one time.
    @Test func eachFontIsMadeOneTime() {
        #expect(Fonts.register())
        #expect(Fonts.ui(12, weight: .regular) === Fonts.ui(12, weight: .regular))
        // Bold takes the face of 600, so it is the same font as semibold.
        #expect(Fonts.ui(14, weight: .bold) === Fonts.ui(14, weight: .semibold))
        #expect(Fonts.ui(12, weight: .regular) !== Fonts.ui(13, weight: .regular))
    }
}
