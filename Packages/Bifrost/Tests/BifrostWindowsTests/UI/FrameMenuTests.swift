import AppKit
import BifrostFoundation
import BifrostLook
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostLayout
@testable import BifrostWindows

// The Panel menu of a frame (FrameMenu, docs/behaviour/menu.md): a Bifrost menu below the menu
// button, with Lock for each frame, and for an Overview also "Overview settings…" above Lock and
// the name field of the tab set below it. The canvas shows it on its Bifrost menu. The Overview
// tests give the canvas a real Overview model, as the app does, so a choice opens the panel and
// renames the tab set through the model.
@Suite("Panel menu", .serialized, .timeLimit(.minutes(1)), .tags(.window))
@MainActor
struct FrameMenuTests {
    private static let overview = panel("overview:1")

    // The canvas with a frame of the Settings panel, and a driver for the Bifrost menu of the
    // canvas. addOverview() also gives the canvas the Overview model and a frame of overview:1.
    @MainActor
    private final class Parts {
        let fixture: CanvasFixture
        let driver: MenuDriver
        let frame: FrameID
        private(set) var overviewFrame: FrameID?
        private(set) var overviews: OverviewModel?
        private var folder: TemporaryFolder?

        init(scale: Int = 100) {
            fixture = CanvasFixture(
                settings: CanvasSettings(interfaceScale: scale), bifrostWindow: true)
            driver = MenuDriver(menu: fixture.canvas.bifrostMenu)
            frame = fixture.open("settings", at: rect(100, 100, 400, 300))
        }

        // The Overview model of the app on the canvas, over a UI store in a temporary folder,
        // and a frame of overview:1 below the Settings frame.
        func addOverview() async throws {
            let folder = try TemporaryFolder()
            self.folder = folder
            let store = await UIStateStore.open(
                file: folder.url.appending(path: "ui-state.json"), clock: ManualClock(),
                log: Recorder<StoreEvent>())
            let sessions = SessionListModel.reading(FakeRowSource())
            let model = OverviewModel(
                store: store, sessions: sessions, selection: SelectionModel(list: sessions),
                layout: fixture.model, clock: ManualClock(),
                now: { Date(timeIntervalSince1970: 0) })
            overviewFrame = fixture.open("overview:1", at: rect(100, 450, 600, 300))
            fixture.canvas.overviews = model
            overviews = model
        }

        var button: TitleButton { fixture.view(frame).titleBar.menuButton }
        var menu: BifrostMenu { fixture.canvas.bifrostMenu }

        // The button rect in screen coordinates.
        var buttonRect: NSRect {
            fixture.window.convertToScreen(button.convert(button.bounds, to: nil))
        }

        // The Panel menu of the Overview frame, as its menu button opens it.
        func showOverviewMenu() throws {
            let id = try #require(overviewFrame)
            fixture.view(id).titleBar.menuButton.performClick(nil)
        }

        // The saved name of the tab set of overview:1.
        func setName() throws -> String {
            try #require(overviews).config(FrameMenuTests.overview).name
        }

        // The field of the name of the tab set.
        func nameField() throws -> MenuTextField {
            try #require(try driver.row(2).field)
        }

        // Type a text over the text of the field, as the keys do.
        func type(_ text: String) throws {
            let field = try nameField()
            let editor = try #require(field.currentEditor() as? NSTextView)
            editor.selectAll(nil)
            editor.insertText(text, replacementRange: editor.selectedRange())
        }

        func close() {
            menu.close()
            fixture.close()
            folder?.remove()
        }
    }

    @Test func thePanelMenuHasLockAndStaysOpenAfterAChange() throws {
        let p = Parts()
        defer { p.close() }
        p.button.performClick(nil)
        #expect(p.menu.isOpen)
        let root = try p.driver.root
        let lock = MenuRow.checkbox(MenuItemSpec(id: "lock", label: "Lock"), checked: false)
        #expect(root.list.state.rows == [lock])
        #expect(root.frame.width == 208)
        // Lock locks the frame, and the menu stays open with the check on.
        try p.driver.click(p.driver.row(0))
        #expect(p.fixture.frame(p.frame)?.locked == true)
        #expect(p.menu.isOpen)
        #expect(try p.driver.row(0).accessibilityValue() as? NSNumber == 1)
        // The keys change it too.
        try p.driver.key("Down")
        try p.driver.key("Space")
        #expect(p.fixture.frame(p.frame)?.locked == false)
        #expect(p.menu.isOpen)
        #expect(try p.driver.row(0).accessibilityValue() as? NSNumber == 0)
    }

    @Test func anOverviewMenuHasOverviewSettingsAndTheSetName() async throws {
        let p = Parts()
        defer { p.close() }
        try await p.addOverview()
        let overviewFrame = try #require(p.overviewFrame)
        try p.showOverviewMenu()
        let rows = try p.driver.root.list.state.rows
        #expect(rows.map(\.id) == ["overview-settings", "lock", "set-name"])
        let settings = MenuItemSpec(id: "overview-settings", label: "Overview settings…")
        #expect(rows[0] == .item(settings))
        #expect(rows[1] == .checkbox(MenuItemSpec(id: "lock", label: "Lock"), checked: false))
        let field = MenuRow.field(
            id: "set-name", label: "Tab set name", text: "Default", maxLength: 40)
        #expect(rows[2] == field)
        #expect(try p.nameField().stringValue == "Default")
        #expect(try p.nameField().accessibilityLabel() == "Tab set name")
        // The field is the menu child of its row.
        let children = try #require(try p.driver.root.list.accessibilityChildren())
        #expect(children.last as? MenuTextField === (try p.nameField()))
        // Lock still locks the frame.
        try p.driver.click(p.driver.row(1))
        #expect(p.fixture.frame(overviewFrame)?.locked == true)
        // Overview settings… opens the Overview Settings panel of this Overview and closes the
        // menu.
        try p.driver.click(p.driver.row(0))
        #expect(p.fixture.model.layout.topFrame?.active == panel("overview-settings:1"))
        #expect(!p.menu.isOpen)
        // The menu of another panel has only Lock.
        p.button.performClick(nil)
        #expect(try p.driver.root.list.state.rows.map(\.id) == ["lock"])
    }

    @Test func theSetNameFieldRenamesTheTabSet() async throws {
        let p = Parts()
        defer { p.close() }
        try await p.addOverview()
        try p.showOverviewMenu()
        // The keys take the focus to the field: Up from no highlight goes to the last row.
        try p.driver.key("Up")
        let field = try p.nameField()
        #expect(field.hasFocus)
        // The field takes the letters: the type-ahead does not move the highlight to Lock.
        // While the field edits, the root panel has the key focus and gets the keys.
        let root = try p.driver.root
        try p.type("  Mine  ")
        try p.driver.key("Return", in: root)
        #expect(try p.setName() == "Mine")
        // The field shows the saved name, and the menu stays open.
        #expect(field.stringValue == "Mine")
        #expect(field.hasFocus)
        #expect(p.menu.isOpen)
        // An empty name changes nothing, and the field shows the saved name again.
        try p.type("   ")
        try p.driver.key("Return", in: root)
        #expect(try p.setName() == "Mine")
        #expect(field.stringValue == "Mine")
        // A name of 40 Characters is the longest (row OV6): 40 emoji fit, and a 41st does not.
        let emoji = String(repeating: "👍🏽", count: 40)
        try p.type(emoji + "👍🏽")
        #expect(field.stringValue == emoji)
        try p.driver.key("Return", in: root)
        #expect(try p.setName() == emoji)
        // Up leaves the field: the parent window has the keys again, and Esc closes the menu.
        try p.driver.key("Up", in: root)
        #expect(!field.hasFocus)
        try p.driver.key("Escape")
        #expect(!p.menu.isOpen)
        // The next menu shows the new name.
        try p.showOverviewMenu()
        #expect(try p.nameField().stringValue == emoji)
    }

    @Test func aPressOutsideOrEscClosesThePanelMenu() throws {
        let p = Parts()
        defer { p.close() }
        p.button.performClick(nil)
        try p.driver.key("Escape")
        #expect(!p.menu.isOpen)
        // A press on the canvas closes the menu and goes on to the canvas.
        p.button.performClick(nil)
        let outside = try MenuDriver.press(at: NSPoint(x: 50, y: 50), in: p.fixture.window)
        #expect(p.menu.handleMouse(outside) === outside)
        #expect(!p.menu.isOpen)
        // A press on the menu button closes the menu, and the button does not get it.
        p.button.performClick(nil)
        let centre = p.button.convert(
            NSPoint(x: p.button.bounds.midX, y: p.button.bounds.midY), to: nil)
        let onButton = try MenuDriver.press(at: centre, in: p.fixture.window)
        #expect(p.menu.handleMouse(onButton) == nil)
        #expect(!p.menu.isOpen)
    }

    // The Panel menu opens at the press of its button, so a drag from the press to Lock and a
    // release there change Lock. A release on the button chooses nothing.
    @Test func aPressOnTheButtonADragAndAReleaseChooseARow() throws {
        let p = Parts()
        defer { p.close() }
        let window = p.fixture.window
        let centre = p.button.convert(
            NSPoint(x: p.button.bounds.midX, y: p.button.bounds.midY), to: nil)
        p.button.mouseDown(with: try MenuDriver.press(at: centre, in: window))
        #expect(p.menu.isOpen)
        // The button shows the press tint until the release.
        #expect(p.button.isHighlighted)
        let up = try MenuDriver.mouse(.leftMouseUp, at: centre, in: window)
        _ = p.menu.handleMouse(up)
        p.button.mouseUp(with: up)
        #expect(!p.button.isHighlighted)
        #expect(p.menu.isOpen)
        #expect(p.fixture.frame(p.frame)?.locked == false)
        // The window is at the origin of the screen, so a screen point is a point of the window.
        let lock = try p.driver.screenCentre(of: p.driver.row(0))
        _ = p.menu.handleMouse(try MenuDriver.mouse(.leftMouseDragged, at: lock, in: window))
        _ = p.menu.handleMouse(try MenuDriver.mouse(.leftMouseUp, at: lock, in: window))
        #expect(p.fixture.frame(p.frame)?.locked == true)
        #expect(p.menu.isOpen)
    }

    // At the Interface scale 150, the menu is 312 points wide (208 units), and its top is 6
    // points (4 units) under the button. AppKit puts a window on whole pixels, so a place can
    // move by up to half a point.
    @Test func thePanelMenuOpensBelowTheButtonAtItsRightEdge() throws {
        let p = Parts(scale: 150)
        defer { p.close() }
        p.button.performClick(nil)
        let frame = try p.driver.root.frame
        let button = p.buttonRect
        #expect(frame.width == 312)
        #expect(abs(frame.maxX - button.maxX) <= 0.5)
        #expect(abs(frame.maxY - (button.minY - 6)) <= 0.5)
    }
}
