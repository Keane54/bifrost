import AppKit
import BifrostLayout
import BifrostTestSupport
import Testing

@testable import BifrostLook
@testable import BifrostWindows

// The shell window: the main window with its display modes. The test never shows a window:
// present records the show, and setPresentation records the presentation options, so the test
// does not change the menu bar or the Dock. A window that does not show gets no full screen, so
// the test never requests a real full screen: it gives the full-screen callbacks itself. A move
// is a setFrame: AppKit gives the delegate the resize of a window that is not on the screen.

// A frame of AppKit in the coordinates of the file, as the shell saves it.
@MainActor
private func file(_ frame: NSRect) -> WindowBounds {
    WindowPlacement.fileBounds(
        appKit: WindowBounds(
            x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height),
        primaryScreenHeight: ShellWindow.primaryScreenHeight())
}

@MainActor
private func notice(_ name: Notification.Name, _ window: NSWindow) -> Notification {
    Notification(name: name, object: window)
}

// A shell window with a manual clock, and the records of its callbacks.
@MainActor
private final class Parts {
    static let place = WindowBounds(x: 100, y: 120, width: 1000, height: 700)

    let clock = ManualClock()
    let content = NSView()
    let shell: ShellWindow
    var shows: [WindowShow.Show] = []
    var options: [NSApplication.PresentationOptions] = []
    var saved: [WindowBounds] = []
    var modes: [DisplayMode] = []

    init(placement: RestoredPlace = .at(Parts.place), mode: DisplayMode = .window) {
        UITestApp.prepare()
        shell = ShellWindow(
            title: "Bifrost Dev", placement: placement, mode: mode, show: .inactive,
            content: content, clock: clock)
        shell.present = { [unowned self] _, show in self.shows.append(show) }
        shell.setPresentation = { [unowned self] options in self.options.append(options) }
        shell.onBoundsChange = { [unowned self] bounds in self.saved.append(bounds) }
        shell.modes.onChange = { [unowned self] mode in self.modes.append(mode) }
    }

    var window: BifrostWindow { shell.window }

    func moved(_ dx: Double) -> NSRect {
        var frame = window.frame
        frame.origin.x += dx
        return frame
    }
}

@Suite("shell window", .serialized, .testTimeLimit, .tags(.window))
@MainActor
struct ShellWindowTests {
    @Test func theWindowHasTheLookAndTheLimitsOfIndexTs() {
        let p = Parts()
        let w = p.window
        #expect(w.styleMask == [.titled, .closable, .miniaturizable, .resizable])
        #expect(w.minSize == NSSize(width: 800, height: 500))
        #expect(w.backgroundColor == ThemeTokens.bg.nsColor)
        #expect(!w.isRestorable)
        #expect(!w.isReleasedWhenClosed)
        // The window has no appearance of its own: the app is dark (UITestApp, AppDelegate).
        #expect(w.appearance == nil)
        #expect(w.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        #expect(w.tabbingMode == .disallowed)
        #expect(w.title == "Bifrost Dev")
        #expect(w.contentView === p.content)
        // The key window hook of a test home is off.
        #expect(!w.actsAsKey)
    }

    @Test func aSavedPlaceOpensAtItsBounds() {
        let p = Parts()
        #expect(file(p.window.frame) == Parts.place)
    }

    // The minimum size of 800 by 500 applies at the start, as the minWidth
    // and minHeight of the BrowserWindow do. The top-left corner stays.
    @Test func theStartPlaceKeepsTheMinimumSize() {
        let small = WindowBounds(x: 100, y: 120, width: 400, height: 300)
        let p = Parts(placement: .at(small))
        #expect(file(p.window.frame) == WindowBounds(x: 100, y: 120, width: 800, height: 500))
    }

    @Test func aCentredPlaceHasTheDefaultSize() {
        let p = Parts(placement: .centred(width: 1440, height: 900))
        #expect(p.window.frame.size == NSSize(width: 1440, height: 900))
    }

    @Test func theNormalBoundsSave500msAfterTheLastMove() async {
        let p = Parts()
        p.window.setFrame(p.moved(40), display: false)
        await p.clock.waitForSleepers(1)
        let wait = p.shell.boundsSaveTask
        p.clock.advance(by: .milliseconds(300))
        let last = p.moved(10)
        p.window.setFrame(last, display: false)
        // The second move moves the save to 500 ms after it. The wait stays the same task.
        #expect(p.shell.boundsSaveTask == wait)
        p.clock.advance(by: .milliseconds(499))
        await p.clock.waitForSleepers(1)
        #expect(p.saved.isEmpty)
        p.clock.advance(by: .milliseconds(1))
        await wait?.value
        #expect(p.saved == [file(last)])
        #expect(p.shell.normalBounds == file(last))
    }

    // A burst of moves and resizes, as a live move gives, makes one wait for the save.
    @Test func aBurstOfMovesMakesOneWait() async {
        let p = Parts()
        p.window.setFrame(p.moved(1), display: false)
        let wait = p.shell.boundsSaveTask
        #expect(wait != nil)
        for step in 2...20 {
            p.window.setFrame(p.moved(Double(step)), display: false)
            #expect(p.shell.boundsSaveTask == wait)
        }
        await p.clock.waitForSleepers(1)
        #expect(p.clock.sleeperCount == 1)
        p.window.close()
    }

    // The end of a live resize saves the normal bounds at once, and the wait stops.
    @Test func theEndOfALiveResizeSavesAtOnce() {
        let p = Parts()
        var frame = p.window.frame
        frame.size.width += 30
        p.window.setFrame(frame, display: false)
        #expect(p.shell.boundsSaveTask != nil)
        p.shell.windowDidEndLiveResize(notice(NSWindow.didEndLiveResizeNotification, p.window))
        #expect(p.saved == [file(frame)])
        #expect(p.shell.boundsSaveTask == nil)
        // A live resize that changed nothing saves nothing.
        p.shell.windowDidEndLiveResize(notice(NSWindow.didEndLiveResizeNotification, p.window))
        #expect(p.saved == [file(frame)])
    }

    @Test func aCloseSavesTheBoundsAtOnce() {
        let p = Parts()
        let moved = p.moved(25)
        p.window.setFrame(moved, display: false)
        p.window.close()
        #expect(p.saved == [file(moved)])
        // The timer of the move stopped, so it saves nothing more.
        #expect(p.shell.boundsSaveTask == nil)
        #expect(!p.shell.isOpen)
    }

    // The bounds of a full screen are not the normal bounds: a resize in the full screen starts
    // no save, and a close saves the bounds of the normal window.
    @Test func fullScreenSavesNoBounds() {
        let p = Parts()
        let normal = p.window.frame
        p.shell.windowWillEnterFullScreen(
            notice(NSWindow.willEnterFullScreenNotification, p.window))
        let screen = NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        p.window.setFrame(screen, display: false)
        p.shell.windowDidEnterFullScreen(notice(NSWindow.didEnterFullScreenNotification, p.window))
        p.window.setFrame(screen.insetBy(dx: 10, dy: 10), display: false)
        #expect(p.shell.boundsSaveTask == nil)
        #expect(p.shell.normalBounds == file(normal))
        p.window.close()
        #expect(p.saved == [file(normal)])
    }

    // A zoomed window keeps its normal bounds, as getNormalBounds of a maximised BrowserWindow.
    @Test func aZoomedFrameIsNotTheNormalBounds() {
        let p = Parts()
        let normal = p.window.frame
        p.window.zoom(nil)
        #expect(p.window.isZoomed)
        #expect(p.shell.boundsSaveTask == nil)
        p.window.close()
        #expect(p.saved == [file(normal)])
    }

    // Borderless (a simple full screen): no title bar, the frame of its screen, the
    // menu bar and the Dock hide while the app is active. Back to window, the window gets its
    // title bar and its normal frame again.
    @Test func aBorderlessWindowCoversItsScreen() throws {
        let p = Parts()
        p.shell.show()
        let normal = p.window.frame
        p.shell.modes.request(.borderless)
        let screen = try #require(p.window.screen ?? NSScreen.screens.first)
        #expect(p.window.styleMask == .borderless)
        #expect(p.window.frame == screen.frame)
        #expect(!p.window.isMovable)
        #expect(p.options == [[.autoHideMenuBar, .autoHideDock]])
        #expect(p.modes == [.borderless])
        // The move to the frame of the screen is not a move of the normal window.
        #expect(p.shell.boundsSaveTask == nil)
        #expect(p.shell.normalBounds == file(normal))
        p.shell.modes.request(.window)
        #expect(p.window.styleMask == [.titled, .closable, .miniaturizable, .resizable])
        #expect(p.window.frame == normal)
        #expect(p.window.isMovable)
        #expect(p.options == [[.autoHideMenuBar, .autoHideDock], []])
        #expect(p.modes == [.borderless, .window])
    }

    // A borderless window covers its screen again after a change of the screens (a new
    // resolution, a display that goes or comes) and after a move to another screen. The test
    // gives the frame that a change of the screens can leave.
    @Test func aBorderlessWindowFollowsAChangeOfTheScreens() async throws {
        let p = Parts()
        p.shell.show()
        p.shell.modes.request(.borderless)
        let screen = try #require(p.window.screen ?? NSScreen.screens.first)
        #expect(p.window.frame == screen.frame)
        let left = screen.frame.insetBy(dx: 100, dy: 100)
        p.window.setFrame(left, display: false)
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        await waitUntil { p.window.frame == screen.frame }
        p.window.setFrame(left, display: false)
        p.shell.windowDidChangeScreen(notice(NSWindow.didChangeScreenNotification, p.window))
        #expect(p.window.frame == screen.frame)
        // Back in the window mode, a change of the screens keeps the normal frame.
        p.shell.modes.request(.window)
        let normal = p.window.frame
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        p.shell.windowDidChangeScreen(notice(NSWindow.didChangeScreenNotification, p.window))
        // The shell follows the screens only in the borderless mode.
        #expect(p.window.frame == normal)
        // The bounds of the borderless frames are not the normal bounds.
        #expect(p.saved.isEmpty)
    }

    // Each switch to the borderless mode follows the screens again: borderless, window, then
    // borderless, and a change of the screens still moves the frame.
    @Test func aSecondBorderlessModeFollowsAChangeOfTheScreens() async throws {
        let p = Parts()
        p.shell.show()
        p.shell.modes.request(.borderless)
        p.shell.modes.request(.window)
        p.shell.modes.request(.borderless)
        let screen = try #require(p.window.screen ?? NSScreen.screens.first)
        p.window.setFrame(screen.frame.insetBy(dx: 100, dy: 100), display: false)
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        await waitUntil { p.window.frame == screen.frame }
    }

    // The first show: the window shows, then the saved mode applies. A reopen
    // shows the window again and does not apply the saved mode again.
    @Test func theSavedModeAppliesAfterTheFirstShow() {
        let p = Parts(mode: .borderless)
        #expect(p.window.styleMask.contains(.titled))
        #expect(p.shell.modes.mode == .window)
        p.shell.show()
        #expect(p.shows == [.inactive])
        #expect(p.shell.modes.mode == .borderless)
        #expect(!p.window.styleMask.contains(.titled))
        p.shell.modes.request(.window)
        p.window.close()
        p.shell.show()
        #expect(p.shows == [.inactive, .inactive])
        #expect(p.shell.modes.mode == .window)
        #expect(p.window.styleMask.contains(.titled))
    }

    // A test home shows the window with no focus. Then a saved full screen does not apply, so
    // the window does not go to its own space.
    @Test func aTestHomeShowSkipsTheSavedFullScreen() {
        let p = Parts(mode: .fullscreen)
        p.shell.show()
        #expect(p.shows == [.inactive])
        #expect(p.shell.modes.mode == .window)
        #expect(!p.shell.modes.isChanging)
        #expect(!p.window.styleMask.contains(.fullScreen))
        #expect(p.modes.isEmpty)
    }

    // The green button and the Esc key: each full-screen callback of the window goes to the
    // display modes, also a change that fails.
    @Test func theFullScreenCallbacksChangeTheMode() {
        let p = Parts()
        p.shell.show()
        let w = p.window
        let modes = p.shell.modes
        p.shell.windowWillEnterFullScreen(notice(NSWindow.willEnterFullScreenNotification, w))
        #expect(modes.isChanging)
        p.shell.windowDidFailToEnterFullScreen(w)
        #expect(!modes.isChanging)
        p.shell.windowWillEnterFullScreen(notice(NSWindow.willEnterFullScreenNotification, w))
        p.shell.windowDidEnterFullScreen(notice(NSWindow.didEnterFullScreenNotification, w))
        #expect(modes.mode == .fullscreen)
        p.shell.windowWillExitFullScreen(notice(NSWindow.willExitFullScreenNotification, w))
        #expect(modes.isChanging)
        p.shell.windowDidFailToExitFullScreen(w)
        #expect(modes.mode == .fullscreen)
        #expect(!modes.isChanging)
        p.shell.windowWillExitFullScreen(notice(NSWindow.willExitFullScreenNotification, w))
        p.shell.windowDidExitFullScreen(notice(NSWindow.didExitFullScreenNotification, w))
        #expect(modes.mode == .window)
        #expect(p.modes == [.fullscreen, .window])
    }

    // AppKit changes the full screen only of a window that shows. The window of the test does
    // not show, so a request for the full screen changes nothing.
    @Test func aWindowThatDoesNotShowGetsNoFullScreen() {
        let p = Parts()
        p.shell.show()
        #expect(!p.window.isVisible)
        p.shell.modes.request(.fullscreen)
        p.shell.modes.toggleFullScreen()
        #expect(!p.shell.modes.isChanging)
        #expect(p.shell.modes.mode == .window)
        #expect(!p.window.styleMask.contains(.fullScreen))
        #expect(p.modes.isEmpty)
    }
}
