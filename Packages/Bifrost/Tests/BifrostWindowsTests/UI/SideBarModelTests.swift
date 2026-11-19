import AppKit
import BifrostFoundation
import BifrostTestSupport
import Observation
import SwiftUI
import Synchronization
import Testing

@testable import BifrostLayout
@testable import BifrostLook
@testable import BifrostSessions
@testable import BifrostSettings
@testable import BifrostWindows

// The side bar and the Layouts popover (docs/behaviour/windows.md, "The side bar and layouts").
@MainActor
@Suite("side bar", .serialized, .timeLimit(.minutes(1)), .tags(.window))
struct SideBarModelTests {
    // A layout model and a side bar model with a store in a new folder.
    @MainActor
    private final class Parts {
        let folder: TemporaryFolder
        let model = WindowLayoutModel(layout: WindowLayout(bounds: LayoutSize(w: 1200, h: 800)))
        let store: UIStateStore
        let sideBar: SideBarModel

        init() async throws {
            folder = try TemporaryFolder()
            store = await UIStateStore.open(
                file: folder.url.appending(path: "ui-state.json"), clock: ManualClock(),
                log: Recorder<StoreEvent>())
            sideBar = SideBarModel(layout: model, store: store)
        }

        func open(_ raw: String) -> FrameID {
            model.apply(.open(panel(raw)))
            guard let frame = model.layout.frame(of: panel(raw)) else {
                preconditionFailure("no frame for \(raw)")
            }
            return frame.id
        }

        deinit { folder.remove() }
    }

    // The Overview button focuses the top Overview that shows, then a minimised one. In a frame,
    // the active panel wins over the other tabs. With no Overview it opens overview:1.
    @Test func theOverviewButtonOpensTheTopOverview() async throws {
        let p = try await Parts()
        p.sideBar.openOverview()
        #expect(p.model.layout.topFrame?.active == panel("overview:1"))
        let two = p.open("overview:2")
        let three = p.open("overview:3")
        let settings = p.open("settings")
        p.model.apply(.minimise(three))
        p.sideBar.openOverview()
        // overview:2 is the top Overview that shows. overview:3 is higher but minimised.
        #expect(p.model.layout.topFrame?.id == two)
        p.model.apply(.minimise(two))
        p.model.apply(.minimise(p.model.layout.frame(of: panel("overview:1"))?.id ?? two))
        p.sideBar.openOverview()
        // No Overview shows. overview:1 went to the side bar last, but overview:2 is higher in
        // the z-order, so it comes back.
        #expect(p.model.layout.topFrame?.id == two)
        #expect(p.model.layout.frame(of: panel("overview:1"))?.minimised == true)
        // A stack with an Overview as a back tab: the open makes it the active tab.
        let five = p.open("overview:5")
        p.model.apply(.stack(five, onto: settings))
        p.model.apply(.activate(panel("settings")))
        p.model.apply(.focus(settings))
        p.sideBar.openOverview()
        #expect(p.model.layout.topFrame?.id == settings)
        #expect(p.model.layout.topFrame?.active == panel("overview:5"))
        #expect(
            SideBarModel.topOverview(p.model.layout.frames) == panel("overview:5"))
    }

    // New Overview opens the lowest Overview number with no frame. A minimised frame and a back
    // tab of a stack count as a frame, and a close frees the number of its Overview.
    @Test func newOverviewOpensTheLowestFreeNumber() async throws {
        let p = try await Parts()
        let view = SideBarView(model: p.sideBar, bodies: FakeBodies())
        #expect(p.sideBar.freeOverview == .overview(1))
        p.sideBar.openNewOverview()
        #expect(p.model.layout.topFrame?.active == .overview(1))
        view.newOverviewButton.action()
        #expect(p.model.layout.topFrame?.active == .overview(2))
        let three = p.open("overview:3")
        p.model.apply(.minimise(three))
        let settings = p.open("settings")
        let four = p.open("overview:4")
        p.model.apply(.stack(four, onto: settings))
        p.model.apply(.activate(panel("settings")))
        p.model.apply(.close(.overview(2)))
        #expect(p.sideBar.freeOverview == .overview(2))
        #expect(!view.newOverviewButton.disabled)
        p.sideBar.openNewOverview()
        #expect(p.model.layout.topFrame?.active == .overview(2))
        // overview:3 is minimised and overview:4 is a back tab, so overview:5 is the next.
        #expect(p.sideBar.freeOverview == .overview(5))
        #expect(p.model.layout.frame(of: .overview(3))?.minimised == true)
        #expect(p.model.layout.frame(of: .overview(4))?.active == panel("settings"))
    }

    // With a frame for each of the 99 Overviews, New Overview is off and does nothing. A close
    // turns it on again.
    @Test func newOverviewIsOffWhen99AreOpen() async throws {
        let p = try await Parts()
        let view = SideBarView(model: p.sideBar, bodies: FakeBodies())
        for number in PanelID.overviewNumbers { p.model.apply(.open(.overview(number))) }
        #expect(p.model.layout.frames.count == 99)
        #expect(p.sideBar.freeOverview == nil)
        #expect(view.newOverviewButton.disabled)
        let layout = p.model.layout
        p.sideBar.openNewOverview()
        view.newOverviewButton.action()
        #expect(p.model.layout == layout)
        p.model.apply(.close(.overview(42)))
        #expect(p.sideBar.freeOverview == .overview(42))
        #expect(!view.newOverviewButton.disabled)
    }

    // The panel buttons come after Selected Item, in the order of the Electron side bar (Service
    // status after the Usage HUD, then Reviews, Daily update, and Performance last), each with the
    // icon of its panel kind. A button opens its panel, brings it to the front when it is open,
    // and brings back its minimised frame.
    @Test func theSideBarHasThePanelButtonsInTheElectronOrder() async throws {
        let p = try await Parts()
        let view = SideBarView(model: p.sideBar, bodies: FakeBodies())
        let top =
            [view.overviewButton, view.newOverviewButton, view.selectedItemButton]
            + view.panelButtons
        #expect(
            top.map(\.id) == [
                "overview", "new-overview", "selected-item", "watchlist", "event-log", "usage-hud",
                "service-status", "reviews", "daily-update", "performance",
            ])
        #expect(
            top.map(\.label) == [
                "Overview", "New Overview", "Selected Item", "Watchlist", "Event log", "Usage HUD",
                "Service status", "Reviews", "Daily update", "Performance",
            ])
        #expect(view.panelButtons.map(\.tip) == view.panelButtons.map(\.label))
        #expect(
            view.panelButtons.map(\.icon) == [
                .eye, .scrollText, .gauge, .activity, .gitPullRequest, .messageSquareText,
                .heartPulse,
            ])
        #expect(view.panelButtons.allSatisfy { $0.dot == nil })
        let panels: [PanelID] = [
            .watchlist, .eventLog, .usageHud, .serviceStatus, .reviews, .dailyUpdate, .performance,
        ]
        for (button, panel) in zip(view.panelButtons, panels) {
            button.action()
            #expect(p.model.layout.topFrame?.active == panel)
        }
        #expect(p.model.layout.frames.count == 7)
        // An open panel comes to the front, and a minimised one comes back.
        view.panelButtons[0].action()
        #expect(p.model.layout.topFrame?.active == .watchlist)
        let hud = try #require(p.model.layout.frame(of: .usageHud))
        p.model.apply(.minimise(hud.id))
        view.panelButtons[2].action()
        #expect(p.model.layout.topFrame?.id == hud.id)
        #expect(p.model.layout.topFrame?.minimised == false)
        #expect(p.model.layout.frames.count == 7)
    }

    // A value that a test changes after a closure took it.
    @MainActor
    private final class Flag {
        var on = false
    }

    // The Reviews button shows its dot while a pull request waits for the user, with the reason
    // as its tooltip. The dot follows the value that the shell gives for the panel.
    @Test func theReviewsButtonShowsItsDotWhileAPullRequestWaits() async throws {
        let p = try await Parts()
        let waits = Flag()
        let sideBar = SideBarModel(
            layout: p.model, store: p.store,
            dot: { panel in
                panel == .reviews && waits.on
                    ? SideBarDot(text: SideBarView.reviewsAttention) : nil
            })
        let view = SideBarView(model: sideBar, bodies: FakeBodies())
        func reviews() -> SideBarButton? { view.panelButtons.first { $0.id == "reviews" } }
        #expect(reviews()?.dot == nil && reviews()?.tip == "Reviews")
        waits.on = true
        #expect(SideBarView.reviewsAttention == "Reviews - a pull request waits for you")
        #expect(reviews()?.dot == SideBarView.reviewsAttention)
        #expect(reviews()?.tip == SideBarView.reviewsAttention)
        #expect(reviews()?.label == "Reviews")
        #expect(view.panelButtons.filter { $0.dot != nil }.map(\.id) == ["reviews"])
    }

    // The Daily update button shows its dot while the marker of the Daily update shows, with
    // the text of the dot as its tooltip.
    @Test func theDailyUpdateButtonShowsItsDot() async throws {
        let p = try await Parts()
        let marker = Flag()
        let sideBar = SideBarModel(
            layout: p.model, store: p.store,
            dot: { panel in
                panel == .dailyUpdate && marker.on
                    ? SideBarDot(text: SideBarView.dailyUpdateAttention) : nil
            })
        let view = SideBarView(model: sideBar, bodies: FakeBodies())
        let daily = { view.panelButtons.first { $0.id == "daily-update" } }
        let plain = try #require(daily())
        #expect(plain.dot == nil)
        #expect(plain.tip == "Daily update")
        marker.on = true
        let marked = try #require(daily())
        #expect(marked.dot == "Daily update - Not sent yet")
        #expect(marked.tip == "Daily update - Not sent yet")
        #expect(marked.dotColour == ThemeTokens.textStrong)
        #expect(view.panelButtons.filter { $0.dot != nil }.map(\.id) == ["daily-update"])
        #expect(view.settingsButton.dot == nil)
    }

    // The Performance button shows the dot that the shell gives, in its colour, with its text as
    // the tooltip. With no dot, the tooltip is the label.
    @Test func thePerformanceButtonShowsTheDotInItsColour() async throws {
        let p = try await Parts()
        let dot = Flag()
        let warning = SideBarDot(text: "Performance - Warning", colour: ThemeTokens.ctxMid)
        let sideBar = SideBarModel(
            layout: p.model, store: p.store,
            dot: { $0 == .performance && dot.on ? warning : nil })
        let view = SideBarView(model: sideBar, bodies: FakeBodies())
        let plain = try #require(view.panelButtons.last)
        #expect(plain.id == "performance")
        #expect(plain.dot == nil)
        #expect(plain.tip == "Performance")
        dot.on = true
        let marked = try #require(view.panelButtons.last)
        #expect(marked.dot == "Performance - Warning")
        #expect(marked.tip == "Performance - Warning")
        #expect(marked.dotColour == ThemeTokens.ctxMid)
    }

    // The Selected Item button opens the Selected Item panel, or brings it to the front.
    @Test func theSelectedItemButtonOpensTheSelectedItem() async throws {
        let p = try await Parts()
        let view = SideBarView(model: p.sideBar, bodies: FakeBodies())
        let button = view.selectedItemButton
        #expect([button.label, button.tip] == ["Selected Item", "Selected Item"])
        #expect(button.icon == .crosshair)
        button.action()
        #expect(p.model.layout.topFrame?.active == .selectedItem)
        _ = p.open("settings")
        button.action()
        #expect(p.model.layout.topFrame?.active == .selectedItem)
        #expect(p.model.layout.frames.count == 2)
    }

    // New session and Resume all are the global buttons. Each has the state of the action model
    // and a tooltip with the title, and an off button gives its reason on a second line. The
    // labels follow the label set. A click on an off button does nothing. With no action runner,
    // both buttons are off.
    @Test func theGlobalButtonsHaveTheirStatesAndTooltips() async throws {
        let h = try await ActionsHarness(active: [Entry.running(s1)])
        let sideBar = SideBarModel(layout: h.layout, store: h.store)
        let view = SideBarView(model: sideBar, bodies: FakeBodies())
        #expect(view.globalButtons.map(\.tip) == ["New session", "Resume all"])
        #expect(view.globalButtons.map(\.disabled) == [true, true])
        sideBar.runner = h.runner
        let buttons = view.globalButtons
        #expect(buttons.map(\.id) == ["new-session", "resume-all"])
        #expect(buttons.map(\.icon) == [.squarePlus, .rotateCcw])
        #expect(buttons.map(\.iconSize) == [15, 15])
        #expect(buttons.map(\.label) == ["New session", "Resume all"])
        let nothing = ActionReasons.nothingToResume
        #expect(buttons.map(\.tip) == ["New session", "Resume all\n\(nothing)"])
        #expect(buttons.map(\.disabled) == [false, true])
        buttons[1].action()
        #expect(h.runner.lastTask == nil)
        buttons[0].action()
        try h.newSessionDialog().cancel()
        #expect(!h.dialogs.isOpen)
        h.values.settings.labels = .space
        #expect(view.globalButtons.map(\.label) == ["Launch", "Reactivate all"])
        #expect(view.globalButtons.map(\.tip) == ["Launch", "Reactivate all\n\(nothing)"])
        // A parked session that ran at the last close turns Resume all on.
        let parked = try await ActionsHarness(
            store: RegistryStore(lastActive: [s1]), all: [Entry.stopped(s1)])
        let other = SideBarModel(layout: parked.layout, store: parked.store)
        other.runner = parked.runner
        let resume = SideBarView(model: other, bodies: FakeBodies()).globalButtons[1]
        #expect(!resume.disabled)
        #expect(resume.tip == "Resume all")
    }

    // The dialog layer covers only the canvas. So while a dialog shows, both global buttons are
    // off with no reason, and a click on them runs nothing. At the close of the dialog, they are
    // on again.
    @Test func theGlobalButtonsAreOffWhileADialogShows() async throws {
        let h = try await ActionsHarness(
            store: RegistryStore(lastActive: [s2]), active: [Entry.running(s1, status: .busy)],
            all: [Entry.stopped(s2)])
        let sideBar = SideBarModel(layout: h.layout, store: h.store)
        sideBar.runner = h.runner
        let view = SideBarView(model: sideBar, bodies: FakeBodies())
        #expect(view.globalButtons.map(\.disabled) == [false, false])
        h.runner.run(.stop, s1)
        let model = try await h.confirmation()
        let task = h.runner.lastTask
        let buttons = view.globalButtons
        #expect(buttons.map(\.disabled) == [true, true])
        #expect(buttons.map(\.tip) == ["New session", "Resume all"])
        for button in buttons { button.action() }
        sideBar.runGlobal(.resumeAll)
        guard case .confirm(let shown) = h.dialogs.dialog else {
            Issue.record("The confirmation went.")
            return
        }
        #expect(shown === model)
        #expect(h.runner.lastTask == task)
        #expect(!h.runner.globalContext.resumeAllRunning)
        model.cancel()
        await h.settle()
        #expect(view.globalButtons.map(\.disabled) == [false, false])
        #expect(h.calls.claudeRuns.isEmpty)
    }

    // The names compare with String equality, so the load finds the saved name also in the
    // other form of its accented letter.
    @Test func aSavedLayoutLoadsAndDeletes() async throws {
        let p = try await Parts()
        let first = p.open("settings")
        p.model.apply(.setRect(first, rect(10, 20, 300, 200)))
        let saved = p.model.layout.snapshot
        #expect(p.sideBar.saveLayout("  Caf\u{E9}  ") == .saved)
        #expect(p.sideBar.layoutNames == ["Caf\u{E9}"])
        #expect(p.store.state.layouts.map(\.name) == ["Caf\u{E9}"])
        p.model.apply(.close(panel("settings")))
        _ = p.open("watchlist")
        p.sideBar.loadLayout("Cafe\u{301}")
        #expect(p.model.layout.snapshot.frames == saved.frames)
        #expect(p.model.layout.frames.map(\.rect) == [rect(10, 20, 300, 200)])
        // A load of a name that is not there changes nothing.
        let layout = p.model.layout
        p.sideBar.loadLayout("Play")
        #expect(p.model.layout == layout)
        p.sideBar.deleteLayout("Cafe\u{301}")
        #expect(p.sideBar.layoutNames == [])
        #expect(p.store.state.layouts.isEmpty)
    }

    @Test func aBadNameAndAFullListGiveTheirResults() async throws {
        let p = try await Parts()
        _ = p.open("settings")
        #expect(p.sideBar.saveLayout("   ") == .badName)
        #expect(p.sideBar.saveLayout(String(repeating: "x", count: 41)) == .badName)
        #expect(p.sideBar.saveLayout(String(repeating: "x", count: 40)) == .saved)
        for number in 2...20 { #expect(p.sideBar.saveLayout("Layout \(number)") == .saved) }
        #expect(p.sideBar.layoutNames.count == 20)
        #expect(p.sideBar.saveLayout("One more") == .full)
        // A name that is in the list gets the new layout, also with a full list.
        #expect(p.sideBar.saveLayout("Layout 2") == .saved)
        #expect(p.sideBar.layoutNames.count == 20)
        #expect(LayoutPopover.message(for: .badName) == "Use 1 to 40 characters.")
        #expect(LayoutPopover.message(for: .full) == "Delete a layout first. The limit is 20.")
        #expect(LayoutPopover.message(for: .saved) == nil)
        // Cmd+Option+S opens the popover and asks for the focus of the name field each time.
        p.sideBar.openLayoutSave()
        p.sideBar.openLayoutSave()
        #expect(p.sideBar.popoverOpen)
        #expect(p.sideBar.popoverFocusRequest == 2)
    }

    @Test func theMinimisedFramesAreInZOrder() async throws {
        let p = try await Parts()
        let a = p.open("settings")
        let b = p.open("watchlist")
        let c = p.open("event-log")
        p.model.apply(.minimise(c))
        p.model.apply(.minimise(a))
        #expect(p.sideBar.minimised.map(\.id) == [a, c])
        p.model.apply(.focus(a))
        #expect(p.sideBar.minimised.map(\.id) == [c, a])
        p.sideBar.restore(c)
        #expect(p.sideBar.minimised.map(\.id) == [a])
        #expect(p.model.layout.topFrame?.id == c)
        #expect(p.model.layout.frames.map(\.id) == [b, a, c])
    }

    // MARK: - The tooltips

    // The side bar in a hosting view in a window that is never ordered front.
    @MainActor
    private final class Shown {
        let parts: Parts
        let window: NSWindow
        let view: SideBarView
        let host: NSHostingView<SideBarView>

        init(minimised: [String]) async throws {
            UITestApp.prepare()
            parts = try await Parts()
            for raw in minimised {
                let id = parts.open(raw)
                parts.model.apply(.minimise(id))
            }
            let bodies = FakeBodies()
            bodies.titles = [panel("settings"): "Settings", panel("watchlist"): "Watchlist"]
            view = SideBarView(model: parts.sideBar, bodies: bodies)
            host = NSHostingView(rootView: view)
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 40, height: 600), styleMask: [.borderless],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
        }

        // Each view below the hosting view.
        var views: [NSView] {
            var all: [NSView] = []
            var next: [NSView] = [host]
            while let view = next.popLast() {
                all.append(view)
                next += view.subviews
            }
            return all
        }

        // The tooltip anchors, from the top of the side bar to the bottom.
        var tips: [TipAnchorView] {
            views.compactMap { $0 as? TipAnchorView }.sorted {
                $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY
            }
        }

        func close() { window.close() }
    }

    @Test
    func theSideBarButtonsUseTipAtTheRight() async throws {
        let shown = try await Shown(minimised: ["settings", "watchlist"])
        defer { shown.close() }
        let tips = shown.tips
        #expect(
            tips.map(\.text) == [
                "Overview", "New Overview", "Selected Item", "Watchlist", "Event log",
                "Usage HUD", "Service status", "Reviews", "Daily update", "Performance",
                "New session", "Resume all", "Settings", "Watchlist", "Layouts", "Settings",
            ])
        #expect(tips.allSatisfy { $0.side == .right })
        #expect(tips.allSatisfy { TooltipController.shared.text(of: $0) == $0.text })
        #expect(shown.views.allSatisfy { $0.toolTip == nil })
    }

    // A keyboard focus on a side bar button opens its tooltip at once (focus-visible of base-ui),
    // and the end of the focus closes it.
    @Test func aKeyboardFocusOpensTheTooltip() async throws {
        let shown = try await Shown(minimised: [])
        defer { shown.close() }
        let anchor = try #require(shown.tips.first)
        #expect(!TooltipController.shared.watchesPresses)
        anchor.setFocused(true)
        #expect(TooltipController.shared.watchesPresses)
        anchor.setFocused(false)
        #expect(!TooltipController.shared.watchesPresses)
    }

    // A rename of the session of a minimised chat reaches its button. The title comes from the
    // rows of the session list, which reads them from the real registry service, and Observation
    // tracks that read, so no other signal is needed.
    @Test func aRenamedSessionShowsItsNewTitleOnTheMinimisedChat() async throws {
        let p = try await Parts()
        let id: SessionID = "73b5ca76-a4a8-4f97-9764-e41657296414"
        let entry = AgentEntry(
            sessionId: id.text, cwd: "/tmp", isBackground: true, name: "alpha", status: .idle,
            pid: 5, id: "73b5ca76")
        let registry = RegistryService(
            registry: SessionRegistry(store: RegistryStore(), escalation: .seconds(600)),
            deps: FixedRegistryDeps(active: [entry]), clock: ManualClock(),
            log: Recorder<SessionsLogEvent>())
        defer { registry.stop() }
        let list = SessionListModel()
        list.read(from: registry)
        registry.start()
        try #require(await waitUntil { list.loaded })
        let bodies = PanelBodiesHub(parts: [], look: PanelLook(), rows: { list.rows })
        p.model.apply(.open(.chat(id)))
        let frame = try #require(p.model.layout.frame(of: .chat(id)))
        p.model.apply(.minimise(frame.id))
        let view = SideBarView(model: p.sideBar, bodies: bodies)
        #expect(view.minimisedButtons.map(\.tip) == ["alpha"])
        let changes = Mutex(0)
        withObservationTracking {
            _ = view.minimisedButtons
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        #expect(registry.setAlias(id.text, "beta"))
        #expect(changes.withLock { $0 } == 1)
        #expect(view.minimisedButtons.map(\.tip) == ["beta"])
        #expect(view.minimisedButtons.map(\.label) == ["Restore beta"])
    }

    // The canvas follows the titles: a new title of an observed value shows in the frame of the
    // panel with no reload.
    @Test func aNewTitleShowsInTheFrameByItself() async {
        let f = CanvasFixture()
        defer { f.close() }
        let a = f.open("settings", at: rect(100, 100, 400, 300))
        #expect(f.view(a).accessibilityLabel() == "Settings")
        f.bodies.titles[panel("settings")] = "Preferences"
        await waitUntil { f.view(a).accessibilityLabel() == "Preferences" }
        #expect(f.view(a).accessibilityLabel() == "Preferences")
    }

    // A reload of the titles shows a new title in the frame of the panel.
    @Test func aReloadOfTheTitlesShowsTheNewTitleInTheFrame() {
        let f = CanvasFixture()
        defer { f.close() }
        let a = f.open("settings", at: rect(100, 100, 400, 300))
        #expect(f.view(a).accessibilityLabel() == "Settings")
        f.bodies.titles[panel("settings")] = "Preferences"
        f.canvas.reloadTitles()
        #expect(f.view(a).accessibilityLabel() == "Preferences")
    }

    @Test
    func theLayoutsButtonUsesTipAtTheRight() async throws {
        let shown = try await Shown(minimised: [])
        defer { shown.close() }
        let tips = shown.tips
        let layoutsTip = try #require(tips.dropLast().last)
        #expect(layoutsTip.text == "Layouts")
        #expect(layoutsTip.side == .right)
        #expect(shown.views.allSatisfy { $0.toolTip == nil })
        let layouts = shown.view.layoutsButton
        #expect([layouts.label, layouts.tip] == ["Layouts", "Layouts"])
        #expect(layouts.icon == .layoutGrid)
        layouts.action()
        #expect(shown.parts.sideBar.popoverOpen)
        layouts.action()
        #expect(!shown.parts.sideBar.popoverOpen)
        let overview = shown.view.overviewButton
        #expect([overview.label, overview.tip] == ["Overview", "Overview"])
        #expect(overview.icon == .list)
        let new = shown.view.newOverviewButton
        #expect([new.label, new.tip] == ["New Overview", "New Overview"])
        #expect(new.icon == .listPlus)
    }

    // The Settings button is the last button of the side bar. It opens Settings, or brings it to
    // the front.
    @Test func theSettingsButtonIsAtTheBottomAndOpensSettings() async throws {
        let shown = try await Shown(minimised: [])
        defer { shown.close() }
        let last = try #require(shown.tips.last)
        #expect(last.text == "Settings")
        #expect(last.side == .right)
        let settings = shown.view.settingsButton
        #expect([settings.label, settings.tip] == ["Settings", "Settings"])
        #expect(settings.icon == .settings)
        settings.action()
        let model = shown.parts.model
        #expect(model.layout.topFrame?.active == panel("settings"))
        model.apply(.open(panel("watchlist")))
        settings.action()
        #expect(model.layout.topFrame?.active == panel("settings"))
        #expect(model.layout.frames.count == 2)
    }

    @Test
    func aMinimisedFrameShowsAnIconButton() async throws {
        let shown = try await Shown(minimised: ["settings", "watchlist"])
        defer { shown.close() }
        #expect(
            shown.tips.map(\.text) == [
                "Overview", "New Overview", "Selected Item", "Watchlist", "Event log",
                "Usage HUD", "Service status", "Reviews", "Daily update", "Performance",
                "New session", "Resume all", "Settings", "Watchlist", "Layouts", "Settings",
            ])
        let buttons = shown.view.minimisedButtons
        #expect(buttons.map(\.label) == ["Restore Settings", "Restore Watchlist"])
        #expect(buttons.map(\.tip) == ["Settings", "Watchlist"])
        // The icon of the kind of the active panel.
        #expect(buttons.map(\.icon) == [.settings, .eye])
        // The button restores the frame.
        buttons.first?.action()
        #expect(shown.parts.sideBar.minimised.map { $0.active } == [panel("watchlist")])
    }

    @Test
    func theMinimisedIconHasNoNativeTitle() async throws {
        let shown = try await Shown(minimised: ["settings"])
        defer { shown.close() }
        #expect(shown.views.allSatisfy { $0.toolTip == nil })
        // The anchor of the tooltip takes no pointer input, so the button gets the press.
        let anchor = try #require(shown.tips.first { $0.text == "Settings" })
        #expect(anchor.hitTest(NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY)) == nil)
        #expect(!anchor.isAccessibilityElement())
        // The icon of each button has allowsHitTesting(false) (pointer-events-none).
        let icon = ButtonIcon(icon: .settings, size: 16).body
        #expect(storedValue("allowsHitTesting", in: icon) as? Bool == false)
    }
}

// The first stored value with the label in the value or its parts (a modifier of a SwiftUI view
// keeps its argument as a stored property).
@MainActor
private func storedValue(_ label: String, in value: Any, depth: Int = 0) -> Any? {
    guard depth < 12 else { return nil }
    for child in Mirror(reflecting: value).children {
        if child.label == label { return child.value }
        if let found = storedValue(label, in: child.value, depth: depth + 1) { return found }
    }
    return nil
}
