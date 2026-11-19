// The main window of the app (docs/behaviour/shell.md, "The window and the menu"). The window is
// titled, closable, miniaturizable and resizable, at least 800 by 500, on the background colour,
// and macOS does not restore it. It opens at its saved place, shows as WindowShow gives, applies
// the saved display mode after the first show, and gives its normal bounds 500 ms after the last
// move or resize, at the end of a live resize and at a close. A full screen, the borderless mode
// and a zoomed window give no new normal bounds. A borderless window covers its screen again after
// a change of the screens.
//
// The window also holds the title, the release at a close and the occlusion state that tells the
// services if the window is visible.
import AppKit
import BifrostFoundation
import BifrostLayout
import BifrostLook

@MainActor
public final class ShellWindow: NSObject, NSWindowDelegate, DisplayModeWindow {
    // The style of the titled window.
    static let titledStyle: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
    // The presentation options of the borderless mode: a full screen with no space of its own.
    static let borderlessOptions: NSApplication.PresentationOptions = [
        .autoHideMenuBar, .autoHideDock,
    ]

    public let window: BifrostWindow
    public let modes: DisplayModeController
    // The normal bounds in the coordinates of the file, 500 ms after the last move or resize,
    // and at once at the end of a live resize and at a close.
    public var onBoundsChange: ((WindowBounds) -> Void)?
    // True when the window becomes visible, false when it stops being visible: closed,
    // minimised, hidden or fully covered (the occlusion state of macOS).
    public var onVisible: ((Bool) -> Void)?
    // True when the window becomes the key window, false when it stops being the key window.
    public var onKeyChange: ((Bool) -> Void)?
    // The window closes. The app detaches each chat and saves the layout. The sessions continue.
    public var onClose: (() -> Void)?
    // False before the first show and after a close.
    public private(set) var isOpen = false

    private let showKind: WindowShow.Show
    private let savedMode: DisplayMode
    private var shown = false
    // The frame of the normal window, in the coordinates of AppKit.
    private var normalFrame: NSRect
    private var borderless = false
    // From the start of the full screen to its end.
    private var inFullScreen = false
    private var sentVisible: Bool?
    // The save of the bounds after the last move or resize. A burst of moves makes one wait.
    private let boundsSave: Debouncer
    // While the window is borderless: the task that follows the changes of the screens.
    private var screenFollow: Task<Void, Never>?

    // The steps that a test replaces: the show of the window and the presentation options of the
    // app. A test never orders a window front and never changes the menu bar.
    var present: @MainActor (NSWindow, WindowShow.Show) -> Void = ShellWindow.presentWindow
    var setPresentation: @MainActor (NSApplication.PresentationOptions) -> Void = { options in
        NSApplication.shared.presentationOptions = options
    }

    // placement is the place of WindowPlacement.restore. mode is the saved mode: it applies after
    // the first show. show is the show of WindowShow. content fills the window.
    public init(
        title: String, placement: RestoredPlace, mode: DisplayMode, show: WindowShow.Show,
        content: NSView, clock: any Clock<Duration> = ContinuousClock()
    ) {
        window = BifrostWindow(
            contentRect: NSRect(
                x: 0, y: 0, width: WindowPlacement.minWidth, height: WindowPlacement.minHeight),
            styleMask: Self.titledStyle, backing: .buffered, defer: false)
        modes = DisplayModeController()
        showKind = show
        savedMode = mode
        boundsSave = Debouncer(clock: clock)
        normalFrame = .zero
        super.init()
        window.title = title
        // The app keeps the window. AppKit must not release it when it closes.
        window.isReleasedWhenClosed = false
        // AppKit does not save the state of this window. Thus a test run of the app writes no
        // saved application state to the real home folder.
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.backgroundColor = ThemeTokens.bg.nsColor
        window.minSize = NSSize(width: WindowPlacement.minWidth, height: WindowPlacement.minHeight)
        window.contentView = content
        place(placement)
        // The content lays out now at the size of the place, so the canvas has its size before
        // the owner applies the start layout.
        window.layoutIfNeeded()
        normalFrame = window.frame
        window.delegate = self
        modes.window = self
    }

    isolated deinit {
        screenFollow?.cancel()
    }

    // The height of the primary screen: the screen at the origin of AppKit, not NSScreen.main.
    package static func primaryScreenHeight() -> Double {
        Double(NSScreen.screens.first?.frame.height ?? 0)
    }

    // The work area of each screen in the coordinates of the file, for WindowPlacement.restore.
    public static func workAreas() -> [WindowBounds] {
        let height = primaryScreenHeight()
        return NSScreen.screens.map { screen in
            WindowPlacement.fileBounds(
                appKit: bounds(screen.visibleFrame), primaryScreenHeight: height)
        }
    }

    // The normal bounds in the coordinates of the file.
    public var normalBounds: WindowBounds {
        WindowPlacement.fileBounds(
            appKit: Self.bounds(normalFrame), primaryScreenHeight: Self.primaryScreenHeight())
    }

    // Show the window, at the start and at a reopen. The saved mode applies after the first show. A
    // test home does not apply a saved full screen.
    public func show() {
        isOpen = true
        present(window, showKind)
        sendVisibility()
        guard !shown else { return }
        shown = true
        if WindowShow.appliesSavedMode(savedMode, show: showKind) { modes.request(savedMode) }
    }

    // MARK: - The place

    // The saved bounds keep their top-left corner and get at least the minimum size of the window.
    // No saved bounds: the default size in the centre of the screen. macOS moves a window that is
    // taller than its screen at the show.
    private func place(_ placement: RestoredPlace) {
        switch placement {
        case .at(let saved):
            let bounds = WindowBounds(
                x: saved.x, y: saved.y, width: max(saved.width, WindowPlacement.minWidth),
                height: max(saved.height, WindowPlacement.minHeight))
            let frame = WindowPlacement.appKitFrame(
                bounds, primaryScreenHeight: Self.primaryScreenHeight())
            window.setFrame(
                NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height),
                display: false)
        case .centred(let width, let height):
            window.setFrame(NSRect(x: 0, y: 0, width: width, height: height), display: false)
            window.center()
        }
    }

    private static func bounds(_ rect: NSRect) -> WindowBounds {
        WindowBounds(
            x: Double(rect.origin.x), y: Double(rect.origin.y), width: Double(rect.width),
            height: Double(rect.height))
    }

    private static func presentWindow(_ window: NSWindow, _ show: WindowShow.Show) {
        switch show {
        case .normal:
            NSApplication.shared.activate()
            window.makeKeyAndOrderFront(nil)
        case .inactive:
            window.orderFrontRegardless()
        case .none:
            break
        }
    }

    // MARK: - The bounds

    public func windowDidMove(_ notification: Notification) {
        frameChanged()
    }

    public func windowDidResize(_ notification: Notification) {
        frameChanged()
    }

    // The end of a live resize saves the normal bounds at once.
    public func windowDidEndLiveResize(_ notification: Notification) {
        guard isNormal, boundsSave.isPending else { return }
        boundsSave.cancel()
        onBoundsChange?(normalBounds)
    }

    // True for the normal window: not borderless, not in a full screen, not minimised and not
    // zoomed.
    private var isNormal: Bool {
        !borderless && !inFullScreen && !window.isMiniaturized && !window.isZoomed
    }

    // A move or a resize of the normal window moves the save to 500 ms after it.
    private func frameChanged() {
        guard isNormal else { return }
        normalFrame = window.frame
        boundsSave.schedule(after: WindowPlacement.saveDelay) { [weak self] in
            guard let self else { return }
            onBoundsChange?(normalBounds)
        }
    }

    // MARK: - The display modes

    // AppKit changes the full screen only of a window that shows. A test window never shows, so
    // a test never gets a real full screen.
    package var canChangeFullScreen: Bool { window.isVisible && !window.isMiniaturized }

    private var isFullScreen: Bool { window.styleMask.contains(.fullScreen) }

    @discardableResult package func enterFullScreen() -> Bool {
        guard !isFullScreen else { return false }
        window.toggleFullScreen(nil)
        return true
    }

    @discardableResult package func exitFullScreen() -> Bool {
        guard isFullScreen else { return false }
        window.toggleFullScreen(nil)
        return true
    }

    // Borderless: no title bar, the frame of the screen of the window, no move, and the menu bar
    // and the Dock hide while the app is active. The window covers its screen again when it
    // moves to another screen and when the screens change (a new resolution, a display that
    // goes or comes, a new arrangement). Back: the titled window with its normal frame.
    package func setBorderless(_ on: Bool) {
        guard on != borderless else { return }
        let animate = window.isVisible
        if on {
            borderless = true
            window.styleMask = .borderless
            window.isMovable = false
            coverScreen(animate: animate)
            setPresentation(Self.borderlessOptions)
            followScreens()
        } else {
            screenFollow?.cancel()
            screenFollow = nil
            window.styleMask = Self.titledStyle
            window.isMovable = true
            window.setFrame(normalFrame, display: true, animate: animate)
            setPresentation([])
            borderless = false
        }
    }

    // The borderless window gets the frame of its screen.
    private func coverScreen(animate: Bool) {
        guard let screen = window.screen ?? NSScreen.screens.first, window.frame != screen.frame
        else { return }
        window.setFrame(screen.frame, display: true, animate: animate)
    }

    // A change of the screens has no delegate method, so one task follows the notification
    // while the window is borderless.
    private func followScreens() {
        let changes = NotificationCenter.default.notifications(
            named: NSApplication.didChangeScreenParametersNotification)
        screenFollow = Task { [weak self] in
            for await _ in changes {
                guard let self, borderless else { return }
                coverScreen(animate: false)
            }
        }
    }

    // The window moved to another screen.
    public func windowDidChangeScreen(_ notification: Notification) {
        guard borderless else { return }
        coverScreen(animate: false)
    }

    // The full-screen callbacks of AppKit go to the display modes. They come for each change:
    // the changes of the display modes, the green button and the Esc key.
    public func windowWillEnterFullScreen(_ notification: Notification) {
        inFullScreen = true
        modes.willEnterFullScreen()
    }

    public func windowDidEnterFullScreen(_ notification: Notification) {
        inFullScreen = true
        modes.didEnterFullScreen()
    }

    public func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        inFullScreen = false
        modes.didFailToEnterFullScreen()
    }

    public func windowWillExitFullScreen(_ notification: Notification) {
        modes.willExitFullScreen()
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        inFullScreen = false
        modes.didExitFullScreen()
    }

    public func windowDidFailToExitFullScreen(_ window: NSWindow) {
        modes.didFailToExitFullScreen()
    }

    // MARK: - The key state, the visibility and the close

    public func windowDidBecomeKey(_ notification: Notification) {
        onKeyChange?(true)
    }

    public func windowDidResignKey(_ notification: Notification) {
        onKeyChange?(false)
    }

    public func windowDidChangeOcclusionState(_ notification: Notification) {
        sendVisibility()
    }

    public func windowDidMiniaturize(_ notification: Notification) {
        send(false)
    }

    public func windowDidDeminiaturize(_ notification: Notification) {
        sendVisibility()
    }

    // A close saves the normal bounds at once.
    public func windowWillClose(_ notification: Notification) {
        isOpen = false
        boundsSave.cancel()
        onBoundsChange?(normalBounds)
        send(false)
        onClose?()
    }

    private func sendVisibility() {
        send(window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible))
    }

    // Sends a value only when it changes.
    private func send(_ visible: Bool) {
        if sentVisible == visible { return }
        sentVisible = visible
        onVisible?(visible)
    }
}

#if DEBUG
extension ShellWindow {
    // The task of the bounds save that waits, or nil.
    var boundsSaveTask: Task<Void, Never>? { boundsSave.task }
}
#endif

// The content of the window: the moving background behind all, the side bar on the left edge
// and the canvas to its right.
public final class ShellContentView: NSView {
    public let background: MetalBackground
    private let sideBar: NSView
    private let canvas: NSView

    // The width of the side bar in points: SideBarView.width layout units at the Interface scale.
    public var sideBarWidth = CGFloat(SideBarView.width) {
        didSet { needsLayout = true }
    }

    public init(sideBar: NSView, canvas: NSView) {
        background = MetalBackground(frame: .zero)
        self.sideBar = sideBar
        self.canvas = canvas
        super.init(frame: .zero)
        addSubview(background)
        addSubview(sideBar)
        addSubview(canvas)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override public func layout() {
        super.layout()
        let width = min(sideBarWidth, bounds.width)
        background.frame = bounds
        sideBar.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        canvas.frame = NSRect(x: width, y: 0, width: bounds.width - width, height: bounds.height)
    }
}
