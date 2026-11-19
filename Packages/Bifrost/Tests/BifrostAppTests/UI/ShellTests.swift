import AppKit
import BifrostDailyUpdate
import BifrostHealth
import BifrostReviews
import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostApp
@testable import BifrostChat
@testable import BifrostDictation
@testable import BifrostFoundation
@testable import BifrostKeyboard
@testable import BifrostLayout
@testable import BifrostLive
@testable import BifrostLook
@testable import BifrostSessions
@testable import BifrostSettings
@testable import BifrostWindows

// The wiring of the shell: the window close, the session input, the layout changes, the key
// state of the window, the settings that reach the canvas and the Overviews, the link of the
// Settings panel to the window and the services, and the live model with the warning dot, the
// version notice and the Setup dialog. The services run with the fake claude and the fake speech
// engine, in the folder of the fake (FakeClaude), with the mod and the skills folders of the
// repo. The fake claude has no plugin commands, so its plugin lists fail. The window is a
// headless window of a test home, so it never shows. Each test stops the services and the
// window, waits for the runs of the fake and the saves of the stores, and then removes its
// folder.
@MainActor
private final class ShellScope {
    let fake: FakeClaude
    let engine = FakeSpeechEngine()
    let services: AppServices
    let plan: StartPlan
    let uiStore: UIStateStore
    let windowStore: WindowStateStore
    let shell: Shell
    // The presentation options that the window asks for. The test never changes the menu bar.
    var presentations: [NSApplication.PresentationOptions] = []

    // environment: the env of the start, for example the key that asks for the Setup dialog.
    // noClaude: the PATH of the services has no claude. clock: the clock of the services.
    // livePlugin: the plugin list of claude has Live details on (LivePluginRunner).
    init(
        environment: [String: String] = [:], noClaude: Bool = false,
        clock: any Clock<Duration> = ContinuousClock(), livePlugin: Bool = false
    ) async throws {
        UITestApp.prepare()
        fake = try FakeClaude()
        let identity = try #require(AppIdentity(bundleID: "com.example.app.native-dev"))
        let folders = DataFolders(identity: identity, home: fake.home)
        try folders.create()
        let plan = StartPlan(
            identity: identity, home: fake.home, realHome: fake.realHome, testHome: true,
            folders: folders)
        self.plan = plan
        let engine = engine
        var appEnvironment = fake.environment
        if noClaude { appEnvironment["PATH"] = "\(fake.folder.appending("home")):/usr/bin:/bin" }
        let resources = try Repo.root().appending(path: "App/Bifrost/Resources")
        let runner: any CommandRunner =
            livePlugin ? LivePluginRunner(fake.runner, claude: fake.claude) : fake.runner
        services = AppServices(
            plan: plan, home: fake.home, environment: appEnvironment, runner: runner,
            processes: FakeProcessInspector(), ptySpawner: SystemPTYSpawner(), clock: clock,
            speechEngine: { _ in engine }, modSource: resources.appending(path: "live-mod"),
            skillsSource: resources.appending(path: "bifrost-skills"))
        await services.openUIStores()
        let uiStore = try #require(services.uiState)
        let windowStore = try #require(services.windowState)
        self.uiStore = uiStore
        self.windowStore = windowStore
        shell = Shell(
            start: Shell.Start(
                title: "Bifrost Dev", testHome: true, headless: true, debugBuild: false,
                environment: environment),
            services: services, uiStore: uiStore, windowStore: windowStore,
            keys: KeyMap.defaults, menu: { _ in })
        shell.window.setPresentation = { [unowned self] in presentations.append($0) }
        shell.show()
    }

    // Stop the shell and the services, wait for the runs of the fake and the saves of the
    // stores, then remove the folder.
    // The window close saves the bounds and the layout in tasks that nothing waits for, and the
    // save timer of the UI store runs on the real clock. A save after the removal makes the
    // folder again (JSONFile.write), so the scope waits for these saves first. saveNow() stops
    // the timer and waits for the layout save. The save of update() comes after the bounds save
    // of the close, so the call ends after that save.
    func finish() async {
        shell.detach()
        shell.window.window.close()
        services.stop()
        await services.usageAlertsSave?.value
        await fake.runner.close(within: .seconds(10))
        let saved = await waitUntil { self.services.registry?.isSaving != true }
        if !saved { Issue.record("A save of the registry store did not end.") }
        await uiStore.saveNow()
        await windowStore.update()
        fake.remove()
    }
}

// A login item that changes no real login item. Each change waits for the approval of the user
// in System Settings. A test sets isOn to act as that approval.
@MainActor
private final class WaitingLoginItem: LoginItemService {
    var isOn = false

    func set(_ on: Bool) throws(LoginItemError) {
        throw .needsApproval
    }
}

// A runner that answers the plugin list of the fake claude with the Live details plugin, on
// until Turn off, and gives each other command to the runner of the fake. So the start rule of
// Live details copies the mod into the test home and listens there, and the notice is on. Only
// the commands of the fake claude get these answers.
private final class LivePluginRunner: CommandRunner {
    private let fake: GuardRunner
    private let claude: String
    private let enabled = Mutex(true)

    init(_ fake: GuardRunner, claude: String) {
        self.fake = fake
        self.claude = claude
    }

    func run(_ command: Command) async -> ExecResult {
        guard command.executable == claude else { return await fake.run(command) }
        let plugin = PluginIDs.live.plugin
        switch command.arguments {
        case ["plugin", "list", "--json"]:
            let on = enabled.withLock { $0 }
            return ExecResult(.exited(0), stdout: #"[{"id":"\#(plugin)","enabled":\#(on)}]"#)
        case ["plugin", "marketplace", "list", "--json"]:
            return ExecResult(.exited(0), stdout: "[]")
        case ["plugin", "disable", plugin, "--scope", "user", "--json"]:
            enabled.withLock { $0 = false }
            return ExecResult(.exited(0), stdout: #"{"outcome":"ok"}"#)
        default:
            return await fake.run(command)
        }
    }
}

// Run the body with a new scope, then finish the scope, also when the body throws.
@MainActor
private func withShell(
    environment: [String: String] = [:], noClaude: Bool = false,
    clock: any Clock<Duration> = ContinuousClock(), livePlugin: Bool = false,
    _ body: (ShellScope) async throws -> Void
) async throws {
    let scope = try await ShellScope(
        environment: environment, noClaude: noClaude, clock: clock, livePlugin: livePlugin)
    do {
        try await body(scope)
    } catch {
        await scope.finish()
        throw error
    }
    await scope.finish()
}

@MainActor
@Suite("shell", .serialized, .timeLimit(.minutes(1)), .tags(.realProcess, .window))
struct ShellTests {
    // The file of the window state is on the disk after the start, with no move, no mode change
    // and no quit. So a quit that the 2 s limit of QuitWait ends before its bounds write still
    // leaves the file (the smoke check of a loaded machine found no file).
    @Test func theStartWritesTheWindowStateFile() async throws {
        try await withShell { scope in
            let file = scope.plan.windowStateFile.path
            await waitUntil { FileManager.default.fileExists(atPath: file) }
            #expect(FileManager.default.fileExists(atPath: file))
        }
    }

    // A window close detaches each chat and stops the dictation service, so the microphone
    // closes.
    @Test func aWindowCloseDetachesEachChatAndClosesTheMicrophone() async throws {
        try await withShell { scope in
            let chat = try #require(SessionID(FakeClaude.alpha.sessionId))
            scope.shell.layout.apply(.open(.chat(chat)))
            #expect(scope.shell.chats.sessionIds == [FakeClaude.alpha.sessionId])
            scope.services.dictation.start(chat: chat)
            await waitUntil { scope.engine.microphoneOpens == 1 }
            scope.shell.window.window.close()
            #expect(scope.shell.chats.sessionIds.isEmpty)
            await waitUntil { scope.engine.microphoneCloses == 1 }
        }
    }

    // A start with no saved layout opens overview:1 at the Overview rect of the default layout.
    // The canvas has the size of the window before the start layout, so the rect fits and the
    // frame is not against the side bar.
    @Test func theDefaultStartPutsTheOverviewAtItsRect() async throws {
        try await withShell { scope in
            let frame = scope.shell.layout.layout.frame(of: .overview(1))
            #expect(frame?.rect == WindowLayoutModel.overviewRect)
            #expect(scope.shell.canvas.bounds.width >= 16 + 760)
        }
    }

    // The shell makes the session input one time, when the services found claude. Later
    // changes of the rows keep it.
    @Test func theSessionInputIsMadeOneTime() async throws {
        try await withShell { scope in
            #expect(scope.shell.input == nil)
            await scope.services.start()
            await waitUntil { scope.shell.input != nil }
            let input = scope.shell.input
            try scope.fake.setAgents([FakeClaude.alpha, FakeClaude.beta, FakeClaude.gamma])
            await waitUntil { scope.services.sessions.rows.count == 3 }
            #expect(scope.shell.input === input)
        }
    }

    // A change of the layout reaches the canvas, the chats and the UI store in the same turn:
    // the chat body is in its frame with the size of the frame, the chat has its terminal in
    // that body, and the store keeps the new layout. The end state is the same in each order of
    // the three parts, so the test does not check the order.
    @Test func aLayoutChangeReachesTheCanvasTheChatsAndTheStore() async throws {
        try await withShell { scope in
            let shell = scope.shell
            let id = try #require(SessionID(FakeClaude.alpha.sessionId))
            shell.layout.apply(.open(.chat(id)))
            let frame = try #require(shell.layout.layout.frame(of: .chat(id)))
            let view = try #require(shell.canvas.frameView(frame.id))
            let terminal = try #require(shell.chats.terminal(id.text))
            #expect(terminal.body.isDescendant(of: view))
            #expect(terminal.body.panelSize != nil)
            #expect(scope.uiStore.state.current == shell.layout.layout.snapshot)
            // A close of the panel: the frame and the chat go, and the store keeps the layout.
            shell.layout.apply(.close(.chat(id)))
            #expect(shell.canvas.frameView(frame.id) == nil)
            #expect(shell.chats.terminal(id.text) == nil)
            #expect(scope.uiStore.state.current == shell.layout.layout.snapshot)
        }
    }

    // The test port sorts the active tab of an open Overview, as a header click does, and the
    // state gives the rows of that tab in view order. An Overview that is not open, and a column
    // that the active tab hides (Cost is not a default column), give a refusal and do not sort.
    // The home of the fake has no Electron folder, so the import report skips each store.
    @Test func theTestPortSortsAnOpenOverviewAndShowsItsRows() async throws {
        try await withShell { scope in
            let shell = scope.shell
            let agents = [FakeClaude.gamma, FakeClaude.alpha, FakeClaude.beta]
            try scope.fake.setAgents(agents)
            await scope.services.start()
            await waitUntil { scope.services.sessions.rows.count == 3 }
            func state(_ order: [FakeClaude.Agent], descending: Bool) -> JSONValue {
                let rows = order.map { agent -> JSONValue in
                    ["id": .string(agent.sessionId), "name": .string(agent.name)]
                }
                return .array([
                    [
                        "panel": "overview:1", "tab": "t1", "sort": "name",
                        "desc": .bool(descending), "rows": .array(rows),
                    ]
                ])
            }
            let byName = [FakeClaude.alpha, FakeClaude.beta, FakeClaude.gamma]
            #expect(shell.overviewsState == state(byName, descending: false))
            try shell.sortOverview(.overview(1), by: .name)
            #expect(shell.overviewsState == state(byName.reversed(), descending: true))
            #expect(throws: Shell.OverviewSortRefusal.notOpen) {
                try shell.sortOverview(.overview(2), by: .name)
            }
            #expect(throws: Shell.OverviewSortRefusal.hiddenColumn) {
                try shell.sortOverview(.overview(1), by: .cost)
            }
            #expect(shell.overviewsState == state(byName.reversed(), descending: true))

            let report = try #require(shell.importState.object)
            #expect(report["imported"] == .array([]))
            let skipped = ImportedStore.allCases.map { ($0.rawValue, JSONValue.string("missing")) }
            #expect(report["skipped"] == .object(Dictionary(uniqueKeysWithValues: skipped)))
        }
    }

    // The window delegate gives the key state to the shell. When the window stops being the key
    // window during a drag, the cursor rects of the window go on again.
    @Test func theLossOfTheKeyStateEndsTheHeldCursorRects() async throws {
        try await withShell { scope in
            let shell = scope.shell
            let frame = try #require(shell.layout.layout.frames.first)
            let window = shell.window.window
            #expect(window.areCursorRectsEnabled)
            let point = LayoutPoint(x: frame.rect.x + 40, y: frame.rect.y + 10)
            #expect(shell.layout.beginDrag(frame: frame.id, mode: .move, at: point))
            #expect(!window.areCursorRectsEnabled)
            shell.window.windowDidResignKey(
                Notification(name: NSWindow.didResignKeyNotification, object: window))
            #expect(window.areCursorRectsEnabled)
            #expect(shell.layout.drag != nil)
            shell.layout.endDrag(at: nil)
        }
    }

    // The Interface scale of the settings zooms the canvas and the side bar.
    @Test func aScaleChangeZoomsTheCanvas() async throws {
        try await withShell { scope in
            var settings = BifrostSettings.Settings()
            settings.interfaceScale = 120
            scope.shell.apply(settings)
            #expect(scope.shell.canvas.metrics.interfaceScale == 120)
            #expect(scope.shell.sideBar.interfaceScale == 120)
            settings.interfaceScale = 100
            scope.shell.apply(settings)
            #expect(scope.shell.canvas.metrics.interfaceScale == 100)
        }
    }

    // Row flash reaches the model of the Overviews, which each Overview table reads.
    @Test func aRowFlashChangeReachesTheOverview() async throws {
        try await withShell { scope in
            #expect(scope.shell.overviews.rowFlash)
            var settings = BifrostSettings.Settings()
            settings.rowFlash = false
            scope.shell.apply(settings)
            #expect(!scope.shell.overviews.rowFlash)
            settings.rowFlash = true
            scope.shell.apply(settings)
            #expect(scope.shell.overviews.rowFlash)
        }
    }

    // The Settings panel gets its model when the settings store opens. Before that, a Settings
    // panel of the layout has an empty body. The model is linked to the window and the services,
    // with the version of the app. The test port changes the settings with a patch, in one edit
    // of the store, and a refused patch changes nothing.
    @Test func theSettingsPanelGetsItsModelWhenTheStoreOpens() async throws {
        try await withShell { scope in
            let shell = scope.shell
            shell.layout.apply(.open(.settings))
            let body = try #require(shell.settingsPanels.body(for: .settings) as? SettingsBody)
            #expect(body.host == nil)
            #expect(shell.settingsPanels.model == nil)
            #expect(shell.settingsState == .null)
            let notOpen = await shell.changeSettings(["interfaceScale": 120])
            #expect(notOpen == SettingsPatchRefusal.notOpen.message)
            await scope.services.start()
            await waitUntil { shell.settingsPanels.model != nil }
            let model = try #require(shell.settingsPanels.model)
            let store = try #require(scope.services.settings)
            #expect(model.store === store)
            #expect(body.host != nil)
            #expect(model.links.appFinder != nil)
            #expect(model.links.appVersion == Shell.appVersion)

            #expect(await shell.changeSettings(["interfaceScale": 120]) == nil)
            #expect(store.settings.interfaceScale == 120)
            #expect(shell.settingsState.object?["interfaceScale"] == 120)
            let saved = try Data(contentsOf: scope.plan.settingsFile)
            // Cmd+L is the key of Event log.
            let conflict = await shell.changeSettings(["keys": ["close-panel:mod": "Mod+L"]])
            #expect(conflict == "Two actions can't share the same key.")
            #expect(try Data(contentsOf: scope.plan.settingsFile) == saved)
            let key = await shell.changeSettings(["keys": ["close-panel:mod": "Mod+Shift+K"]])
            #expect(key == nil)
            #expect(store.settings.keys == ["close-panel:mod": "Mod+Shift+K"])
        }
    }

    // A login item that waits for the approval gives the note of Start at login. An open of
    // Settings reads the login item again: before the approval the note stays, and after the
    // approval in System Settings it clears.
    @Test func anOpenOfSettingsClearsTheLoginNoteAfterTheApproval() async throws {
        try await withShell { scope in
            let loginItem = WaitingLoginItem()
            await scope.services.start(loginItem: loginItem)
            #expect(await waitUntil { scope.shell.settingsPanels.model != nil })
            let model = try #require(scope.shell.settingsPanels.model)
            let store = try #require(scope.services.settings)
            try await store.edit { $0.startAtLogin = true }
            #expect(await waitUntil { model.links.loginItemProblem() == .needsApproval })
            model.links.onPanelOpen()
            #expect(model.links.loginItemProblem() == .needsApproval)
            loginItem.isOn = true
            model.links.onPanelOpen()
            #expect(model.links.loginItemProblem() == nil)
            #expect(store.settings.startAtLogin)
        }
    }

    // The links give the Settings model the display mode of the window, both ways, the state of
    // the login item of the services and a finder of the installed apps. The display mode is not
    // a setting, so the settings do not change.
    @Test func theSettingsLinkFollowsTheWindowAndTheServices() async throws {
        try await withShell { scope in
            let folder = try TemporaryFolder()
            defer { folder.remove() }
            let store = await SettingsStore.open(file: folder.url.appending(path: "settings.json"))
            #expect(SettingsLinks().appFinder == nil)
            let model = SettingsModel(
                store: store, layout: scope.shell.layout, links: scope.shell.settingsLinks())
            let modes = scope.shell.window.modes
            #expect(model.links.displayMode() == modes.mode)
            model.links.requestDisplayMode(.borderless)
            #expect(modes.mode == .borderless)
            #expect(model.links.displayMode() == .borderless)
            modes.request(.window)
            #expect(model.links.displayMode() == .window)
            #expect(scope.presentations == [ShellWindow.borderlessOptions, []])
            #expect(model.links.loginItemProblem() == nil)
            #expect(model.links.appFinder != nil)
            #expect(store.settings == BifrostSettings.Settings())
        }
    }

    // The links give the Settings model the confirm dialog of the window, so Reset all keys is
    // on, and the state of the dialogs: Save is off while a dialog shows. The dialog is the
    // overlay of the canvas.
    @Test func theSettingsLinkGivesTheConfirmDialogOfTheWindow() async throws {
        try await withShell { scope in
            let folder = try TemporaryFolder()
            defer { folder.remove() }
            let store = await SettingsStore.open(file: folder.url.appending(path: "settings.json"))
            #expect(SettingsLinks().confirm == nil)
            let model = SettingsModel(
                store: store, layout: scope.shell.layout, links: scope.shell.settingsLinks())
            let dialogs = scope.shell.dialogs
            #expect(scope.shell.canvas.dialogLayer === dialogs.view)
            let confirm = try #require(model.links.confirm)
            #expect(!model.links.dialogShows())
            let text = ConfirmText(title: "Reset all keys", body: "b", confirm: "Reset all keys")
            let answer = Task { await confirm(text) }
            await waitUntil { dialogs.isOpen }
            #expect(model.links.dialogShows())
            dialogs.escape()
            #expect(await answer.value == false)
            #expect(!model.links.dialogShows())
        }
    }

    // MARK: - The panels and the alerts of phase 4e

    // The Event log, the Usage HUD, the Watchlist and Show Info have their own bodies, not the
    // text of a later build.
    @Test func thePanelsOfPhase4eHaveTheirBodies() async throws {
        try await withShell { scope in
            let chat = try #require(SessionID(FakeClaude.alpha.sessionId))
            let panels: [PanelID] = [.eventLog, .usageHud, .watchlist, .showInfo(chat)]
            for panel in panels { scope.shell.layout.apply(.open(panel)) }
            let bodies = scope.shell.bodies
            #expect(bodies.body(for: .eventLog) is EventLogPanel)
            #expect(bodies.body(for: .usageHud) is UsageHUDHost)
            #expect(bodies.body(for: .watchlist) is WatchlistPanel)
            #expect(bodies.body(for: .showInfo(chat)) is ShowInfoHost)
        }
    }

    // A click on a usage notification shows the closed window again, then opens the Usage HUD.
    @Test func aClickOnAUsageNotificationShowsTheWindowAndOpensTheHUD() async throws {
        try await withShell { scope in
            scope.shell.window.window.close()
            #expect(!scope.shell.window.isOpen)
            scope.services.onUsageClick()
            #expect(scope.shell.window.isOpen)
            #expect(scope.shell.layout.layout.topFrame?.active == .usageHud)
        }
    }

    // The usage notification takes no focus input: it shows also while the window has the
    // focus (a headless window counts as focused). A test home records it.
    @Test func aUsageNotificationShowsWhileTheWindowHasTheFocus() async throws {
        try await withShell { scope in
            let recorder = try #require(scope.services.notifier as? RecordingNotifier)
            await scope.services.start()
            let registry = try #require(scope.services.registry)
            await waitUntil { scope.services.sessions.rows.count == 2 }
            let now = Int(Date().timeIntervalSince1970 * 1000)
            let limits = RateLimits(
                fiveHour: RateWindow(usedPercent: 95, resetsAt: now + 3_600_000))
            registry.pushLive(
                .usage(
                    sessionId: FakeClaude.alpha.sessionId, at: now,
                    LiveUsage(rateLimits: limits)))
            await waitUntil { !recorder.recorded.isEmpty }
            #expect(recorder.recorded.map(\.source) == [.usageLimit])
        }
    }

    // A refused box notification gives one line in the Event log, also after a second refusal.
    @Test func aRefusedNotificationGivesOneLineInTheEventLog() async throws {
        try await withShell { scope in
            scope.shell.alerts.refused()
            scope.shell.alerts.refused()
            await waitUntil { !scope.services.eventLog.entries.isEmpty }
            // The gap of the batcher ends on the clock of the services, so a second line would
            // be in the entries now.
            await scope.services.eventLog.batchTimer?.value
            #expect(
                scope.services.eventLog.entries.map(\.kind)
                    == [.notice(EventLog.notificationRefused)])
        }
    }

    // The hint of the empty Event log follows the Live details notice of the live model: it
    // shows before the first read, hides while the notice is on, and shows again after Turn off.
    @Test func theHintOfTheEventLogFollowsTheLiveNotice() async throws {
        try await withShell(livePlugin: true) { scope in
            let shell = scope.shell
            shell.layout.apply(.open(.eventLog))
            let body = try #require(shell.bodies.body(for: .eventLog) as? EventLogPanel)
            #expect(shell.live.notice == .loading)
            await waitUntil { !body.hintText.isHidden }
            #expect(!body.hintText.isHidden)
            await scope.services.start()
            await waitUntil { shell.live.notice.isOn }
            #expect(shell.live.notice == .on(sessions: 0))
            await waitUntil { body.hintText.isHidden }
            #expect(body.hintText.isHidden)
            #expect(await shell.runPluginAction(.disable, skills: false) == nil)
            #expect(shell.live.notice == .off)
            await waitUntil { !body.hintText.isHidden }
            #expect(!body.hintText.isHidden)
            #expect(scope.services.eventLog.entries.isEmpty)
        }
    }

    // The state of the test port: the Event log, the Usage HUD, the rows of the Watchlist while
    // it is in a frame, and the PR line of each Show Info panel.
    @Test func theTestPortStateShowsThePanelsOfPhase4e() async throws {
        try await withShell { scope in
            let shell = scope.shell
            #expect(shell.eventsState == ["count": 0, "last": []])
            #expect(shell.watchlistState == .null)
            #expect(shell.showInfoState == [])
            guard case .array(let bars) = shell.usageState.object?["bars"] else {
                Issue.record("The usage state has no bars.")
                return
            }
            #expect(bars.count == 2)
            await scope.services.start()
            await waitUntil { scope.services.sessions.rows.count == 2 }
            let chat = try #require(SessionID(FakeClaude.alpha.sessionId))
            shell.layout.apply(.open(.watchlist))
            shell.layout.apply(.open(.showInfo(chat)))
            await waitUntil { shell.watchlistState == [] }
            let panel: JSONValue = .string(PanelID.showInfo(chat).text)
            await waitUntil { shell.showInfoState.array?.first?.object?["pr"] != .null }
            #expect(shell.showInfoState.array?.map { $0.object?["panel"] } == [panel])
        }
    }

    // MARK: - Live details and the skills

    // The shell makes the live model before the side bar draws, and the Settings button reads
    // its warning. When the services found claude, the model gets the two controls, and the
    // Settings model shares it. The plugin list of the fake fails, so Live details shows a
    // problem, and the button shows the dot. Settings > General gets the version notice of the
    // model: the fake gives no version. With a test home that does not ask for it, no Setup
    // dialog opens. The state of the test port gives the two statuses.
    @Test func theLiveModelGetsTheControlsAndGivesTheDotAndTheNotice() async throws {
        try await withShell { scope in
            let shell = scope.shell
            #expect(shell.live.status == nil)
            #expect(shell.sideBar.dot(.settings) == nil)
            #expect(shell.liveDetailsState == .null)
            await scope.services.start()
            await waitUntil { shell.live.status != nil && shell.live.skillsStatus != nil }
            await waitUntil { shell.live.version != nil }
            #expect(shell.live.status?.plugin == .unknown)
            #expect(shell.live.warning)
            #expect(shell.sideBar.dot(.settings) != nil)
            #expect(shell.liveDetailsState.object?["plugin"] == "unknown")
            #expect(shell.skillsPluginState.object?["skills"]?.array?.count == 6)
            await waitUntil { shell.settingsPanels.model != nil }
            let model = try #require(shell.settingsPanels.model)
            #expect(model.live === shell.live)
            let notice = try #require(
                LiveRules.claudeVersionNotice(shell.live.version, failed: false))
            await waitUntil { model.versionNotice == notice }
            #expect(model.versionNotice == notice)
            #expect(shell.setup != nil)
            #expect(!shell.dialogs.isOpen)
        }
    }

    // While a warning shows, the window that becomes the key window reads the Live details status
    // again (LiveRetry), but only when the last read ended 5 minutes or more ago. The services
    // run on a manual clock. The clock moves in the same turn as the key change, so the first
    // step of the back-off (at 1 minute) cannot read first.
    @Test func theKeyWindowReadsAgainWhileAWarningShows() async throws {
        let clock = ManualClock()
        try await withShell(clock: clock) { scope in
            let shell = scope.shell
            await scope.services.start()
            await waitUntil { shell.live.status != nil && shell.live.version != nil }
            await shell.live.firstReads?.value
            #expect(shell.live.warning)
            shell.window.onKeyChange?(true)
            #expect(shell.live.retryReadTask == nil)
            clock.advance(by: LiveRetry.focusGap)
            shell.window.onKeyChange?(true)
            let read = try #require(shell.live.retryReadTask)
            await read.value
        }
    }

    // A test home that asks for it (BIFROST_TEST_SETUP=1) gets the Setup dialog at the start:
    // the setup is not done, and the state of Live details is unknown.
    @Test func aTestHomeThatAsksForTheSetupDialogGetsItAtTheStart() async throws {
        try await withShell(environment: [SetupDialog.testKey: "1"]) { scope in
            await scope.services.start()
            await waitUntil { scope.shell.dialogs.isOpen }
            #expect(scope.shell.dialogs.isOpen)
        }
    }

    // With no claude, the live model gets no controls and the bundled skills folder: both
    // sections say that claude was not found, and Settings > Skills still lists the skills.
    @Test func withNoClaudeTheLiveModelListsTheBundledSkills() async throws {
        try await withShell(noClaude: true) { scope in
            let live = scope.shell.live
            await scope.services.start()
            await waitUntil { live.skillsStatus?.skills.isEmpty == false }
            #expect(live.status?.error == "claude was not found.")
            #expect(live.skillsStatus?.skills.count == 6)
            let found = await scope.shell.runPluginAction(.install, skills: false)
            #expect(found == "claude was not found.")
        }
    }

    // The quit stops the live model: no action runs after it. The test port gives the text of
    // the failure.
    @Test func theQuitStopsTheLiveModel() async throws {
        try await withShell { scope in
            let shell = scope.shell
            await scope.services.start()
            await waitUntil { shell.live.status != nil }
            shell.detach()
            let stopped = "Bifrost stopped the Claude Code command."
            #expect(await shell.runPluginAction(.install, skills: false) == stopped)
            #expect(await shell.runPluginAction(.disable, skills: true) == stopped)
        }
    }

    // With no claude, the services make no Reviews part, and the panel says that Claude Code is
    // missing while Watch GitHub is on.
    @Test func withNoClaudeTheReviewsPanelSaysWhy() async throws {
        try await withShell(noClaude: true) { scope in
            let services = scope.services
            await services.start()
            #expect(services.sessions.status == .claudeNotFound && services.reviews == nil)
            let settings = try #require(services.settings)
            #expect(scope.shell.reviews.links.snapshot().phase == .off)
            _ = try await settings.edit { $0.reviewsWatch = true }
            #expect(scope.shell.reviews.links.snapshot().phase == .noClaude)
        }
    }

    // The shell joins Reviews to the window: the notifications of Reviews read the focus of the
    // alerts (a headless window counts as focused), a click on one shows the window and opens the
    // Reviews panel, and the confirm of the automatic comment handling in Settings reaches the
    // Reviews part, which records the consent. A turn-off of Watch GitHub closes the Review panel
    // and the Answer panel.
    @Test func theShellJoinsReviewsToTheWindow() async throws {
        try await withShell { scope in
            let shell = scope.shell
            let services = scope.services
            await services.start()
            let parts = try #require(services.reviews)
            #expect(services.reviewsFocused())
            shell.window.window.close()
            services.onReviewsClick()
            #expect(shell.window.isOpen)
            #expect(shell.layout.layout.topFrame?.active == .reviews)
            let settings = try #require(services.settings)
            _ = try await settings.edit { $0.reviewsWatch = true }
            #expect(await waitUntil { parts.store != nil })
            await parts.settled()
            #expect(parts.autoFixConsent == false)
            _ = try await settings.edit { $0.reviewsAutoFix = true }
            shell.settingsLinks().reviews.confirmAutoFix()
            await parts.settled()
            #expect(parts.autoFixConsent == true)
            let pr = try #require(PRKey(text: "owner-a/repo-a#7"))
            shell.reviews.draft.open(pr)
            shell.reviews.answer.open(pr)
            #expect(shell.layout.layout.frame(of: .reviewDraft) != nil)
            #expect(shell.layout.layout.frame(of: .answer) != nil)
            _ = try await settings.edit { $0.reviewsWatch = false }
            #expect(await waitUntil { parts.store == nil })
            #expect(shell.layout.layout.frame(of: .reviewDraft) == nil)
            #expect(shell.layout.layout.frame(of: .answer) == nil)
            #expect(shell.reviews.draft.flow == nil && shell.reviews.answer.flow == nil)
            await shell.reviews.draft.task?.value
            await parts.closeForQuit().value
        }
    }

    // The quit waits for the close of the Reviews store: when done runs, the store is closed and
    // its lock is free. The store is in the test home.
    @Test func theQuitWaitsForTheCloseOfTheReviewsStore() async throws {
        try await withShell { scope in
            let services = scope.services
            await services.start()
            let parts = try #require(services.reviews)
            let settings = try #require(services.settings)
            _ = try await settings.edit { $0.reviewsWatch = true }
            #expect(await waitUntil { parts.store != nil })
            await parts.settled()
            await withCheckedContinuation { done in scope.shell.quit { done.resume() } }
            #expect(parts.store == nil && parts.watcher == nil)
            let layout = ReviewsLayout(folder: services.sharedState.reviewsFolder)
            #expect(layout.folder.path.hasPrefix(scope.fake.home.path))
            let again = try await ReviewsStore.open(layout: layout, log: Recorder<StoreEvent>())
            await again.close().value
        }
    }

    // The quit closes the store of the Daily update at once, beside the other closes: its last
    // save ends and its lock is free when the quit ends.
    @Test func theQuitClosesTheDailyUpdateStore() async throws {
        try await withShell { scope in
            let services = scope.services
            await services.start()
            #expect(await waitUntil { scope.shell.dailyUpdate.service != nil })
            await withCheckedContinuation { done in scope.shell.quit { done.resume() } }
            #expect(scope.shell.dailyUpdate.service == nil)
            let layout = services.dailyLayout
            #expect(layout.folder.path.hasPrefix(scope.fake.home.path))
            let lock = try FileLock.take(layout.lockFile)
            lock.release()
        }
    }

    // The end of each update cycle and the stop of the automatic checks reach the Performance
    // monitor through the health log: three failed cycles give a reason, and the stop ends it.
    @Test func theUpdateCyclesReachThePerformanceMonitor() async throws {
        try await withShell { scope in
            let shell = scope.shell
            let reason = "Bifrost couldn't check for updates 3 times in a row."
            let reasons = { shell.performance.monitor.snapshot.reasons.map(\.text) }
            for _ in 1...3 { shell.updateCycleEnded(ok: false) }
            #expect(await waitUntil { reasons().contains(reason) })
            shell.updateChecksStopped()
            #expect(await waitUntil { !reasons().contains(reason) })
        }
    }

    // MARK: - The session actions

    // When the services found claude, the shell makes the action runner and links it to the
    // keys, the side bar, the Overviews and the Selected Item panel, whose frame of the default
    // layout gets its body. The labels of the side bar follow a change of the settings. The
    // command files of an earlier run leave the run folder.
    @Test func theRunnerLinksTheActionsOfTheWindow() async throws {
        try await withShell { scope in
            let shell = scope.shell
            let run = scope.plan.runFolder.path
            try FileManager.default.createDirectory(
                atPath: run, withIntermediateDirectories: true)
            let old = "\(run)/attach-abcd1234.command"
            try "old\n".write(toFile: old, atomically: false, encoding: .utf8)
            let frame = try #require(shell.layout.layout.frame(of: .selectedItem))
            #expect(shell.canvas.frameView(frame.id)?.shownBody is WaitingPanel)
            #expect(shell.runner == nil)
            #expect(!shell.sideBar.globalState(.newSession).enabled)
            await scope.services.start()
            await waitUntil { shell.runner != nil }
            let runner = try #require(shell.runner)
            #expect(shell.commands.runner === runner)
            #expect(shell.sideBar.runner === runner)
            #expect(shell.sideBar.globalState(.newSession).enabled)
            #expect(shell.canvas.frameView(frame.id)?.shownBody is SelectedItemPanel)
            // A double-click on a row of the Overview runs Open: the chat of the row opens.
            await waitUntil { runner.row(FakeClaude.alpha.sessionId) != nil }
            shell.overviews.open(FakeClaude.alpha.sessionId)
            let alpha = try #require(SessionID(FakeClaude.alpha.sessionId))
            #expect(shell.layout.layout.frame(of: .chat(alpha)) != nil)
            await waitUntil { !FileManager.default.fileExists(atPath: old) }
            #expect(shell.sideBar.labels == .plain)
            let store = try #require(scope.services.settings)
            _ = try await store.edit { $0.labels = .space }
            #expect(shell.sideBar.labels == .space)
        }
    }

    // A click on a box notification selects the row and runs Open through the action runner
    // (RunPlan.notifiedOpenStep), not through the open of the Overviews. A click before the list
    // loads waits for the row, and a click on a session that the loaded list does not have opens
    // nothing.
    @Test func aClickOnABoxNotificationOpensTheSessionThroughTheRunner() async throws {
        try await withShell { scope in
            let shell = scope.shell
            let alpha = try #require(SessionID(FakeClaude.alpha.sessionId))
            shell.alerts.open(alpha.text)
            #expect(shell.layout.layout.frame(of: .chat(alpha)) == nil)
            await scope.services.start()
            await waitUntil { shell.layout.layout.frame(of: .chat(alpha)) != nil }
            #expect(shell.runner != nil)
            #expect(shell.selection.selectedId == alpha.text)
            var overviewOpens: [String] = []
            shell.overviews.open = { overviewOpens.append($0) }
            shell.layout.apply(.close(.chat(alpha)))
            shell.selection.selectedId = nil
            shell.alerts.open(alpha.text)
            #expect(shell.layout.layout.frame(of: .chat(alpha)) != nil)
            #expect(shell.selection.selectedId == alpha.text)
            #expect(overviewOpens.isEmpty)
            // A session that left the list: the click opens and selects nothing.
            let gone = "5a0e0009-0000-4000-8000-000000000009"
            let frames = shell.layout.layout.frames.count
            shell.alerts.open(gone)
            #expect(shell.selection.selectedId == alpha.text)
            #expect(shell.layout.layout.frames.count == frames)
        }
    }

    // The actions of the test port run through the runner: Rename saves the name of the request
    // in the Rename dialog, a confirmation with no confirm answers no and runs nothing, and an
    // action that is off gives its reason. The state gives the lines, the dialog and the
    // selection.
    // The Rename dialog has a SwiftUI text field (SharedFieldEditor).
    @Test(.sharedFieldEditor) func theTestPortRunsAnActionAndAnswersItsDialogs() async throws {
        try await withShell { scope in
            let shell = scope.shell
            #expect(
                await shell.runTestAction(
                    TestAction(.global(.resumeAll))) == "the session actions need claude")
            try scope.fake.setAgents([FakeClaude.alpha, FakeClaude.gamma])
            await scope.services.start()
            await waitUntil { shell.runner?.row(FakeClaude.gamma.sessionId) != nil }
            let alpha = try #require(SessionID(FakeClaude.alpha.sessionId))
            let gamma = try #require(SessionID(FakeClaude.gamma.sessionId))
            let rename = TestAction(.session(.rename, alpha), name: "renamed")
            #expect(await shell.runTestAction(rename) == nil)
            #expect(shell.runner?.row(alpha.text)?.name == "renamed")
            let runs = scope.fake.commandRuns()
            // gamma works, so its Stop asks first. With no confirm, the answer is no, and no
            // claude command runs. The registry reads the session list at its own times, so the
            // check leaves out those reads.
            #expect(await shell.runTestAction(TestAction(.session(.stop, gamma))) == nil)
            #expect(scope.fake.commandRuns() == runs)
            #expect(!shell.dialogs.isOpen)
            // Resume all has no parked row to resume.
            let runner = try #require(shell.runner)
            let reason = await shell.runTestAction(TestAction(.global(.resumeAll)))
            #expect(reason != nil)
            #expect(reason == ActionModel.globalState(.resumeAll, runner.globalContext).reason)
            let state = shell.actionsState
            #expect(state["dialog"] == .bool(false))
            #expect(state["error"] == .null)
            #expect(state["running"] == .array([]))
            #expect(state["selected"] == .null)
        }
    }
}
