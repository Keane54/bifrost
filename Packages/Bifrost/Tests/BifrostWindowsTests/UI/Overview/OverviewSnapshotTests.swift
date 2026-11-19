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
        // 100 by 100 pixels at scale 2: the limit is 5 pixels.
        #expect(Snapshot.limit(pixels: base.width * base.height) == 5)
        #expect(Snapshot.limit(pixels: 1400 * 240) == 168)
        #expect(Snapshot.differingPixels(base, base) == 0)
        let atLimit = Block(frame: frame, pixels: 5)
        let overLimit = Block(frame: frame, pixels: 6)
        let five = try #require(Snapshot.image(of: atLimit, background: .black))
        let six = try #require(Snapshot.image(of: overLimit, background: .black))
        #expect(Snapshot.differingPixels(base, five) == 5)
        #expect(Snapshot.differingPixels(base, six) == 6)
        // The PNG form keeps each pixel.
        let png = try #require(Snapshot.png(six))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(Snapshot.differingPixels(six, decoded) == 0)

        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let stored = folder.url.appending(path: "Snapshots")
        try FileManager.default.createDirectory(at: stored, withIntermediateDirectories: true)
        try #require(Snapshot.png(base)).write(to: stored.appending(path: "block.png"))
        let bundle = try #require(Bundle(url: folder.url))
        let check = Snapshot(bundle: bundle, target: "BifrostWindowsTests", pixels: true)
        check.check(Block(frame: frame), named: "block", background: .black)
        check.check(atLimit, named: "block", background: .black)
        withKnownIssue("6 pixels differ: over the limit of 5") {
            check.check(overLimit, named: "block", background: .black)
        }
        withKnownIssue("an image of another size") {
            let other = Block(frame: NSRect(x: 0, y: 0, width: 40, height: 50))
            check.check(other, named: "block", background: .black)
        }
        withKnownIssue("no stored PNG") {
            check.check(Block(frame: frame), named: "missing", background: .black)
        }
        // With the pixel compare off (SNAPSHOT_PIXELS=0 on the CI runner), only the size counts.
        let sizeOnly = Snapshot(bundle: bundle, target: "BifrostWindowsTests", pixels: false)
        sizeOnly.check(overLimit, named: "block", background: .black)
        withKnownIssue("an image of another size, with the pixel compare off") {
            let other = Block(frame: NSRect(x: 0, y: 0, width: 40, height: 50))
            sizeOnly.check(other, named: "block", background: .black)
        }
    }
}

// A grey view with a white line of pixels at its top left corner: one pixel high at scale 2.
@MainActor
private final class Block: NSView {
    private let pixels: Int

    init(frame: NSRect, pixels: Int = 0) {
        self.pixels = pixels
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1).setFill()
        bounds.fill()
        NSColor.white.setFill()
        NSRect(x: 0, y: bounds.maxY - 0.5, width: CGFloat(pixels) * 0.5, height: 0.5).fill()
    }
}
