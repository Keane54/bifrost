import AppKit
import BifrostDailyUpdate
import BifrostDictation
import BifrostFoundation
import BifrostHealth
import BifrostLayout
import BifrostLook
import BifrostSessions
import BifrostSettings
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostApp
@testable import BifrostWindows


// The look of the Performance panel in a test.
@MainActor
private func panelStyle() -> PanelStyle {
    PanelStyle(metrics: CanvasMetrics(interfaceScale: 100), transparency: 15)
}

// The Performance parts of the window (docs/behaviour/health.md, "The panel"): the health events
// of the polls, the stores and the updater reach the monitor, and the side bar dot follows its
// level. Safety: the process table is a fake with no process, the status pages, the Keychain read
// and the usage answers are fakes, the files are in a temporary folder, and the clocks are manual
// clocks (the registry polls a fake on the real clock), so no test reads a process, reaches the
// network or starts gh.

private let performanceNow = Date(
    timeIntervalSince1970: TimeInterval(utcMs(2026, 11, 18, 9)) / 1000)

private struct NoProcesses: ProcessSampling {
    func read() async -> [ProcessSample] { [] }
}

private struct NoStatusAnswer: StatusFetcher {
    func fetch(_ url: URL) async -> Data? { nil }
}

private struct NoUsageAnswer: UsageFetcher {
    func fetch(token: String, timeout: Duration) async -> UsageResponse? { nil }
}

// A Keychain read that gives a fake login. It runs no program.
private struct FakeLogin: CommandRunner {
    func run(_ command: Command) async -> ExecResult {
        let expires = utcMs(2026, 11, 18, 10)
        return ExecResult(
            .exited(0),
            stdout: #"{"claudeAiOauth":{"accessToken":"fake-access-token-for-tests","#
                + #""refreshToken":"fake-refresh-token","expiresAt":\#(expires)}}"#)
    }
}

// The calls of the registry: each list fails, and the other calls give nothing.
private struct FailingLists: RegistryServiceDeps {
    func listActive() async throws -> AgentList { .failed(.commandFailed(detail: "boom")) }
    func listAll() async throws -> AgentList { .failed(.commandFailed(detail: "boom")) }
    func readBranch(_ cwd: String) async throws -> String? { nil }
    func readTerminalApps(_ pids: [pid_t]) async -> TerminalApps { TerminalApps() }
    func readAttachClients() async -> [AttachClient] { [] }
    func saveStore(_ store: RegistryStore) async throws {}
}

// The bodies of a side bar with no panels: the side bar only reads the titles.
@MainActor
private final class NoBodies: PanelBodies {
    func body(for panel: PanelID) -> NSView { NSView() }
    func title(for panel: PanelID) -> String { panel.text }
    func releaseBody(for panel: PanelID) {}
}

// The Performance parts on the events of one reporter, a fake process table and a manual clock,
// and the check of the status pages, whose pages give no answer.
@MainActor
private final class PerformanceHome {
    let folder: TemporaryFolder
    let reporter: HealthReporter
    let statusClock = ManualClock()
    let status: ServiceStatusMonitor
    let parts: PerformanceParts

    init() throws {
        UITestApp.prepare()
        folder = try TemporaryFolder()
        let (reporter, events) = HealthReporter.make()
        self.reporter = reporter
        let plan = PerformancePlan(
            logFolder: folder.url.appending(path: "logs"), measuresNetwork: false,
            ghFolder: folder.url)
        status = ServiceStatusMonitor(
            fetcher: NoStatusAnswer(), health: reporter, clock: statusClock,
            now: { performanceNow })
        parts = PerformanceParts(
            plan: plan,
            environment: PerformanceEnvironment(
                events: events, home: folder.url, clones: folder.url.appending(path: "repos"),
                processes: NoProcesses(), clock: ManualClock(), now: { performanceNow }),
            style: panelStyle, clock: ManualClock())
    }

    var reasons: [String] { parts.monitor.snapshot.reasons.map(\.text) }

    // The lines of health.log.
    var logLines: [String] {
        let file = folder.url.appending(path: "logs/health.log")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    func finish() {
        status.stop()
        parts.stop()
        folder.remove()
    }
}

@MainActor
@Suite("the Performance wiring", .serialized, .testTimeLimit, .tags(.window))
struct PerformanceWiringTests {
    // The session list, the account usage, the status pages and the updates report each poll to
    // the one reporter, and three failures in a row of each give a reason in the monitor.
    @Test func eachPollReachesTheMonitor() async throws {
        let home = try PerformanceHome()
        defer { home.finish() }
        var timing = RegistryTiming()
        timing.active = .milliseconds(20)
        let registry = RegistryService(
            registry: SessionRegistry(store: RegistryStore(), escalation: .seconds(600)),
            deps: FailingLists(), clock: ContinuousClock(), now: { performanceNow },
            timing: timing, log: Recorder<SessionsLogEvent>(), health: home.reporter)
        registry.start()
        let sessions = "Bifrost couldn't check for sessions"
        await waitUntil { home.reasons.contains { $0.hasPrefix(sessions) } }
        registry.stop()
        let pollerClock = ManualClock()
        let poller = AccountPoller(
            runner: FakeLogin(), fetcher: NoUsageAnswer(), clock: pollerClock,
            now: { performanceNow }, health: home.reporter)
        poller.start()
        await poller.pollTask?.value
        for _ in 1...2 {
            await pollerClock.waitForSleepers(exactly: 1)
            pollerClock.advance(by: AccountPoller.interval)
            await poller.timerTask?.value
            await poller.pollTask?.value
        }
        let status = home.status
        status.start()
        await status.checkTask?.value
        for _ in 1...2 {
            await home.statusClock.waitForSleepers(exactly: 1)
            home.statusClock.advance(by: ServiceStatusMonitor.interval)
            await status.timerTask?.value
            await status.checkTask?.value
        }
        for _ in 1...3 { home.reporter.record(.poll(.updates, .failed)) }
        let expected = [
            "Bifrost couldn't check your account usage 3 times in a row.",
            "Bifrost couldn't check Claude's status 3 times in a row.",
            "Bifrost couldn't check for updates 3 times in a row.",
        ]
        await waitUntil { expected.allSatisfy(home.reasons.contains) }
        #expect(home.reasons.contains { $0.hasPrefix(sessions) })
        #expect(expected.allSatisfy(home.reasons.contains))
        // The stop of the poller ends its streak.
        poller.stop()
        await waitUntil { !home.reasons.contains(expected[0]) }
        #expect(!home.reasons.contains(expected[0]))
    }

    // The services open settings.json with the health log of the app, so a failed save of the
    // settings reaches the monitor of the shell parts. The services find no claude, so no
    // program runs.
    @Test func aFailedSaveOfASettingsFileReachesTheMonitor() async throws {
        UITestApp.prepare()
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let identity = try #require(AppIdentity(bundleID: "com.example.app.native-dev"))
        let folders = DataFolders(identity: identity, home: folder.url)
        try folders.create()
        let plan = StartPlan(
            identity: identity, home: folder.url, realHome: folder.url.appending(path: "real"),
            testHome: true, folders: folders)
        let services = AppServices(
            plan: plan, home: folder.url, environment: ["PATH": "/nonexistent-bifrost-test"],
            processes: FakeProcessInspector(), speechEngine: { _ in FakeSpeechEngine() },
            now: { performanceNow })
        let parts = PerformanceParts(
            plan: services.performancePlan,
            environment: PerformanceEnvironment(
                events: services.healthEvents, home: folder.url,
                clones: folder.url.appending(path: "repos"), processes: NoProcesses(),
                clock: ManualClock(), now: { performanceNow }),
            style: panelStyle, clock: ManualClock())
        defer {
            services.stop()
            parts.stop()
        }
        await services.start()
        let settings = try #require(services.settings)
        // The folder refuses each new file, so the safe write of the settings fails.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: folders.support.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: folders.support.path)
        }
        await #expect(throws: SettingsError.self) {
            try await settings.edit { $0.rowFlash.toggle() }
        }
        let reasons = { parts.monitor.snapshot.reasons }
        await waitUntil { !reasons().isEmpty }
        let saved = "Bifrost couldn't save your settings at "
        #expect(reasons().map(\.text).contains { $0.hasPrefix(saved) })
        #expect(reasons().allSatisfy { $0.past })
        #expect(parts.monitor.snapshot.level == .warning)
    }

    // The side bar dot of Performance has the colour of the level while it is Warning or
    // Problem, and the text of the level as its tooltip. Clear removes the past events, and with
    // no sample the dot goes.
    @Test func theSideBarDotFollowsTheLevel() async throws {
        let home = try PerformanceHome()
        defer { home.finish() }
        let store = await UIStateStore.open(
            file: home.folder.url.appending(path: "ui-state.json"), clock: ManualClock(),
            log: Recorder<StoreEvent>())
        let layout = WindowLayoutModel(layout: WindowLayout(bounds: LayoutSize(w: 1200, h: 800)))
        let parts = home.parts
        let sideBar = SideBarModel(
            layout: layout, store: store, dot: { $0 == .performance ? parts.dot : nil })
        let view = SideBarView(model: sideBar, bodies: NoBodies())
        let button = { view.panelButtons.last }
        #expect(button()?.id == "performance")
        #expect(button()?.dot == nil)
        for _ in 1...3 { home.reporter.record(.poll(.sessions, .failed)) }
        await waitUntil { home.parts.dot != nil }
        #expect(button()?.dot == "Performance - Warning")
        #expect(button()?.dotColour == ThemeTokens.ctxMid)
        for _ in 1...7 { home.reporter.record(.poll(.sessions, .failed)) }
        await waitUntil { home.parts.monitor.snapshot.level == .problem }
        #expect(button()?.dot == "Performance - Problem")
        #expect(button()?.dotColour == ThemeTokens.ctxHigh)
        home.parts.monitor.clear()
        #expect(home.parts.monitor.snapshot.level == nil)
        #expect(button()?.dot == nil)
        await store.saveNow()
    }

    // The end of an update cycle reaches the monitor: three failed cycles in a row give a reason
    // and a line in health.log, in the logs folder of the plan, and a good cycle ends the streak.
    @Test func anUpdateCycleEndReachesTheMonitor() async throws {
        let home = try PerformanceHome()
        defer { home.finish() }
        let reason = "Bifrost couldn't check for updates 3 times in a row."
        for _ in 1...3 { home.reporter.record(.poll(.updates, .failed)) }
        await waitUntil { home.reasons == [reason] }
        #expect(home.reasons == [reason])
        await waitUntil { home.logLines.count == 3 }
        #expect(home.logLines.last?.hasSuffix(" poll failed: updates (3 in a row)") == true)
        home.reporter.record(.poll(.updates, .ok))
        await waitUntil { home.reasons.isEmpty }
        #expect(home.reasons.isEmpty)
    }

    // Turning the automatic update checks off ends the streak of failed checks, so the old
    // failures stop being a reason. The stop writes no line to health.log.
    @Test func aStopOfTheAutomaticChecksEndsTheUpdateStreak() async throws {
        let home = try PerformanceHome()
        defer { home.finish() }
        let reason = "Bifrost couldn't check for updates 3 times in a row."
        for _ in 1...3 { home.reporter.record(.poll(.updates, .failed)) }
        await waitUntil { home.reasons == [reason] }
        #expect(home.reasons == [reason])
        home.reporter.record(.stopped(.updates))
        await waitUntil { home.reasons.isEmpty }
        #expect(home.reasons.isEmpty)
        // A new failure counts from 1 again.
        home.reporter.record(.poll(.updates, .failed))
        await waitUntil { home.logLines.count == 4 }
        #expect(home.logLines.last?.hasSuffix(" poll failed: updates (1 in a row)") == true)
        #expect(home.reasons.isEmpty)
    }

    // A test home has no network sampler and no GitHub points, so the monitor makes no request
    // and starts no gh. Each other start measures them. health.log goes to the logs folder of
    // the home of the plan.
    @Test func aTestHomeHasNoNetworkSamplerAndNoGitHubPoints() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let identity = try #require(AppIdentity(bundleID: "com.example.app.native-dev"))
        let folders = DataFolders(identity: identity, home: folder.url)
        let (_, events) = HealthReporter.make()
        let environment = PerformanceEnvironment(
            events: events, home: folder.url, clones: folder.url.appending(path: "repos"),
            processes: NoProcesses(), clock: ManualClock(), now: { performanceNow })
        let test = PerformancePlan(
            StartPlan(
                identity: identity, home: folder.url, realHome: folder.url.appending(path: "real"),
                testHome: true, folders: folders))
        #expect(!test.measuresNetwork)
        #expect(test.logFolder == folders.logs)
        #expect(test.ghFolder == folders.support)
        let testSamplers = PerformanceParts.samplers(test, environment)
        #expect(testSamplers.network == nil)
        #expect(testSamplers.github == nil)
        let normal = PerformancePlan(
            StartPlan(
                identity: identity, home: folder.url, realHome: folder.url, testHome: false,
                folders: folders))
        #expect(normal.measuresNetwork)
        let normalSamplers = PerformanceParts.samplers(normal, environment)
        #expect(normalSamplers.network != nil)
        #expect(normalSamplers.github != nil)
    }
}
