import AppKit
import BifrostTestSupport
import Testing

@testable import BifrostLayout
@testable import BifrostWindows

// The basic accessibility of the canvas: roles, labels and actions (the section "The UI" of the
// architecture design).
@MainActor
@Suite("canvas accessibility", .serialized, .tags(.window))
struct CanvasAccessibilityTests {
    @Test func theCanvasAndTheFramesHaveRolesAndLabels() throws {
        let f = CanvasFixture()
        defer { f.close() }
        let a = f.open("settings", at: rect(100, 100, 400, 300))
        let b = f.open("watchlist", at: rect(600, 100, 300, 300))
        let c = f.open("event-log", at: rect(100, 450, 400, 300))
        f.model.apply(.minimise(c))
        #expect(f.canvas.isAccessibilityElement())
        #expect(f.canvas.accessibilityRole() == .group)
        #expect(f.canvas.accessibilityLabel() == "Panels")
        // The frames that show, in z-order. The marks, the outline and a minimised frame are
        // not there.
        let children = try #require(f.canvas.accessibilityChildren() as? [NSView])
        #expect(children == [f.view(a), f.view(b)])
        for (id, title) in [(a, "Settings"), (b, "Watchlist")] {
            let frame = f.view(id)
            #expect(frame.isAccessibilityElement())
            #expect(frame.accessibilityRole() == .group)
            #expect(frame.accessibilityLabel() == title)
        }
        #expect(!f.canvas.marks.isAccessibilityElement())
        #expect(f.canvas.marks.accessibilityChildren()?.isEmpty ?? true)
        #expect(!f.canvas.outline.isAccessibilityElement())
        #expect(f.canvas.outline.accessibilityChildren()?.isEmpty ?? true)
        // The title bar: the title, then the three buttons, each with a label and a press.
        let parts = try #require(f.view(a).accessibilityChildren() as? [NSObject])
        let bar = f.view(a).titleBar
        let title = try #require(bar.titleLabel)
        #expect(parts.prefix(4) == [title, bar.menuButton, bar.minimiseButton, bar.closeButton])
        #expect(title.accessibilityRole() == .staticText)
        #expect(title.accessibilityValue() == "Settings")
        let buttons = [bar.menuButton, bar.minimiseButton, bar.closeButton]
        #expect(buttons.map { $0.accessibilityLabel() } == ["Panel menu", "Minimise", "Close"])
        #expect(buttons.map(\.toolTip) == ["Panel menu", "Minimise", "Close"])
        #expect(buttons.allSatisfy { $0.accessibilityRole() == .button })
        // The body of the panel comes last.
        #expect(parts.last === f.view(a).shownBody)
        // A locked frame shows the lock glyph, with the label Locked.
        f.model.apply(.lock(a, true))
        let locked = try #require(f.view(a).accessibilityChildren() as? [NSObject])
        #expect(locked.contains(bar.lockView))
        #expect(bar.lockView.accessibilityLabel() == "Locked")
        #expect(bar.lockView.accessibilityRole() == .image)
    }

    @Test func tabsAreRadioButtonsInATabGroup() throws {
        let f = CanvasFixture()
        defer { f.close() }
        let a = f.open("watchlist", at: rect(600, 100, 300, 300))
        let b = f.open("settings", at: rect(100, 450, 400, 250))
        f.model.apply(.stack(b, onto: a))
        let bar = f.view(a).titleBar
        let group = bar.tabStrip
        #expect(group.isAccessibilityElement())
        #expect(group.accessibilityRole() == .tabGroup)
        let parts = try #require(f.view(a).accessibilityChildren() as? [NSObject])
        #expect(parts.first === group)
        #expect(bar.titleLabel == nil)
        let tabs = try #require(group.accessibilityChildren() as? [TabView])
        #expect(tabs == bar.tabViews)
        #expect(tabs.map { $0.accessibilityRole() } == [.radioButton, .radioButton])
        #expect(tabs.map { $0.accessibilityLabel() } == ["Watchlist", "Settings"])
        #expect(tabs.map { $0.accessibilityValue() as? Int } == [0, 1])
        #expect(tabs.map { $0.isAccessibilitySelected() } == [false, true])
        #expect(group.accessibilityTabs() as? [TabView] == tabs)
        #expect(group.accessibilityValue() as? TabView === tabs.last)
        // A press on a radio button activates its tab.
        #expect(tabs[0].accessibilityPerformPress())
        #expect(f.frame(a)?.active == panel("watchlist"))
        let after = try #require(f.view(a).titleBar.tabViews.first)
        #expect(after.isAccessibilitySelected())
        #expect(f.view(a).accessibilityLabel() == "Watchlist")
    }

    // A tab takes the keyboard focus as a button does. Space and Return activate it.
    @Test func spaceOrReturnOnAFocusedTabActivatesIt() throws {
        let f = CanvasFixture()
        defer { f.close() }
        let a = f.open("watchlist", at: rect(600, 100, 300, 300))
        let b = f.open("settings", at: rect(100, 450, 400, 250))
        f.model.apply(.stack(b, onto: a))
        let tabs = f.view(a).titleBar.tabViews
        #expect(tabs.allSatisfy { $0.acceptsFirstResponder })
        func key(_ text: String, _ code: UInt16) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: f.window.windowNumber, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)
        }
        tabs[0].keyDown(with: try #require(key(" ", 49)))
        #expect(f.frame(a)?.active == panel("watchlist"))
        tabs[1].keyDown(with: try #require(key("\r", 36)))
        #expect(f.frame(a)?.active == panel("settings"))
    }

    @Test func theRaiseActionBringsAFrameToTheFront() {
        let f = CanvasFixture()
        defer { f.close() }
        let a = f.open("settings", at: rect(100, 100, 400, 300))
        let b = f.open("watchlist", at: rect(600, 100, 300, 300))
        #expect(f.model.layout.topFrame?.id == b)
        #expect(f.view(a).accessibilityPerformRaise())
        #expect(f.model.layout.topFrame?.id == a)
        #expect(f.view(a).isTop)
        #expect(!f.view(b).isTop)
        #expect(f.canvas.accessibilityChildren() as? [NSView] == [f.view(b), f.view(a)])
    }

    @Test func theFrameActionsMinimiseCloseAndLock() throws {
        let f = CanvasFixture()
        defer { f.close() }
        let a = f.open("settings", at: rect(100, 100, 400, 300))
        let b = f.open("watchlist", at: rect(600, 100, 300, 300))
        func names(_ id: FrameID) -> [String] {
            f.view(id).accessibilityCustomActions()?.map(\.name) ?? []
        }
        func run(_ id: FrameID, _ name: String) -> Bool {
            let action = f.view(id).accessibilityCustomActions()?.first { $0.name == name }
            return action?.handler?() ?? false
        }
        #expect(names(a) == ["Minimise", "Close", "Lock"])
        #expect(run(a, "Lock"))
        #expect(f.frame(a)?.locked == true)
        #expect(names(a) == ["Minimise", "Close", "Unlock"])
        #expect(run(a, "Unlock"))
        #expect(f.frame(a)?.locked == false)
        #expect(run(a, "Minimise"))
        #expect(f.frame(a)?.minimised == true)
        #expect(f.view(a).isHidden)
        #expect(run(b, "Close"))
        #expect(f.frame(b) == nil)
        #expect(f.model.layout.memory[panel("watchlist")] == rect(600, 100, 300, 300))
    }
}
