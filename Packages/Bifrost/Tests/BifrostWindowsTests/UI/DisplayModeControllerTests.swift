import BifrostLayout
import BifrostTestSupport
import Observation
import Synchronization
import Testing

@testable import BifrostWindows

// The display modes against a fake window. The fake records each call and gives no callback by
// itself: the test gives the full-screen callbacks of AppKit, as the delegate of ShellWindow
// does. Thus no test requests a real full screen.

// One call of the controller to the window.
private enum WindowCall: Equatable {
    case enter, exit
    case borderless(Bool)
}

@MainActor
private final class FakeModeWindow: DisplayModeWindow {
    var isOpen = true
    var canChangeFullScreen = true
    var calls: [WindowCall] = []
    // Runs inside a call that starts a full-screen change: AppKit can give a callback before
    // toggleFullScreen(_:) returns.
    var inside: () -> Void = {}

    // False when the fake window is already in the target state: no callback comes.
    var startsChange = true

    func enterFullScreen() -> Bool {
        calls.append(.enter)
        if startsChange { inside() }
        return startsChange
    }

    func exitFullScreen() -> Bool {
        calls.append(.exit)
        if startsChange { inside() }
        return startsChange
    }

    func setBorderless(_ on: Bool) {
        calls.append(.borderless(on))
    }
}

// A controller on a fake window, and the modes that it gives to onChange.
@MainActor
private final class Parts {
    let window = FakeModeWindow()
    let modes = DisplayModeController()
    var changes: [DisplayMode] = []

    init() {
        modes.window = window
        modes.onChange = { [unowned self] in changes.append($0) }
    }

    // AppKit moves the window into the full screen.
    func entered() {
        modes.willEnterFullScreen()
        modes.didEnterFullScreen()
    }

    // AppKit moves the window out of the full screen.
    func exited() {
        modes.willExitFullScreen()
        modes.didExitFullScreen()
    }
}

@MainActor
@Suite("display mode controller", .tags(.window))
struct DisplayModeControllerTests {
    // A view that reads the mode, such as the Display mode row of Settings, sees each change. A
    // change of the full screen counts at its end.
    @Test func anObserverOfTheModeSeesEachChange() {
        let p = Parts()
        let seen = Mutex(0)
        func watch() {
            withObservationTracking { _ = p.modes.mode } onChange: { seen.withLock { $0 += 1 } }
        }
        watch()
        p.modes.request(.borderless)
        #expect(seen.withLock { $0 } == 1)
        watch()
        p.modes.toggleFullScreen()
        p.entered()
        #expect(seen.withLock { $0 } == 2)
        #expect(p.modes.mode == .fullscreen)
    }

    @Test func windowAndBorderlessChangeAtOnce() {
        let p = Parts()
        p.modes.request(.borderless)
        #expect(p.window.calls == [.borderless(true)])
        #expect(p.modes.mode == .borderless)
        #expect(!p.modes.isChanging)
        p.modes.request(.window)
        #expect(p.window.calls == [.borderless(true), .borderless(false)])
        #expect(p.changes == [.borderless, .window])
    }

    @Test func aRequestForTheModeOfNowChangesNothing() {
        let p = Parts()
        p.modes.request(.window)
        p.modes.request(.borderless)
        p.modes.request(.borderless)
        #expect(p.window.calls == [.borderless(true)])
        #expect(p.changes == [.borderless])
    }

    // The mode stays until AppKit ends the change. The will callback of a requested change
    // changes nothing.
    @Test func theFullScreenComesWhenAppKitEndsTheChange() {
        let p = Parts()
        p.modes.request(.fullscreen)
        #expect(p.window.calls == [.enter])
        #expect(p.modes.isChanging)
        p.modes.willEnterFullScreen()
        #expect(p.modes.mode == .window)
        #expect(p.changes.isEmpty)
        p.modes.didEnterFullScreen()
        #expect(p.modes.mode == .fullscreen)
        #expect(!p.modes.isChanging)
        #expect(p.changes == [.fullscreen])
    }

    // AppKit can give the callbacks before toggleFullScreen(_:) returns.
    @Test func callbacksInsideTheRequestEndTheChange() {
        let p = Parts()
        p.window.inside = { [unowned p] in p.modes.willEnterFullScreen() }
        p.modes.request(.fullscreen)
        #expect(p.modes.isChanging)
        p.modes.didEnterFullScreen()
        p.window.inside = { [unowned p] in p.exited() }
        p.modes.request(.borderless)
        #expect(p.window.calls == [.enter, .exit, .borderless(true)])
        #expect(p.modes.mode == .borderless)
        #expect(!p.modes.isChanging)
        #expect(p.changes == [.fullscreen, .borderless])
    }

    // The window is borderless again after the toggle. Its mode is never Window between the
    // steps.
    @Test func theToggleGoesBackToTheModeBeforeTheFullScreen() {
        let p = Parts()
        p.modes.request(.borderless)
        p.modes.toggleFullScreen()
        #expect(p.window.calls == [.borderless(true), .borderless(false), .enter])
        #expect(p.modes.mode == .borderless)
        p.entered()
        p.modes.toggleFullScreen()
        #expect(p.modes.mode == .fullscreen)
        p.exited()
        #expect(
            p.window.calls == [
                .borderless(true), .borderless(false), .enter, .exit, .borderless(true),
            ])
        #expect(p.modes.mode == .borderless)
        #expect(p.changes == [.borderless, .fullscreen, .borderless])
    }

    // The green button and the Esc key change the mode with no request.
    @Test func theGreenButtonAndEscChangeTheMode() {
        let p = Parts()
        p.entered()
        #expect(p.modes.mode == .fullscreen)
        p.exited()
        #expect(p.modes.mode == .window)
        #expect(p.window.calls.isEmpty)
        #expect(p.changes == [.fullscreen, .window])
    }

    @Test func theToggleLeavesAFullScreenOfTheGreenButtonToTheWindow() {
        let p = Parts()
        p.entered()
        p.modes.toggleFullScreen()
        p.exited()
        #expect(p.window.calls == [.exit])
        #expect(p.modes.mode == .window)
    }

    // A change from the full screen to borderless saves one mode, not Window first.
    @Test func fromTheFullScreenToBorderlessIsOneChange() {
        let p = Parts()
        p.modes.toggleFullScreen()
        p.entered()
        p.modes.request(.borderless)
        #expect(p.modes.isChanging)
        p.exited()
        #expect(p.window.calls == [.enter, .exit, .borderless(true)])
        #expect(p.changes == [.fullscreen, .borderless])
    }

    @Test func aRequestDuringAChangeWaitsForItsEnd() {
        let p = Parts()
        p.modes.request(.fullscreen)
        p.modes.request(.borderless)
        #expect(p.window.calls == [.enter])
        p.entered()
        #expect(p.window.calls == [.enter, .exit])
        p.exited()
        #expect(p.window.calls == [.enter, .exit, .borderless(true)])
        #expect(p.modes.mode == .borderless)
    }

    @Test func aNewerRequestReplacesTheWaitingRequest() {
        let p = Parts()
        p.modes.request(.fullscreen)
        p.modes.request(.borderless)
        p.modes.request(.window)
        p.entered()
        p.exited()
        #expect(p.window.calls == [.enter, .exit])
        #expect(p.modes.mode == .window)
        #expect(p.changes == [.fullscreen, .window])
    }

    // A waiting toggle reads the mode when it starts: the full screen came, so it leaves it.
    @Test func aWaitingToggleReadsTheModeWhenItStarts() {
        let p = Parts()
        p.modes.request(.fullscreen)
        p.modes.toggleFullScreen()
        p.entered()
        #expect(p.window.calls == [.enter, .exit])
        p.exited()
        #expect(p.modes.mode == .window)
    }

    // Two toggles give the mode before them, so a second toggle cancels a waiting toggle.
    @Test func twoWaitingTogglesCancel() {
        let p = Parts()
        p.modes.toggleFullScreen()
        p.modes.toggleFullScreen()
        p.modes.toggleFullScreen()
        p.entered()
        #expect(p.window.calls == [.enter])
        #expect(p.modes.mode == .fullscreen)
        #expect(!p.modes.isChanging)
    }

    // AppKit could not start the full screen. The window is titled, and the next request starts.
    @Test func aFailedEnterLeavesTheWindow() {
        let p = Parts()
        p.modes.request(.borderless)
        p.modes.toggleFullScreen()
        p.modes.request(.borderless)
        p.modes.willEnterFullScreen()
        p.modes.didFailToEnterFullScreen()
        #expect(
            p.window.calls == [.borderless(true), .borderless(false), .enter, .borderless(true)])
        #expect(p.changes == [.borderless, .window, .borderless])
        #expect(!p.modes.isChanging)
    }

    // AppKit could not end the full screen. The full screen stays with its mode before, and the
    // borderless step does not come.
    @Test func aFailedExitKeepsTheFullScreen() {
        let p = Parts()
        p.modes.request(.fullscreen)
        p.entered()
        p.modes.request(.borderless)
        p.modes.willExitFullScreen()
        p.modes.didFailToExitFullScreen()
        #expect(p.modes.mode == .fullscreen)
        #expect(!p.modes.isChanging)
        #expect(p.window.calls == [.enter, .exit])
        p.modes.toggleFullScreen()
        p.exited()
        #expect(p.modes.mode == .window)
        #expect(p.changes == [.fullscreen, .window])
    }

    // A request that AppKit does not start ends at once.
    @Test func aCallThatStartsNoChangeEndsAtOnce() {
        let p = Parts()
        p.window.startsChange = false
        // The window shows the full screen already: the enter ends with no callback.
        p.modes.request(.fullscreen)
        #expect(p.modes.mode == .fullscreen)
        #expect(!p.modes.isChanging)
        // The exit of a window that is not in the full screen ends at once too, and a request
        // after it starts.
        p.modes.request(.window)
        #expect(p.modes.mode == .window)
        #expect(!p.modes.isChanging)
        p.modes.request(.borderless)
        #expect(p.modes.mode == .borderless)
        #expect(p.changes == [.fullscreen, .window, .borderless])
    }

    // A callback that changes nothing gives no new mode.
    @Test func aCallbackOfNoChangeKeepsTheMode() {
        let p = Parts()
        p.modes.request(.borderless)
        p.modes.didExitFullScreen()
        p.modes.didFailToEnterFullScreen()
        p.modes.didFailToExitFullScreen()
        #expect(p.modes.mode == .borderless)
        p.modes.request(.window)
        p.entered()
        p.modes.didEnterFullScreen()
        #expect(p.changes == [.borderless, .window, .fullscreen])
    }

    // The window stays after a close. A request while it is closed changes nothing.
    @Test func aRequestForAClosedWindowChangesNothing() {
        let p = Parts()
        p.window.isOpen = false
        p.modes.request(.borderless)
        p.modes.toggleFullScreen()
        #expect(p.window.calls.isEmpty)
        p.window.isOpen = true
        p.modes.request(.borderless)
        #expect(p.window.calls == [.borderless(true)])
    }

    // AppKit changes the full screen only of a window that shows. A request for the full screen
    // then changes nothing, and the borderless mode still changes.
    @Test func noFullScreenForAWindowThatDoesNotShow() {
        let p = Parts()
        p.window.canChangeFullScreen = false
        p.modes.request(.borderless)
        p.modes.toggleFullScreen()
        #expect(p.window.calls == [.borderless(true)])
        #expect(p.modes.mode == .borderless)
        #expect(!p.modes.isChanging)
        p.modes.request(.window)
        #expect(p.modes.mode == .window)
    }
}
