import AppKit
import BifrostTestSupport
import Testing

@testable import BifrostLayout
@testable import BifrostLook
@testable import BifrostWindows

// The title bar of a frame: the row of its parts, the tabs that shrink in proportion, and the
// look of a press. The title bar lays out in the layout pass of AppKit, so a test runs the pass
// before it reads a frame. Each test has its own window, which is never ordered front.
@MainActor
@Suite("title bar", .serialized, .tags(.window))
struct TitleBarTests {
    private func host(_ bar: TitleBarView, width: CGFloat) -> NSWindow {
        UITestApp.prepare()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 28), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        bar.frame = NSRect(x: 0, y: 0, width: width, height: 28)
        window.contentView?.addSubview(bar)
        return window
    }

    // A frame in the coordinates of the title bar.
    private func place(_ view: NSView, in bar: TitleBarView) -> CGRect {
        bar.convert(view.bounds, from: view)
    }

    private let panels = [panel("watchlist"), panel("settings")]
    private let titles = [panel("watchlist"): "Watchlist", panel("settings"): "Settings"]

    // Tabs that fit keep the width of their text and insets, from the left. Tabs that do not fit
    // fill the space up to the buttons, each in proportion to its width.
    @Test func tabsShrinkInProportionWhenTheyDoNotFit() {
        let bar = TitleBarView()
        let window = host(bar, width: 500)
        defer { window.close() }
        bar.update(panels: panels, active: panels[1], titles: titles, locked: false)
        bar.layoutSubtreeIfNeeded()
        let wide = bar.tabViews.map { place($0, in: bar) }
        #expect(wide.map(\.minX) == [4, wide[0].maxX])
        let natural = wide.map(\.width)
        #expect(natural.allSatisfy { $0 > 16 })
        // The menu button starts 4 after the space of the tabs.
        let menuEnd: CGFloat = 500 - 12 - 24 * 2 - 4 * 2
        #expect(place(bar.menuButton, in: bar).maxX == menuEnd)
        // A title bar with room for 60 points of tabs.
        let room: CGFloat = 60
        let buttons: CGFloat = 24 * 3 + 4 * 2
        bar.frame.size.width = 4 + room + 4 + buttons + 12
        bar.layoutSubtreeIfNeeded()
        let narrow = bar.tabViews.map { place($0, in: bar) }
        #expect(abs(narrow.map(\.width).reduce(0, +) - room) <= 0.5)
        let share = natural[0] / natural.reduce(0, +)
        #expect(abs(narrow[0].width - room * share) <= 0.5)
        #expect(narrow[1].minX == narrow[0].maxX)
        let menuStart: CGFloat = 4 + room + 4
        #expect(place(bar.menuButton, in: bar).minX == menuStart)
    }

    // A new title gives its tab the width of the new title: while the tabs fit, the tab has
    // its new natural width, and while they do not fit, the shares follow the new widths.
    @Test func aRenamedTabTakesTheWidthOfItsNewTitle() {
        let bar = TitleBarView()
        let window = host(bar, width: 500)
        defer { window.close() }
        bar.update(panels: panels, active: panels[1], titles: titles, locked: false)
        bar.layoutSubtreeIfNeeded()
        let before = bar.tabViews.map { place($0, in: bar).width }
        var renamed = titles
        renamed[panel("watchlist")] = "The watchlist of the long running sessions"
        bar.update(panels: panels, active: panels[1], titles: renamed, locked: false)
        bar.layoutSubtreeIfNeeded()
        let fit = bar.tabViews.map { place($0, in: bar).width }
        #expect(fit[0] > before[0] * 2)
        #expect(fit[1] == before[1])
        #expect(abs(fit[0] - bar.tabViews[0].intrinsicContentSize.width) <= 0.5)
        // Room for 60 points of tabs: the shares follow the widths of the titles.
        let room: CGFloat = 60
        let buttons: CGFloat = 24 * 3 + 4 * 2
        bar.frame.size.width = 4 + room + 4 + buttons + 12
        bar.layoutSubtreeIfNeeded()
        let natural = bar.tabViews.map(\.intrinsicContentSize.width)
        let narrow = bar.tabViews.map { place($0, in: bar).width }
        let share = natural[0] / natural.reduce(0, +)
        #expect(abs(narrow[0] - room * share) <= 0.5)
        // A rename while the tabs do not fit moves the shares too.
        bar.update(panels: panels, active: panels[1], titles: titles, locked: false)
        bar.layoutSubtreeIfNeeded()
        let again = bar.tabViews.map(\.intrinsicContentSize.width)
        let newShare = again[0] / again.reduce(0, +)
        #expect(abs(place(bar.tabViews[0], in: bar).width - room * newShare) <= 0.5)
    }

    // The lock glyph comes before the buttons only while the frame is locked. A hidden part
    // takes no space.
    @Test func theLockTakesSpaceOnlyWhileItShows() {
        let bar = TitleBarView()
        let window = host(bar, width: 400)
        defer { window.close() }
        let settings = [panel("settings")]
        bar.update(panels: settings, active: settings[0], titles: titles, locked: true)
        bar.layoutSubtreeIfNeeded()
        let lockStart: CGFloat = 400 - 12 - 24 * 3 - 4 * 3 - 12
        #expect(place(bar.lockView, in: bar) == CGRect(x: lockStart, y: 8, width: 12, height: 12))
        let locked = bar.titleLabel.map { place($0, in: bar) }
        bar.update(panels: settings, active: settings[0], titles: titles, locked: false)
        bar.layoutSubtreeIfNeeded()
        let open = bar.titleLabel.map { place($0, in: bar) }
        // The title gets the space of the lock and its gap.
        let gained: CGFloat = 12 + 4
        #expect(open?.width == locked.map { $0.width + gained })
    }

    // The canvas gives each frame its panels at each change of the layout. The same panels,
    // titles and lock change no part of the title bar.
    @Test func theSameContentChangesNothing() {
        let bar = TitleBarView()
        let window = host(bar, width: 500)
        defer { window.close() }
        bar.update(panels: panels, active: panels[1], titles: titles, locked: false)
        bar.layoutSubtreeIfNeeded()
        bar.displayIfNeeded()
        let parts = bar.tabViews.flatMap { [$0] + $0.subviews }
        #expect(parts.allSatisfy { !$0.needsDisplay && !$0.needsLayout })
        bar.update(panels: panels, active: panels[1], titles: titles, locked: false)
        #expect(parts.allSatisfy { !$0.needsDisplay && !$0.needsLayout })
        #expect(!bar.needsLayout)
        // A new title changes the tab.
        var renamed = titles
        renamed[panel("settings")] = "Preferences"
        bar.update(panels: panels, active: panels[1], titles: renamed, locked: false)
        #expect(bar.tabViews.map(\.title) == ["Watchlist", "Preferences"])
    }

    // A press of a title bar button gives the cyan tint, and the release takes it away. The
    // button draws the state of its cell in its layer.
    @Test func aPressTintsTheButtonUntilTheRelease() {
        let bar = TitleBarView()
        let window = host(bar, width: 400)
        defer { window.close() }
        let button = bar.closeButton
        bar.layoutSubtreeIfNeeded()
        button.displayIfNeeded()
        #expect(button.layer?.backgroundColor == nil)
        button.highlight(true)
        button.displayIfNeeded()
        #expect(button.layer?.backgroundColor == TitleButton.pressColour)
        button.highlight(false)
        button.displayIfNeeded()
        #expect(button.layer?.backgroundColor == nil)
    }
}
