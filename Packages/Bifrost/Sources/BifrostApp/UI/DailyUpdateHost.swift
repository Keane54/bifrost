import AppKit
import BifrostDailyUpdate
import BifrostFoundation
import BifrostSessions
import BifrostSettings
import BifrostWindows
import Foundation
import OSLog
import Observation

// What the Daily update takes from the app services.
struct DailyEnvironment {
    let health: HealthReporter
    let eventLog: EventLogModel
    let notifier: any Notifier
    // The skills folder of the app.
    let skills: URL
    let clock: any Clock<Duration>
    let now: @Sendable () -> Date
    // True when a reminder bounces the Dock icon: not in a test home.
    let bouncesDock: Bool
    // macOS refused a reminder: the Event log keeps one line for it.
    let refused: @MainActor () -> Void
    // True when the app found no claude. It reads an observed value.
    let claudeMissing: @MainActor () -> Bool

    @MainActor
    init(_ app: AppServices) {
        health = app.health
        eventLog = app.eventLog
        notifier = app.notifier
        skills = app.skillsSource
        clock = app.clock
        now = app.now
        bouncesDock = app.bouncesDock
        refused = { [weak app] in app?.notificationRefused() }
        let sessions = app.sessions
        claudeMissing = { sessions.status == .claudeNotFound }
    }

    init(
        health: HealthReporter, eventLog: EventLogModel, notifier: any Notifier, skills: URL,
        clock: any Clock<Duration>, now: @escaping @Sendable () -> Date, bouncesDock: Bool,
        refused: @escaping @MainActor () -> Void = {},
        claudeMissing: @escaping @MainActor () -> Bool = { false }
    ) {
        self.refused = refused
        self.claudeMissing = claudeMissing
        self.health = health
        self.eventLog = eventLog
        self.notifier = notifier
        self.skills = skills
        self.clock = clock
        self.now = now
        self.bouncesDock = bouncesDock
    }
}

// The Daily update in the window (docs/behaviour/daily-update.md): its panel, the open of its
// store, its service and the follows that feed the service. The shell holds one.
// - start() opens the store. With another copy of Bifrost on the folder, or a folder that cannot
//   be used, nothing runs and nothing is written, and the panel and Settings say why.
// - With the store open, one follow of the Daily update settings writes the skill export and
//   tells the service to plan again. The service starts when claude is found too
//   (claudeFound), in either order.
// - A stop is final: the service ends its timer and its runs, and it never reminds again. close()
//   then waits for an open that runs, and closes the store: its last save ends and its lock is
//   free.
@MainActor
@Observable
package final class DailyUpdateHost {
    // The life of the Daily update.
    private enum Phase {
        // start() did not come yet.
        case idle
        // The store opens.
        case opening(Task<Void, Never>)
        // The store is open, and the service waits for claude. The follow of the settings writes
        // the skill export.
        case waitingForClaude(DailyStateStore, settingsFollow: Task<Void, Never>)
        // The service runs, with the follow of the settings and the follows of the system time.
        case running(DailyUpdateService, DailyStateStore, follows: [Task<Void, Never>])
        // No service: the text says why (another copy holds the lock, or the folder cannot be
        // used).
        case unavailable(String)
        // After stop(): nothing starts again. The store waits for close(). An open that ran at
        // the stop gives its store here when it ends.
        case stopped(DailyStateStore?, opening: Task<Void, Never>?)
    }

    // What the service needs from the shell and the services. It comes with start().
    private struct Inputs {
        let settings: SettingsStore
        let environment: DailyEnvironment
        let showPanel: @MainActor () -> Void
    }

    // The Daily update panel. It reads the service of this host.
    let panels: DailyUpdatePanels
    private let layout: DailyLayout
    private var phase = Phase.idle
    // The two inputs that come in either order: the shell and the services at start(), and
    // claude with gh when the services found claude.
    @ObservationIgnored private var inputs: Inputs?
    @ObservationIgnored private var tools: (claude: ClaudeRunner, gh: GHCommand)?
    private static let logger = Logger(bifrost: "daily-update")

    // links gives the panel the confirm dialog, the open of its settings, the browser, the
    // clipboard and the look.
    init(
        layout: DailyLayout, links: DailyPanelLinks = DailyPanelLinks(),
        clock: any Clock<Duration>, now: @escaping () -> Date
    ) {
        self.layout = layout
        // The panel reads the service and the notice of this host. The host owns the panel, so
        // the panel holds it weakly, and the init links them at its end.
        weak var host: DailyUpdateHost?
        panels = DailyUpdatePanels(
            model: DailyUpdatePanelModel(
                service: { host?.service }, unavailable: { host?.unavailable }, links: links,
                clock: clock, now: now, zone: .autoupdatingCurrent))
        host = self
    }

    isolated deinit {
        switch phase {
        case .waitingForClaude(_, let follow):
            follow.cancel()
        case .running(let service, _, let follows):
            for follow in follows { follow.cancel() }
            service.stop()
        case .idle, .opening, .unavailable, .stopped:
            break
        }
    }

    // MARK: - What the window reads

    // The service, while it runs.
    var service: DailyUpdateService? {
        if case .running(let service, _, _) = phase { service } else { nil }
    }

    // Why the store did not open: another copy of Bifrost holds the Daily update, or its folder
    // cannot be used. nil in each other phase.
    var notice: String? {
        if case .unavailable(let text) = phase { text } else { nil }
    }

    // Why the Daily update does not run, for the panel and for Settings: the notice, or no
    // claude. nil while it runs or starts.
    var unavailable: String? {
        if let notice { return notice }
        if service == nil, inputs?.environment.claudeMissing() == true {
            return DailyUpdateService.noClaudeText
        }
        return nil
    }

    // True while the Daily update button of the side bar shows its marker.
    var marker: Bool { service?.showsMarker ?? false }

    // MARK: - The start

    // Open the store with the settings store of the app. Only the first call counts, and only
    // before a stop.
    func start(
        settings: SettingsStore, environment: DailyEnvironment,
        showPanel: @escaping @MainActor () -> Void
    ) {
        guard case .idle = phase else { return }
        inputs = Inputs(settings: settings, environment: environment, showPanel: showPanel)
        let (layout, health) = (layout, environment.health)
        phase = .opening(
            Task { [weak self] in
                let result: Result<DailyStateStore, DailyStoreError>
                do throws(DailyStoreError) {
                    result = .success(
                        try await DailyStateStore.open(
                            layout: layout, log: HealthStoreLog(health: health)))
                } catch {
                    result = .failure(error)
                }
                self?.opened(result)
            })
    }

    // The services found claude: the service can run drafts. gh runs in the runs folder.
    func claudeFound(_ claude: ClaudeRunner, gh: GHCommand) {
        tools = (claude, gh)
        startService()
    }

    private func opened(_ result: Result<DailyStateStore, DailyStoreError>) {
        switch (phase, result) {
        case (.opening, .success(let store)):
            guard let inputs else { return }
            phase = .waitingForClaude(store, settingsFollow: followSettings(inputs.settings))
            startService()
        case (.opening, .failure(let error)):
            phase = .unavailable(error.message)
        case (.stopped(_, let opening), .success(let store)):
            // The stop came during the open: close() frees the lock of this store.
            phase = .stopped(store, opening: opening)
        default:
            break
        }
    }

    private func startService() {
        guard case .waitingForClaude(let store, let settingsFollow) = phase, let inputs,
            let tools
        else { return }
        let app = inputs.environment
        let settings = inputs.settings
        let eventLog = app.eventLog
        let runner = DailyRunner(
            claude: tools.claude, gh: tools.gh, layout: layout, skills: app.skills,
            report: { eventLog.line($0.line) }, clock: app.clock)
        let bounces = app.bouncesDock
        let showPanel = inputs.showPanel
        let service = DailyUpdateService(
            store: store, runner: runner, settings: { settings.settings.dailyUpdate },
            notifier: app.notifier,
            bounceDock: { if bounces { NSApp.requestUserAttention(.informationalRequest) } },
            openPanel: { [weak self] area in
                self?.panels.model.show(area: area)
                showPanel()
            },
            clock: app.clock, now: app.now, calendar: { .autoupdatingCurrent },
            refused: app.refused)
        phase = .running(
            service, store, follows: [settingsFollow] + Self.followSystemTime(of: service))
        service.start()
    }

    // MARK: - The follows

    // The Daily update settings of now, then each change (docs/behaviour/daily-update.md, "The
    // run"). The service plans again, and the skill export follows the settings: with no
    // dailyUpdate block, the export has the defaults, and a change of another setting writes
    // nothing. The writes run one at a time in this task, so an older export never writes over a
    // newer one. A failed write goes to the log, and the next change writes again.
    private func followSettings(_ settings: SettingsStore) -> Task<Void, Never> {
        let writer = SkillExportWriter(layout: layout)
        let values = Observations { settings.settings.dailyUpdate ?? .defaults }
        return Task { [weak self] in
            var written: DailySettings?
            for await value in values {
                self?.service?.settingsChanged()
                guard value != written else { continue }
                do throws(FileError) {
                    try await writer.write(value)
                    written = value
                } catch {
                    let reason = error.message
                    Self.logger.error(
                        "Bifrost cannot write the skill export: \(reason, privacy: .private)")
                }
            }
        }
    }

    // A wake, a change of the clock or of the time zone, and a new day: the service plans again.
    private static func followSystemTime(of service: DailyUpdateService) -> [Task<Void, Never>] {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        let streams = [
            workspace.notifications(named: NSWorkspace.didWakeNotification),
            center.notifications(named: .NSSystemClockDidChange),
            center.notifications(named: .NSSystemTimeZoneDidChange),
            center.notifications(named: .NSCalendarDayChanged),
        ]
        return streams.map { stream in
            Task { [weak service] in
                for await _ in stream { service?.timeChanged() }
            }
        }
    }

    // MARK: - Settings

    // Read the MCP servers for the ticket source of Settings > Daily update: the probe of the
    // run, in the Daily update folder. It needs claude, and only reads: another copy of Bifrost
    // that holds the Daily update does not stop it.
    func readInventory() async -> InventoryRead {
        guard let claude = tools?.claude else { return .noClaude }
        guard let inventory = await InventoryReader(claude: claude).read(in: layout.folder) else {
            return .failed
        }
        return .found(inventory)
    }

    // MARK: - The stop

    // The stop of the app: the service ends its timer and its runs, and the follows end. It
    // never reminds again.
    func stop() {
        switch phase {
        case .idle, .unavailable:
            phase = .stopped(nil, opening: nil)
        case .opening(let task):
            phase = .stopped(nil, opening: task)
        case .waitingForClaude(let store, let follow):
            follow.cancel()
            phase = .stopped(store, opening: nil)
        case .running(let service, let store, let follows):
            for follow in follows { follow.cancel() }
            service.stop()
            phase = .stopped(store, opening: nil)
        case .stopped:
            break
        }
    }

    // The quit: stop, wait for an open that runs, then close the store. The close waits for the
    // last save, then frees the lock.
    func close() async {
        stop()
        guard case .stopped(_, let opening) = phase else { return }
        await opening?.value
        guard case .stopped(let store, _) = phase else { return }
        await store?.close()
    }

    #if DEBUG
    // The test port state of the Daily update: null with no service, else the status and each
    // tab with its marker, the size of its draft and its send.
    var testPortState: JSONValue {
        guard let snapshot = service?.snapshot else { return .null }
        let tabs = snapshot.tabs.map { tab -> JSONValue in
            [
                "id": .string(tab.id), "marker": .bool(snapshot.showsMarker(tab)),
                "draft": .int(tab.draft.count), "sent": .bool(tab.sentAt != nil),
            ]
        }
        return [
            "status": .string(snapshot.status.rawValue), "running": .bool(snapshot.isRunning),
            "tabs": .array(tabs),
        ]
    }

    // The daily op of the test port: refresh runs the drafts as Refresh does, and mark-sent
    // marks the area as sent as its button does. The result is nil, or why it did not act.
    func testPortOp(_ action: TestDailyAction) -> String? {
        guard let service else { return unavailable ?? "the Daily update does not run" }
        switch action {
        case .refresh:
            service.refresh()
        case .markSent(let area):
            guard service.snapshot.tabs.contains(where: { $0.id == area }) else {
                return "no tab for the area \(area)"
            }
            service.markSent(area)
        }
        return nil
    }
    #endif
}
