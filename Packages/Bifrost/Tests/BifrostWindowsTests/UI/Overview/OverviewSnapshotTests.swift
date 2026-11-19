import AppKit
import BifrostSessions
import BifrostTestSupport
import Testing

@testable import BifrostLook
@testable import BifrostWindows

// The snapshot of the Overview body, and the self-test of the image compare (Snapshot). The rows
// are test rows: no real session name or folder.
@Suite("Overview snapshot", .serialized, .testTimeLimit, .tags(.window))
@MainActor
struct OverviewSnapshotTests {
    private let snapshot = Snapshot(bundle: .module, target: "BifrostWindowsTests")
    private let ground = ThemeTokens.panel(transparency: 0).nsColor

    // Three rows of the All tab: a working row that is selected, a watched row with a yellow box
    // and a priority, and an external idle row in another project. The Priority column is on.
    @Test func theOverviewWithThreeRowsMatchesItsSnapshot() async throws {
        let wall = TestWallClock()
        let now = wall.milliseconds
        let working = overviewRow(
            1, name: "alpha", state: .working, cwd: "/work/demo/app", lastActivity: now - 5_000)
        var alert = overviewRow(
            2, name: "bravo", state: .needsYou, cwd: "/work/demo/app", lastActivity: now - 90_000)
        alert.alert = .yellow(since: now - 90_000)
        alert.watch = RowWatch(colour: .lightBlue, order: 0)
        alert.priority = .p2
        let external = overviewRow(
            3, name: "charlie", kind: .external, cwd: "/work/other/tool",
            lastActivity: now - 7_200_000)
        let p = try await OverviewParts(
            rows: [working, alert, external], size: NSSize(width: 700, height: 120))
        p.update(.toggleColumn(p.tab.id, .priority))
        p.selection.selectedId = working.sessionId
        // A still flash: the image shows the brackets at full opacity.
        p.model.rowFlash = false
        await p.settle()
        snapshot.check(p.body, named: "overview-three-rows", background: ground)
    }

    // The Overview Settings panel of overview:1 on the Columns part: the All tab in the picker,
    // its colour chosen, the column rows with Branch on and the kind row locked, and Reset to
    // default on.
    @Test func theOverviewSettingsPanelMatchesItsSnapshot() async throws {
        let p = try await OverviewParts(rows: [], size: NSSize(width: 360, height: 400))
        p.update(.toggleColumn(p.tab.id, .branch))
        let panels = OverviewSettingsPanels(model: p.model, look: p.look)
        let host = try #require(panels.body(for: panel("overview-settings:1")))
        p.body.removeFromSuperview()
        host.frame = p.content.bounds
        p.content.addSubview(host)
        host.layoutSubtreeIfNeeded()
        snapshot.check(host, named: "overview-settings", background: ground)
    }

    // The compare passes a change of 0.05 % of the pixels or less, and records an issue for a
    // larger change, an image of another size and a missing PNG. The stored PNG is in a test
    // folder, so the test needs no fixture. A recording run skips the test: it would record.
    @Test(.disabled(if: ProcessInfo.processInfo.environment[Snapshot.recordVariable] == "1"))
    func aChangedPixelAreaOverTheLimitFails() throws {
        let frame = NSRect(x: 0, y: 0, width: 50, height: 50)
        let base = try #require(Snapshot.image(of: Block(frame: frame), background: .black))
        // 100 by 100 pixels at scale 2: the limit is 10 pixels.
        #expect(Snapshot.limit(pixels: base.width * base.height) == 10)
        #expect(Snapshot.limit(pixels: 1400 * 240) == 336)
        #expect(Snapshot.differingPixels(base, base) == 0)
        let atLimit = Block(frame: frame, pixels: 10)
        let overLimit = Block(frame: frame, pixels: 11)
        let ten = try #require(Snapshot.image(of: atLimit, background: .black))
        let eleven = try #require(Snapshot.image(of: overLimit, background: .black))
        #expect(Snapshot.differingPixels(base, ten) == 10)
        #expect(Snapshot.differingPixels(base, eleven) == 11)
        // A shift of the colour that the eye cannot see is no difference, also over 2 of 255 in
        // a channel. A shift that the eye sees is one.
        let faintRed = NSColor(srgbRed: 131 / 255, green: 0.5, blue: 0.5, alpha: 1)
        let visibleRed = NSColor(srgbRed: 150 / 255, green: 0.5, blue: 0.5, alpha: 1)
        let faint = Block(frame: frame, pixels: 60, line: faintRed)
        let visible = Block(frame: frame, pixels: 60, line: visibleRed)
        let faintImage = try #require(Snapshot.image(of: faint, background: .black))
        let visibleImage = try #require(Snapshot.image(of: visible, background: .black))
        #expect(Snapshot.differingPixels(base, faintImage) == 0)
        #expect(Snapshot.differingPixels(base, visibleImage) == 60)
        // The PNG form keeps each pixel.
        let png = try #require(Snapshot.png(eleven))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(Snapshot.differingPixels(eleven, decoded) == 0)

        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let stored = folder.url.appending(path: "Snapshots")
        try FileManager.default.createDirectory(at: stored, withIntermediateDirectories: true)
        try #require(Snapshot.png(base)).write(to: stored.appending(path: "block.png"))
        let bundle = try #require(Bundle(url: folder.url))
        let check = Snapshot(bundle: bundle, target: "BifrostWindowsTests")
        check.check(Block(frame: frame), named: "block", background: .black)
        check.check(atLimit, named: "block", background: .black)
        withKnownIssue("11 pixels differ: over the limit of 10") {
            check.check(overLimit, named: "block", background: .black)
        }
        withKnownIssue("an image of another size") {
            let other = Block(frame: NSRect(x: 0, y: 0, width: 40, height: 50))
            check.check(other, named: "block", background: .black)
        }
        withKnownIssue("no stored PNG") {
            check.check(Block(frame: frame), named: "missing", background: .black)
        }
    }

    // The image is dark also in a light app, as on a CI runner: the check fixes the appearance.
    @Test func theImageHasTheDarkAppearanceAlsoInALightApp() throws {
        let app = NSApplication.shared
        let old = app.appearance
        defer { app.appearance = old }
        let frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        app.appearance = NSAppearance(named: .aqua)
        let light = try #require(Snapshot.image(of: SystemText(frame: frame), background: .black))
        app.appearance = NSAppearance(named: .darkAqua)
        let dark = try #require(Snapshot.image(of: SystemText(frame: frame), background: .black))
        #expect(Snapshot.differingPixels(light, dark) == 0)
        // The system text colour of the dark appearance is light.
        #expect(Snapshot.pixels(dark).first.map { $0 > 200 } == true)
    }

    // The CIEDE2000 differences of pairs from the test data of Sharma, Wu and Dalal (2005), and
    // the CIELAB colours of black, white and a mid grey of sRGB.
    @Test func theColourDifferenceIsCIEDE2000() {
        typealias Lab = ColourDifference.Lab
        let pairs: [(Lab, Lab, Double)] = [
            (Lab(l: 50, a: 2.6772, b: -79.7751), Lab(l: 50, a: 0, b: -82.7485), 2.0425),
            (Lab(l: 50, a: 0, b: 0), Lab(l: 50, a: -1, b: 2), 2.3669),
            (
                Lab(l: 60.2574, a: -34.0099, b: 36.2677), Lab(l: 60.4626, a: -34.1751, b: 39.4387),
                1.2644
            ),
            (Lab(l: 50, a: 2.49, b: -0.001), Lab(l: 50, a: -2.49, b: 0.0009), 7.1792),
        ]
        for (one, two, expected) in pairs {
            #expect(abs(ColourDifference.deltaE00(one, two) - expected) < 0.0001)
            #expect(abs(ColourDifference.deltaE00(two, one) - expected) < 0.0001)
        }
        let black = ColourDifference.lab(red: 0, green: 0, blue: 0)
        let white = ColourDifference.lab(red: 255, green: 255, blue: 255)
        let grey = ColourDifference.lab(red: 128, green: 128, blue: 128)
        #expect(abs(black.l) < 0.001 && abs(white.l - 100) < 0.01 && abs(grey.l - 53.585) < 0.01)
        #expect(abs(white.a) < 0.01 && abs(white.b) < 0.01)
        #expect(ColourDifference.deltaE00(grey, grey) == 0)
    }
}

// A grey view with a line of pixels at its top left corner: one pixel high at scale 2, white
// unless the test gives another colour.
@MainActor
private final class Block: NSView {
    private let pixels: Int

    private let line: NSColor

    init(frame: NSRect, pixels: Int = 0, line: NSColor = .white) {
        self.pixels = pixels
        self.line = line
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1).setFill()
        bounds.fill()
        line.setFill()
        NSRect(x: 0, y: bounds.maxY - 0.5, width: CGFloat(pixels) * 0.5, height: 0.5).fill()
    }
}

// A view in the system text colour, which is dark in the light appearance and light in the dark
// one.
@MainActor
private final class SystemText: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textColor.setFill()
        bounds.fill()
    }
}
