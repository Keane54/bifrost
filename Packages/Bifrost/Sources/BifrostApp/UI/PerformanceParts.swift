import BifrostFoundation
import BifrostHealth
import BifrostLayout
import BifrostLook
import BifrostReviews
import BifrostSessions
import BifrostWindows
import Foundation

// What the Performance monitor and its panel take from the app services and the window.
struct PerformanceEnvironment {
    // The health events of the app (AppServices.healthEvents). The monitor is their one reader.
    let events: AsyncStream<HealthEvent>
    // The home of the app, for the free disk, and the clones folder of Reviews.
    let home: URL
    let clones: URL
    // The process table. A test gives a fake.
    let processes: any ProcessSampling
    // The terminal processes of the PTY manager, the session rows and the open chat panels.
    let terminals: @MainActor () -> [TerminalProcess]
    let rows: @MainActor () -> [SessionRow]
    let chatPanels: @MainActor () -> Set<SessionID>
    // The gh command of the GitHub points, or nil before the app found claude.
    let gh: @Sendable () async -> GHCommand?
    // The UI state that keeps the choice of the Details row.
    let uiState: UIStateStore?
    let clock: any Clock<Duration>
    let now: @Sendable () -> Date

    // The values of the services and of the window. A chat panel counts also as a back tab and
    // in a minimised frame. gh is the gh of the services in the folder of the plan.
    @MainActor
    init(_ app: AppServices, layout: WindowLayoutModel, uiState: UIStateStore) {
        events = app.healthEvents
        home = app.home
        clones = ReviewsLayout(folder: app.sharedState.reviewsFolder).reposRoot
        processes = ProcessTable()
        terminals = { [weak app] in
            (app?.ptys?.list() ?? []).compactMap { attach in
                attach.pid > 0 ? TerminalProcess(view: attach.view, pid: attach.pid) : nil
            }
        }
        rows = { [weak app] in app?.registry?.rows ?? [] }
        chatPanels = { [weak layout] in
            let panels = (layout?.layout.frames ?? []).flatMap(\.panels)
            return Set(
                panels.compactMap { panel in
                    if case .chat(let session) = panel { session } else { nil }
                })
        }
        let folder = app.performancePlan.ghFolder
        gh = { @MainActor [weak app] in app?.gh(in: folder) }
        self.uiState = uiState
        clock = app.clock
        now = app.now
    }

    init(
        events: AsyncStream<HealthEvent>, home: URL, clones: URL, processes: any ProcessSampling,
        terminals: @escaping @MainActor () -> [TerminalProcess] = { [] },
        rows: @escaping @MainActor () -> [SessionRow] = { [] },
        chatPanels: @escaping @MainActor () -> Set<SessionID> = { [] },
        gh: @escaping @Sendable () async -> GHCommand? = { nil }, uiState: UIStateStore? = nil,
        clock: any Clock<Duration>, now: @escaping @Sendable () -> Date
    ) {
        self.events = events
        self.home = home
        self.clones = clones
        self.processes = processes
        self.terminals = terminals
        self.rows = rows
        self.chatPanels = chatPanels
        self.gh = gh
        self.uiState = uiState
        self.clock = clock
        self.now = now
    }
}

// The Performance monitor in the window (docs/behaviour/health.md, "Performance"): the monitor,
// its panel and the dot of its button on the side bar. The shell holds one. The monitor starts
// at the init and samples also while the panel is closed, so the dot is right. The quit ends it.
@MainActor
package final class PerformanceParts {
    let monitor: PerformanceMonitor
    let panels: PerformancePanels
    // The action runner of the window, for the Stop button of the panel.
    private weak var runner: ActionRunner?

    // style gives the look of the panel at the Interface scale and the panel transparency.
    init(
        plan: PerformancePlan, environment: PerformanceEnvironment,
        style: @escaping @MainActor () -> PanelStyle, clock: any Clock<Duration>
    ) {
        let monitor = PerformanceMonitor(
            events: environment.events, samplers: Self.samplers(plan, environment),
            log: HealthLog(folder: plan.logFolder), clock: environment.clock,
            now: environment.now)
        self.monitor = monitor
        // The panel stops a session through these parts. The parts own the panel, so the panel
        // holds them weakly, and the init links them at its end.
        weak var parts: PerformanceParts?
        panels = PerformancePanels(
            monitor: monitor, uiState: environment.uiState, stop: { parts?.stopSession($0) },
            style: style, clock: clock)
        parts = self
        monitor.start()
    }

    // The samplers of the monitor. A test home (PerformancePlan.measuresNetwork) has no network
    // sampler and no GitHub points, so it makes no request and starts no gh.
    static func samplers(
        _ plan: PerformancePlan, _ environment: PerformanceEnvironment
    ) -> PerformanceSamplers {
        PerformanceSamplers(
            app: AppUsage(
                processes: environment.processes, terminals: environment.terminals,
                rows: environment.rows, chatPanels: environment.chatPanels),
            mac: .system, network: plan.measuresNetwork ? NetworkState() : nil,
            disk: DiskState(home: environment.home, clones: environment.clones),
            github: plan.measuresNetwork ? GitHubLimit(command: environment.gh) : nil,
            mainThread: MainThreadWatch())
    }

    // The window made its action runner: the Stop button of the panel uses it.
    func attach(_ runner: ActionRunner) {
        self.runner = runner
    }

    // The Stop button of the panel: the Stop action of the window on the session of the row,
    // with its checks and its confirmation. With no runner yet, nothing happens.
    private func stopSession(_ row: SessionRow) {
        runner?.run(.stop, row.sessionId)
    }

    // The dot of the Performance button of the side bar: the text and the colour of the level
    // while it is Warning or Problem, else nil. It reads the observed snapshot.
    var dot: SideBarDot? {
        guard let level = monitor.snapshot.level, let text = PerformanceText.attention(level)
        else { return nil }
        return SideBarDot(text: text, colour: PerformanceColours.level(level))
    }

    // The quit: the panel stops its frame counter, and the monitor ends its tasks, its run loop
    // observers and the follow of the health events.
    func stop() {
        panels.stop()
        monitor.end()
    }

    #if DEBUG
    // The test port state of the monitor: the level and the number of reasons.
    var testPortState: JSONValue {
        TestPortMessage.performance(monitor.snapshot)
    }
    #endif
}
