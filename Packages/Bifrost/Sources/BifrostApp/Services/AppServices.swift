import BifrostDailyUpdate
import BifrostDictation
import BifrostFoundation
import BifrostHealth
import BifrostLayout
import BifrostLive
import BifrostReviews
import BifrostSessions
import BifrostSettings
import BifrostWindows
import Foundation
import OSLog
import Observation

// The services of the app: the settings store, the registry, the session commands, the Live
// details control and its server, the skills control, the PTY manager of the chats, the two UI
// stores, the dictation service, the notifier, the Event log, the account usage poller, the usage
// notification, the PR lookup of Show Info and Reviews, and the model of the session list that the
// window shows.
//
// The class is observable. The shell, the panels and the app delegate read its properties, and
// follow their changes with Observations (or SwiftUI): the session list in sessions (the rows, the
// status and loaded), and the services that each step of the start makes (settings, registry,
// actions, ptys, liveControl, skillsControl, uiState, windowState, usageAlerts, prLookup and
// reviews).
// Each service property gets its value one time, at its step, and keeps it.
//
// The init is synchronous and makes only the model, in the "starting" status, so the window can
// show it at once (docs/behaviour/shell.md, The start order), the dictation service, which does
// no engine work until a chat warms it, the notifier, the Event log and the account usage poller,
// which does not poll until start() turns it on. The app makes the services before its launch
// ends, so the system notifier is the delegate of the notification centre in time for a click.
// openUIStores() first runs the one-time import of the Electron data (ElectronImport), then opens
// ui-state.json and window-state.json before the window shows. Then start() does the work of the
// start, in this order:
// 0. Wait for the end of the import (one task for the two calls), so no store opens before it.
// 1. Open settings.json and registry.json. The settings property gets the store at once, so the
//    window can apply the settings before the slow steps. A release app then saves the real state
//    of its login item (SettingsEffects.loginItemFix), and the effects of each later change of
//    the settings run (SettingsEffects). Then usage-alerts.json opens, and the usage notification
//    follows the session usage and the account values. The poller polls while Account usage is
//    on in Settings, and the check of the status pages starts.
// 2. Find claude and the base env of each claude run (see ClaudeLookup).
// 3. With no claude, the model shows "claude not found", and nothing more starts.
// 4. Make the PTY manager of the chats with the claude runner, so it exists before the first rows
//    come.
// 5. Make the registry with the escalation time and the poll interval of the settings. The model
//    reads the rows and the error from the registry, their one place, from the end of its first
//    active poll. The registry follows each later change of these two settings. The Event log
//    reads its state events. Then make the session commands, which read the rows of the
//    registry, the PR lookup of Show Info, and Reviews, which starts to follow its settings.
// 6. Make the Live details control, with the server on the shared socket of the shared home, and
//    the skills control, and start the two in the same turn of the main actor, Live details
//    first. Each start runs as a task in the lock of the plugin changes, in the order of the
//    calls: the clean-up of the old hook data and the start rule of Live details (LiveControl),
//    then the start rule of the skills (SkillsControl). The registry does not wait for them. Each
//    batch of lines of the mod goes to the registry.
// 7. Start the registry.
@MainActor
@Observable
public final class AppServices {
    // The steps of the life of the services.
    private enum Phase {
        case waiting, starting, started, stopped
    }

    public let sessions = SessionListModel()
    // These services exist after their step of start().
    public private(set) var settings: SettingsStore?
    package private(set) var registry: RegistryService?
    // The session commands (New session, Stop, Resume, Resume all, Delete and Take control), on
    // the registry, after start() found claude.
    package private(set) var actions: SessionActions?
    // The Live details control, after start() found claude. Its server listens on the shared
    // socket by the start rule.
    package private(set) var liveControl: LiveControl?
    package var liveServer: LiveServer? { liveControl?.server }
    // The skills control, after start() found claude. It shares the lock of Live details.
    package private(set) var skillsControl: SkillsControl?
    // The one lock of the plugin changes of Live details and of the skills (SerialLock).
    package let pluginLock = SerialLock()
    // The PTY manager of the chat windows and of the hidden attaches, after start() found
    // claude. Its owner sets its callbacks, gives each view to the session input and each chat
    // view to the chat terminals.
    public private(set) var ptys: PTYManager?
    // The UI state and the window state, after openUIStores().
    public private(set) var uiState: UIStateStore?
    public private(set) var windowState: WindowStateStore?
    // Why the last change of the login item failed, so Settings can show its text. nil when the
    // last change worked, or before any change.
    public private(set) var loginItemProblem: LoginItemError?
    // The one reader of the terminal size of a session process. The chat terminals and the session
    // input share it.
    public let sessionSizes: SessionSizeReader
    // The dictation service of the chat windows. The init makes it with the engine of the plan. The
    // engine does no work until a chat warms it.
    public let dictation: DictationService
    // The vim mode check of a hold of the dictation key, on the files of the home.
    public let vimMode: VimModeReader
    // The paths of the state that Bifrost shares with Claude Code, under the shared home of the
    // plan.
    package let sharedState: SharedClaudeState
    // The mod folder of the app that the Live details control copies to the shared mod folder.
    private let modSource: URL
    // The skills folder of the app that the skills control copies to the shared skills folder.
    // With no claude, Settings > Skills still lists its skills.
    package let skillsSource: URL
    // The report of the one-time import of this start, after the import. nil when no import ran:
    // the plan has no Electron folder, the marker exists, or the check of the marker failed. The
    // debug test port shows it.
    package private(set) var importReport: ImportReport?
    // The one notifier of the app (the recorder in a test home). The box alerts of the shell and
    // the usage notification show through it.
    package let notifier: any Notifier
    // The one Event log of the app.
    package let eventLog: EventLogModel
    // The poller of the account usage, or nil in a test home. It polls only while Account usage
    // is on in Settings.
    package let poller: AccountPoller?
    // The one health reporter of the app, and its stream of events. The registry, the account
    // usage poller, Live details, the check of the status pages, the update cycle and the stores
    // report to it. The Performance monitor of the shell is the one reader of the stream.
    package let health: HealthReporter
    package let healthEvents: AsyncStream<HealthEvent>
    // The check of the status pages of Claude, GitHub and Sentry, from step 1 until stop(). nil
    // when the plan checks none (a test home).
    package let serviceStatus: ServiceStatusMonitor?
    // The release notes and What's new. nil when the app has no address of the releases.
    package let releaseNotes: ReleaseNotesService?
    // What the Performance monitor of the shell takes from the plan.
    package let performancePlan: PerformancePlan
    // The usage notification, after the settings store opened (step 1).
    package private(set) var usageAlerts: UsageAlertMonitor?
    // The PR lookup of Show Info, after start() found claude: gh gets the env of the claude runs.
    package private(set) var prLookup: PRLookup?
    // A click on a usage notification. The shell shows the window and opens the Usage HUD.
    @ObservationIgnored package var onUsageClick: () -> Void = {}
    // Reviews (ReviewsParts), after start() found claude: gh gets the env of the claude runs. It
    // follows the Reviews settings until stop(). The shell gives the focus of the window for its
    // notifications, and the action of a click on one of them, before start().
    package private(set) var reviews: ReviewsParts?
    @ObservationIgnored package var reviewsFocused: @MainActor () -> Bool = { false }
    @ObservationIgnored package var onReviewsClick: @MainActor () -> Void = {}
    // Reviews stopped: the shell closes the trust panel (its claude ends), the Review panel and
    // the Answer panel.
    @ObservationIgnored package var onReviewsClose: @MainActor () -> Void = {}

    private let plan: StartPlan
    // The resolved home of the app. Settings > General and the session actions find the
    // installed apps in it.
    package let home: URL
    private let environment: [String: String]
    private let runner: any CommandRunner
    private let processes: any ProcessInspector
    // The spawner of the PTYs of the chats. A test records the signals with its own spawner.
    private let ptySpawner: any PTYSpawner
    // The clock of the services. The shell gives it to the chats, to the session input and to
    // the Overviews.
    package let clock: any Clock<Duration>
    // The wall time of the services. The shell gives it to the Overviews for the age texts.
    package let now: @Sendable () -> Date
    private static let logger = Logger(bifrost: "services")
    @ObservationIgnored private var phase = Phase.waiting
    // The tasks that follow the changes of the settings until stop(): the effects from step 1,
    // and the values of the registry from step 5.
    @ObservationIgnored private var follows: [Task<Void, Never>] = []
    // False until the window says that it shows: a closed window polls slowly (user decision,
    // 2026-11-13).
    @ObservationIgnored private var windowVisible = false
    // The task of the one-time import of the Electron data. openUIStores() and start() wait for
    // the same task.
    @ObservationIgnored private var dataImport: Task<ImportReport?, Never>?
    // The login item of a release app, from start(). nil in each other app.
    @ObservationIgnored private var loginItem: (any LoginItemService)?
    // The claude runner, after start() found claude. The version check of liveSources uses it.
    @ObservationIgnored private var claude: ClaudeRunner?

    // gh with the env of the claude runs and the runner of the services, with the folder as its
    // current folder, after start() found claude. Else nil.
    package func gh(in folder: URL) -> GHCommand? {
        claude.map { Self.gh($0, runner: runner, in: folder) }
    }

    private static func gh(
        _ claude: ClaudeRunner, runner: any CommandRunner, in folder: URL
    ) -> GHCommand {
        GHCommand(path: "gh", environment: claude.environment, folder: folder, runner: runner)
    }

    // The services of the app with the real system parts. home is the resolved home of the app
    // (HomeLocator.choose). environment is the env of the app. A test home records the
    // notifications and has no account usage poller (StartPlan).
    public convenience init(plan: StartPlan, home: URL, environment: [String: String]) {
        let clock = ContinuousClock()
        let runner = ProcessRunner()
        // The poller reports to the health reporter of the services, so the reporter comes first.
        let health = HealthReporter.make()
        let poller =
            plan.pollsAccount
            ? AccountPoller(
                runner: runner, fetcher: SessionUsageFetcher(), clock: clock, now: Date.init,
                health: health.reporter)
            : nil
        self.init(
            plan: plan, home: home, environment: environment, runner: runner, clock: clock,
            notifier: appNotifier(testHome: plan.recordsNotifications) { SystemNotifier() },
            poller: poller, statusFetcher: plan.checksServiceStatus ? SessionStatusFetcher() : nil,
            releaseNotes: ReleaseNotesService.source(
                plan: plan, releasesPage: Self.bundledReleasesPage, clock: clock),
            health: health)
    }

    // The seams of the tests. now gives the wall time. speechEngine makes the engine of
    // dictation for the plan. A test gives a fake engine, so no test makes the real engine.
    // processes reads the process table and the session sizes. A test gives a fake, so no test
    // reads a process of the Mac. The notifier is the recorder unless the test gives a fake, and
    // there is no poller unless the test gives one with fakes, so no test shows a notification,
    // reads the Keychain or reaches the network. modSource and skillsSource are the mod folder
    // and the skills folder of the app bundle; a test gives the folders of the repo. health is the
    // health reporter of the app and its stream: a poller that the caller makes reports to it.
    package init(
        plan: StartPlan, home: URL, environment: [String: String],
        runner: any CommandRunner = ProcessRunner(),
        processes: any ProcessInspector = SystemProcessInspector(),
        ptySpawner: any PTYSpawner = SystemPTYSpawner(),
        clock: any Clock<Duration> = ContinuousClock(),
        speechEngine: (StartPlan) -> any SpeechEngine = AppServices.speechEngine(for:),
        now: @escaping @Sendable () -> Date = Date.init,
        notifier: any Notifier = RecordingNotifier(), poller: AccountPoller? = nil,
        statusFetcher: (any StatusFetcher)? = nil, releaseNotes: ReleaseNotesSource? = nil,
        modSource: URL = AppServices.bundledFolder("live-mod"),
        skillsSource: URL = AppServices.bundledFolder("bifrost-skills"),
        health: (reporter: HealthReporter, events: AsyncStream<HealthEvent>) =
            HealthReporter.make()
    ) {
        self.plan = plan
        self.home = home
        self.environment = environment
        self.runner = runner
        self.processes = processes
        self.ptySpawner = ptySpawner
        self.clock = clock
        self.now = now
        sessionSizes = SessionSizeReader(inspector: processes)
        dictation = DictationService(engine: speechEngine(plan), clock: clock)
        vimMode = VimModeReader(home: home)
        sharedState = SharedClaudeState(home: plan.sharedHome)
        self.notifier = notifier
        eventLog = EventLogModel(clock: clock, now: now)
        self.poller = poller
        self.health = health.reporter
        healthEvents = health.events
        serviceStatus = statusFetcher.map {
            ServiceStatusMonitor(fetcher: $0, health: health.reporter, clock: clock, now: now)
        }
        // The file of What's new reports a failed save to the health log, as each store does.
        self.releaseNotes = releaseNotes.map {
            ReleaseNotesService(
                source: $0, whatsNewFile: plan.opensWhatsNew ? plan.releaseNotesFile : nil,
                log: HealthStoreLog(health: health.reporter))
        }
        performancePlan = PerformancePlan(plan)
        self.modSource = modSource
        self.skillsSource = skillsSource
    }

    // The Releases page of the project on GitHub, from the Info.plist key BifrostReleasesURL (the
    // build setting BIFROST_RELEASES_URL). nil when the key is missing or is no https address.
    nonisolated package static var bundledReleasesPage: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "BifrostReleasesURL") as? String,
            let url = URL(string: text), url.scheme == "https"
        else { return nil }
        return url
    }

    // A folder in the resources of the app bundle: Contents/Resources/live-mod for the mod, and
    // Contents/Resources/bifrost-skills for the skills.
    nonisolated package static func bundledFolder(_ name: String) -> URL {
        (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
            .appending(path: name, directoryHint: .isDirectory)
    }

    // The Live details control, the skills control and the version check of Claude Code for the
    // minimum of Bifrost, after start() found claude, else nil. The live model of Settings reads
    // them.
    package var liveSources: LiveModel.Sources? {
        guard let liveControl, let skillsControl, let claude else { return nil }
        return LiveModel.Sources(live: liveControl, skills: skillsControl) {
            await ClaudeVersion.check(claude, minimum: ClaudeVersionCheck.appMinimum)
        }
    }

    // The speech engine of the plan: the fake engine for a development app with a test home in
    // a Debug build, else the real engine. The real engine does no work at its init.
    nonisolated package static func speechEngine(for plan: StartPlan) -> any SpeechEngine {
        #if DEBUG
        if plan.fakeSpeech { return FakeSpeechEngine(script: .helper) }
        #endif
        return AnalyzerEngine()
    }

    // Import the Electron data one time, then open ui-state.json and window-state.json from the
    // files of the plan. The import, the read and the parse run off the main actor. The app calls
    // this one time, before the window shows and before start(). A call after the first call
    // ended opens nothing. Each store tells the health log about a failed save.
    public func openUIStores() async {
        await importElectronData()
        if uiState == nil {
            uiState = await UIStateStore.open(file: plan.uiStateFile, clock: clock, log: storeLog)
        }
        if windowState == nil {
            windowState = await WindowStateStore.open(file: plan.windowStateFile, log: storeLog)
        }
    }

    // The log of the store files: the system log, and the health log for a failed save.
    private var storeLog: HealthStoreLog { HealthStoreLog(health: health) }

    // Start the services. A second call does nothing. After stop(), nothing more starts, also
    // when the call waits for a step. loginItem is the login item of a release app, or nil when
    // the app must not have one (LoginItemRule). effects runs the effects of a settings change
    // that reach the app target: the menu, the zoom and the updates.
    public func start(
        loginItem: (any LoginItemService)? = nil,
        effects: @escaping @MainActor (SettingsEffect) -> Void = { _ in }
    ) async {
        guard phase == .waiting else { return }
        phase = .starting
        self.loginItem = loginItem
        // The import of openUIStores() ends before a store opens, also when no caller called
        // openUIStores() first.
        await importElectronData()
        guard phase == .starting else { return }
        let settings = await SettingsStore.open(file: plan.settingsFile, log: storeLog)
        self.settings = settings
        if let loginItem { await Self.takeLoginState(of: loginItem, into: settings) }
        guard phase == .starting else { return }
        // An edit during the fix save (release only) is in the first value and runs no effect.
        followEffects(of: settings, loginItem: loginItem, effects: effects)
        await startUsageAlerts(settings)
        guard phase == .starting else { return }
        if settings.settings.accountUsage { poller?.start() }
        serviceStatus?.start()
        let store = await Self.openStore(plan.registryFile.path, log: storeLog)
        guard phase == .starting else { return }
        let claude = await findClaude()
        guard phase == .starting else { return }
        guard let claude else {
            Self.logger.error("Bifrost cannot find claude, so it does not read the session list.")
            sessions.claudeMissing()
            return
        }

        self.claude = claude
        ptys = PTYManager(claude: claude, spawner: ptySpawner)

        // The values of the settings after the waits.
        let values = registryValues(settings.settings)
        let deps = RegistrySystemDeps(
            claude: claude, runner: runner, skipRoots: plan.branchSkipRoots, saver: store.saver,
            processes: processes)
        let registry = RegistryService(
            registry: SessionRegistry(store: store.store, escalation: values.escalation),
            deps: deps, clock: clock, now: now, timing: values.timing, health: health)
        registry.setWindowVisible(windowVisible)
        sessions.read(from: registry)
        eventLog.read(registry.events)
        follow(settings, into: registry)
        self.registry = registry
        actions = makeActions(claude, on: registry)
        prLookup = PRLookup(
            runner: runner, environment: claude.environment, skipRoots: plan.branchSkipRoots,
            clock: clock)
        reviews = makeReviews(claude, settings: settings)
        reviews?.start()

        let live = makeLiveControl(claude, on: registry)
        let skills = makeSkillsControl(claude)
        liveControl = live
        skillsControl = skills
        // The two starts in this turn, Live details first, so the lock runs them in that order.
        // A start that does not listen logs its reason (LiveServer), and the app goes on.
        live.start()
        skills.start()

        phase = .started
        registry.start()
    }

    // Read the state of the login item again, when Settings opens and when the app becomes
    // active. The user can allow a login item that waits for the approval in System Settings
    // while Bifrost runs. When the real state now agrees with Start at login, the problem of the
    // last change is gone, so loginItemProblem clears. With no login item (a development app) or
    // no problem, the call does nothing.
    public func readLoginItemAgain() {
        guard loginItemProblem != nil, let loginItem, let settings else { return }
        if loginItem.isOn == settings.settings.startAtLogin { loginItemProblem = nil }
    }

    // The window shows (true) or hides (false). A hidden window polls slowly.
    public func setWindowVisible(_ visible: Bool) {
        windowVisible = visible
        registry?.setWindowVisible(visible)
    }

    // Stop the dictation, the usage notification, the poller, the PR lookup, Reviews, the session
    // commands, the registry, the Event log, the Live details control and the skills control,
    // and close each PTY. A close only detaches: the SIGHUP goes to the attach child, never to the
    // session. A start that waits then starts nothing. The stop of the session commands cancels
    // each job and refuses each later command, and sends nothing to a claude rm that runs.
    public func stop() {
        phase = .stopped
        // The microphone closes at a quit.
        dictation.stopAll()
        for follow in follows { follow.cancel() }
        follows = []
        usageAlerts?.stop()
        poller?.stop()
        serviceStatus?.stop()
        prLookup?.stop()
        reviews?.stop()
        actions?.stop()
        registry?.stop()
        eventLog.stop()
        liveControl?.stop()
        skillsControl?.stop()
        ptys?.closeAll()
    }

    // The claude runner, after start() found claude. nil before it, and when claude is missing.
    package var claudeRunner: ClaudeRunner? { claude }

    // The files of the Daily update, in the Daily update folder of the shared home.
    package var dailyLayout: DailyLayout { DailyLayout(folder: sharedState.dailyUpdateFolder) }

    // True when the app bounces its Dock icon for a reminder: not in a test home.
    package var bouncesDock: Bool { !plan.recordsNotifications }

    // The save of the last change of the notified periods, or nil. A quit waits for it.
    package var usageAlertsSave: Task<Void, Never>? { usageAlerts?.save }

    // macOS refused a notification: the Event log keeps one line for it.
    package func notificationRefused() {
        eventLog.notice(EventLog.notificationRefused)
    }

    // The run folder of Open in terminal, from the plan.
    package var runFolder: URL { plan.runFolder }

    // MARK: - The steps

    // Step 0: the one-time import of the Electron data into the support folder of the plan, the
    // folder of the store files. Only a development identity has an Electron folder to import.
    // The marker of the import stops each later run, also in a later start of the app.
    // importReport gets the report.
    private func importElectronData() async {
        guard let folder = plan.electronSupport else { return }
        let support = plan.settingsFile.deletingLastPathComponent()
        let task =
            dataImport
            ?? Task { [now] in
                await ElectronImport.runOnce(
                    from: ElectronStores(folder: folder), to: support, now: now(),
                    log: SystemImportLog())
            }
        dataImport = task
        importReport = await task.value
    }

    // Step 1: open usage-alerts.json after the settings store, then make the usage notification.
    // It reads the setting Notifications at each check, and it follows the session usage of the
    // registry (after step 5) and the account values of the poller.
    private func startUsageAlerts(_ settings: SettingsStore) async {
        let store = await UsageAlertStore.open(
            file: plan.usageAlertsFile, now: now(), log: storeLog)
        guard phase == .starting else { return }
        let monitor = UsageAlertMonitor(
            store: store, home: plan.sharedHome, enabled: { settings.settings.notifications },
            notify: { [weak self] in self?.notifyUsage(title: $0, body: $1) }, now: now)
        monitor.follow(
            session: { [weak self] in self?.registry?.usage },
            account: { [weak self] in self?.poller?.value })
        usageAlerts = monitor
    }

    // The usage notification goes straight to the notifier: unlike a box alert, it shows also
    // while the window has the focus. A click shows the window and opens the Usage HUD.
    private func notifyUsage(title: String, body: String) {
        notifier.show(
            AlertNote(title: title, body: body, source: .usageLimit),
            onClick: { [weak self] _ in self?.onUsageClick() },
            onFailed: { [weak self] in self?.notificationRefused() })
    }

    // Step 1: the real state of the login item wins over the file. The user can change the login
    // item in System Settings while Bifrost does not run. A failed save does not stop the start.
    private static func takeLoginState(
        of loginItem: any LoginItemService, into settings: SettingsStore
    ) async {
        guard let on = SettingsEffects.loginItemFix(settings.settings, realOn: loginItem.isOn)
        else { return }
        do throws(SettingsError) {
            try await settings.edit { $0.startAtLogin = on }
        } catch {
            let reason = error.message
            logger.error(
                "Bifrost cannot save the state of the login item. \(reason, privacy: .private)")
        }
    }

    // Step 1: run the effects of each change of the settings, in the order of SettingsEffects.
    // The settings of now are the first old value, so the open runs no effect. The services
    // change the login item, and effects gets the menu, the zoom and the updates. A failed effect
    // does not stop the effects after it. stop() ends the observation.
    private func followEffects(
        of settings: SettingsStore, loginItem: (any LoginItemService)?,
        effects: @escaping @MainActor (SettingsEffect) -> Void
    ) {
        let changes = Observations { settings.settings }
        let first = settings.settings
        follows.append(
            Task { [weak self] in
                var old = first
                for await new in changes {
                    guard !Task.isCancelled, let self else { return }
                    for effect in SettingsEffects.effects(old, new) {
                        runEffect(effect, loginItem: loginItem, effects: effects)
                    }
                    old = new
                }
            })
    }

    // Run one effect of a settings change. With no login item (a development app), Start at
    // login saves and registers nothing. A failed change of the login item goes to the log and
    // to loginItemProblem, and a later good change clears loginItemProblem.
    private func runEffect(
        _ effect: SettingsEffect, loginItem: (any LoginItemService)?,
        effects: @MainActor (SettingsEffect) -> Void
    ) {
        switch effect {
        case .loginItem(let on):
            guard let loginItem else { return }
            do throws(LoginItemError) {
                try loginItem.set(on)
                loginItemProblem = nil
            } catch {
                loginItemProblem = error
                let reason = String(describing: error)
                Self.logger.error(
                    "Bifrost cannot change the login item: \(reason, privacy: .public).")
            }
        case .menu, .zoom, .updates:
            effects(effect)
        // The poller polls at once when the setting turns on. Off clears its values.
        case .accountUsage(let on):
            if on { poller?.start() } else { poller?.stop() }
        case .reviews, .reviewsView, .reviewsPoll, .reviewsAutoFix:
            // Reviews follows its settings itself (ReviewsParts), so these effects do nothing.
            break
        }
    }

    // Step 5: the registry follows the escalation time and the interval of the active poll of
    // the settings. The observation gives the values of now first: the registry has them, and a
    // set of the same value changes nothing. stop() ends the observation.
    private func follow(_ settings: SettingsStore, into registry: RegistryService) {
        let changes = Observations { registryValues(settings.settings) }
        follows.append(
            Task { [weak registry] in
                for await values in changes {
                    guard !Task.isCancelled, let registry else { return }
                    registry.setEscalation(values.escalation)
                    registry.setActiveInterval(values.timing.active)
                }
            })
    }

    // Step 5: Reviews on the Reviews folder of the shared home. gh gets the env of the claude
    // runs, and its runs are in the Reviews folder. The store saves through the health log. git
    // gets the same env, and the clones come from GitHub (a test home: from its local bare
    // repositories, in a Debug build only). The trust read uses .claude.json of the shared home,
    // and the trust runs open on the PTY manager. The PR sessions run on claude, the registry and
    // the session commands, with the bundled skills; in a test home their names start with
    // bifrost-test-. The sandbox of a request session refuses the secret paths of the real home.
    private func makeReviews(_ claude: ClaudeRunner, settings: SettingsStore) -> ReviewsParts {
        let folder = sharedState.reviewsFolder
        let layout = ReviewsLayout(folder: folder)
        let sessions = registry.flatMap { registry in
            actions.map {
                SessionParts(
                    claude: claude, registry: registry, actions: $0, skills: skillsSource,
                    userHome: plan.realHome,
                    testPrefix: plan.reviewsRemotes != nil)
            }
        }
        return ReviewsParts(
            settings: settings, layout: layout,
            access: GHRunner(gh: Self.gh(claude, runner: runner, in: folder)),
            notifier: notifier, health: health, storeLog: HealthStoreLog(health: health),
            log: SystemReviewsLog(), clock: clock, now: now,
            focused: { [weak self] in self?.reviewsFocused() ?? false },
            refused: { [weak self] in self?.notificationRefused() },
            openPanel: { [weak self] in self?.onReviewsClick() },
            repos: makeRepoStore(claude, layout: layout), ptys: ptys, trustHome: plan.sharedHome,
            sessions: sessions, closed: { [weak self] in self?.onReviewsClose() },
            eventLine: { [weak self] in self?.eventLog.line($0) })
    }

    // The repo store of Reviews. Each clone comes from https://github.com/<owner>/<repo>.git. A
    // Debug build with a test home takes it from <test home>/git-remotes/<owner>/<repo>.git, with
    // the closed test-home items of RepoGit (a commit identity and local remotes).
    private func makeRepoStore(_ claude: ClaudeRunner, layout: ReviewsLayout) -> RepoStore {
        let (environment, clock, log) = (claude.environment, clock, SystemReviewsLog())
        #if DEBUG
        if let remotes = plan.reviewsRemotes {
            let identity = CommitIdentity(
                name: "Bifrost Test", email: "bifrost-test@example.invalid")
            let git = RepoGit(
                path: "git", environment: environment, layout: layout, identity: identity,
                localRemotesForTestHome: true, runner: runner)
            let address: @Sendable (RepoName) -> URL = {
                remotes.appendingPathComponent($0.key + ".git", isDirectory: true)
            }
            return RepoStore(
                layout: layout, git: git, cloneAddress: address, clock: clock, log: log)
        }
        #endif
        let git = RepoGit(path: "git", environment: environment, layout: layout, runner: runner)
        // A repository name holds only letters, digits, ".", "_" and "-", so the address always
        // parses. The fallback is an address that RepoGit refuses (only https reaches a remote).
        return RepoStore(
            layout: layout, git: git,
            cloneAddress: { repo in
                URL(string: "https://github.com/\(repo.key).git")
                    ?? URL(filePath: "/dev/null", directoryHint: .notDirectory)
            }, clock: clock, log: log)
    }

    // <shared home>/.claude/projects: the projects folder of Claude Code, with the transcripts.
    // The session commands and Hand over only read it.
    package var claudeProjects: URL {
        plan.sharedHome.appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    // Step 5: the session commands on the registry. git gets the env of the claude runs, so it is
    // the git of the login PATH, and it runs in no folder at or below a skip root. The commands
    // only read the projects folder of Claude Code (claudeProjects). The signals are the real
    // signals: only Take control sends one, after its checks.
    private func makeActions(
        _ claude: ClaudeRunner, on registry: RegistryService
    ) -> SessionActions {
        let environment = claude.environment
        let skipRoots = plan.branchSkipRoots
        return SessionActions(
            claude: { claude }, registry: registry,
            probe: ProcessProbe(
                inspector: processes, runner: runner, environment: environment,
                skipRoots: skipRoots, clock: clock),
            signals: SystemSignals(),
            worktrees: WorktreeChecker(
                runner: runner, environment: environment, skipRoots: skipRoots, clock: clock),
            projects: claudeProjects, clock: clock, log: SystemSessionsLog())
    }

    // Step 6: the Live details control on the shared paths. The plugin commands get the env of
    // the plugin home of the plan (a test home), and a SuspendingClock for their limit of 40 s.
    // The version check uses the normal runner. The server takes the lines on the shared socket
    // and gives each batch to the registry.
    private func makeLiveControl(
        _ claude: ClaudeRunner, on registry: RegistryService
    ) -> LiveControl {
        let plugins = pluginRunner(claude)
        let (clock, now) = (self.clock, self.now)
        return LiveControl(
            paths: sharedState,
            cli: { PluginCLI(claude: plugins, ids: .live, clock: SuspendingClock()) },
            version: { await ClaudeVersion.check(claude, minimum: ClaudeVersionCheck.liveMinimum) },
            server: { socket in
                LiveServer(
                    socketPath: socket.path(percentEncoded: false), clock: clock, now: now,
                    onEvents: { registry.pushLive($0) })
            },
            registry: registry, modSource: modSource, lock: pluginLock,
            forceListen: plan.forceListen, log: SystemLiveLog(), now: now, health: health)
    }

    // Step 6: the skills control on the shared paths, with the lock of Live details. Its plugin
    // commands get the same env and limit as the commands of Live details.
    private func makeSkillsControl(_ claude: ClaudeRunner) -> SkillsControl {
        let plugins = pluginRunner(claude)
        return SkillsControl(
            paths: sharedState,
            cli: { PluginCLI(claude: plugins, ids: .skills, clock: SuspendingClock()) },
            source: skillsSource, lock: pluginLock, log: SystemLiveLog())
    }

    // The runner of the plugin commands: claude with the env of the plugin home of the plan (a
    // test home).
    private func pluginRunner(_ claude: ClaudeRunner) -> ClaudeRunner {
        ClaudeRunner(
            path: claude.path,
            baseEnvironment: PluginCLI.environment(claude.environment, testHome: plan.pluginHome),
            runner: runner)
    }

    // The claude runner, or nil when the app cannot find claude. The base env of the runner is
    // the env of the lookup, so each claude run gets the child env of that env.
    private func findClaude() async -> ClaudeRunner? {
        switch plan.claude {
        case .environmentPath:
            let path = ClaudeLocator.findOnPath("claude", path: environment["PATH"])
            return path.map {
                ClaudeRunner(path: $0, baseEnvironment: environment, runner: runner)
            }
        case .loginShell:
            // One login shell gives the path and the env. The shell is the SHELL of the app env,
            // so the lookup does not read the env of the process.
            let login = await LoginShell.load(
                runner: runner, shell: environment["SHELL"] ?? "/bin/zsh", fallback: environment,
                home: home)
            return login.claudePath.map {
                ClaudeRunner(path: $0, baseEnvironment: login.environment, runner: runner)
            }
        }
    }

    // Open registry.json. The read and the parse run off the main actor.
    @concurrent private static func openStore(
        _ path: String, log: HealthStoreLog
    ) async -> (store: RegistryStore, saver: StoreSaver) {
        StoreFile.open(path: path, log: log)
    }
}

// The values of the registry that come from the settings: the time from a yellow box to red,
// and the timing with the interval of the active poll.
func registryValues(_ settings: Settings) -> (escalation: Duration, timing: RegistryTiming) {
    var timing = RegistryTiming()
    timing.active = .seconds(settings.pollSeconds)
    return (.seconds(settings.escalationMinutes * 60), timing)
}
