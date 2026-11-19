import AppKit
import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostDictation
@testable import BifrostKeyboard
@testable import BifrostLayout
@testable import BifrostSettings
@testable import BifrostWindows

// The key commands of the window and of the rows. They change the layout and the selection, so
// each test checks the new state (docs/behaviour/keys.md, "Which shortcuts work today").
@Suite("key commands", .serialized, .timeLimit(.minutes(1)), .tags(.window))
@MainActor
struct KeyCommandsTests {
    static let s1 = "11111111-1111-4111-8111-111111111111"
    static let s2 = "22222222-2222-4222-8222-222222222222"
    static let s3 = "33333333-3333-4333-8333-333333333333"

    // The frames: f1 shows overview:1, and f2 (on top) has the tabs
    // selected-item and chat:S1, with the chat as the active tab. The rows are S1, S2 and S3,
    // and S2 is selected. The rows have one name, so the All tab of overview:1 shows them in the
    // order of the list.
    @MainActor
    private final class Parts {
        let folder: TemporaryFolder
        let model = WindowLayoutModel(layout: WindowLayout(bounds: LayoutSize(w: 1200, h: 800)))
        let store: UIStateStore
        let sideBar: SideBarModel
        let rows: FakeRowSource
        let selection: SelectionModel
        let overviews: OverviewPanels
        let commands: KeyCommands
        var opened: [String] = []
        var menu: [MenuItemModel.Action] = []

        static let f1 = SavedFrame(
            panels: [panel("overview:1")], active: panel("overview:1"),
            rect: rect(0, 0, 100, 100), minimised: false, locked: false)
        static let f2 = SavedFrame(
            panels: [panel("selected-item"), panel("chat:\(s1)")], active: panel("chat:\(s1)"),
            rect: rect(0, 0, 100, 100), minimised: false, locked: false)

        init(frames: [SavedFrame] = [f1, f2]) async throws {
            let rows = FakeRowSource()
            self.rows = rows
            let list = SessionListModel.reading(rows)
            selection = SelectionModel(list: list)
            folder = try TemporaryFolder()
            store = await UIStateStore.open(
                file: folder.url.appending(path: "ui-state.json"), clock: ManualClock(),
                log: Recorder<StoreEvent>())
            sideBar = SideBarModel(layout: model, store: store)
            overviews = .test(store: store, sessions: list, selection: selection, layout: model)
            model.apply(.load(LayoutSnapshot(frames: frames, memory: [:])))
            rows.apply(ids: [s1, s2, s3])
            selection.selectedId = s2
            // The two sinks record into this object after its init.
            var openSink: (String) -> Void = { _ in }
            var menuSink: (MenuItemModel.Action) -> Void = { _ in }
            commands = KeyCommands(
                layout: model, sideBar: sideBar, selection: selection, overviews: overviews,
                openChat: { openSink($0) }, menu: { menuSink($0) })
            openSink = { [unowned self] in self.opened.append($0) }
            menuSink = { [unowned self] in self.menu.append($0) }
        }

        func run(_ id: String) {
            commands.run(keySlot(id))
        }

        var top: LayoutFrame? { model.layout.topFrame }

        // The config of overview:1.
        var config: OverviewConfig { overviews.model.config(.overview(1)) }

        deinit { folder.remove() }
    }

    @Test
    func nextStackTabWraps() async throws {
        let p = try await Parts()
        p.run("next-stack-tab:mod")
        #expect(p.top?.active == panel("selected-item"))
        // The chat is the active tab again, so the previous tab wraps to selected-item too.
        p.model.apply(.activate(panel("chat:\(Self.s1)")))
        p.run("prev-stack-tab:mod")
        #expect(p.top?.active == panel("selected-item"))
        let one = try await Parts(frames: [Parts.f1])
        let before = one.model.layout
        one.run("next-stack-tab:mod")
        #expect(one.model.layout == before)
    }

    @Test
    func loadLayoutThreeGivesIndexTwo() async throws {
        let p = try await Parts()
        let only = SavedFrame(
            panels: [panel("watchlist")], active: panel("watchlist"),
            rect: rect(10, 10, 300, 200), minimised: false, locked: false)
        p.store.change { state in
            for name in ["one", "two", "three"] {
                _ = state.saveLayout(name, LayoutSnapshot(frames: [], memory: [:]))
            }
            _ = state.saveLayout("three", LayoutSnapshot(frames: [only], memory: [:]))
        }
        let sideBar = SideBarModel(layout: p.model, store: p.store)
        let commands = KeyCommands(
            layout: p.model, sideBar: sideBar, selection: p.selection, overviews: p.overviews,
            openChat: { _ in }, menu: { _ in })
        let slot = keySlot("load-layout.3:mod")
        commands.run(slot)
        #expect(p.model.layout.frames.map(\.panels) == [[panel("watchlist")]])
        // There is no layout at index 3, so load-layout.4 does nothing. The layout changes
        // first, so a load of the last layout in its place changes it back and fails the check.
        p.model.apply(.open(panel("settings")))
        let four = keySlot("load-layout.4:mod")
        let loaded = p.model.layout
        commands.run(four)
        #expect(p.model.layout == loaded)
        #expect(p.model.layout.frames.count == 2)
        let save = keySlot("save-layout:mod")
        commands.run(save)
        #expect(sideBar.popoverOpen)
        #expect(sideBar.popoverFocusRequest == 1)
        #expect(p.model.layout == loaded)
    }

    // The keys of the Event log and the Usage HUD open their panels. A panel that is open comes
    // to the front, and a minimised one comes back. The selection does not change.
    @Test func eventLogModAndUsageHudModOpenTheirPanels() async throws {
        let p = try await Parts()
        p.run("event-log:mod")
        #expect(p.top?.active == .eventLog)
        p.run("usage-hud:mod")
        #expect(p.top?.active == .usageHud)
        #expect(p.model.layout.frames.count == 4)
        p.run("event-log:mod")
        #expect(p.top?.active == .eventLog)
        let hud = try #require(p.model.layout.frame(of: .usageHud))
        p.model.apply(.minimise(hud.id))
        p.run("usage-hud:mod")
        #expect(p.top?.id == hud.id)
        #expect(p.top?.minimised == false)
        #expect(p.model.layout.frames.count == 4)
        #expect(p.selection.selectedId == Self.s2)
        #expect(p.opened.isEmpty)
    }

    @Test
    func focusOverviewGivesTheFocusedOverview() async throws {
        let p = try await Parts()
        p.run("focus-overview:mod")
        #expect(p.top?.active == panel("overview:1"))
        // No frame shows an Overview: overview:1 opens.
        let chat = try await Parts(frames: [Parts.f2])
        chat.run("focus-overview:mod")
        #expect(chat.top?.active == panel("overview:1"))
        #expect(chat.model.layout.frames.count == 2)
    }

    @Test
    func selectRowSelectsTheNthRow() async throws {
        let p = try await Parts()
        p.run("select-row.1:mod")
        #expect(p.selection.selectedId == Self.s1)
        p.run("select-row.3:mod")
        #expect(p.selection.selectedId == Self.s3)
        p.run("select-row.4:mod")
        #expect(p.selection.selectedId == Self.s3)
        // With no focused Overview, the row keys do nothing.
        let chat = try await Parts(frames: [Parts.f2])
        chat.run("select-row.1:mod")
        #expect(chat.selection.selectedId == Self.s2)
    }

    @Test
    func selectNextStopsAtTheLastRow() async throws {
        let p = try await Parts()
        p.selection.selectedId = nil
        p.run("select-next:key")
        #expect(p.selection.selectedId == Self.s1)
        p.run("select-next:key")
        #expect(p.selection.selectedId == Self.s2)
        p.selection.selectedId = Self.s3
        p.run("select-next:key")
        #expect(p.selection.selectedId == Self.s3)
        p.selection.selectedId = Self.s1
        p.run("select-prev:key")
        #expect(p.selection.selectedId == Self.s1)
        p.selection.selectedId = nil
        p.run("select-prev:mod")
        #expect(p.selection.selectedId == Self.s3)
    }

    @Test
    func aSessionCommandWithoutASelectionGivesNone() async throws {
        let p = try await Parts()
        p.selection.selectedId = nil
        p.run("open:key")
        #expect(p.opened.isEmpty)
    }

    // MARK: - New tests

    // The selection keeps no copy of the rows: it reads the owned rows from the session list
    // when a key asks. So a row that the list parks does not open, also before the view gives
    // the order of its rows again.
    @Test func aRowThatTheListParksDoesNotOpenAtOnce() async throws {
        let p = try await Parts()
        p.rows.apply(
            rows: [Self.s1, Self.s2, Self.s3].map {
                SessionRow.test(sessionId: $0, state: $0 == Self.s2 ? .parked : .idle)
            }, error: nil)
        p.run("open:key")
        #expect(p.opened.isEmpty)
    }

    // Open opens the chat of the selected row, and only of an owned row that is not parked. A
    // selected ID that is not in the rows gives no chat.
    @Test func openOpensTheChatOfTheSelectedOwnedRow() async throws {
        let p = try await Parts()
        p.run("open:key")
        p.run("open:mod")
        p.run("open:key2")
        #expect(p.opened == [Self.s2, Self.s2, Self.s2])
        p.rows.apply(ids: [Self.s1, Self.s2, Self.s3], owned: [Self.s1])
        p.run("open:key")
        p.selection.selectedId = "gone"
        p.run("open:key")
        #expect(p.opened == [Self.s2, Self.s2, Self.s2])
    }

    // The hold click of open:hold opens the chat of the clicked row and keeps the selection. The
    // other hold slots run through the action runner, and these parts have no runner.
    @Test func theHoldClickOfOpenOpensTheChatOfTheClickedRow() async throws {
        let p = try await Parts()
        let open = keySlot("open:hold")
        p.commands.runHold(open, row: Self.s3)
        #expect(p.opened == [Self.s3])
        #expect(p.selection.selectedId == Self.s2)
        let priority = keySlot("set-priority.4:hold")
        p.commands.runHold(priority, row: Self.s3)
        #expect(p.opened == [Self.s3])
    }

    // Close panel closes the active panel of the top frame. Toggle fullscreen runs the action of
    // the menu.
    @Test func theMenuSlotsCloseThePanelAndToggleTheFullScreen() async throws {
        let p = try await Parts()
        p.run("close-panel:mod")
        #expect(p.model.layout.frame(of: panel("chat:\(Self.s1)")) == nil)
        #expect(p.top?.panels == [panel("selected-item")])
        p.run("toggle-fullscreen:mod")
        #expect(p.menu == [.toggleFullScreen])
    }

    // Each slot that does not act in run(_:) changes nothing. The session keys and the keys of
    // the Event log and the Usage HUD act now, so 2 slots are left. The key layer gives Esc as an
    // intent, so the Esc slot does nothing here. The dictation slot also stays in the list: the
    // chat input reads its key, and run(_:) does nothing for it.
    @Test func aSlotOfALaterPhaseDoesNothing() async throws {
        let p = try await Parts()
        func actsNow(_ command: KeyCommand) -> Bool {
            switch command {
            case .escape, .dictation: false
            default: true
            }
        }
        let later = KeySlot.all.filter { !actsNow($0.command) }
        #expect(later.map(\.text) == ["escape:key", "dictation:hold"])
        let config = p.config
        let layout = p.model.layout
        for slot in later { p.commands.run(slot) }
        #expect(p.model.layout == layout)
        #expect(p.selection.selectedId == Self.s2)
        #expect(p.opened.isEmpty)
        #expect(p.menu.isEmpty)
        #expect(!p.sideBar.popoverOpen)
        #expect(p.config == config)
    }

    // With no action runner (the services did not find claude yet), no session key and no
    // global key acts: the layout, the selection and the side bar stay as they are.
    @Test func theSessionKeysNeedTheRunner() async throws {
        let p = try await Parts()
        p.rows.apply(ids: [Self.s1, Self.s2, Self.s3], owned: [Self.s1, Self.s2])
        let layout = p.model.layout
        for id in [
            "interrupt:mod", "interrupt:key", "stop:key", "copy-id:key", "show-info:mod",
            "send-message:mod", "rename:key", "new-session:mod", "resume-all:mod",
        ] {
            p.run(id)
        }
        p.commands.runHold(keySlot("interrupt:hold"), row: Self.s1)
        #expect(p.model.layout == layout)
        #expect(p.selection.selectedId == Self.s2)
        #expect(p.opened.isEmpty)
        #expect(p.menu.isEmpty)
    }

    // MARK: - The Overview keys

    // The rows S1, S2 and S3 with the names alpha, beta and gamma.
    static let named = [(s1, "alpha"), (s2, "beta"), (s3, "gamma")].map {
        SessionRow.test(sessionId: $0.0, name: $0.1)
    }

    // Shift+Tab (prev-overview-tab) activates the tab before the active tab of the focused
    // Overview, and wraps from the first tab to the last. Tab (next-overview-tab) wraps from the
    // last tab to the first. With no focused Overview, the tab keys do nothing.
    @Test func prevOverviewTabWrapsToTheLastTab() async throws {
        let p = try await Parts()
        let tabs = p.config.tabs.map(\.id)
        #expect(tabs.count == 6)
        #expect(p.config.active == tabs[0])
        p.run("prev-overview-tab:key")
        #expect(p.config.active == tabs[5])
        p.run("next-overview-tab:key")
        #expect(p.config.active == tabs[0])
        p.run("next-overview-tab:key")
        #expect(p.config.active == tabs[1])
        p.run("prev-overview-tab:key")
        #expect(p.config.active == tabs[0])
        // overview:1 is in no frame, so no Overview is focused.
        let chat = try await Parts(frames: [Parts.f2])
        chat.run("next-overview-tab:key")
        chat.run("prev-overview-tab:key")
        #expect(chat.config.active == tabs[0])
        #expect(chat.model.layout.frames.count == 1)
    }

    // With overview:1 only in a minimised frame, and then only as a back tab of a stack that
    // shows, no Overview is focused: the row keys and the tab keys do nothing. Focus Overview
    // still brings overview:1 back, and then the keys act on it.
    @Test func theKeysSkipAnOverviewThatDoesNotShow() async throws {
        let minimised = SavedFrame(
            panels: [panel("overview:1")], active: panel("overview:1"),
            rect: rect(0, 0, 100, 100), minimised: true, locked: false)
        let backTab = SavedFrame(
            panels: [panel("selected-item"), panel("overview:1")],
            active: panel("selected-item"), rect: rect(0, 0, 100, 100), minimised: false,
            locked: false)
        for frames in [[minimised, Parts.f2], [backTab]] {
            let p = try await Parts(frames: frames)
            let tab = p.config.active
            for id in [
                "select-row.1:mod", "select-next:key", "select-prev:key", "next-overview-tab:key",
                "prev-overview-tab:key",
            ] {
                p.run(id)
            }
            #expect(p.selection.selectedId == Self.s2)
            #expect(p.config.active == tab)
            p.run("focus-overview:mod")
            #expect(p.top?.active == .overview(1))
            #expect(p.top?.minimised == false)
            #expect(p.model.layout.frames.count == frames.count)
            p.run("select-row.1:mod")
            #expect(p.selection.selectedId == Self.s1)
            p.run("next-overview-tab:key")
            #expect(p.config.active != tab)
        }
    }

    // Focus Overview opens the focused Overview, else the top Overview of the side bar, else
    // overview:1, and its rows view then becomes the first responder.
    @Test func focusOverviewFocusesTheRowsOfTheTopOverview() async throws {
        let c = try await OverviewCanvas(rows: Self.named)
        defer { c.close() }
        let one = c.open("overview:1")
        let two = c.open("overview:2")
        c.layout.apply(.minimise(two))
        let settings = c.open("settings")
        #expect(c.window.firstResponder === c.window)
        // overview:1 is the active Overview of the highest frame that shows.
        c.run("focus-overview:mod")
        #expect(c.layout.layout.topFrame?.id == one)
        let rowsOne = try #require(c.rows(1))
        #expect(c.window.firstResponder === rowsOne)
        // No Overview is the active panel of a frame that shows: the top Overview of the side
        // bar comes back. overview:2 is a back tab of the frame of Settings, which shows, and
        // overview:1 is minimised.
        c.layout.apply(.minimise(one))
        c.layout.apply(.restore(two))
        c.layout.apply(.stack(two, onto: settings))
        c.layout.apply(.activate(panel("settings")))
        c.run("focus-overview:mod")
        #expect(c.layout.layout.topFrame?.id == settings)
        #expect(c.layout.layout.topFrame?.active == .overview(2))
        #expect(c.layout.layout.frame(of: .overview(1))?.minimised == true)
        let rowsTwo = try #require(c.rows(2))
        #expect(c.window.firstResponder === rowsTwo)
        // With no Overview in a frame, a new overview:1 opens, and its rows get the focus.
        c.layout.apply(.close(.overview(1)))
        c.layout.apply(.close(.overview(2)))
        c.run("focus-overview:mod")
        #expect(c.layout.layout.topFrame?.active == .overview(1))
        #expect(c.window.firstResponder === c.rows(1))
    }

    // The row keys use the rows of the active tab of the focused Overview, in the order of the
    // view: the Overview whose rows view is the first responder, else the active Overview of the
    // highest frame that shows.
    @Test func theRowKeysUseTheViewRowsOfTheFocusedOverview() async throws {
        let c = try await OverviewCanvas(rows: Self.named)
        defer { c.close() }
        c.open("overview:1")
        let two = c.open("overview:2")
        // overview:2 sorts by name, descending.
        let tab = c.model.config(.overview(2)).active
        c.model.update(.overview(2), .sortBy(tab, .name))
        let oneRows = c.model.viewRows(.overview(1)).map(\.sessionId)
        let twoRows = c.model.viewRows(.overview(2)).map(\.sessionId)
        #expect(oneRows == [Self.s1, Self.s2, Self.s3])
        #expect(twoRows == [Self.s3, Self.s2, Self.s1])
        // No rows view has the focus: the keys use overview:2, in the highest frame.
        c.run("select-row.1:mod")
        #expect(c.selection.selectedId == Self.s3)
        c.run("select-next:key")
        #expect(c.selection.selectedId == Self.s2)
        // The rows of overview:1 have the focus: the keys use overview:1, also below overview:2.
        let rowsOne = try #require(c.rows(1))
        rowsOne.focus()
        c.layout.apply(.focus(two))
        #expect(c.window.firstResponder === rowsOne)
        c.run("select-row.3:mod")
        #expect(c.selection.selectedId == Self.s3)
        c.run("select-next:key")
        #expect(c.selection.selectedId == Self.s3)
        c.run("select-row.1:mod")
        #expect(c.selection.selectedId == Self.s1)
        c.run("select-next:key")
        #expect(c.selection.selectedId == Self.s2)
        // The Tab key activates the next tab of overview:1, and the row keys use its rows. The
        // Alerts tab shows only the rows with a box, and these rows have none.
        c.run("next-overview-tab:key")
        #expect(c.model.config(.overview(1)).activeTab.name == "Alerts")
        #expect(c.model.config(.overview(2)).active == tab)
        c.run("select-row.1:mod")
        c.run("select-next:key")
        c.run("select-prev:key")
        #expect(c.selection.selectedId == Self.s2)
    }

    // A click on a tab or on Add tab of an Overview gives its rows the focus, so the Tab key and
    // the row keys then act on that Overview, not on the Overview whose rows had the focus.
    @Test func aTabBarActionFocusesTheRowsOfItsOverview() async throws {
        let c = try await OverviewCanvas(rows: Self.named)
        defer { c.close() }
        c.open("overview:1")
        c.open("overview:2")
        let rowsOne = try #require(c.rows(1))
        rowsOne.focus()
        let bar = try #require(c.tabBar(2))
        let tabs = bar.tabs.map(\.id)
        bar.tabs[1].activate()
        #expect(c.window.firstResponder === c.rows(2))
        c.send("Tab")
        #expect(c.model.config(.overview(2)).active == tabs[2])
        #expect(c.model.config(.overview(1)).active == tabs[0])
        // Add tab: the new tab is active, and the rows of overview:2 keep the focus.
        rowsOne.focus()
        bar.addButton.action()
        #expect(c.window.firstResponder === c.rows(2))
        c.send("Tab", [.shift])
        #expect(c.model.config(.overview(2)).active == tabs[5])
        #expect(c.model.config(.overview(1)).active == tabs[0])
    }

    // Esc reads Settings on the top frame. A minimised Settings is not on top.
    @Test func settingsOnTopReadsTheActivePanelOfTheTopFrame() async throws {
        let p = try await Parts()
        #expect(!p.commands.settingsOnTop)
        p.model.apply(.open(panel("settings")))
        #expect(p.commands.settingsOnTop)
        let settings = try #require(p.top?.id)
        p.model.apply(.minimise(settings))
        #expect(!p.commands.settingsOnTop)
        // The intent of the send box changes no layout: it only moves the focus.
        let layout = p.model.layout
        for intent in [EscapeIntent.none, .leaveSendBox] { p.commands.escape(intent) }
        #expect(p.model.layout == layout)
    }

    // Cmd+, opens Settings at the top. With Settings open behind another frame, or minimised, it
    // brings the frame to the front. A second key changes nothing.
    @Test func settingsModOpensSettings() async throws {
        let p = try await Parts()
        p.run("settings:mod")
        #expect(p.top?.active == panel("settings"))
        let frames = p.model.layout.frames.count
        p.run("settings:mod")
        #expect(p.model.layout.frames.count == frames)
        p.model.apply(.open(panel("watchlist")))
        p.run("settings:mod")
        #expect(p.top?.active == panel("settings"))
        let settings = try #require(p.top?.id)
        p.model.apply(.minimise(settings))
        p.run("settings:mod")
        #expect(p.top?.active == panel("settings"))
        #expect(p.top?.minimised == false)
        #expect(p.selection.selectedId == Self.s2)
    }

    // Cmd+F in a real window with Settings on top: with no key slot on Cmd+F, the Settings host
    // takes the key equivalent and moves the focus to the search field. With a slot on Cmd+F,
    // the host gives the key on, and the window key filter runs that slot.
    @Test func cmdFGoesToTheSearchOrToABifrostKeyOnCmdF() async throws {
        for slotOnCmdF in [false, true] {
            let p = try await Parts()
            let folder = try TemporaryFolder()
            defer { folder.remove() }
            let store = await SettingsStore.open(
                file: folder.url.appending(path: "settings.json"), log: Recorder<StoreEvent>())
            if slotOnCmdF {
                try await store.edit {
                    $0.keys = .object(["focus-overview:mod": .string("Mod+F")])
                }
            }
            let model = SettingsModel(store: store, layout: p.model)
            let panels = SettingsPanels()
            panels.attach(model)
            UITestApp.prepare()
            let window = BifrostWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.actsAsKey = true
            defer { window.close() }
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            window.contentView = content
            let body = try #require(panels.body(for: panel("settings")))
            body.frame = content.bounds
            content.addSubview(body)
            body.layoutSubtreeIfNeeded()
            let filter = WindowKeyFilter(
                window: window, commands: p.commands, selection: p.selection,
                keys: KeyMap(stored: store.settings.keys))
            model.open()
            #expect(p.commands.settingsOnTop)
            // The app offers a key with Cmd to the key equivalents first, then to the window.
            for down in [true, false] {
                guard
                    let event = USKeyboard.keyEvent(
                        down: down, id: "f", mods: [.meta], isRepeat: false, window: window)
                else { continue }
                if down && window.performKeyEquivalent(with: event) { continue }
                window.sendEvent(event)
            }
            let search = (body as? SettingsBody)?.host?.searchFieldView
            let editing = (window.firstResponder as? NSTextView)?.delegate as? NSTextField
            if slotOnCmdF {
                #expect(editing == nil)
                #expect(p.top?.active == panel("overview:1"))
            } else {
                #expect(editing != nil && editing === search)
                #expect(p.commands.settingsOnTop)
            }
            #expect(filter.isHolding == false)
        }
    }

    // Esc opens Settings and brings it to the front, and Esc on top of it closes it, through the
    // intents of the Esc rule. The window key filter gives the intents: with the window as the
    // first responder, Esc gets to the end of the responder chain.
    @Test func escOpensAndClosesSettings() async throws {
        let p = try await Parts()
        p.commands.escape(.openSettings)
        #expect(p.top?.active == panel("settings"))
        #expect(p.commands.settingsOnTop)
        p.commands.escape(.closeSettings)
        #expect(p.model.layout.frame(of: panel("settings")) == nil)
        // Through the window and its key filter.
        UITestApp.prepare()
        let window = BifrostWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.actsAsKey = true
        defer { window.close() }
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let filter = WindowKeyFilter(
            window: window, commands: p.commands, selection: p.selection, keys: KeyMap())
        func escape() {
            for down in [true, false] {
                guard
                    let event = USKeyboard.keyEvent(
                        down: down, id: "Escape", mods: [], isRepeat: false, window: window)
                else {
                    Issue.record("no Esc")
                    return
                }
                window.sendEvent(event)
            }
        }
        #expect(window.firstResponder === window)
        escape()
        #expect(p.commands.settingsOnTop)
        escape()
        #expect(p.model.layout.frame(of: panel("settings")) == nil)
        #expect(filter.isHolding == false)
    }

    // Esc in the send box gives up the focus of the send box: the window becomes the first
    // responder, the draft stays, and Settings does not open. The next Esc is in the other zone,
    // so it opens Settings.
    @Test func escLeavesTheSendBox() async throws {
        let p = try await Parts()
        let window = testWindow()
        defer { window.close() }
        let sendBox = NSTextView(frame: NSRect(x: 10, y: 10, width: 200, height: 100))
        sendBox.identifier = FocusMark.sendBox
        sendBox.string = "draft"
        window.contentView?.addSubview(sendBox)
        let filter = WindowKeyFilter(
            window: window, commands: p.commands, selection: p.selection, keys: KeyMap())
        #expect(window.makeFirstResponder(sendBox))
        let layout = p.model.layout
        press("Escape", in: window)
        #expect(window.firstResponder === window)
        #expect(sendBox.string == "draft")
        #expect(p.model.layout == layout)
        press("Escape", in: window)
        #expect(p.commands.settingsOnTop)
        #expect(filter.isHolding == false)
    }
}

// A window of 600 by 400 points that acts as the key window and is never ordered front, with an
// empty content view.
@MainActor
func testWindow() -> BifrostWindow {
    UITestApp.prepare()
    let window = BifrostWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.actsAsKey = true
    window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    return window
}

// Press and release a key in the window, as the app gives it: a key with Cmd goes to the key
// equivalents first, then to the window.
@MainActor
func press(
    _ id: String, _ mods: Set<USKeyboard.Mod> = [], in window: NSWindow,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    for down in [true, false] {
        guard
            let event = USKeyboard.keyEvent(
                down: down, id: id, mods: mods, isRepeat: false, window: window)
        else {
            Issue.record("No event for \(id).", sourceLocation: sourceLocation)
            return
        }
        if down && mods.contains(.meta) && window.performKeyEquivalent(with: event) { continue }
        window.sendEvent(event)
    }
}

// The session keys (docs/behaviour/keys.md, "Which shortcuts work today"): each one runs its
// action through the action runner, on the selected row, on the clicked row of a hold click, or
// with no row. The runner runs on fake deps (ActionsHarness): no test runs a program, opens an
// app or signals a process.
@Suite("the session keys", .serialized, .timeLimit(.minutes(1)), .tags(.window))
@MainActor
struct SessionKeyTests {
    // The key commands on the parts of the harness, with its runner.
    @MainActor
    private final class Keys {
        let h: ActionsHarness
        let commands: KeyCommands

        init(active: [AgentEntry] = [], all: [AgentEntry] = [], store: RegistryStore = .init())
            async throws
        {
            let h = try await ActionsHarness(store: store, active: active, all: all)
            self.h = h
            let overviews = OverviewPanels.test(
                store: h.store, sessions: h.list, selection: h.selection, layout: h.layout)
            commands = KeyCommands(
                layout: h.layout, sideBar: SideBarModel(layout: h.layout, store: h.store),
                selection: h.selection, overviews: overviews,
                openChat: { [layout = h.layout] in layout.openChat($0) },
                menu: { _ in })
            commands.runner = h.runner
        }

        func run(_ id: String) {
            commands.run(keySlot(id))
        }

        func hold(_ id: String, row: String) {
            commands.runHold(keySlot(id), row: row)
        }
    }

    // The action and the choice of each session key. Set priority 0 gives no priority, and Open
    // project gives the default app, or no action with no default app.
    @Test func eachSessionKeyGivesItsActionAndChoice() {
        func action(_ id: String, app: ProjectAppID? = .zed) -> KeyAction? {
            KeyCommands.sessionAction(keySlot(id).command, defaultApp: app)
        }
        let plain: [(String, ActionID)] = [
            ("send-message:mod", .sendMessage), ("send-message:key", .sendMessage),
            ("run-slash:mod", .runSlash), ("run-slash:key", .runSlash),
            ("interrupt:mod", .interrupt), ("interrupt:key", .interrupt),
            ("show-info:mod", .showInfo), ("show-info:key", .showInfo),
            ("copy-id:mod", .copyId), ("copy-id:key", .copyId),
            ("open-in-terminal:mod", .openInTerminal), ("open-in-terminal:key", .openInTerminal),
            ("take-control:mod", .takeControl), ("take-control:key", .takeControl),
            ("resume:mod", .resume), ("rename:key", .rename), ("stop:mod", .stop),
            ("stop:key", .stop), ("delete:mod", .delete), ("delete:key", .delete),
        ]
        for (id, expected) in plain {
            #expect(action(id) == KeyAction(id: expected, arg: nil), "\(id)")
        }
        for number in 1...5 {
            let priority = MenuArg.priority(SessionPriority(rawValue: number))
            for variant in ["mod", "key", "hold"] {
                let id = "set-priority.\(number):\(variant)"
                #expect(action(id) == KeyAction(id: .setPriority, arg: priority), "\(id)")
            }
        }
        for id in ["set-priority.0:mod", "set-priority.0:key"] {
            #expect(action(id) == KeyAction(id: .setPriority, arg: .priority(nil)), "\(id)")
        }
        for id in ["open-project:mod", "open-project:key"] {
            #expect(action(id) == KeyAction(id: .openProject, arg: .app(.zed)), "\(id)")
            #expect(action(id, app: nil) == nil, "\(id)")
        }
        // The global keys, Open and the window keys are no session action of a row.
        for id in ["new-session:mod", "resume-all:mod", "open:key", "select-row.1:mod"] {
            #expect(action(id) == nil, "\(id)")
        }
    }

    // A session key runs on the row that is selected at the press, read by its ID then.
    @Test func aSessionKeyActsOnTheSelectedRow() async throws {
        let k = try await Keys(active: [Entry.running(s1), Entry.running(s2)])
        let h = k.h
        h.selection.selectedId = s1
        k.run("set-priority.2:mod")
        await h.settle()
        h.selection.selectedId = s2
        k.run("set-priority.5:key")
        await h.settle()
        #expect(h.row(s1)?.priority == .p2)
        #expect(h.row(s2)?.priority == .p5)
        k.run("set-priority.0:mod")
        await h.settle()
        #expect(h.row(s2)?.priority == nil)
        #expect(h.row(s1)?.priority == .p2)
        k.run("copy-id:key")
        await h.settle()
        #expect(h.clipboard.texts == [s2])
        k.run("show-info:mod")
        let s2Session = try #require(SessionID(s2))
        #expect(h.layout.layout.topFrame?.active == .showInfo(s2Session))
        k.run("send-message:key")
        k.run("run-slash:mod")
        #expect(
            h.sendBoxFocuses == [
                SendBoxFocus(session: s2, slash: false), SendBoxFocus(session: s2, slash: true),
            ])
        k.run("rename:key")
        let rename = try h.renameDialog()
        rename.cancel()
        #expect(!h.dialogs.isOpen)
        #expect(h.runner.error == nil)
    }

    // A session key with no selection, or with a selected ID that is not in the rows, runs
    // nothing.
    @Test func aSelectedIdThatIsNotInTheRowsGivesNone() async throws {
        let k = try await Keys(active: [Entry.running(s1)])
        let h = k.h
        for selected in [nil, s3, "gone"] {
            h.selection.selectedId = selected
            for id in [
                "copy-id:key", "set-priority.1:key", "rename:key", "stop:key", "delete:mod",
                "show-info:key", "send-message:mod", "interrupt:key",
            ] {
                k.run(id)
            }
        }
        #expect(h.runner.lastTask == nil)
        #expect(!h.dialogs.isOpen)
        #expect(h.sendBoxFocuses.isEmpty)
        #expect(h.clipboard.texts.isEmpty)
        #expect(h.layout.layout.frames.isEmpty)
        #expect(h.calls.all.isEmpty)
    }

    // Open project opens the folder in the default project app: the app of the settings when it
    // is installed, else VS Code, then Zed. Finder alone gives no action. A failed open shows its
    // reason in the error line.
    @Test func openProjectUsesTheDefaultProjectApp() async throws {
        let k = try await Keys(active: [Entry.running(s1)])
        let h = k.h
        func app(_ id: ProjectAppID) -> InstalledApp {
            InstalledApp(app: ProjectApp(id: id, label: id.name), path: "/Apps/\(id.name).app")
        }
        h.selection.selectedId = s1
        h.values.apps = [app(.finder)]
        k.run("open-project:key")
        #expect(h.runner.lastTask == nil)
        h.values.apps = [app(.finder), app(.zed), app(.vscode)]
        k.run("open-project:key")
        await h.settle()
        h.values.settings.projectApp = .zed
        k.run("open-project:mod")
        await h.settle()
        #expect(
            h.opener.calls == [
                .open(file: "/p", app: "/Apps/VS Code.app"),
                .open(file: "/p", app: "/Apps/Zed.app"),
            ])
        h.opener.failure = .unknownApp
        k.run("open-project:key")
        await h.settle()
        #expect(h.runner.error == ActionRefusal.unknownApp.message)
    }

    // Each Interrupt key goes through the runner: Cmd+., X and the X hold each start a run, and
    // each run types the Esc of the interrupt into the session. The session input types an
    // Interrupt only 1.5 s or more after the last Esc (SessionInput.interruptGap), because two
    // Esc open the rewind menu. So the clock moves 1.5 s after each run.
    @Test func theInterruptKeysRunThroughTheRunner() async throws {
        let k = try await Keys(active: [Entry.running(s1)])
        let h = k.h
        try await h.quietChat(s1, shortId: short1)
        h.selection.selectedId = s1
        var runs: Set<Task<Void, Never>> = []
        for id in ["interrupt:mod", "interrupt:key", "interrupt:hold"] {
            if id.hasSuffix(":hold") { k.hold(id, row: s1) } else { k.run(id) }
            let run = try #require(h.runner.lastTask, "\(id)")
            runs.insert(run)
            await h.drive(run)
            h.inputClock.advance(by: .milliseconds(1500))
        }
        #expect(runs.count == 3)
        #expect(h.typed.filter { $0 == "\u{1B}" }.count == 3)
        #expect(h.runner.error == nil)
    }

    // Cmd+. in a chat window: the focus in the chat selects the row of its session, and the key
    // then interrupts that session through the window key filter and the runner. The other row
    // was selected before the focus.
    @Test func theInterruptKeyActsOnTheFocusedChat() async throws {
        let k = try await Keys(active: [Entry.running(s1), Entry.running(s2)])
        let h = k.h
        try await h.quietChat(s1, shortId: short1)
        h.selection.selectedId = s2
        let window = BifrostWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.actsAsKey = true
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = content
        let filter = WindowKeyFilter(
            window: window, commands: k.commands, selection: h.selection,
            keys: KeyMap([.dictation: .off]))
        let host = TerminalHost(
            state: GateState(), holdTime: ChatInput.holdTime, clock: ManualClock())
        host.view.sessionId = s1
        content.addSubview(host.view)
        #expect(window.makeFirstResponder(host.view))
        #expect(h.selection.selectedId == s1)
        for down in [true, false] {
            guard
                let event = USKeyboard.keyEvent(
                    down: down, id: ".", mods: [.meta], isRepeat: false, window: window)
            else { continue }
            if down && window.performKeyEquivalent(with: event) { continue }
            window.sendEvent(event)
        }
        let run = try #require(h.runner.lastTask)
        await h.drive(run)
        #expect(h.typed == "\u{1B}")
        #expect(h.runner.error == nil)
        #expect(filter.isHolding == false)
    }

    // Stop and Delete ask first. While the confirmation shows, a second press opens no second
    // dialog and runs nothing, and no other session key or global key acts. Cancel runs no
    // command.
    @Test func theStopAndDeleteKeysAskFirst() async throws {
        let k = try await Keys(active: [Entry.running(s1, status: .busy)])
        let h = k.h
        h.selection.selectedId = s1
        for id in ["stop:key", "delete:key"] {
            k.run(id)
            let model = try await h.confirmation()
            let task = h.runner.lastTask
            for other in [id, "set-priority.2:key", "copy-id:key", "new-session:mod"] {
                k.run(other)
            }
            guard case .confirm(let shown) = h.dialogs.dialog else {
                Issue.record("The confirmation of \(id) went.")
                return
            }
            #expect(shown === model, "\(id)")
            #expect(h.runner.lastTask == task, "\(id)")
            model.cancel()
            await h.settle()
            #expect(!h.dialogs.isOpen, "\(id)")
        }
        #expect(h.row(s1)?.priority == nil)
        #expect(h.clipboard.texts.isEmpty)
        #expect(h.calls.claudeRuns.isEmpty)
        #expect(h.runner.notice == nil)
    }

    // A hold click runs the hold action on the clicked row, and the click does not select it.
    @Test func aHoldClickActsOnTheClickedRow() async throws {
        let k = try await Keys(active: [Entry.running(s1), Entry.running(s2)])
        let h = k.h
        h.selection.selectedId = s1
        k.hold("set-priority.3:hold", row: s2)
        await h.settle()
        #expect(h.row(s2)?.priority == .p3)
        #expect(h.row(s1)?.priority == nil)
        k.hold("show-info:hold", row: s2)
        let s2Session = try #require(SessionID(s2))
        #expect(h.layout.layout.topFrame?.active == .showInfo(s2Session))
        k.hold("open:hold", row: s2)
        #expect(h.chatOpen(s2))
        #expect(h.selection.selectedId == s1)
        // A row that is not in the list gets nothing.
        k.hold("set-priority.1:hold", row: s3)
        #expect(h.row(s3) == nil)
        #expect(h.runner.error == nil)
    }

    // New session and Resume all need no row. New session opens its dialog, and Resume all
    // resumes the parked sessions that ran at the last close. With nothing to resume, Resume all
    // does nothing.
    @Test func theGlobalKeysRunWithNoRow() async throws {
        let k = try await Keys()
        k.h.selection.selectedId = nil
        k.run("resume-all:mod")
        #expect(k.h.runner.lastTask == nil)
        k.run("new-session:mod")
        let model = try k.h.newSessionDialog()
        model.cancel()
        #expect(!k.h.dialogs.isOpen)
        let parked = try await Keys(
            all: [Entry.stopped(s1)], store: RegistryStore(lastActive: [s1]))
        let h = parked.h
        let gate = TestGate()
        defer { gate.openAll() }
        h.calls.hold(gate)
        parked.run("resume-all:mod")
        await gate.waitUntilHolding(1)
        #expect(h.calls.claudeRuns == [["--bg", "--resume", s1]])
        #expect(h.runner.globalContext.resumeAllRunning)
    }

    // A key in a chat window acts on the selection. The focus in the chat selects its session,
    // and a later change of the selection moves the key to the new row. A plain key in the chat
    // goes to the terminal, not to the session keys.
    @Test func aSessionKeyInAChatWindowActsOnTheSelection() async throws {
        let k = try await Keys(active: [Entry.running(s1), Entry.running(s2)])
        let h = k.h
        let window = testWindow()
        defer { window.close() }
        let filter = WindowKeyFilter(
            window: window, commands: k.commands, selection: h.selection,
            keys: KeyMap([.dictation: .off]))
        let host = TerminalHost(
            state: GateState(), holdTime: ChatInput.holdTime, clock: ManualClock())
        host.view.sessionId = s1
        window.contentView?.addSubview(host.view)
        h.selection.selectedId = s2
        #expect(window.makeFirstResponder(host.view))
        #expect(h.selection.selectedId == s1)
        press("3", [.meta, .ctrl], in: window)
        await h.settle()
        #expect(h.row(s1)?.priority == .p3)
        h.selection.selectedId = s2
        press("4", [.meta, .ctrl], in: window)
        await h.settle()
        #expect(h.row(s2)?.priority == .p4)
        #expect(h.row(s1)?.priority == .p3)
        press("1", in: window)
        await h.settle()
        #expect(h.row(s2)?.priority == .p4)
        #expect(filter.isHolding == false)
    }
}
