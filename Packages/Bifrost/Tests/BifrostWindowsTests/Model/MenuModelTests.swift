import BifrostKeyboard
import BifrostLayout
import BifrostLook
import BifrostSettings
import BifrostTestSupport
import BifrostWindows
import Testing

// The app menu as data: the menus, the items, their keys and the Zoom steps. The native app has
// no Reload item and no developer tools item. The key recorder comes in phase 4. The check marks
// of the View items come from the display mode when the menu validates its items
// (MainMenuTests). An item that cannot act is grey (isEnabled).

private func make(keys: KeyMap = .defaults) -> MenuModel {
    MenuModel.make(appName: "Bifrost", keys: keys)
}

private func entries(_ model: MenuModel, _ title: String) -> [MenuEntry] {
    model.menus.first { $0.title == title }?.entries ?? []
}

private func items(_ model: MenuModel, _ title: String) -> [MenuItemModel] {
    entries(model, title).compactMap { entry in
        if case .item(let item) = entry { return item }
        return nil
    }
}

private func allItems(_ model: MenuModel) -> [MenuItemModel] {
    model.menus.flatMap { items(model, $0.title) }
}

private func item(_ model: MenuModel, _ menu: String, _ title: String) -> MenuItemModel? {
    items(model, menu).first { $0.title == title }
}

// The key of a menu item as a binding text in the standard form.
private func binding(_ key: Chord) -> String {
    key.description
}

private func cmd(_ key: String) -> Chord {
    chord("Mod+\(key)")
}

// The View items that are radio items: the three modes.
private func isModeItem(_ item: MenuItemModel) -> Bool {
    switch item.action {
    case .mode, .toggleFullScreen: true
    default: false
    }
}

@Suite("menu")
struct MenuModelTests {
    // Only the item of the mode has a check mark.
    @Test
    func theItemOfTheModeIsChecked() {
        let titles: [DisplayMode: String] = [
            .window: "Window", .borderless: "Borderless", .fullscreen: "Fullscreen",
        ]
        let view = items(make(), "View")
        #expect(view.filter(isModeItem).map(\.title) == ["Window", "Borderless", "Fullscreen"])
        for mode in DisplayMode.allCases {
            let checked = allItems(make()).filter { $0.action.isChecked(in: mode) }
            #expect(checked.map(\.title) == [titles[mode]])
        }
    }

    @Test
    func theViewItemsCallTheHandlers() {
        let model = make()
        #expect(item(model, "View", "Window")?.action == .mode(.window))
        #expect(item(model, "View", "Borderless")?.action == .mode(.borderless))
        #expect(item(model, "View", "Fullscreen")?.action == .toggleFullScreen)
    }

    @Test
    func fullscreenHasItsKey() {
        let model = make()
        #expect(item(model, "View", "Fullscreen")?.key == cmd("Control+F"))
        #expect(item(model, "View", "Borderless")?.key == nil)
        #expect(item(model, "View", "Window")?.key == nil)
    }

    // The native menu has no action that closes the window. Cmd+W closes the active panel.
    @Test
    func closePanelHasCmdW() {
        let model = make()
        let close = item(model, "Window", "Close Panel")
        #expect(close?.key == cmd("W"))
        #expect(close?.action == .closePanel)
        #expect(allItems(model).filter { $0.key == cmd("W") }.map(\.title) == ["Close Panel"])
    }

    @Test
    func theMenuHasTheRoles() {
        let actions = allItems(make()).map(\.action)
        let needed: [MenuItemModel.Action] = [
            .about, .hide, .hideOthers, .showAll, .quit, .undo, .redo, .cut, .copy, .paste,
            .selectAll, .minimize, .zoomWindow,
        ]
        for action in needed {
            #expect(actions.contains(action), "\(action)")
        }
    }

    // The items with their own key are the Bifrost items. The items of macOS keep their keys
    // (Minimize keeps Cmd+M).
    @Test
    func noKeyThatMacOSKeeps() {
        let kept: Set<Chord> = Set(
            [
                "Mod+Tab", "Mod+Space", "Mod+M", "Mod+Alt+Escape", "Mod+Shift+3", "Mod+Shift+4",
                "Mod+Shift+5", "Mod+Shift+Q", "Mod+Shift+/", "Mod+Control+Q", "Control+Space",
            ].map { chord($0) })
        let own = allItems(make()).filter { item in
            switch item.action {
            case .checkForUpdates, .mode, .toggleFullScreen, .zoom, .closePanel: true
            default: false
            }
        }
        #expect(own.count == 8)
        for item in own {
            guard let key = item.key else { continue }
            #expect(!kept.contains(key), "\(item.title)")
        }
    }

    @Test
    func theMenuUsesTheKeyMap() {
        let model = make()
        #expect(item(model, "Window", "Close Panel")?.key == cmd("W"))
        #expect(item(model, "View", "Fullscreen")?.key == cmd("Control+F"))
        // A changed key in the settings gives a changed key equivalent.
        let changed = KeyMap(
            keyChanges(["close-panel:mod": "Mod+Shift+W", "toggle-fullscreen:mod": "Mod+Alt+F"]))
        let custom = make(keys: changed)
        #expect(item(custom, "Window", "Close Panel")?.key == cmd("Shift+W"))
        #expect(item(custom, "View", "Fullscreen")?.key == cmd("Alt+F"))
    }

    @Test
    func aClearedKeyGivesNoKey() {
        let keys = KeyMap([.closePanel: .off, .toggleFullscreen: .off])
        let model = make(keys: keys)
        let close = item(model, "Window", "Close Panel")
        let fullscreen = item(model, "View", "Fullscreen")
        #expect(close != nil)
        #expect(fullscreen != nil)
        #expect(close?.key == nil)
        #expect(fullscreen?.key == nil)
    }

    @Test("the View menu has Zoom In, Zoom Out and Actual Size, and they call the zoom action")
    func theZoomItems() {
        let model = make()
        let zoomIn = item(model, "View", "Zoom In")
        let zoomOut = item(model, "View", "Zoom Out")
        let actual = item(model, "View", "Actual Size")
        #expect(zoomIn?.key == cmd("="))
        #expect(zoomOut?.key == cmd("-"))
        #expect(actual != nil)
        #expect(actual?.key == nil)
        #expect([zoomIn, zoomOut, actual].map { $0?.action } == [
            .zoom(.zoomIn), .zoom(.zoomOut), .zoom(.reset),
        ])
    }

    @Test("zoom steps the scale by 10 from 80 to 150 and Actual Size is 100")
    func zoomStep() {
        #expect(MenuModel.zoomStep(100, .zoomIn) == 110)
        #expect(MenuModel.zoomStep(140, .zoomIn) == 150)
        #expect(MenuModel.zoomStep(150, .zoomIn) == 150)
        #expect(MenuModel.zoomStep(100, .zoomOut) == 90)
        #expect(MenuModel.zoomStep(90, .zoomOut) == 80)
        #expect(MenuModel.zoomStep(80, .zoomOut) == 80)
        #expect(MenuModel.zoomStep(130, .reset) == 100)
        #expect(MenuModel.zoomStep(80, .reset) == 100)
    }

    // Each key of the model is in the list: the native model gives the role items their keys.
    @Test
    func noKeyOfTheDefaultMap() {
        let renderer = Set(KeyMap.defaults.activeBindings.map { binding($0.chord) })
        let keys = allItems(make()).compactMap(\.key)
        let texts = Set(keys.map(binding))
        #expect(texts.count == keys.count)
        #expect(texts.contains("Mod+="))
        #expect(texts.contains("Mod+-"))
        for text in texts.sorted() {
            #expect(!renderer.contains(text), "\(text)")
        }
    }

    // The menus and their items in order, with the Check for Updates item.
    @Test func theMenuHasItsItemsInOrder() {
        let model = MenuModel.make(appName: "Bifrost Dev", keys: .defaults)
        func row(_ entry: MenuEntry) -> String {
            switch entry {
            case .separator: return "-"
            case .item(let item):
                let key = item.key.map { " [\(binding($0))]" } ?? ""
                return item.title + key
            }
        }
        #expect(model.menus.map(\.title) == ["Bifrost Dev", "Edit", "View", "Window"])
        #expect(
            entries(model, "Bifrost Dev").map(row) == [
                "About Bifrost Dev", "Check for Updates…", "-", "Hide Bifrost Dev [Mod+H]",
                "Hide Others [Mod+Alt+H]", "Show All", "-", "Quit Bifrost Dev [Mod+Q]",
            ])
        #expect(
            entries(model, "Edit").map(row) == [
                "Undo [Mod+Z]", "Redo [Mod+Shift+Z]", "-", "Cut [Mod+X]", "Copy [Mod+C]",
                "Paste [Mod+V]", "Select All [Mod+A]",
            ])
        #expect(
            entries(model, "View").map(row) == [
                "Window", "Borderless", "Fullscreen [Mod+Control+F]", "-", "Zoom In [Mod+=]",
                "Zoom Out [Mod+-]", "Actual Size",
            ])
        #expect(
            entries(model, "Window").map(row) == [
                "Close Panel [Mod+W]", "Minimize [Mod+M]", "Zoom",
            ])
    }

    // An item that cannot act is grey: a mode item and Fullscreen with the window closed, Close
    // Panel with no panel that shows, a Zoom item before the settings open, and Check for Updates
    // while the updater cannot check. The items of macOS always act.
    @Test func anItemThatCannotActIsDisabled() {
        let ready = MenuState(
            mode: .window, windowOpen: true, panelShows: true, settingsOpen: true,
            canCheckForUpdates: true)
        let actions = allItems(make()).map(\.action)
        #expect(actions.allSatisfy { $0.isEnabled(in: ready) })
        func disabled(_ change: (inout MenuState) -> Void) -> [MenuItemModel.Action] {
            var state = ready
            change(&state)
            return actions.filter { !$0.isEnabled(in: state) }
        }
        let modes: [MenuItemModel.Action] = [.mode(.window), .mode(.borderless), .toggleFullScreen]
        #expect(disabled { $0.windowOpen = false } == modes)
        #expect(disabled { $0.panelShows = false } == [.closePanel])
        let zoom: [MenuItemModel.Action] = [.zoom(.zoomIn), .zoom(.zoomOut), .zoom(.reset)]
        #expect(disabled { $0.settingsOpen = false } == zoom)
        #expect(disabled { $0.canCheckForUpdates = false } == [.checkForUpdates])
    }

    // Close Panel closes the active panel of the top frame that is not minimised. With no frame,
    // or with only minimised frames, no panel shows.
    @Test func noPanelShowsWithNoFrameOrOnlyMinimisedFrames() throws {
        func state(_ layout: WindowLayout?) -> MenuState {
            MenuState(
                mode: .window, windowOpen: true, layout: layout, settingsOpen: true,
                canCheckForUpdates: true)
        }
        #expect(!state(nil).panelShows)
        var layout = WindowLayout(bounds: LayoutSize(w: 1200, h: 800))
        #expect(!state(layout).panelShows)
        layout.apply(.open(panel("overview:1")))
        #expect(state(layout).panelShows)
        let frame = try #require(layout.frames.first)
        layout.apply(.minimise(frame.id))
        #expect(!state(layout).panelShows)
    }

    // The limits of the Zoom items are the limits of the Interface scale setting.
    @Test func theZoomLimitsAreTheScaleChoices() {
        #expect(MenuModel.zoomStep(150, .zoomIn) == CanvasMetrics.scaleChoices.last)
        #expect(MenuModel.zoomStep(80, .zoomOut) == CanvasMetrics.scaleChoices.first)
        #expect(MenuModel.zoomStep(120, .reset) == Settings().interfaceScale)
    }
}
