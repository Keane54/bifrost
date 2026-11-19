import AppKit
import BifrostSessions
import BifrostTestSupport
import QuartzCore
import Testing

@testable import BifrostLook
@testable import BifrostWindows

// The row icon of the Overview (docs/behaviour/overview.md, Cells and the icon): the glyph in the
// project colour, the brackets in the box colour, and the flash of the brackets.
@Suite("session icon", .tags(.window))
@MainActor
struct SessionIconViewTests {
    init() { UITestApp.prepare() }

    private func icon(_ row: SessionRow, rowFlash: Bool = true, app: AppIcon? = nil)
        -> SessionIconView
    {
        let view = SessionIconView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        view.show(SessionIconLook(row: row, appIcon: app, rowFlash: rowFlash), unit: 1)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func flashes(_ view: SessionIconView) -> Bool {
        view.brackets.layer?.animation(forKey: SessionIconView.flashKey) != nil
    }

    private func boxed(_ alert: SessionAlert) -> SessionRow {
        var row = SessionRow.test(state: .needsYou)
        row.alert = alert
        return row
    }

    @Test func theFlashRunsOnlyWithTheSettingAndAFlashingRow() throws {
        let row = boxed(.yellow(since: 1))
        let view = icon(row)
        #expect(flashes(view))
        // The flash: opacity 1, 0.25, 1 over 1 s, ease in and out, with no end.
        let flash = try #require(
            view.brackets.layer?.animation(forKey: SessionIconView.flashKey)
                as? CAKeyframeAnimation)
        #expect(flash.keyPath == "opacity")
        #expect((flash.values as? [NSNumber])?.map(\.doubleValue) == [1, 0.25, 1])
        #expect((flash.keyTimes)?.map(\.doubleValue) == [0, 0.5, 1])
        #expect(flash.duration == 1)
        #expect(flash.repeatCount == .infinity)
        #expect(
            flash.timingFunctions == [
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
            ])
        // The setting off stops the flash, and the box stays.
        view.show(SessionIconLook(row: row, appIcon: nil, rowFlash: false), unit: 1)
        #expect(!flashes(view))
        #expect(!view.brackets.isHidden)
        // A row with no box has no brackets and no flash, also with the setting on.
        view.show(SessionIconLook(row: boxed(.none), appIcon: nil, rowFlash: true), unit: 1)
        #expect(!flashes(view))
        #expect(view.brackets.isHidden)
        // The flash keeps its animation while the row keeps flashing.
        let red = boxed(.red(.prompt, since: 1))
        view.show(SessionIconLook(row: red, appIcon: nil, rowFlash: true), unit: 1)
        let first = view.brackets.layer?.animation(forKey: SessionIconView.flashKey)
        let yellow = boxed(.yellow(since: 2))
        view.show(SessionIconLook(row: yellow, appIcon: nil, rowFlash: true), unit: 1)
        #expect(view.brackets.layer?.animation(forKey: SessionIconView.flashKey) === first)
    }

    @Test func theBracketsHaveTheBoxColour() throws {
        #expect(icon(boxed(.yellow(since: 1))).brackets.colour == ThemeTokens.boxYellow)
        #expect(icon(boxed(.red(.error, since: 1))).brackets.colour == ThemeTokens.boxRed)
        let none = icon(boxed(.none))
        #expect(none.brackets.colour == nil)
        #expect(none.brackets.isHidden)
        // The four brackets: the arms are 30 % of the side, and the bars 2 units thick. The
        // middle of the icon and the middle of each edge have no bracket.
        let view = icon(boxed(.red(.error, since: 1)))
        let image = try #require(Snapshot.image(of: view.brackets, background: .black))
        let pixels = Snapshot.pixels(image)
        let side = image.width
        func isRed(_ x: Int, _ y: Int) -> Bool {
            let start = (y * side + x) * 4
            return pixels[start] > 200 && pixels[start + 1] < 150
        }
        for (x, y) in [(0, 0), (side - 1, 0), (0, side - 1), (side - 1, side - 1)] {
            #expect(isRed(x, y))
        }
        #expect(isRed(1, side / 4))
        #expect(!isRed(1, side / 2))
        #expect(!isRed(side / 2, 1))
        #expect(!isRed(side / 2, side / 2))
    }

    @Test func theGlyphHasTheProjectColour() {
        let row = SessionRow.test(cwd: "/work/demo/app")
        let index = SessionIconRules.projectColourIndex(SessionIconRules.projectKey(row.cwd))
        let owned = icon(row)
        #expect(owned.look?.glyph == .mark)
        #expect(owned.glyphView.contentTintColor == ThemeTokens.projects[index - 1].nsColor)
        #expect(owned.look?.title == "Owned session")
        #expect(owned.accessibilityLabel() == "Owned session")
        // A worktree of the repository has the colour of the repository.
        let worktree = icon(SessionRow.test(cwd: "/work/demo/app/.claude/worktrees/fix"))
        #expect(worktree.glyphView.contentTintColor == owned.glyphView.contentTintColor)
        // An external row with no app icon shows the terminal glyph in the project colour.
        let external = icon(SessionRow.test(kind: .external, cwd: row.cwd))
        #expect(external.look?.glyph == .terminal)
        #expect(external.glyphView.contentTintColor == owned.glyphView.contentTintColor)
        #expect(external.look?.title == "External session")
        // A parked row has the mark in the parked colour, also an external row.
        let parked = icon(SessionRow.test(kind: .external, cwd: row.cwd, state: .parked))
        #expect(parked.look?.glyph == .mark)
        #expect(parked.glyphView.contentTintColor == ThemeTokens.parked.nsColor)
        #expect(parked.look?.title == "Parked session")
        // The icon of a terminal app keeps its own colours and has the name of the app.
        let image = NSImage(size: NSSize(width: 32, height: 32))
        let term = AppIcon(image: image, name: "Example Term")
        let app = icon(SessionRow.test(kind: .external, cwd: row.cwd), app: term)
        #expect(app.look?.glyph == .app(image))
        #expect(app.glyphView.image === image)
        #expect(app.glyphView.contentTintColor == nil)
        #expect(app.look?.title == "Example Term")
        // The glyph is 2/3 of the side, and the icon of an app 7/8.
        #expect(owned.glyphView.frame.width == 12)
        #expect(app.glyphView.frame.width == 16)
    }

    // An owned row that an app shows has the icon of that app in place of the mark: the icon of
    // Bifrost for a chat window, or the icon of a terminal app for a claude attach client. A
    // parked row keeps the mark, also with an app icon.
    @Test func anOwnedRowShowsTheIconOfItsApp() {
        let image = NSImage(size: NSSize(width: 32, height: 32))
        let bifrost = AppIcon(image: image, name: SessionAppIcons.bifrostName)
        let inChat = icon(SessionRow.test(), app: bifrost)
        #expect(inChat.look?.glyph == .app(image))
        #expect(inChat.look?.title == "Bifrost")
        #expect(inChat.glyphView.contentTintColor == nil)
        let warp = AppIcon(image: image, name: "Warp")
        #expect(icon(SessionRow.test(), app: warp).look?.title == "Warp")
        let parked = icon(SessionRow.test(state: .parked), app: warp)
        #expect(parked.look?.glyph == .mark)
        #expect(parked.look?.title == "Parked session")
    }
}
