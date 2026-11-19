// The display mode of the main window: Window, Borderless or Fullscreen. The controller follows
// the full-screen callbacks of AppKit, which the delegate of the window gives it. Thus the green
// button and the Esc key change the mode with no request. The window is a DisplayModeWindow, so
// a test can give a fake.
//
// The rules:
// - Borderless is a style of the window. Its change ends at once.
// - A change of the native full screen starts at the request, or at the will callback when it
//   has no request. It ends at the did callback, or at the did-fail callback of AppKit.
// - One change runs at a time. A request during a change waits in one slot until the change
//   ends. A newer request replaces the waiting request. A second toggle cancels a waiting toggle,
//   because two toggles give the mode before them.
// - The toggle goes back to the mode before the full screen, else to Window. It reads the mode
//   when it starts, not when it waits.
// - A call that starts no change (the window is already in the target state) gives no callback.
//   The change then ends at once, as if the did callback came.
// - During a change, the mode is the mode before the change. onChange comes only for a new mode.
// - The mode is observed, so a view that reads it, such as the Display mode row of Settings, shows
//   each change.
import BifrostLayout
import Observation

// The parts of the window that the display modes use (ShellWindow in the app).
@MainActor
package protocol DisplayModeWindow: AnyObject {
    // False before the first show and after a close, until the next show. A request then
    // changes nothing.
    var isOpen: Bool { get }
    // True when AppKit can change the full screen of the window now. For a window that does not
    // show, AppKit starts no change and gives no callback, so a request changes nothing.
    var canChangeFullScreen: Bool { get }
    // Start the change to the native full screen, or back to the window. AppKit then gives the
    // callbacks. Each returns true when it started a change. It returns false when the window is
    // already in the target state: AppKit then gives no callback.
    @discardableResult func enterFullScreen() -> Bool
    @discardableResult func exitFullScreen() -> Bool
    // Make the window borderless on its screen (true), or titled with its normal frame (false).
    func setBorderless(_ on: Bool)
}

@MainActor
@Observable
public final class DisplayModeController {
    @MainActor
    private enum State: Equatable {
        case window, borderless
        // AppKit moves the window into the full screen. before is the mode before it.
        case enteringFullScreen(before: DisplayMode)
        case fullScreen(before: DisplayMode)
        // AppKit moves the window out of the full screen. then is the mode after it: Window or
        // Borderless.
        case exitingFullScreen(then: DisplayMode, before: DisplayMode)
    }

    @MainActor
    private enum Request: Equatable {
        case set(DisplayMode), toggle
    }

    // The mode changed. The app saves it in window-state.json.
    @ObservationIgnored public var onChange: ((DisplayMode) -> Void)?
    @ObservationIgnored weak var window: (any DisplayModeWindow)?
    // The window starts titled. The saved mode applies after the first show.
    private var state = State.window
    // The request that waits for the end of the change.
    @ObservationIgnored private var waiting: Request?

    init() {}

    // The mode that the View menu shows and the file keeps.
    public var mode: DisplayMode {
        switch state {
        case .window: .window
        case .borderless: .borderless
        case .enteringFullScreen(let before): before
        case .fullScreen, .exitingFullScreen: .fullscreen
        }
    }

    // True while AppKit changes the full screen.
    package var isChanging: Bool {
        switch state {
        case .enteringFullScreen, .exitingFullScreen: true
        case .window, .borderless, .fullScreen: false
        }
    }

    // A View item or the saved mode asks for a mode.
    public func request(_ mode: DisplayMode) {
        submit(.set(mode))
    }

    // The Fullscreen item or its key.
    public func toggleFullScreen() {
        submit(.toggle)
    }

    private func submit(_ request: Request) {
        if isChanging {
            waiting = (waiting == .toggle && request == .toggle) ? nil : request
        } else {
            start(request)
        }
    }

    private func start(_ request: Request) {
        guard let window, window.isOpen else { return }
        let target =
            switch (request, state) {
            case (.set(let mode), _): mode
            case (.toggle, .fullScreen(let before)): before
            case (.toggle, _): DisplayMode.fullscreen
            }
        guard target != mode else { return }
        // The window calls come last: AppKit can give a callback before the call returns.
        switch (state, target) {
        case (.fullScreen(let before), _):
            guard window.canChangeFullScreen else { return }
            state = .exitingFullScreen(then: target, before: before)
            // A call that does nothing gives no callback, so the change ends here.
            if !window.exitFullScreen() { didExitFullScreen() }
        case (_, .fullscreen):
            guard window.canChangeFullScreen else { return }
            let before = mode
            if before == .borderless { window.setBorderless(false) }
            state = .enteringFullScreen(before: before)
            if !window.enterFullScreen() { didEnterFullScreen() }
        default:
            window.setBorderless(target == .borderless)
            settle(target == .borderless ? .borderless : .window)
        }
    }

    // MARK: - The callbacks of AppKit

    func willEnterFullScreen() {
        switch state {
        case .window, .borderless: state = .enteringFullScreen(before: mode)
        case .enteringFullScreen, .fullScreen, .exitingFullScreen: break
        }
    }

    func didEnterFullScreen() {
        switch state {
        case .enteringFullScreen(let before), .fullScreen(let before),
            .exitingFullScreen(_, let before):
            settle(.fullScreen(before: before))
        case .window, .borderless:
            settle(.fullScreen(before: mode))
        }
    }

    // AppKit could not start the full screen. The window is titled.
    func didFailToEnterFullScreen() {
        guard case .enteringFullScreen = state else { return }
        settle(.window)
    }

    func willExitFullScreen() {
        guard case .fullScreen(let before) = state else { return }
        state = .exitingFullScreen(then: .window, before: before)
    }

    func didExitFullScreen() {
        switch state {
        case .exitingFullScreen(let then, _):
            if then == .borderless { window?.setBorderless(true) }
            settle(then == .borderless ? .borderless : .window)
        case .enteringFullScreen, .fullScreen:
            settle(.window)
        case .window, .borderless:
            break
        }
    }

    // AppKit could not end the full screen. The full screen stays, so its next mode does not
    // come.
    func didFailToExitFullScreen() {
        guard case .exitingFullScreen(_, let before) = state else { return }
        settle(.fullScreen(before: before))
    }

    // The new state. A new mode goes to onChange. At the end of a change, the waiting request
    // starts.
    private func settle(_ next: State) {
        let old = mode
        state = next
        if mode != old { onChange?(mode) }
        guard !isChanging, let request = waiting else { return }
        waiting = nil
        start(request)
    }
}
