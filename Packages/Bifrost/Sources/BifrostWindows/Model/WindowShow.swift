// How the main window shows at the start (docs/behaviour/shell.md, "The window and the menu"). A
// normal start shows the window and makes the app active. A test home shows the window without the
// focus and never takes it, so a key that the user types in another app during a smoke test never
// reaches the app. A headless test home (BIFROST_TEST_HEADLESS=1) shows no window and no Dock icon
// (user decision, 2026-11-13). The app then treats the window as visible and focused, as in a smoke
// test with a window that shows.
import BifrostLayout

public enum WindowShow {
    public enum Show: Sendable, Equatable {
        // Show the window in front and make the app active.
        case normal
        // Show the window in front of the other windows, with no activation and no focus.
        case inactive
        // Show no window.
        case none
    }

    // The variable of a headless test home.
    package static let headlessKey = "BIFROST_TEST_HEADLESS"

    // True for a headless test home: the variable is "1" and the start has a test home. The
    // headless parameters below take this value.
    public static func headless(testHome: Bool, environment: [String: String]) -> Bool {
        testHome && environment[headlessKey] == "1"
    }

    // How the window shows (showMainWindow). A start with no test home ignores the headless flag.
    public static func show(testHome: Bool, headless: Bool) -> Show {
        guard testHome else { return .normal }
        return headless ? .none : .inactive
    }

    // True when the app uses the accessory policy: no Dock icon and no menu bar, and macOS does
    // not make the app active at the start (hideFromDock).
    public static func accessory(testHome: Bool, headless: Bool) -> Bool {
        testHome && headless
    }

    // The visibility of the window for the poll of the sessions. A headless window counts as
    // visible, so the sessions poll at the normal interval.
    public static func seenVisible(_ visible: Bool, headless: Bool) -> Bool {
        headless || visible
    }

    // The focus of the window for the alerts. A headless window counts as focused, so no alert
    // notification starts.
    public static func seenFocused(_ focused: Bool, headless: Bool) -> Bool {
        headless || focused
    }

    // True when the alert of a start error makes the app active first, so the alert shows in
    // front. With a test home, the alert never takes the focus.
    public static func alertActivates(testHome: Bool) -> Bool {
        !testHome
    }

    #if DEBUG
    // True when the window acts as the key window while the app is not active: only with a test
    // home in a Debug build, so the test port can type into the window. A Release build does not
    // have this rule.
    public static func actsAsKey(testHome: Bool, debugBuild: Bool) -> Bool {
        testHome && debugBuild
    }
    #endif

    // True when the saved display mode applies after the first show. A show that is not normal
    // (a test home) does not apply a saved full screen: the native full screen moves the window
    // to its own space and shows it in front.
    package static func appliesSavedMode(_ mode: DisplayMode, show: Show) -> Bool {
        mode != .fullscreen || show == .normal
    }
}
