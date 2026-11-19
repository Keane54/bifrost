// The NSMenu of the app from the menu model (MenuModel). The items of macOS (About,
// Hide, Quit, the Edit items, Minimize and Zoom) have the standard actions with no target, so they
// go to the first responder. The Bifrost items (Check for Updates, the modes, Fullscreen, the Zoom
// steps and Close Panel) go to the target with their action in the item. The target validates
// its items (NSMenuItemValidation) with validate(_:state:), so the View items show the mode and
// an item that cannot act is grey.
import AppKit
import BifrostKeyboard

// The target of the Bifrost items. MainMenu.action(of:) gives the action of the item.
@MainActor
@objc public protocol MainMenuTarget: AnyObject {
    func runMenuItem(_ sender: NSMenuItem)
}

// The two actions of the Edit menu that no AppKit class declares for Swift. The protocol only
// gives the selectors undo: and redo: (the actions of NSWindow and of the text views).
@MainActor
@objc private protocol UndoActions {
    func undo(_ sender: Any?)
    func redo(_ sender: Any?)
}

// The action of a Bifrost item, in its represented object.
@MainActor
private final class MenuAction: NSObject {
    let action: MenuItemModel.Action

    init(_ action: MenuItemModel.Action) {
        self.action = action
    }
}

@MainActor
public enum MainMenu {
    // The menu of the model. Each Bifrost item calls runMenuItem of the target.
    public static func build(_ model: MenuModel, target: any MainMenuTarget) -> NSMenu {
        let main = NSMenu(title: "Main Menu")
        for part in model.menus {
            let submenu = NSMenu(title: part.title)
            for entry in part.entries {
                switch entry {
                case .separator: submenu.addItem(.separator())
                case .item(let item): submenu.addItem(menuItem(item, target: target))
                }
            }
            let top = NSMenuItem(title: part.title, action: nil, keyEquivalent: "")
            top.submenu = submenu
            main.addItem(top)
        }
        return main
    }

    // The action of an item of build, or nil for another item.
    public static func action(of item: NSMenuItem) -> MenuItemModel.Action? {
        (item.representedObject as? MenuAction)?.action
    }

    // Gives an item of build its check mark for the display mode, and gives true when the item
    // can act. AppKit asks the target to validate the items each time that the menu opens and
    // before a key of the menu acts, so the menu does not build again for a new state. A key of
    // an item that cannot act goes on to the window.
    public static func validate(_ item: NSMenuItem, state: MenuState) -> Bool {
        guard let action = action(of: item) else { return true }
        item.state = action.isChecked(in: state.mode) ? .on : .off
        return action.isEnabled(in: state)
    }

    // Make the menu the main menu of the app.
    public static func install(_ menu: NSMenu) {
        registerDefaults()
        NSApplication.shared.mainMenu = menu
    }

    // The settings of macOS for the menu. The app calls this function before the launch ends
    // (applicationWillFinishLaunching), and install calls it too.
    // - macOS adds an Enter Full Screen item to a menu named View when no item has the
    //   toggleFullScreen: action. The View menu has its own Fullscreen item, so the app stops the
    //   item of macOS. The value does not go to the defaults file.
    // - No window tabs, so macOS adds no tab items to the menu.
    public static func registerDefaults() {
        UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    private static func menuItem(_ model: MenuItemModel, target: any MainMenuTarget) -> NSMenuItem {
        let item = NSMenuItem(
            title: model.title, action: selector(model.action),
            keyEquivalent: model.key?.keyEquivalent ?? "")
        item.keyEquivalentModifierMask = NSEvent.ModifierFlags(model.key?.modifiers ?? [])
        item.representedObject = MenuAction(model.action)
        if isBifrostAction(model.action) { item.target = target }
        return item
    }

    private static func isBifrostAction(_ action: MenuItemModel.Action) -> Bool {
        switch action {
        case .checkForUpdates, .mode, .toggleFullScreen, .zoom, .closePanel: true
        default: false
        }
    }

    // The standard action of each item of macOS. A Bifrost item runs runMenuItem.
    private static func selector(_ action: MenuItemModel.Action) -> Selector {
        switch action {
        case .about: #selector(NSApplication.orderFrontStandardAboutPanel(_:))
        case .hide: #selector(NSApplication.hide(_:))
        case .hideOthers: #selector(NSApplication.hideOtherApplications(_:))
        case .showAll: #selector(NSApplication.unhideAllApplications(_:))
        case .quit: #selector(NSApplication.terminate(_:))
        case .undo: #selector((any UndoActions).undo(_:))
        case .redo: #selector((any UndoActions).redo(_:))
        case .cut: #selector(NSText.cut(_:))
        case .copy: #selector(NSText.copy(_:))
        case .paste: #selector(NSText.paste(_:))
        case .selectAll: #selector(NSText.selectAll(_:))
        case .minimize: #selector(NSWindow.performMiniaturize(_:))
        case .zoomWindow: #selector(NSWindow.performZoom(_:))
        case .checkForUpdates, .mode, .toggleFullScreen, .zoom, .closePanel:
            #selector((any MainMenuTarget).runMenuItem(_:))
        }
    }
}
