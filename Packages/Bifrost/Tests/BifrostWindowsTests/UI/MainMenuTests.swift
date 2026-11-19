import AppKit
import BifrostFoundation
import BifrostLayout
import BifrostTestSupport
import Testing

@testable import BifrostKeyboard
@testable import BifrostWindows

// The NSMenu of MainMenu.build against the menu model and against the key map
// (docs/behaviour/keys.md, "What happens when you press a key"). The tests set the main menu of
// the test process. The process never becomes an active app, so no menu bar shows.

// The target of the Bifrost items: it records the action of each item that it gets. It
// validates the items as the app does, with its state. Each item can act by default.
@MainActor
private final class Target: NSObject, MainMenuTarget, NSMenuItemValidation {
    var actions: [MenuItemModel.Action] = []
    var state = MenuState(
        mode: .window, windowOpen: true, panelShows: true, settingsOpen: true,
        canCheckForUpdates: true)

    func runMenuItem(_ sender: NSMenuItem) {
        if let action = MainMenu.action(of: sender) { actions.append(action) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        MainMenu.validate(menuItem, state: state)
    }
}

// Each item of a menu and of its submenus, in order.
@MainActor
private func allItems(_ menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { item in [item] + (item.submenu.map(allItems) ?? []) }
}

@MainActor
private func name(_ selector: Selector?) -> String {
    selector.map(NSStringFromSelector) ?? ""
}

// The selector of each action. The Bifrost actions go to the target, and the others go to the
// first responder, as the standard items of a Mac app do.
@MainActor
private func expectedSelector(_ action: MenuItemModel.Action) -> String {
    switch action {
    case .about: "orderFrontStandardAboutPanel:"
    case .hide: "hide:"
    case .hideOthers: "hideOtherApplications:"
    case .showAll: "unhideAllApplications:"
    case .quit: "terminate:"
    case .undo: "undo:"
    case .redo: "redo:"
    case .cut: "cut:"
    case .copy: "copy:"
    case .paste: "paste:"
    case .selectAll: "selectAll:"
    case .minimize: "performMiniaturize:"
    case .zoomWindow: "performZoom:"
    case .checkForUpdates, .mode, .toggleFullScreen, .zoom, .closePanel: "runMenuItem:"
    }
}

@MainActor
private func mask(_ key: Chord?) -> NSEvent.ModifierFlags {
    NSEvent.ModifierFlags(key?.modifiers ?? [])
}

// The named keys of the key equivalents, back to their names.
@MainActor
private let keyNames: [String: String] = {
    var names: [String: String] = [
        " ": "Space", "\r": "Enter", "\t": "Tab", "\u{1B}": "Escape", "\u{8}": "Backspace",
        "\u{F700}": "ArrowUp", "\u{F701}": "ArrowDown", "\u{F702}": "ArrowLeft",
        "\u{F703}": "ArrowRight", "\u{F728}": "Delete", "\u{F729}": "Home", "\u{F72B}": "End",
        "\u{F72C}": "PageUp", "\u{F72D}": "PageDown",
    ]
    for number in 1...12 {
        if let scalar = Unicode.Scalar(0xF703 + UInt32(number)) {
            names[String(scalar)] = "F\(number)"
        }
    }
    return names
}()

// The key of an item as a binding in the standard form. An upper-case key equivalent means
// Shift, as in AppKit.
@MainActor
private func binding(of item: NSMenuItem) -> String? {
    let key = item.keyEquivalent
    let flags = item.keyEquivalentModifierMask
    var parts: [String] = []
    if flags.contains(.command) { parts.append("Mod") }
    if flags.contains(.control) { parts.append("Control") }
    if flags.contains(.option) { parts.append("Alt") }
    if flags.contains(.shift) || key != key.lowercased() { parts.append("Shift") }
    parts.append(keyNames[key] ?? key.uppercased())
    return Chord(parts.joined(separator: "+"))?.description
}

// The items that macOS adds to the Edit menu: Emoji & Symbols and Start Dictation. They stay. One
// hidden Emoji & Symbols item has the key Ctrl+Cmd+Space, which a custom binding can also have.
@MainActor
private func isSystemEditItem(_ item: NSMenuItem) -> Bool {
    ["orderFrontCharacterPalette:", "startDictation:"].contains(name(item.action))
}

// A seeded generator, so each run tests the same 200 maps (SplitMix64).
@MainActor
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@MainActor
private let randomKeys: [String] = {
    let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init)
    let digits = (0...9).map(String.init)
    let symbols = ["/", ".", ",", ";", "'", "[", "]", "-", "=", "`", "\\"]
    let named = [
        "Enter", "Tab", "Space", "Backspace", "Escape", "ArrowUp", "ArrowDown", "ArrowLeft",
        "ArrowRight", "Home", "End", "PageUp", "PageDown", "Delete",
    ]
    return letters + digits + symbols + named + (1...12).map { "F\($0)" }
}()

// A random stored keys value: some slots get a random binding or no key (null). The two menu
// slots change in about half of the maps. The value goes through the rules of the settings
// (KeyMap(stored:)), so it holds only bindings that the app accepts.
@MainActor
private func randomMap(_ random: inout SeededGenerator) -> KeyMap {
    var stored: [String: JSONValue] = [:]
    var slots = KeySlot.all.map(\.description)
    let menuSlots = [KeySlot.closePanel.description, KeySlot.toggleFullscreen.description]
    for slot in menuSlots where Bool.random(using: &random) { slots.append(slot) }
    for _ in 0..<Int.random(in: 1...40, using: &random) {
        guard let slot = slots.randomElement(using: &random) else { continue }
        if Int.random(in: 0..<10, using: &random) == 0 {
            stored[slot] = .null
            continue
        }
        var parts: [String] = []
        for modifier in ["Mod", "Control", "Alt", "Shift"] where Bool.random(using: &random) {
            parts.append(modifier)
        }
        parts.append(randomKeys.randomElement(using: &random) ?? "A")
        stored[slot] = .string(parts.joined(separator: "+"))
    }
    // The key of the hidden Emoji & Symbols item of macOS, so the maps hold it.
    if Int.random(in: 0..<4, using: &random) == 0 {
        stored["new-session:mod"] = .string("Mod+Control+Space")
    }
    return KeyMap(stored: .object(stored))
}

// A key down of the keyboard layout of the system, as a press of the key gives it. The event is
// not posted.
@MainActor
private func keyEvent(_ code: CGKeyCode, _ flags: CGEventFlags) -> NSEvent? {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) else {
        return nil
    }
    event.flags = flags
    return NSEvent(cgEvent: event)
}

// One turn of the run loop, so AppKit can add its items to the main menu.
@MainActor
private func runLoopTurn() {
    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
}

@Suite("main menu", .serialized, .testTimeLimit, .tags(.window))
@MainActor
struct MainMenuTests {
    // The test process ends its launch one time, so AppKit adds its items to the main menu as in
    // the app. The process stays a prohibited app: no Dock icon, no menu
    // bar and no activation.
    private static let launched: Bool = {
        UITestApp.prepare()
        NSApplication.shared.finishLaunching()
        return true
    }()

    init() {
        _ = Self.launched
    }

    @Test func theBuiltMenuMatchesTheModel() throws {
        let keys = KeyMap(
            stored: .object([
                KeySlot.closePanel.description: .string("Mod+Shift+W"),
                KeySlot.toggleFullscreen.description: .null,
            ]))
        let model = MenuModel.make(appName: "Bifrost Dev", keys: keys)
        let target = Target()
        let menu = MainMenu.build(model, target: target)
        #expect(menu.items.map(\.title) == model.menus.map(\.title))
        var custom: [(NSMenuItem, MenuItemModel.Action)] = []
        for (top, part) in zip(menu.items, model.menus) {
            let submenu = try #require(top.submenu)
            #expect(submenu.title == part.title)
            #expect(submenu.items.count == part.entries.count)
            for (item, entry) in zip(submenu.items, part.entries) {
                guard case .item(let expected) = entry else {
                    #expect(item.isSeparatorItem)
                    continue
                }
                #expect(item.title == expected.title)
                #expect(
                    item.keyEquivalent == (expected.key?.keyEquivalent ?? ""), "\(expected.title)")
                #expect(item.keyEquivalentModifierMask == mask(expected.key), "\(expected.title)")
                #expect(name(item.action) == expectedSelector(expected.action))
                #expect(MainMenu.action(of: item) == expected.action)
                if expectedSelector(expected.action) == "runMenuItem:" {
                    #expect(item.target === target)
                    custom.append((item, expected.action))
                } else {
                    #expect(item.target == nil)
                }
            }
        }
        #expect(custom.count == 8)
        // Each Bifrost item gives its action to the target.
        for (item, _) in custom {
            let run = #selector((any MainMenuTarget).runMenuItem(_:))
            #expect(NSApp.sendAction(run, to: target, from: item))
        }
        #expect(target.actions == custom.map(\.1))
    }

    // The menu builds only for a key change. Each update of the View menu (AppKit runs one when
    // the menu opens and before a key of the menu acts) asks the target, so the check mark
    // follows the display mode.
    @Test func theViewItemsShowTheModeWhenTheMenuUpdates() throws {
        let target = Target()
        let model = MenuModel.make(appName: "Bifrost Dev", keys: .defaults)
        let menu = MainMenu.build(model, target: target)
        let view = try #require(menu.item(withTitle: "View")?.submenu)
        let titles: [DisplayMode: String] = [
            .window: "Window", .borderless: "Borderless", .fullscreen: "Fullscreen",
        ]
        for mode in [DisplayMode.fullscreen, .window, .borderless, .fullscreen] {
            target.state.mode = mode
            view.update()
            let checked = view.items.filter { $0.state == .on }.map(\.title)
            #expect(checked == [titles[mode]], "\(mode)")
        }
        // The other menus have no check mark.
        for top in menu.items where top.title != "View" {
            let submenu = try #require(top.submenu)
            submenu.update()
            #expect(submenu.items.allSatisfy { $0.state == .off }, "\(top.title)")
        }
    }

    // An item that cannot act is grey when the menu updates, and its key does not run it: the
    // key goes on to the window. Here the window is closed and no panel shows.
    @Test func anItemThatCannotActIsGreyAndItsKeyDoesNotRunIt() throws {
        let target = Target()
        target.state.windowOpen = false
        target.state.panelShows = false
        let plain = try #require(keyEvent(13, []))
        try #require(
            plain.charactersIgnoringModifiers == "w",
            "The test needs a keyboard layout with W on the key code 13 (ANSI).")
        let model = MenuModel.make(appName: "Bifrost Dev", keys: .defaults)
        let menu = MainMenu.build(model, target: target)
        for top in menu.items { top.submenu?.update() }
        let bifrost = allItems(menu).filter { $0.target === target }
        let disabled = bifrost.filter { !$0.isEnabled }.map(\.title)
        #expect(disabled == ["Window", "Borderless", "Fullscreen", "Close Panel"])
        let close = try #require(keyEvent(13, [.maskCommand]))
        #expect(!menu.performKeyEquivalent(with: close))
        #expect(target.actions.isEmpty)
        target.state.panelShows = true
        let again = try #require(keyEvent(13, [.maskCommand]))
        #expect(menu.performKeyEquivalent(with: again))
        #expect(target.actions == [.closePanel])
    }

    // AppKit gives a key equivalent to the main menu before the key filter. So no item of the
    // main menu may use the key of a Bifrost binding, except the two menu slots (Close Panel and
    // Fullscreen), which have the key of their own slot (the section "How state flows" of the
    // architecture design). The test reads NSApp.mainMenu after one run-loop turn, with the items
    // that AppKit adds.
    @Test func noMenuItemUsesTheKeyOfABindingExceptTheTwoMenuSlots() throws {
        var random = SeededGenerator(state: 0x0006_5EED)
        var maps = [KeyMap.defaults]
        for _ in 0..<200 { maps.append(randomMap(&random)) }
        let target = Target()
        var checked = 0
        var slotKeys = 0
        var emojiKeys = 0
        for keys in maps {
            let model = MenuModel.make(appName: "Bifrost Dev", keys: keys)
            MainMenu.install(MainMenu.build(model, target: target))
            runLoopTurn()
            let menu = try #require(NSApp.mainMenu)
            let active = Set(keys.activeBindings.map(\.chord.description))
            if active.contains("Mod+Control+Space") { emojiKeys += 1 }
            for item in allItems(menu) where !item.keyEquivalent.isEmpty {
                // No binding has the Fn key.
                if item.keyEquivalentModifierMask.contains(.function) { continue }
                if isSystemEditItem(item) { continue }
                let text = try #require(binding(of: item), "\(item.title)")
                checked += 1
                switch MainMenu.action(of: item) {
                case .closePanel?:
                    slotKeys += 1
                    #expect(text == keys[.closePanel].chord?.description)
                case .toggleFullScreen?:
                    slotKeys += 1
                    #expect(text == keys[.toggleFullscreen].chord?.description)
                default:
                    #expect(!active.contains(text), "\(item.title) has \(text)")
                }
            }
        }
        // The maps test the rule: most maps keep a key on both menu slots, and some give a
        // binding the key of the hidden Emoji & Symbols item.
        #expect(checked > 201 * 12)
        #expect(slotKeys > 201)
        #expect(emojiKeys > 10)
    }

    // AppKit adds no full-screen item and no tab item: the View menu has its own Fullscreen item.
    @Test func theFullscreenItemIsTheOnlyFullScreenItem() throws {
        let model = MenuModel.make(appName: "Bifrost Dev", keys: .defaults)
        MainMenu.install(MainMenu.build(model, target: Target()))
        runLoopTurn()
        let items = allItems(try #require(NSApp.mainMenu))
        #expect(items.filter { $0.title == "Fullscreen" }.count == 1)
        #expect(!items.contains { $0.title.contains("Full Screen") })
        #expect(!items.contains { name($0.action) == "toggleFullScreen:" })
        let tabItems = [
            "Show Tab Bar", "Show All Tabs", "Move Tab to New Window", "Merge All Windows",
        ]
        #expect(!items.contains { tabItems.contains($0.title) })
        #expect(!NSWindow.allowsAutomaticWindowTabbing)
        // The registered value, not a missing key (a missing key also reads as false).
        let registered = UserDefaults.standard.object(forKey: "NSFullScreenMenuItemEverywhere")
        #expect(registered as? Bool == false)
    }

    // The app registers the defaults of the menu before the launch ends, with no menu yet. The
    // test removes the registered value first.
    @Test func theMenuDefaultsRegisterWithNoMenu() {
        let domain = UserDefaults.registrationDomain
        var registered = UserDefaults.standard.volatileDomain(forName: domain)
        registered.removeValue(forKey: "NSFullScreenMenuItemEverywhere")
        UserDefaults.standard.setVolatileDomain(registered, forName: domain)
        NSWindow.allowsAutomaticWindowTabbing = true
        #expect(UserDefaults.standard.object(forKey: "NSFullScreenMenuItemEverywhere") == nil)
        MainMenu.registerDefaults()
        let value = UserDefaults.standard.object(forKey: "NSFullScreenMenuItemEverywhere")
        #expect(value as? Bool == false)
        #expect(!NSWindow.allowsAutomaticWindowTabbing)
    }

    // A custom menu key of Shift and a symbol. Its key equivalent is "]"
    // with Shift. A press of Shift and ] gives the characters "}", and AppKit matches the key
    // with the keyboard layout, so the item gets the press.
    @Test func aShiftSymbolKeyOfAMenuSlotMatchesItsItem() throws {
        let plain = try #require(keyEvent(30, []))
        try #require(
            plain.charactersIgnoringModifiers == "]",
            "The test needs a keyboard layout with ] on the key code 30 (ANSI).")
        let keys = KeyMap(stored: .object([KeySlot.closePanel.description: .string("Mod+Shift+]")]))
        #expect(keys[.closePanel].chord?.description == "Mod+Shift+]")
        let target = Target()
        let menu = MainMenu.build(
            MenuModel.make(appName: "Bifrost Dev", keys: keys), target: target)
        MainMenu.install(menu)
        let press = try #require(keyEvent(30, [.maskCommand, .maskShift]))
        #expect(press.charactersIgnoringModifiers == "}")
        #expect(menu.performKeyEquivalent(with: press))
        #expect(target.actions == [.closePanel])
        // With the default key, the press is not a key of the menu. The press is a new event: an
        // event keeps the item that it matched, as each press of a key is a new event.
        let other = Target()
        let standard = MainMenu.build(
            MenuModel.make(appName: "Bifrost Dev", keys: .defaults), target: other)
        MainMenu.install(standard)
        let next = try #require(keyEvent(30, [.maskCommand, .maskShift]))
        #expect(!standard.performKeyEquivalent(with: next))
        #expect(other.actions.isEmpty)
    }
}
