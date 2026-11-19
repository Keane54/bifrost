import AppKit
import BifrostTestSupport
import Testing

@testable import BifrostLook

// The icons of the side bar, the frames, the layout menu, the Overview rows, Show Info, the
// Bifrost menu, the Selected Item panel and the Reviews panel: the lucide icon of each panel kind,
// the ellipsis of the Panel menu, the layout grid, the mic, the two glyphs of a row icon, the copy
// and close buttons of Show Info, the check mark and the submenu arrow of a menu, the lock glyph of
// a locked frame, the action buttons and the error icon of the Selected Item panel, and the
// loader of an approval of a Reviews row.

// True when the image has a pixel that is not transparent.
@MainActor
private func hasInk(_ image: NSImage) -> Bool {
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: rep)
    else { return false }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(in: NSRect(x: 0, y: 0, width: 48, height: 48))
    NSGraphicsContext.restoreGraphicsState()
    for y in 0..<48 {
        for x in 0..<48 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
            return true
        }
    }
    return false
}

@MainActor
@Suite("icons", .tags(.window))
struct IconsTests {
    init() { UITestApp.prepare() }

    @Test func eachIconLoadsAsATemplateImage() {
        #expect(IconName.allCases.count == 45)
        for name in IconName.allCases {
            let image = Icons.image(name)
            #expect(image.isTemplate, "\(name)")
            #expect(hasInk(image), "\(name)")
            let side: CGFloat = name == .lockGlyph ? 12 : 24
            #expect(image.size == NSSize(width: side, height: side), "\(name)")
        }
    }

    @Test func eachIconFileHasACaseAndEachCaseHasAFile() throws {
        let folder = try #require(Icons.folder)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".svg") }.sorted()
        #expect(files == IconName.allCases.map { "\($0.rawValue).svg" }.sorted())
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "LICENSE").path))
    }

    // Each lucide file names the pinned release, and its svg element has the attributes of
    // lucide: 24 by 24, no fill, stroke 2 in the current colour, round caps and joins. A copy of
    // lucide-static also has a class attribute.
    @Test func eachLucideIconKeepsTheAttributesOfLucide() throws {
        let folder = try #require(Icons.folder)
        let expected = [
            "xmlns": "http://www.w3.org/2000/svg", "width": "24", "height": "24",
            "viewBox": "0 0 24 24", "fill": "none", "stroke": "currentColor", "stroke-width": "2",
            "stroke-linecap": "round", "stroke-linejoin": "round",
        ]
        for name in IconName.allCases where name != .lockGlyph {
            let text = try String(
                contentsOf: folder.appending(path: "\(name.rawValue).svg"), encoding: .utf8)
            let comment = text.prefix { $0 != "\n" }
            #expect(comment.contains("lucide") && comment.contains("1.70.0"), "\(name)")
            let tag = try #require(text.firstMatch(of: /<svg\s[^>]*>/), "\(name)").output
            var attributes: [String: String] = [:]
            for match in tag.matches(of: /([a-zA-Z:-]+)="([^"]*)"/) {
                attributes[String(match.output.1)] = String(match.output.2)
            }
            attributes["class"] = nil
            #expect(attributes == expected, "\(name)")
        }
    }

    // The lock glyph of a locked frame: 12 by 12, stroke 1.5, and no round caps or joins (those
    // are the attributes of lucide, not of the glyph).
    @Test func theLockGlyphIsTwelvePointsWithAThinStroke() throws {
        let folder = try #require(Icons.folder)
        let text = try String(
            contentsOf: folder.appending(path: "lock-glyph.svg"), encoding: .utf8)
        #expect(text.contains("viewBox=\"0 0 12 12\""))
        #expect(text.contains("stroke-width=\"1.5\""))
        #expect(text.contains("<rect height=\"5\" rx=\"1\" width=\"8\" x=\"2\" y=\"5.5\"/>"))
        #expect(text.contains("<path d=\"M4 5.5V4a2 2 0 0 1 4 0v1.5\"/>"))
        #expect(!text.contains("stroke-linecap"))
        #expect(!text.contains("stroke-linejoin"))
    }

    // The 18 icons of PANEL_ICONS, in the order of the brief, then the three of the frames and
    // the side bar, the mic of the dictation, the glyphs of the row icon, then the Add tab button,
    // the drag handle and the arrow of the Tab picker of the Overview, the New Overview button of
    // the side bar, the copy and close buttons of Show Info, the check mark and the submenu arrow
    // of the Bifrost menu, the New session and the Resume all buttons of the side bar, then the
    // action buttons and the error icon of the Selected Item panel, then the page button of
    // Service status, the Refresh button of the Reviews panel and the loader of an approval.
    @Test func theNamesAreTheLucideFileNames() {
        #expect(
            IconName.allCases.map(\.rawValue) == [
                "activity", "crosshair", "eye", "file-pen", "gauge", "git-pull-request",
                "heart-pulse", "info", "list", "message-circle-question-mark", "message-square",
                "message-square-text", "puzzle", "scroll-text", "settings", "shield",
                "shield-check", "sliders-horizontal", "ellipsis-vertical", "layout-grid",
                "lock-glyph", "mic", "hexagon", "square-terminal", "plus", "grip-vertical",
                "chevron-down", "list-plus", "copy", "x", "check", "chevron-right",
                "square-plus", "rotate-ccw", "shrink", "arrow-right-left", "hand", "app-window",
                "slash", "power", "eye-off", "circle-alert", "external-link", "refresh-cw",
                "loader",
            ])
    }
}
