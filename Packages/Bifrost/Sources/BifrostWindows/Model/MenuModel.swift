import BifrostKeyboard
import BifrostLayout
import BifrostSettings

// The app menu as plain data: the menus, the items, the menu keys and the Zoom steps. MainMenu (the
// UI of the windows) builds the NSMenu from it. The app builds the menu again only after a change
// of a menu key. When the menu validates its items, the View items get their check mark from the
// display mode (isChecked), and an item that cannot act is grey (isEnabled).
//
// The Window menu has no item that closes the window: the key of Close Panel (Cmd+W) closes the
// active panel. The native app has no Reload item and no developer tools item.

// The steps of Zoom In, Zoom Out and Actual Size (docs/behaviour/shell.md).
public enum ZoomStep: Sendable {
    case zoomIn, zoomOut, reset
}

public struct MenuItemModel: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        // The app menu.
        case about, checkForUpdates, hide, hideOthers, showAll, quit
        // The Edit menu.
        case undo, redo, cut, copy, paste, selectAll
        // The View menu.
        case mode(DisplayMode), toggleFullScreen, zoom(ZoomStep)
        // The Window menu. zoomWindow is the Zoom item of macOS, not a step of the scale.
        case closePanel, minimize, zoomWindow
    }

    package var title: String
    package var action: Action
    // The key equivalent, or nil for no key.
    package var key: Chord?

    package init(title: String, action: Action, key: Chord? = nil) {
        self.title = title
        self.action = action
        self.key = key
    }
}

// What the menu reads when it opens: the display mode for the check marks, and what each Bifrost
// item can act on. The Human Interface Guidelines make an item that cannot act grey.
public struct MenuState: Sendable, Equatable {
    package var mode: DisplayMode
    // The window shows, so a mode item can change its mode.
    package var windowOpen: Bool
    // A frame that is not minimised shows, so Close Panel has a panel to close.
    package var panelShows: Bool
    // The settings store is open, so a Zoom item can save the Interface scale.
    package var settingsOpen: Bool
    // The updater can start a check.
    package var canCheckForUpdates: Bool

    package init(
        mode: DisplayMode, windowOpen: Bool, panelShows: Bool, settingsOpen: Bool,
        canCheckForUpdates: Bool
    ) {
        self.mode = mode
        self.windowOpen = windowOpen
        self.panelShows = panelShows
        self.settingsOpen = settingsOpen
        self.canCheckForUpdates = canCheckForUpdates
    }

    // The state of the app. With no layout (before the shell opens), no panel shows.
    public init(
        mode: DisplayMode, windowOpen: Bool, layout: WindowLayout?, settingsOpen: Bool,
        canCheckForUpdates: Bool
    ) {
        self.init(
            mode: mode, windowOpen: windowOpen, panelShows: layout?.topFrame != nil,
            settingsOpen: settingsOpen, canCheckForUpdates: canCheckForUpdates)
    }
}

extension MenuItemModel.Action {
    // True for the View item of the display mode: it shows a check mark.
    package func isChecked(in displayMode: DisplayMode) -> Bool {
        switch self {
        case .mode(let mode): mode == displayMode
        case .toggleFullScreen: displayMode == .fullscreen
        default: false
        }
    }

    // True when the item can act. The items of macOS always can.
    package func isEnabled(in state: MenuState) -> Bool {
        switch self {
        case .checkForUpdates: state.canCheckForUpdates
        case .mode, .toggleFullScreen: state.windowOpen
        case .zoom: state.settingsOpen
        case .closePanel: state.panelShows
        case .about, .hide, .hideOthers, .showAll, .quit, .undo, .redo, .cut, .copy, .paste,
            .selectAll, .minimize, .zoomWindow:
            true
        }
    }
}

package enum MenuEntry: Sendable, Equatable {
    case item(MenuItemModel), separator
}

public struct MenuModel: Sendable, Equatable {
    package struct Menu: Sendable, Equatable {
        package var title: String
        package var entries: [MenuEntry]

        package init(title: String, entries: [MenuEntry]) {
            self.title = title
            self.entries = entries
        }
    }

    // The Interface scale of the Zoom items: a step of 10 from 80 to 150 percent
    // (CanvasMetrics.scaleChoices).
    static let scaleStep = 10, scaleMin = 80, scaleMax = 150

    package var menus: [Menu]

    package init(menus: [Menu]) {
        self.menus = menus
    }

    // The menu for the app name and the key map. A slot with no key gives an item with no key.
    public static func make(appName: String, keys: KeyMap) -> MenuModel {
        MenuModel(menus: [
            Menu(title: appName, entries: appEntries(appName)),
            Menu(title: "Edit", entries: editEntries),
            Menu(title: "View", entries: viewEntries(keys)),
            Menu(title: "Window", entries: windowEntries(keys)),
        ])
    }

    // The Interface scale after a Zoom item. A step stays from 80 to 150 percent. Actual Size
    // gives the default scale.
    public static func zoomStep(_ scale: Int, _ step: ZoomStep) -> Int {
        switch step {
        case .reset: Settings().interfaceScale
        case .zoomIn: min(scaleMax, max(scaleMin, scale + scaleStep))
        case .zoomOut: min(scaleMax, max(scaleMin, scale - scaleStep))
        }
    }

    // MARK: - The menus

    private static func item(
        _ title: String, _ action: MenuItemModel.Action, _ key: Chord? = nil
    ) -> MenuEntry {
        .item(MenuItemModel(title: title, action: action, key: key))
    }

    // A key with Cmd, as macOS gives it to the item of the action.
    private static func cmd(_ key: Character, _ more: KeyEvent.Modifiers = []) -> Chord {
        Chord(more.union(.command), key: .character(key))
    }

    // The app menu of macOS, with Check for Updates.
    private static func appEntries(_ name: String) -> [MenuEntry] {
        [
            item("About \(name)", .about),
            item("Check for Updates…", .checkForUpdates),
            .separator,
            item("Hide \(name)", .hide, cmd("H")),
            item("Hide Others", .hideOthers, cmd("H", .option)),
            item("Show All", .showAll),
            .separator,
            item("Quit \(name)", .quit, cmd("Q")),
        ]
    }

    // The Edit menu of macOS, so Cmd+C and the other text keys work in each text box.
    private static let editEntries: [MenuEntry] = [
        item("Undo", .undo, cmd("Z")),
        item("Redo", .redo, cmd("Z", .shift)),
        .separator,
        item("Cut", .cut, cmd("X")),
        item("Copy", .copy, cmd("C")),
        item("Paste", .paste, cmd("V")),
        item("Select All", .selectAll, cmd("A")),
    ]

    // The three modes as radio items, then the Zoom items.
    private static func viewEntries(_ keys: KeyMap) -> [MenuEntry] {
        [
            item("Window", .mode(.window)),
            item("Borderless", .mode(.borderless)),
            item("Fullscreen", .toggleFullScreen, keys[.toggleFullscreen].chord),
            .separator,
            item("Zoom In", .zoom(.zoomIn), cmd("=")),
            item("Zoom Out", .zoom(.zoomOut), cmd("-")),
            item("Actual Size", .zoom(.reset)),
        ]
    }

    private static func windowEntries(_ keys: KeyMap) -> [MenuEntry] {
        [
            item("Close Panel", .closePanel, keys[.closePanel].chord),
            item("Minimize", .minimize, cmd("M")),
            item("Zoom", .zoomWindow),
        ]
    }
}
