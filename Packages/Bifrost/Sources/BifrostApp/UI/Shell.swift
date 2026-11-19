import AppKit
import BifrostChat
import BifrostDailyUpdate
import BifrostDictation
import BifrostFoundation
import BifrostHealth
import BifrostKeyboard
import BifrostLayout
import BifrostLive
import BifrostLook
import BifrostSessions
import BifrostSettings
import BifrostWindows

// The main window of the app and the parts that it joins: the window and its display modes, the
// canvas and the side bar, the panel bodies (the chat terminals, the Overview panels, the Overview
// Settings panels, the Settings panel, the Event log, the Usage HUD, the Show Info panels, the
// Watchlist, the Reviews panel, the Service status panel, the Daily update (DailyUpdateHost),
// Performance (PerformanceParts) and the text of a later build for each other panel), the release
// notes dialog (ReleaseNotesHost), the window key filter and the key commands, the box alerts, the
// session input and the two UI stores.
//
// The start (docs/behaviour/shell.md, "The start order"): the delegate opens the two UI stores
// after the one-time import of the Electron data, then makes the shell, then starts the services.
// The shell:
// 1. Makes the chat terminals at once. They get the PTY manager and the session input when the
//    services find claude (attach(ptys:input:)), before the first rows.
// 2. Makes the canvas with the private backdrop blur (user decision), and the window. The window
//    gives the canvas its size, so the layout has its bounds before the start layout.
// 3. Gives each change of the layout model to the canvas, then to the chats, then to the UI store
//    (a drag holds the saves). This starts before the start layout, so a start layout that is not
//    the layout of the file (the default layout, or a load that dropped a bad frame) saves 500 ms
//    after the start.
// 4. Applies the start layout: current of ui-state.json, else the default layout (overview:1 and
//    the Selected Item).
// 5. Shows the window.
//
// The dialogs: the shell makes the dialog host of the window and gives its layer to the canvas.
// The Settings panel asks with its confirm dialog.
//
// The session actions: at the first change of the session list after the services found claude,
// the shell makes the action runner (ActionRunner) on the session commands, the session input, the
// registry, the chats (for the Take control loader), the dialogs, the installed apps and the opens
// of NSWorkspace. The keys, the side bar, the Overviews and the Watchlist (the double-click and the
// row menu of the shared OverviewModel), the clicks of the box notifications and the Selected Item
// panel then run their actions through it. Until then, their actions do nothing, and the Selected
// Item panel is empty. Show Info has the app actions of the runner (AppActions, with the installed
// apps), so its Copy session ID and its open of the PR use the same opens and the same clipboard.
// The runner reads the settings of the store at each read, so the labels and the states follow
// each change of the settings. The installed apps come from InstalledAppList, which follows the
// Terminal app setting from the open of the settings store. At the start of the runner, the files
// that an earlier run left in the run folder of Open in terminal go
// (TerminalLauncher.removeOldFiles).
//
// The Settings panel: the shell makes its part with the window. When the settings store of the
// services opens (step 1 of their start), the shell makes the model of the panel with the live
// model and its links to the window and the services (settingsLinks()), and gives it to the
// part. Then it
// makes the Setup dialog, which opens in the dialog layer at the first start (SetupDialog). With
// a test home, the dialog opens by itself only when the env asks for it (opensAtStart).
//
// Live details and the skills (docs/behaviour/live.md, Settings > Live details): the shell makes
// the live model (LiveModel) with the window, before the side bar, which gets the warning dot of
// the Settings button from it at its init. When the services found claude, the model gets the
// two controls and the version check of Claude Code for the minimum of Bifrost
// (AppServices.liveSources). With no claude, it gets no controls and the bundled skills folder,
// so Settings > Skills still lists the skills. The
// notice about the version of Claude Code at the top of Settings > General follows the version
// of the model. The window that becomes the key window lets a warning read again
// (LiveModel.windowFocused), and the quit stops the model.
//
// The rows: the shell observes the session list of the services (AppServices.sessions). At each
// change of the rows or of loaded, it syncs the chats. Each part of the shell reads the rows from
// that one list. The chats, the session input and the Overviews read it at each check, so they
// keep no copy.
//
// The alerts: the shell gives the rows of the list to the alert service from the first active
// poll, so the first rows only record the boxes. The service reads the alert settings and the
// focus of the window: a closed window has no focus, and a headless window counts as focused.
// The notifications go through the one notifier of the services, and a test home records each
// notification and plays no sound. A click on a notification shows the window, and then the
// shell selects the row and runs Open through the action runner (RunPlan.notifiedOpenStep). The
// open waits for the row while the session list has not loaded or the runner is not there, and
// it stops when the loaded list does not have the row. A newer click replaces a wait. The shell
// tells the service each show and each close of the window, so a click while the window is closed
// opens the session when the window shows. A refused notification gives one line in the Event log.
//
// The usage notification of the services shows also while the window has the focus. A click on
// it shows the window and opens the Usage HUD. A show of the window asks the poller for a poll
// when the Usage HUD shows in a frame, as the HUD does at its own show.
//
// Reviews (ShellReviews.swift): the Reviews panel reads the Reviews part of the services through
// its links: the snapshot of the settings and the watcher, the commands of the watcher and the
// session of a PR. The shell gives it the open of a chat through the action runner and Open
// Settings. The notifications of Reviews read the focus of the window as the box alerts do, a
// click on one shows the window and opens the Reviews panel, and a refused one gives a line in the
// Event log. The Reviews button of the side bar shows its dot while the watcher needs the user.
//
// The panels of phase 4e read the services through closures that read observed values: the
// Event log reads its model, the names of the rows and the Live details notice of the live model
// (its hint shows while the notice is not on), the Usage HUD the session usage and the account
// poller, Show Info the PR lookup after the start made it, and the Watchlist the registry for a
// move and the label set of the settings.
//
// The window delegate gives the key state of the window: the background moves only in the key
// window, and a drag of a frame turns the cursor rects on again when the window stops being the key
// window. One task follows the reduced motion setting of macOS. The chats and the session input use
// the clock of the services.
//
// A window close and a quit only detach: each chat sends SIGHUP to its attach child, and the
// sessions continue. A closed window has no chats. A reopen makes them again.
//
// Dictation: the chats share the dictation service of the services. The dictation key is the key of
// the settings (Off gives none). Each chat that listens gives its voice level to the canvas, which
// shows the green look on its frame. A window close and a quit stop each dictation and then the
// service at once, so the microphone closes.
// The updater of the app (Sparkle), as the shell and Settings > Updates see it. The app target
// makes the updater before the shell, so it gives the version, the observed state of the updater
// and the closure that starts a check to Shell.init. The default has no updater: its state is off.
@MainActor
public struct UpdaterHooks {
    // The version of the app (CFBundleShortVersionString), or nil.
    let version: String?
    // What the updater does now. The app target changes it at the events of the updater.
    let state: UpdaterState
    // Start a check for updates. The updater shows its result.
    let check: @MainActor () -> Void

    public init(version: String?, state: UpdaterState, check: @escaping @MainActor () -> Void) {
        self.version = version
        self.state = state
        self.check = check
    }

    // No updater: Check now is off.
    public static let none = UpdaterHooks(version: nil, state: UpdaterState(), check: {})
}

@MainActor
public final class Shell {
    // The values of the start that the shell uses.
    public struct Start {
        let title: String
        let testHome: Bool
        let headless: Bool
        let debugBuild: Bool
        // The env of the app. With a test home, it can ask for the Setup dialog at the start
        // (SetupDialog.opensAtStart).
        let environment: [String: String]

        public init(
            title: String, testHome: Bool, headless: Bool, debugBuild: Bool,
            environment: [String: String] = [:]
        ) {
            self.title = title
            self.testHome = testHome
            self.headless = headless
            self.debugBuild = debugBuild
            self.environment = environment
        }
    }

    public let window: ShellWindow
    public let layout: WindowLayoutModel
    let canvas: CanvasView
    let sideBar: SideBarModel
    let selection: SelectionModel
    public let chats: ChatTerminals
    let filter: WindowKeyFilter

    private let services: AppServices
    // The updater of the app, for Settings > Updates.
    private let updater: UpdaterHooks
    private let uiStore: UIStateStore
    private let windowStore: WindowStateStore
    private let content: ShellContentView
    let commands: KeyCommands
    let bodies: PanelBodiesHub
    // The model that all Overview panels and Overview Settings panels share.
    let overviews: OverviewModel
    // The box alerts: the notifications and the alert sound of the new boxes of the rows.
    let alerts: AlertMonitor
    // The bodies of the panels of phase 4e.
    let usageHUD: UsageHUDPanels
    let watchlist: WatchlistPanels
    let showInfo: ShowInfoPanels
    // The body of the Reviews panel. Its links read the Reviews part of the services
    // (ShellReviews.swift).
    let reviews: ReviewsPanels
    // The Service status panel. The services check the status pages.
    let serviceStatus: ServiceStatusPanels
    // The Daily update: its panel, its store and its service (DailyUpdateHost).
    let dailyUpdate: DailyUpdateHost
    // The Performance monitor, its panel and its side bar dot.
    let performance: PerformanceParts
    // The release notes dialog and What's new at the start.
    let releaseNotes: ReleaseNotesHost
    // The body of the Settings panel. It gets its model when the settings store opens.
    let settingsPanels = SettingsPanels()
    // The dialogs of the window, in their layer over the canvas.
    let dialogs: DialogHost
    // The state of Live details and of the skills: the Settings sections, the warning dot of the
    // side bar and the Setup dialog read it.
    let live: LiveModel
    // The Setup dialog, after the settings store opens. The shell keeps it, so it follows the
    // state until the quit.
    private(set) var setup: SetupDialog?
    // True when the Setup dialog can open by itself at this start.
    private let setupAtStart: Bool
    private let look = PanelLook()
    private let headless: Bool
    // The installed apps of the session actions.
    private let installedApps: InstalledAppList
    // The opens and the clipboard of the session actions, and the app actions on them. The action
    // runner and Show Info share them.
    private let opener: WorkspaceOpener
    private let clipboard: WorkspaceClipboard
    private let appActions: AppActions
    // The session input and the action runner, after the services found claude.
    private(set) var input: SessionInput?
    private(set) var runner: ActionRunner?
    // The session of a clicked notification while its open waits for the row or the runner.
    private var notifiedWait: String?
    // The task that follows the rows of the session list, the task that follows the reduced
    // motion setting of macOS, the task that waits for the open of the settings store, the task
    // that waits for the controls of Live details and of the skills, and the task that gives the
    // version notice of the live model to Settings > General.
    private var rowsFollow: Task<Void, Never>?
    private var motionFollow: Task<Void, Never>?
    private var settingsOpen: Task<Void, Never>?
    private var liveAttach: Task<Void, Never>?
    private var versionFollow: Task<Void, Never>?
    private var ptysAttached = false
    // False after a close of the window and before its reopen. A closed window has no chats.
    private var windowOpen = true
    // The motion of the animated background, after the settings open. Until then the background
    // stays still.
    private var motion: BackgroundMotion?
    private var windowKey = false
    private var windowVisible = false
    #if DEBUG
    // The motion of the background during a run of the debug bench: true counts the window as
    // focused, as a headless window does. false keeps the background still. nil gives the normal
    // rule.
    private var benchMotion: Bool?
    #endif

    // menu runs an action of the menu (the key of toggle-fullscreen).
    public init(
        start: Start, services: AppServices, uiStore: UIStateStore,
        windowStore: WindowStateStore, keys: KeyMap, updater: UpdaterHooks = .none,
        menu: @escaping (MenuItemModel.Action) -> Void
    ) {
        self.services = services
        self.updater = updater
        self.uiStore = uiStore
        self.windowStore = windowStore
        headless = start.headless
        setupAtStart = SetupDialog.opensAtStart(
            testHome: start.testHome, environment: start.environment)
        let installedApps = InstalledAppList(home: services.home)
        self.installedApps = installedApps
        let opener = WorkspaceOpener(clock: services.clock)
        let clipboard = WorkspaceClipboard()
        self.opener = opener
        self.clipboard = clipboard
        let appActions = AppActions(
            rows: { [weak services] in services?.registry?.rows ?? [] },
            apps: { installedApps.apps }, opener: opener, clipboard: clipboard)
        self.appActions = appActions
        layout = WindowLayoutModel(layout: WindowLayout(bounds: LayoutSize(w: 1, h: 1)))
        let vimMode = services.vimMode
        let list = services.sessions
        selection = SelectionModel(list: list)
        let chats = ChatTerminals(
            ptys: services.ptys, sizes: services.sessionSizes, rows: { list.rows },
            clock: services.clock, links: .system, pasteboard: .general,
            renderer: TerminalRenderer.read(.standard),
            dictation: ChatDictationParts(
                service: services.dictation, vimMode: { await vimMode.vimMode() },
                openURL: { _ = NSWorkspace.shared.open($0) }))
        self.chats = chats
        // A row shows the icon of the app that shows its session (SessionIconRules.holder): the
        // icon of this app for a session in a chat window, else the icon of its terminal app.
        // The chats know their own attaches. The registry gives the terminal app of a row after
        // the start of the services, and the icons look up each terminal app one time.
        let appIcons = SessionAppIcons()
        let attachedChats = chats.attachedChats
        overviews = OverviewModel(
            store: uiStore, sessions: list, selection: selection, layout: layout,
            clock: services.clock, now: services.now,
            appIcon: { [weak services] row in
                appIcons.icon(
                    SessionIconRules.holder(
                        row, inChat: attachedChats.contains(row.sessionId),
                        terminal: services?.registry?.terminalOf(row.sessionId)))
            })
        alerts = AlertMonitor(
            notifier: services.notifier,
            sound: appAlertSound(testHome: start.testHome) { AlertSound.play() },
            settings: { [weak services] in
                let settings = services?.settings?.settings
                return AlertSettings(
                    notifications: settings?.notifications ?? false,
                    redBoxSound: settings?.redBoxSound ?? false)
            }, clock: services.clock)
        // The window makes the key filter after the parts. The rows of an Overview read it at
        // each click (the hold keys, D8).
        weak var keyFilter: WindowKeyFilter?
        let overviewPanels = OverviewPanels(
            model: overviews, look: look, filter: { keyFilter })
        let look = look
        let metrics = { @MainActor @Sendable in CanvasMetrics(interfaceScale: look.interfaceScale) }
        // The live model comes before the Event log and the side bar, which read it.
        let live = LiveModel(clock: services.clock)
        self.live = live
        // The hint of an empty Event log shows while the Live details notice is not on. The
        // notice comes from the observed status of the live model, so the hint follows it.
        let eventLog = EventLogPanels(
            model: services.eventLog, sessions: list, liveOn: { live.notice.isOn },
            metrics: metrics)
        usageHUD = UsageHUDPanels(
            usage: { [weak services] in services?.registry?.usage },
            poller: { [weak services] in services?.poller }, metrics: metrics,
            clock: services.clock, now: services.now)
        showInfo = ShowInfoPanels(
            list: list, lookup: { [weak services] in services?.prLookup }, actions: appActions,
            look: look, clock: services.clock, now: services.now, zone: .autoupdatingCurrent)
        watchlist = WatchlistPanels(
            model: overviews, registry: { [weak services] in services?.registry },
            labels: { [weak services] in services?.settings?.settings.labels ?? .plain },
            look: look, filter: { keyFilter })
        // The row menu of the Reviews panel is the Bifrost menu of the canvas, which the shared
        // Overview model holds.
        let menuHolder = overviews
        reviews = ReviewsPanels(
            links: Self.reviewsLinks(services), opener: opener, look: look,
            menu: { [weak menuHolder] in menuHolder?.menu }, clock: services.clock,
            now: services.now)
        // The dialogs come before the Daily update: its panel asks through them.
        let dialogs = DialogHost(look: look, clock: services.clock)
        self.dialogs = dialogs
        let settingsPanels = settingsPanels
        serviceStatus = ServiceStatusPanels(
            monitor: services.serviceStatus, metrics: metrics, clock: services.clock,
            now: services.now)
        let dailyUpdate = DailyUpdateHost(
            layout: services.dailyLayout,
            links: DailyPanelLinks(
                confirm: { await dialogs.confirm($0, openFolder: nil, onBusy: {}) },
                openSettings: { settingsPanels.model?.open(.dailyUpdate) }, opener: opener,
                clipboard: clipboard, look: look),
            clock: services.clock, now: services.now)
        self.dailyUpdate = dailyUpdate
        let performance = PerformanceParts(
            plan: services.performancePlan,
            environment: PerformanceEnvironment(services, layout: layout, uiState: uiStore),
            style: { PanelStyle(metrics: metrics(), transparency: look.panelTransparency) },
            clock: services.clock)
        self.performance = performance
        releaseNotes = ReleaseNotesHost(service: services.releaseNotes)
        bodies = PanelBodiesHub(
            parts: [
                chats, overviewPanels, OverviewSettingsPanels(model: overviews, look: look),
                settingsPanels, eventLog, usageHUD, showInfo, watchlist, reviews, reviews.trust,
                serviceStatus, dailyUpdate.panels, performance.panels,
            ], look: look,
            rows: { [weak services] in services?.sessions.rows ?? [] },
            waiting: [.selectedItem])
        canvas = CanvasView(
            model: layout, bodies: bodies, settings: CanvasSettings(blur: .backdrop))
        canvas.overviews = overviews
        canvas.dialogLayer = dialogs.view
        // The dots of the side bar: the warning of the live model on Settings, the attention of
        // the watcher on Reviews, the marker of the service on Daily update and the level of the
        // monitor on Performance. Each reads an observed value, so the buttons follow each change.
        sideBar = SideBarModel(
            layout: layout, store: uiStore,
            dot: { [weak services] panel in
                switch panel {
                case .settings:
                    live.warning ? SideBarDot(text: SideBarView.settingsAttention) : nil
                case .reviews:
                    services?.reviews?.attention == true
                        ? SideBarDot(text: SideBarView.reviewsAttention) : nil
                case .dailyUpdate:
                    dailyUpdate.marker ? SideBarDot(text: SideBarView.dailyUpdateAttention) : nil
                case .performance:
                    performance.dot
                default:
                    nil
                }
            })
        // The frame of a chat that listens shows the green look with its voice level.
        chats.onDictationLook = { [weak canvas] in canvas?.setDictation($0, level: $1) }
        content = ShellContentView(
            sideBar: SideBarView.host(model: sideBar, bodies: bodies), canvas: canvas)
        let placement = WindowPlacement.restore(
            windowStore.state.bounds, workAreas: ShellWindow.workAreas())
        window = ShellWindow(
            title: start.title, placement: placement, mode: windowStore.state.mode,
            show: WindowShow.show(testHome: start.testHome, headless: start.headless),
            content: content, clock: services.clock)
        #if DEBUG
        if WindowShow.actsAsKey(testHome: start.testHome, debugBuild: start.debugBuild) {
            window.window.actAsKeyForTestHome()
        }
        #endif
        commands = KeyCommands(
            layout: layout, sideBar: sideBar, selection: selection, overviews: overviewPanels,
            openChat: { [layout] in layout.openChat($0) }, menu: menu)
        // The key map gives the filter the dictation key too.
        filter = WindowKeyFilter(
            window: window.window, commands: commands, selection: selection, keys: keys)
        keyFilter = filter
        wire()
        // The canvas has its size, so the start layout applies to the bounds of the area.
        layout.applyStartLayout(uiStore.state.current)
    }

    isolated deinit {
        rowsFollow?.cancel()
        motionFollow?.cancel()
        settingsOpen?.cancel()
        liveAttach?.cancel()
        versionFollow?.cancel()
    }

    // MARK: - The start

    private func wire() {
        layout.onChange = { [weak self] change in self?.layoutChanged(change) }
        // The list of now, then each change of the rows or of loaded. The shell reads the two
        // values from the list.
        let list = services.sessions
        let changes = Observations { _ = (list.rows, list.loaded) }
        rowsFollow = Task { [weak self] in
            for await _ in changes { self?.rowsChanged() }
        }
        // The file of the window state is on the disk from the start. A quit that the time limit
        // of QuitWait ends early then cannot leave the app with no file.
        Task { [windowStore] in await windowStore.update() }
        window.onBoundsChange = { [windowStore] bounds in
            Task { await windowStore.update(bounds: bounds) }
        }
        window.modes.onChange = { [windowStore] mode in
            Task { await windowStore.update(mode: mode) }
        }
        window.onVisible = { [weak self] visible in self?.visibilityChanged(visible) }
        window.onKeyChange = { [weak self] key in self?.keyChanged(key) }
        window.onClose = { [weak self] in self?.closed() }
        alerts.showWindow = { [weak self] in self?.showForAlert() }
        alerts.open = { [weak self] in self?.openNotified($0) }
        alerts.refused = { [weak services] in services?.notificationRefused() }
        alerts.focused = { [weak self] in self?.alertFocused ?? false }
        usageHUD.showWindow = { [weak self] in self?.showForAlert() }
        usageHUD.openPanel = { [layout] in layout.apply(.open($0)) }
        services.onUsageClick = { [weak usageHUD] in usageHUD?.notificationClicked() }
        wireReviews()
        let options = NSWorkspace.shared.notificationCenter.notifications(
            named: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
        motionFollow = Task { [weak self] in
            for await _ in options { self?.reduceMotionChanged() }
        }
        // The settings of now first, then each change, until the store opens.
        let services = services
        let opens = Observations { services.settings }
        settingsOpen = Task { [weak self] in
            for await store in opens {
                guard let store else { continue }
                self?.attachSettings(store)
                return
            }
        }
        // The controls when the services found claude, or none when they found no claude. Only
        // the first of the two counts.
        let found = Observations {
            (services.liveSources, services.sessions.status == .claudeNotFound)
        }
        liveAttach = Task { [live] in
            for await (sources, noClaude) in found {
                if let sources {
                    live.attach(sources)
                    return
                }
                if noClaude {
                    live.attach(nil, skillsFolder: services.skillsSource)
                    return
                }
            }
        }
    }

    // MARK: - The window

    // Show the window: at the start, at a reopen and at a click on a notification. A reopen makes
    // the chats again. A session of a click that waits for the window opens now, and a Usage HUD
    // that shows asks for a poll.
    public func show() {
        windowOpen = true
        window.show()
        syncChats()
        alerts.windowShown()
        usageHUD.windowShown()
    }

    // The service of dictation, for the test port.
    public var dictation: DictationService { services.dictation }

    // The window closed: the session of a later click on a notification waits for the next show,
    // each chat stops its dictation and detaches, the dictation service stops, and the layout
    // saves now.
    private func closed() {
        windowOpen = false
        alerts.windowClosed()
        chats.detachAll()
        services.dictation.stopAll()
        Task { [uiStore] in await uiStore.saveNow() }
    }

    // A quit: the normal bounds of an open window, the layout save, the close of the Reviews
    // store with its last saves, the close of the Daily update store with its last save, a
    // settings write in flight and the save of the notified periods, for 2 s at most together
    // (QuitWait). Then done runs. detach() comes after done. The closes of Reviews and of the
    // Daily update start at once, so a slow step before them cannot use their time. The edit of
    // the settings by Reviews comes before the wait for the settings writes. The save of the
    // periods is the last one when the other waits end, so a change during those waits is in it
    // too.
    public func quit(_ done: @escaping @MainActor () -> Void) {
        let bounds = window.isOpen ? window.normalBounds : nil
        let settings = services.settings
        let reviews = services.reviews?.closeForQuit()
        let dailyUpdate = dailyUpdate
        let daily = Task { await dailyUpdate.close() }
        QuitWait.run(
            work: { [uiStore, windowStore, services] in
                if let bounds { await windowStore.update(bounds: bounds) }
                await uiStore.saveNow()
                await reviews?.value
                await daily.value
                await settings?.waitForWrites()
                await services.usageAlertsSave?.value
            }, done: done)
    }

    // The last step of a quit: each chat stops its dictation and detaches (SIGHUP to each attach
    // child only), the dictation service stops, the live model reads and changes nothing more,
    // the tasks of the action runner that did not end get a cancel, and the Daily update and the
    // Performance monitor stop.
    public func detach() {
        windowOpen = false
        chats.detachAll()
        services.dictation.stopAll()
        live.stop()
        runner?.stop()
        dailyUpdate.stop()
        performance.stop()
    }

    // The end of an update cycle of the updater (the release app only). The health log gets the
    // result of the poll of the updates: ok, or failed.
    public func updateCycleEnded(ok: Bool) {
        services.health.record(.poll(.updates, ok ? .ok : .failed))
    }

    // The automatic update checks of the updater turned off (the release app only). No more
    // scheduled checks come, so the health log ends the streak of failed checks.
    public func updateChecksStopped() {
        services.health.record(.stopped(.updates))
    }

    private func visibilityChanged(_ visible: Bool) {
        services.setWindowVisible(WindowShow.seenVisible(visible, headless: headless))
        windowVisible = visible
        updateMotion()
    }

    // MARK: - The rows and the chats

    private func rowsChanged() {
        attachPTYs()
        syncChats()
        let list = services.sessions
        if list.loaded { alerts.rows(list.rows) }
        openWaitingNotified()
    }

    // The services found claude: the shell makes the session input one time, and the chats get the
    // PTY manager and the session input. Each chat owns the attach of its chat view and gives its
    // chunks and its end to the session input. The session input owns each hidden attach and gives
    // its output to a terminal model, at the session size. Then the shell makes the action runner.
    // The services make the PTY manager, the registry and the session commands in one step, so
    // the three are there together.
    private func attachPTYs() {
        guard !ptysAttached, let ptys = services.ptys, let registry = services.registry,
            let actions = services.actions
        else { return }
        ptysAttached = true
        let list = services.sessions
        let input = SessionInput(
            ptys: ptys, sizes: services.sessionSizes, rows: { list.rows },
            makeTerminal: { HiddenTerminalModel(size: $0) }, clock: services.clock)
        self.input = input
        chats.attach(ptys: ptys, input: input)
        attachRunner(actions: actions, input: input, registry: registry, ptys: ptys)
        if let claude = services.claudeRunner,
            let gh = services.gh(in: services.dailyLayout.runsFolder)
        {
            dailyUpdate.claudeFound(claude, gh: gh)
        }
    }

    // Make the action runner and link it to the keys, the side bar, the Overviews and the
    // Selected Item panel. The Selected Item panel of the start layout gets its body now.
    private func attachRunner(
        actions: SessionActions, input: SessionInput, registry: RegistryService, ptys: PTYManager
    ) {
        let rows = { [weak registry] in registry?.rows ?? [] }
        let installedApps = installedApps
        let terminals = TerminalLauncher(
            rows: rows, apps: { installedApps.apps },
            terminalOf: { [weak registry] in registry?.terminalOf($0) },
            claudePath: { [weak ptys] in ptys?.claudePath }, runFolder: services.runFolder,
            opener: opener, clipboard: clipboard, clock: services.clock)
        terminals.removeOldFiles()
        let services = services
        // Hand over types through the session input, and it only reads the projects folder of
        // Claude Code.
        let handOver = HandOver(
            input: input, registry: registry, projects: services.claudeProjects,
            notes: services.sharedState.handoversFolder,
            rules: services.skillsSource.appending(
                path: "skills/bifrost-hand-over/hand-over-rules.md", directoryHint: .notDirectory),
            clock: services.clock, now: services.now)
        let runner = ActionRunner(
            actions: actions, input: input, registry: registry, apps: appActions,
            terminals: terminals, layout: layout, selection: selection, chats: chats,
            dialogs: dialogs, uiState: uiStore,
            // The store is observable, so a reader of the labels or of an action state follows
            // each change of the settings.
            settings: { [weak services] in
                services?.settings?.settings ?? BifrostSettings.Settings()
            },
            installedApps: { installedApps.apps }, clock: services.clock, handOver: handOver)
        self.runner = runner
        commands.runner = runner
        sideBar.runner = runner
        performance.attach(runner)
        runner.attach(overviews, menu: canvas.bifrostMenu)
        let selectedItem = SelectedItemPanels(runner: runner, overviews: overviews, look: look)
        canvas.reloadBodies(bodies.add(selectedItem))
    }

    // A change of the layout model. The canvas gets it first: it moves the bodies into their
    // frames, so a chat that gets the focus has its view in the window. Then the chats get the
    // layout, and the UI store keeps it.
    private func layoutChanged(_ change: WindowLayoutModel.Change) {
        canvas.modelChanged(change)
        if change == .layout { syncChats() }
        layout.save(change, to: uiStore)
    }

    // The chats follow the layout and the rows, while the window is open.
    private func syncChats() {
        guard windowOpen else { return }
        chats.sync(layout: layout.layout, loaded: services.sessions.loaded)
    }

    // MARK: - Reviews

    // The links of Reviews that need the window: the open of the chat of a PR session through
    // the action runner, Open Settings at Settings > Reviews, and a click on a notification of
    // Reviews, which shows the window and opens the Reviews panel. The notifications of Reviews
    // read the focus of the window as the box alerts do.
    private func wireReviews() {
        reviews.links.openChat = { [weak self] in self?.runner?.run(.open, $0) }
        reviews.links.openPanel = { [layout] in layout.apply(.open($0)) }
        reviews.links.closePanel = { [layout] in layout.apply(.close($0)) }
        reviews.links.terminalFont = { [chats] in chats.terminalFont }
        reviews.links.openSettings = { [weak self] in
            guard let self else { return }
            if let model = settingsPanels.model {
                model.open(.reviews)
            } else {
                layout.apply(.open(.settings))
            }
        }
        services.reviewsFocused = { [weak self] in self?.alertFocused ?? false }
        services.onReviewsClose = { [weak self] in self?.reviews.reviewsStopped() }
        services.onReviewsClick = { [weak self] in
            self?.showForAlert()
            self?.layout.apply(.open(.reviews))
        }
    }

    // MARK: - The alerts

    // A click on a notification shows the window: a minimised window comes back. A normal start
    // makes the app active, and a test home does not (WindowShow).
    private func showForAlert() {
        if window.window.isMiniaturized { window.window.deminiaturize(nil) }
        show()
    }

    // The session of a clicked notification. It replaces a session that waits.
    private func openNotified(_ sessionId: String) {
        notifiedWait = sessionId
        openWaitingNotified()
    }

    // The open of the session of a clicked notification (RunPlan.notifiedOpenStep): with its row
    // and the runner, the shell selects the row and runs Open through the runner. Open does
    // nothing for a parked or an external row. While the session list has not loaded or the
    // runner is not there, the session waits for the next change of the rows. A loaded list with
    // no row of the session stops the wait.
    private func openWaitingNotified() {
        guard let sessionId = notifiedWait else { return }
        let list = services.sessions
        switch RunPlan.notifiedOpenStep(sessionId, rows: list.rows, loaded: list.loaded) {
        case .wait:
            return
        case .drop:
            notifiedWait = nil
        case .open:
            guard let runner else { return }
            notifiedWait = nil
            selection.selectedId = sessionId
            runner.run(.open, sessionId)
        }
    }

    // True when the window has the focus. A headless window counts as focused, so the background
    // moves.
    private var windowFocused: Bool {
        WindowShow.seenFocused(windowKey, headless: headless)
    }

    // The focus input of the alert rule: the window is open and has the focus. A closed window
    // can keep its last key state, so it counts as not focused. A headless window counts as
    // focused, so no alert notification shows.
    private var alertFocused: Bool {
        WindowShow.seenFocused(windowOpen && windowKey, headless: headless)
    }

    // MARK: - The settings

    // The settings of the window: the canvas, the side bar, the tooltips, the panel bodies, the
    // Row flash of the Overviews, the terminal font and the animated background.
    public func apply(_ settings: BifrostSettings.Settings) {
        canvas.apply(CanvasSettings(settings, blur: .backdrop))
        sideBar.interfaceScale = settings.interfaceScale
        sideBar.panelTransparency = settings.panelTransparency
        let metrics = CanvasMetrics(interfaceScale: settings.interfaceScale)
        TooltipController.shared.metrics = metrics
        content.sideBarWidth = metrics.points(SideBarView.width)
        look.interfaceScale = settings.interfaceScale
        look.panelTransparency = settings.panelTransparency
        overviews.rowFlash = settings.rowFlash
        chats.setFont(settings.terminalFont, metrics: metrics)
        if motion == nil {
            motion = BackgroundMotion(
                setting: settings.animatedBackground,
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        } else {
            motion?.setSetting(settings.animatedBackground)
        }
        updateMotion()
    }

    // A new key map of the settings, with the dictation key.
    public func setKeys(_ keys: KeyMap) {
        filter.setKeys(keys)
    }

    // The settings store opened: the Settings panel gets its model with the live model, linked
    // to the window and the services. Settings > General gets the version notice of the live
    // model. Then the Setup dialog follows the state, with the dialogs of the window, and the
    // skill export of the Daily update follows the settings. Only the first store counts.
    private func attachSettings(_ store: SettingsStore) {
        guard settingsPanels.model == nil else { return }
        installedApps.follow(store)
        let model = SettingsModel(
            store: store, layout: layout, live: live, links: settingsLinks())
        settingsPanels.attach(model)
        let live = live
        let notices = Observations { LiveRules.claudeVersionNotice(live.version, failed: false) }
        versionFollow = Task { [weak model] in
            for await notice in notices { model?.versionNotice = notice }
        }
        let dialogs = dialogs
        setup = SetupDialog(settings: model, atStart: setupAtStart) { dialogs.setup($0) }
        releaseNotes.startWhatsNew(version: Self.appVersion, settings: store, dialogs: dialogs)
        dailyUpdate.start(settings: store, environment: DailyEnvironment(services)) {
            [weak self] in
            self?.showForAlert()
            self?.layout.apply(.open(.dailyUpdate))
        }
    }

    // The version of the app (CFBundleShortVersionString), or nil.
    static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    // The links of the model of the Settings panel: the values of Settings > General that the
    // settings file does not keep. These are the display mode of the window, the installed apps
    // of the home, why the last change of the login item failed, with the way to the Login Items
    // of System Settings, and the version of the app. The display mode of the window is
    // observed, so the row follows each change. Each open of the panel reads the state of the
    // login item again, so an approval in System Settings clears the note.
    //
    // The model gets the confirm dialog of the window, for Reset all keys, and the state of the
    // dialogs: while a dialog shows, Save is off. A confirmation while another dialog shows gives
    // false. A confirmed turn-on of the automatic comment handling of Reviews reaches the Reviews
    // part (ReviewsParts.autoFixConfirmed).
    package func settingsLinks() -> SettingsLinks {
        let dialogs = dialogs
        let modes = window.modes
        let home = services.home
        let services = services
        return SettingsLinks(
            confirm: { await dialogs.confirm($0, openFolder: nil, onBusy: {}) },
            dialogShows: { dialogs.isOpen }, displayMode: { modes.mode },
            requestDisplayMode: { modes.request($0) },
            appFinder: {
                GeneralApps.find(home: home, terminal: $0, exists: ProjectApps.fileExists)
            },
            loginItemProblem: { [weak services] in services?.loginItemProblem },
            openLoginItems: { SystemLoginItem.openSystemSettings() },
            onPanelOpen: { [weak services] in services?.readLoginItemAgain() },
            appVersion: Self.appVersion,
            reviews: ReviewsLinks(
                confirmAutoFix: { [weak services] in services?.reviews?.autoFixConfirmed() },
                removeClones: { [weak services] in await services?.reviews?.removeAllClones() }),
            updates: UpdatesLinks(
                version: updater.version, state: updater.state, check: updater.check,
                openReleaseNotes: { [weak self] in _ = self?.openReleaseNotes() }),
            dailyUpdate: DailyUpdateLinks(
                readInventory: { [dailyUpdate] in await dailyUpdate.readInventory() },
                unavailable: { [dailyUpdate] in dailyUpdate.unavailable },
                openPanel: { [weak self] in self?.layout.apply(.open(.dailyUpdate)) }))
    }

    // Open the release notes dialog (Settings > Updates, and the test port).
    @discardableResult
    public func openReleaseNotes() -> Bool {
        releaseNotes.open(in: dialogs)
    }

    // MARK: - The animated background

    // The key state of the window: the background moves only in the key window, a drag turns
    // the cursor rects on again when the window stops being the key window, and the key window
    // lets a warning of Live details read again.
    private func keyChanged(_ key: Bool) {
        windowKey = key
        if !key { canvas.windowResignedKey() }
        // A warning of Live details can read again when the window gets the focus.
        if key { live.windowFocused() }
        updateMotion()
    }

    private func reduceMotionChanged() {
        motion?.setReduceMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        updateMotion()
    }

    // The fields move only with the setting on, an active window and no reduced motion. A
    // headless window counts as focused and visible.
    private func updateMotion() {
        guard var next = motion else { return }
        #if DEBUG
        let focused = benchMotion ?? windowFocused
        #else
        let focused = windowFocused
        #endif
        let visible = WindowShow.seenVisible(windowVisible, headless: headless)
        next.setWindowActive(BackgroundMotion.windowActive(focused: focused, visible: visible))
        motion = next
        content.background.apply(next)
    }

    #if DEBUG
    // MARK: - The debug bench

    // The PTY manager of the chats, after the services found claude. The bench checks its claude.
    public var ptys: PTYManager? { services.ptys }

    // The phase of the background motion (moving, paused or still), or none before the settings
    // open. The test port shows it, so a bench run shows that the background moves.
    public var backgroundPhase: String { motion.map { "\($0.phase)" } ?? "none" }

    // The parts of the window for a run of the debug bench: the window, the canvas, the layout, the
    // chats, the PTY manager, the session IDs of the rows (sorted) and the motion of the
    // background.
    public func benchStage() -> BenchStage {
        BenchStage(
            window: window.window, canvas: canvas, layout: layout, chats: chats,
            ptys: { [weak services] in services?.ptys },
            sessionIds: { [weak services] in
                Set((services?.sessions.rows ?? []).map(\.sessionId)).sorted()
            },
            setMotion: { [weak self] motion in
                self?.benchMotion = motion
                self?.updateMotion()
            })
    }

    // MARK: - The test port

    // The Overview panels of the layout for the state of the test port, in the order of the
    // frames: for each panel, its ID, the ID of the active tab, the sort column and its
    // direction, and the rows of the active tab in view order (the ID and the name of each row).
    public var overviewsState: JSONValue {
        let panels = layout.layout.frames.flatMap(\.panels).filter { $0.kind == .overview }
        return .array(
            panels.map { panel in
                let tab = overviews.config(panel).activeTab
                let rows = overviews.viewRows(panel).map { row -> JSONValue in
                    ["id": .string(row.sessionId), "name": .string(row.name)]
                }
                return [
                    "panel": .string(panel.text), "tab": .string(tab.id),
                    "sort": .string(tab.sort.column.rawValue),
                    "desc": .bool(tab.sort.descending), "rows": .array(rows),
                ]
            })
    }

    // The report of the import of this start for the state of the test port: the fields of the
    // marker file with no version. null when no import ran.
    public var importState: JSONValue {
        guard let report = services.importReport else { return .null }
        return [
            "at": .int(report.at), "imported": .array(report.imported.map(JSONValue.string)),
            "kept": .array(report.kept.map(JSONValue.string)),
            "skipped": .object(report.skipped.mapValues(JSONValue.string)),
        ]
    }

    // The saved settings for the state of the test port: the fields of settings.json. null
    // before the settings store opens.
    public var settingsState: JSONValue {
        guard let settings = services.settings?.settings,
            let fields = SettingsPatch.fields(of: settings)
        else { return .null }
        return .object(fields)
    }

    // The status of Live details for the state of the test port, as the live model has it: the
    // fields of LiveStatus. null before the first read.
    public var liveDetailsState: JSONValue {
        guard let status = live.status else { return .null }
        return [
            "plugin": .string(status.plugin.rawValue), "modCurrent": .bool(status.modCurrent),
            "oldInstall": .bool(status.oldInstall), "listening": .bool(status.listening),
            "liveSessions": .int(status.liveSessions),
            "claudeVersion": status.claudeVersion.map(JSONValue.string) ?? .null,
            "versionOk": .bool(status.versionOk),
            "error": status.error.map(JSONValue.string) ?? .null,
        ]
    }

    // The status of the skills for the state of the test port, as the live model has it: the
    // plugin, folderCurrent, the names of the skills and the error. null before the first read.
    public var skillsPluginState: JSONValue {
        guard let status = live.skillsStatus else { return .null }
        return [
            "plugin": .string(status.plugin.rawValue), "folderCurrent": .bool(status.folderCurrent),
            "skills": .array(status.skills.map { .string($0.name) }),
            "error": status.error.map(JSONValue.string) ?? .null,
        ]
    }

    // The rows of the session list for the state of the test port, in the order of the list: the
    // session ID, the state, the pid or null, and listed (SessionRow.listedActive).
    public var sessionsState: JSONValue {
        .array(
            services.sessions.rows.map { row -> JSONValue in
                [
                    "id": .string(row.sessionId), "state": .string("\(row.state)"),
                    "pid": row.pid.map { .int(Int($0)) } ?? .null,
                    "listed": .bool(row.listedActive),
                ]
            })
    }

    // Run the session command Resume on the row of the session for the test port, as the Resume
    // action does. The result is nil when the resume worked, else the text of the refusal.
    public func resumeSession(_ sessionId: String) async -> String? {
        guard let actions = services.actions else { return ActionRefusal.claudeNotFound.message }
        do throws(ActionRefusal) {
            _ = try await actions.run(.resume(sessionId))
            return nil
        } catch {
            return error.message
        }
    }

    // Run an action of Live details (skills false) or of the skills (skills true) for the test
    // port, as the button of its section does, but with no confirm for Remove. The result is nil
    // when the action worked, else the text of the failure.
    public func runPluginAction(_ action: LiveAction, skills: Bool) async -> String? {
        await live.runAction(action, skills ? .skills : .live)?.message
    }

    // Change the settings with the patch of a request of the test port, in one edit of the
    // settings store (SettingsPatch). The result is nil when the edit saved, else the reason
    // for the answer. A refused patch changes nothing.
    public func changeSettings(_ patch: [String: JSONValue]) async -> String? {
        do throws(SettingsPatchRefusal) {
            guard let store = services.settings else { throw .notOpen }
            let change = try SettingsPatch(patch, settings: store.settings)
            do throws(SettingsError) {
                try await store.edit { change.apply(to: &$0) }
            } catch {
                throw .notSaved(error)
            }
            return nil
        } catch {
            return error.message
        }
    }

    // The Event log for the state of the test port: the number of entries and the texts of the
    // newest 5 (TestPortMessage.events).
    public var eventsState: JSONValue { TestPortMessage.events(services.eventLog.entries) }

    // The Usage HUD for the state of the test port: the bars and the source line of now. The
    // values hold no token.
    public var usageState: JSONValue {
        let view = UsageView.of(
            services.registry?.usage, now: services.now().millisecondsSince1970,
            account: services.poller?.value, zone: .autoupdatingCurrent)
        return TestPortMessage.usage(bars: view.bars, source: view.source)
    }

    // The Reviews panel: the rows of both tabs, the consent of the automatic rounds and the
    // problem line (TestPortMessage.reviews).
    public var reviewsState: JSONValue {
        let snapshot = ReviewsParts.snapshot(
            settings: services.settings?.settings, parts: services.reviews,
            claudeMissing: services.sessions.status == .claudeNotFound)
        let parts = services.reviews
        return TestPortMessage.reviews(
            snapshot, consent: parts?.autoFixConsent, round: { parts?.round(of: $0) })
    }

    // The rows that the Watchlist shows, in watch order, or null while it is in no frame.
    public var watchlistState: JSONValue {
        guard let panel = watchlist.shown else { return .null }
        return TestPortMessage.rows(panel.input?.rows ?? [])
    }

    // The release notes dialog: null while it does not show (ReleaseNotesHost.testPortState).
    public var releaseNotesState: JSONValue { releaseNotes.testPortState(of: dialogs) }

    // The Daily update: null with no service (DailyUpdateHost.testPortState).
    public var dailyUpdateState: JSONValue { dailyUpdate.testPortState }

    // The level of the Performance monitor and its number of reasons.
    public var performanceState: JSONValue { performance.testPortState }

    // The daily op of the test port (DailyUpdateHost.testPortOp).
    public func runDailyTest(_ action: TestDailyAction) -> String? {
        dailyUpdate.testPortOp(action)
    }

    // The PR line of each Show Info panel in a frame: the panel ID and the PR
    // (TestPortMessage.pr).
    public var showInfoState: JSONValue {
        .array(
            showInfo.models.map { model in
                [
                    "panel": .string(PanelID.showInfo(model.session).text),
                    "pr": TestPortMessage.pr(model.pr),
                ]
            })
    }

    // Why the test port cannot sort an Overview. The message is the error text of the answer.
    public enum OverviewSortRefusal: Error, Equatable {
        // The panel is not an Overview in a frame.
        case notOpen
        // The active tab hides the column, so its header is not there to click.
        case hiddenColumn

        public var message: String {
            switch self {
            case .notOpen: "the Overview is not open"
            case .hiddenColumn: "the column is not visible in the active tab"
            }
        }
    }

    // Sort the active tab of the Overview panel by the column, as a click on its header does: a
    // new column sorts in its first direction, and the sort column changes its direction. A
    // panel that is not in a frame, or a column that the active tab hides, gives a refusal and
    // changes nothing.
    public func sortOverview(
        _ panel: PanelID, by column: OverviewColumn
    ) throws(OverviewSortRefusal) {
        guard panel.kind == .overview, overviews.isOpen(panel) else { throw .notOpen }
        let tab = overviews.config(panel).activeTab
        guard tab.columns.contains(column) else { throw .hiddenColumn }
        overviews.update(panel, .sortBy(tab.id, column))
    }

    // The session actions for the state of the test port: the selected ID, the notice line and
    // the error line of the runner, whether a dialog shows, and the IDs of the rows with an
    // action that did not end, in the order of the rows. Before the runner, the lines are null
    // and no row runs.
    public var actionsState: [String: JSONValue] {
        let rows = services.registry?.rows ?? []
        let running = runner.map { runner in rows.filter { runner.isRunning($0.sessionId) } } ?? []
        return [
            "selected": selection.selectedId.map(JSONValue.string) ?? .null,
            "notice": runner?.notice.map(JSONValue.string) ?? .null,
            "error": runner?.error.map(JSONValue.string) ?? .null,
            "dialog": .bool(dialogs.isOpen),
            "running": .array(running.map { .string($0.sessionId) }),
        ]
    }

    // Run the action of a request of the test port, with the answers to its dialogs
    // (TestActionDriver). The result is nil at the end of the run, else the reason for the
    // answer.
    public func runTestAction(_ action: TestAction) async -> String? {
        guard let runner else { return "the session actions need claude" }
        return await TestActionDriver.run(action, on: runner, clock: services.clock)
    }

    // Type the text into the session, as the send box does. The result is nil at the end of the
    // send, else the reason for the answer.
    public func sendTestText(_ session: SessionID, _ text: String) async -> String? {
        guard let runner else { return "the session actions need claude" }
        return await TestActionDriver.send(text, to: session, on: runner)
    }
    #endif
}
