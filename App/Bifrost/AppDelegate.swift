import AppKit
import BifrostApp
import BifrostFoundation
import BifrostKeyboard
import BifrostLayout
import BifrostSettings
import BifrostWindows
import OSLog
import SwiftUI

/// The start of the app. It finds the identity, applies the start rule and the start guard,
/// makes the data folders and the updater, runs the one-time import of the Electron data (only
/// the development app imports), opens the two UI stores, makes and shows the shell (the main
/// window with the canvas, the side bar, the panels, the key filter and the chats), starts the
/// debug test port in a Debug build with a test home, and then starts the services
/// (docs/behaviour/shell.md, "The start order").
@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, MainMenuTarget {
    private var updates: Updates?
    private var services: AppServices?
    private var shell: Shell?
    private var appName = "Bifrost"
    // The key map of the key filter: the defaults until the settings open.
    private var keys = KeyMap.defaults
    // False until the settings store opens. The menu and the updater take the settings at the
    // open.
    private var settingsSeen = false
    // The observation of the settings of the services, until the quit.
    private var settingsFollow: Task<Void, Never>?
    // The log of the window: the Zoom items.
    private static let windowLog = Logger(bifrost: "window")
    #if DEBUG
    // The debug test port: only in a Debug build, and only when the plan has a socket (a test
    // home).
    private var testPort: TestPortServer?
    private var testPortHandler: TestPortHandler?
    #endif

    /// True in the Debug configuration. The project defines DEBUG only for that configuration.
    #if DEBUG
    private static let isDebugBuild = true
    #else
    private static let isDebugBuild = false
    #endif

    /// True only in a build that sets the condition BIFROST_CUTOVER. No build configuration
    /// sets it before cutover. Thus the release build does not run before cutover.
    #if BIFROST_CUTOVER
    private static let isCutoverBuild = true
    #else
    private static let isCutoverBuild = false
    #endif

    /// The app has no main nib, so this function makes the delegate and starts the event loop.
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // The application keeps a weak reference to its delegate. This keeps the delegate alive.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    /// A headless test home has no Dock icon and no menu bar. The policy changes before the launch
    /// ends, so the Dock never shows the icon. Bifrost is dark only: the appearance of the app
    /// gives each window, alert and panel the dark look.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        // Before the launch ends, so macOS adds no full-screen item to the first menu.
        MainMenu.registerDefaults()
        let environment = ProcessInfo.processInfo.environment
        guard let identity = AppIdentity(bundleID: Bundle.main.bundleIdentifier),
            case .home(_, let isTest) = Self.homeChoice(identity, environment)
        else { return }
        let headless = WindowShow.headless(testHome: isTest, environment: environment)
        if WindowShow.accessory(testHome: isTest, headless: headless) {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = ProcessInfo.processInfo.environment
        // Before the app knows its home, a test home variable means that a test runs. Then a
        // start error must not take the focus.
        let testRun = environment[HomeLocator.testHomeKey] != nil
        let identity = AppIdentity(bundleID: Bundle.main.bundleIdentifier)
        let problem = StartRule.problem(identity: identity, isDebugBuild: Self.isDebugBuild)
        // The start rule gives a problem for a nil identity. Thus the guard fails only with a
        // problem, and the "??" value is a fallback that does not occur.
        guard let identity, problem == nil else {
            installMenu()
            stop(
                message: "Bifrost can't start", detail: detail(for: problem ?? .missingIdentity),
                testHome: testRun)
            return
        }
        let name = Self.appName(for: identity.variant)
        appName = name
        installMenu()

        guard StartGuard.mayStart(variant: identity.variant, cutover: Self.isCutoverBuild) else {
            stop(
                message: "This build of Bifrost isn't ready to run yet",
                detail: "It's a release build from before the switch to the native app. "
                    + "Use Bifrost Dev for now.",
                testHome: testRun)
            return
        }

        // The home folder of the user in the user database. macOS gives this folder also when
        // HOME names another folder, for example the test home of the smoke test.
        let realHome = FileManager.default.homeDirectoryForCurrentUser
        let home: URL
        let isTestHome: Bool
        switch Self.homeChoice(identity, environment) {
        case .home(let chosen, let isTest):
            home = chosen
            isTestHome = isTest
        case .refused(let value):
            // A refused test home must never fall back to the real home.
            stop(
                message: "\(name) can't start", detail: HomeLocator.refusalText(value),
                testHome: true)
            return
        }
        let folders = DataFolders(identity: identity, home: home)
        do {
            try folders.create()
        } catch {
            stop(
                message: "\(name) can't set up its data folders",
                detail: reason(for: error, folders), testHome: isTestHome)
            return
        }

        updates = Updates(variant: identity.variant)

        let plan = StartPlan(
            identity: identity,
            home: home,
            realHome: realHome,
            testHome: isTestHome,
            folders: folders,
            environment: environment
        )
        // The init only makes the session list in the "starting" status, the notifier, the Event
        // log and the account usage poller. start() below does the work (docs/behaviour/shell.md,
        // The start order). The notifier of a normal home is the delegate of the notification
        // centre, and the init makes it here, before the launch ends, so macOS gives it each
        // click on a notification.
        let services = AppServices(plan: plan, home: home, environment: environment)
        self.services = services
        // Only a release app with no test home has a login item. Bifrost Dev saves Start at
        // login and registers nothing.
        let loginItem: (any LoginItemService)? =
            LoginItemRule.allowed(identity: identity, testHome: isTestHome)
            ? SystemLoginItem() : nil
        // The settings when the store opens (step 1 of the start), then after each change.
        let settings = Observations { services.settings?.settings }
        settingsFollow = Task { [weak self] in
            for await value in settings {
                if let value { self?.settingsChanged(value) }
            }
        }

        let headless = WindowShow.headless(testHome: isTestHome, environment: environment)
        let start = Shell.Start(
            title: name, testHome: isTestHome, headless: headless, debugBuild: Self.isDebugBuild,
            environment: environment)
        // The one-time import of the Electron data runs first, then the two UI stores open. Both
        // run off the main actor (openUIStores). Then the window shows. Then the services start.
        Task {
            await services.openUIStores()
            guard let uiStore = services.uiState, let windowStore = services.windowState else {
                return
            }
            self.openShell(start, services: services, uiStore: uiStore, windowStore: windowStore)
            #if DEBUG
            if let socket = plan.testPort, let shell = self.shell {
                self.startTestPort(
                    socket, shell: shell, testHome: isTestHome ? home : nil,
                    fakeClaude: Bundle.main.object(
                        forInfoDictionaryKey: TestPortHandler.fakeClaudeKey) as? String)
            }
            #endif
            await services.start(
                loginItem: loginItem, effects: { [weak self] in self?.settingsEffect($0) })
        }
    }

    // MARK: - The window

    /// Makes the shell from the two UI stores and shows the window.
    private func openShell(
        _ start: Shell.Start, services: AppServices, uiStore: UIStateStore,
        windowStore: WindowStateStore
    ) {
        // Settings > Updates reads the updater through these closures. Without an updater, Check
        // now is off.
        let updater = updates.map { updates in
            UpdaterHooks(
                version: updates.version, state: updates.state,
                check: { updates.checkForUpdates() })
        }
        let shell = Shell(
            start: start, services: services, uiStore: uiStore, windowStore: windowStore,
            keys: keys, updater: updater ?? .none,
            menu: { [weak self] in self?.runMenuAction($0) })
        self.shell = shell
        // The result of each update cycle and the stop of the automatic checks go to the health
        // log through the shell.
        updates?.cycleResult = { [weak shell] in shell?.updateCycleEnded(ok: $0) }
        updates?.checksStopped = { [weak shell] in shell?.updateChecksStopped() }
        if let settings = services.settings { shell.apply(settings.settings) }
        // The show sends the visibility (a headless window counts as visible) and applies the
        // saved mode.
        shell.show()
    }

    #if DEBUG
    /// Starts the debug test port on the socket of the plan. The bench of the port writes its
    /// results only in the test home.
    private func startTestPort(
        _ socket: String, shell: Shell, testHome: URL?, fakeClaude: String?
    ) {
        let handler = TestPortHandler(shell: shell, testHome: testHome, fakeClaude: fakeClaude)
        let server = TestPortServer(socketPath: socket, handle: { await handler.handle($0) })
        server.onAnswered = { handler.answered($0) }
        testPortHandler = handler
        testPort = server
        Task { _ = await server.start() }
    }
    #endif

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            shell?.show()
        }
        return true
    }

    /// The app became active: the services read the state of the login item again. The user can
    /// allow a login item that waits for the approval in System Settings while Bifrost runs, and
    /// then the note under Start at login clears.
    func applicationDidBecomeActive(_ notification: Notification) {
        services?.readLoginItemAgain()
    }

    /// A quit saves the normal bounds of an open window and the layout (saveNow). The quit waits
    /// for the writes, for 2 s at most.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shell else { return .terminateNow }
        shell.quit { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    /// The last steps of a quit: each chat detaches (SIGHUP to each attach child only), and the
    /// services stop. The sessions continue.
    func applicationWillTerminate(_ notification: Notification) {
        settingsFollow?.cancel()
        #if DEBUG
        testPort?.stop()
        #endif
        shell?.detach()
        services?.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - The settings

    /// The settings when the store opens, and after each change: the window applies them, with
    /// the Interface scale, and a new key map goes to the key filter. The menu builds again and
    /// the updater takes Check for updates automatically when the settings store opens. After
    /// that, the effects of a change reach them (settingsEffect(_:)).
    private func settingsChanged(_ settings: BifrostSettings.Settings) {
        shell?.apply(settings)
        let next = KeyMap(stored: settings.keys)
        let first = !settingsSeen
        settingsSeen = true
        if first || next != keys {
            keys = next
            shell?.setKeys(next)
        }
        if first {
            installMenu()
            updates?.setAutomatic(settings.autoUpdate)
        }
    }

    /// An effect of a settings change that reaches the app target (SettingsEffects). The services
    /// run the other effects.
    private func settingsEffect(_ effect: SettingsEffect) {
        switch effect {
        case .menu: installMenu()
        case .updates(let on): updates?.setAutomatic(on)
        // settingsChanged(_:) gives the window the new scale with the rest of its look.
        case .zoom: break
        case .loginItem, .accountUsage, .reviews, .reviewsView, .reviewsPoll, .reviewsAutoFix: break
        }
    }

    // MARK: - The menu

    /// Builds the menu from the keys of the settings, and makes it the main menu. Before the
    /// settings store opens, the menu has the default keys. The menu reads the store, so it never
    /// shows an older key map. The app builds it again only after a change of a menu key (the
    /// menu effect). The View items get the mode in validateMenuItem(_:).
    private func installMenu() {
        let menuKeys = services?.settings.map { KeyMap(stored: $0.settings.keys) } ?? .defaults
        let model = MenuModel.make(appName: appName, keys: menuKeys)
        MainMenu.install(MainMenu.build(model, target: self))
    }

    /// An item of the Bifrost actions of the menu.
    func runMenuItem(_ sender: NSMenuItem) {
        guard let action = MainMenu.action(of: sender) else { return }
        runMenuAction(action)
    }

    /// Runs an action of the menu. The key commands call this function too.
    func runMenuAction(_ action: MenuItemModel.Action) {
        let app = NSApplication.shared
        switch action {
        case .about: app.orderFrontStandardAboutPanel(nil)
        case .checkForUpdates: updates?.checkForUpdates()
        case .hide: app.hide(nil)
        case .hideOthers: app.hideOtherApplications(nil)
        case .showAll: app.unhideAllApplications(nil)
        case .quit: app.terminate(nil)
        case .undo, .redo, .cut, .copy, .paste, .selectAll:
            // These items go to the first responder (MainMenu). A key command never gives them.
            break
        case .mode(let mode): shell?.window.modes.request(mode)
        case .toggleFullScreen: shell?.window.modes.toggleFullScreen()
        case .zoom(let step): zoom(step)
        case .closePanel: shell?.layout.apply(.closeActive)
        case .minimize: shell?.window.window.performMiniaturize(nil)
        case .zoomWindow: shell?.window.window.performZoom(nil)
        }
    }

    /// Zoom In, Zoom Out and Actual Size change the Interface scale setting. The store then
    /// gives the change to the window. Before the settings open, a Zoom item does nothing.
    private func zoom(_ step: ZoomStep) {
        guard let settings = services?.settings else { return }
        Task {
            do throws(SettingsError) {
                try await settings.edit {
                    $0.interfaceScale = MenuModel.zoomStep($0.interfaceScale, step)
                }
            } catch {
                let reason = error.message
                Self.windowLog.error(
                    "Bifrost cannot change the Interface scale. \(reason, privacy: .private)")
            }
        }
    }

    /// Gives each View item of a mode its check mark, and makes an item grey when it cannot
    /// act: Check for Updates while the updater cannot start a check, the mode items and
    /// Fullscreen while the window is closed, Close Panel while no panel shows, and the Zoom items
    /// before the settings open. AppKit calls this function each time that the menu opens.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let state = MenuState(
            mode: shell?.window.modes.mode ?? .window, windowOpen: shell?.window.isOpen ?? false,
            layout: shell?.layout.layout, settingsOpen: services?.settings != nil,
            canCheckForUpdates: updates?.canCheck ?? false)
        return MainMenu.validate(menuItem, state: state)
    }

    // MARK: - Start errors

    /// Shows the problem in an alert, then quits the app. The alert makes the app active
    /// first, except with a test home.
    private func stop(message: String, detail: String, testHome: Bool) {
        if WindowShow.alertActivates(testHome: testHome) {
            NSApplication.shared.activate()
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApplication.shared.terminate(nil)
    }

    private func detail(for problem: StartProblem) -> String {
        switch problem {
        case .missingIdentity:
            "This copy of the app doesn't have a usable bundle identifier, so it doesn't know "
                + "where to keep its data. Try building the app again."
        case .releaseIdentityInDebugBuild:
            "This is a development build, but its bundle identifier doesn't end in "
                + "\(AppIdentity.developmentSuffix). To keep your Bifrost data safe, it won't "
                + "start. Check the bundle identifier in the Debug settings, then build the app "
                + "again."
        }
    }

    private func reason(for error: any Error, _ folders: DataFolders) -> String {
        if let error = error as? DataFoldersError {
            switch error {
            case .notAFolder(let path):
                return "There's a file where a folder should be:\n\(path)\n\n"
                    + "Move or rename that file, then open the app again."
            }
        }
        return "\(error.localizedDescription)\n\nThe app keeps its data in these folders:\n"
            + "\(folders.support.path)\n\(folders.dot.path)"
    }

    // MARK: - Helpers

    /// The name of the app in the window title and in the app menu.
    static func appName(for variant: AppVariant) -> String {
        switch variant {
        case .development: "Bifrost Dev"
        case .release: "Bifrost"
        }
    }

    /// The home of the app (HomeLocator.choose) with the real home of the user database.
    private static func homeChoice(
        _ identity: AppIdentity, _ environment: [String: String]
    ) -> HomeChoice {
        HomeLocator.choose(
            variant: identity.variant,
            environment: environment,
            realHome: FileManager.default.homeDirectoryForCurrentUser,
            check: .system
        )
    }
}
