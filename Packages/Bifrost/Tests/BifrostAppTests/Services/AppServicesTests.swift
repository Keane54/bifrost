import BifrostKeyboard
import BifrostReviews
import BifrostTestSupport
import BifrostWindows
import Foundation
import Synchronization
import Testing

@testable import BifrostApp
@testable import BifrostDictation
@testable import BifrostFoundation
@testable import BifrostLayout
@testable import BifrostLive
@testable import BifrostSessions
@testable import BifrostSettings

// The tests of AppServices with real processes: a fake claude and a fake login shell in a
// TemporaryFolder (FakeClaude), and the test home in the same folder. The runner of the fake
// runs only the programs in that folder. The waits look at the model every 20 ms up to a
// deadline, because real processes run. Each test runs in a TestScope. The scope removes the
// folder only after the claude runs and the store save end, so no folder stays in /tmp. The
// process inspector is a fake, so no test reads a process of the Mac. A test that needs no
// timer of the registry gives a manual clock, so the registry polls only one time.

private func milliseconds() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

private func development() throws -> AppIdentity {
    try #require(AppIdentity(bundleID: "com.example.app.native-dev"))
}

// One fake and the services that a test makes with it. finish() stops the services, waits
// until the claude runs and the store save in progress end, and then removes the folder of the
// fake. Thus no run and no save writes to the folder after the removal.
@MainActor
private final class TestScope {
    let fake: FakeClaude
    // The process table of the registry and the session sizes. It reads no process.
    let processes = FakeProcessInspector()
    private var made: [AppServices] = []
    // The ends of the observations.
    private var observers: [@MainActor () -> Void] = []

    init() throws {
        fake = try FakeClaude()
    }

    // The services of the development app in the home of the fake, as the app makes them: the
    // data folders first, then the plan, then the services. The test calls start().
    func services(
        testHome: Bool = true, environment: [String: String]? = nil, visible: Bool = true,
        ptySpawner: any PTYSpawner = SystemPTYSpawner(),
        clock: any Clock<Duration> = ContinuousClock(), notifier: any Notifier = FakeNotifier(),
        poller: AccountPoller? = nil
    ) throws -> (services: AppServices, plan: StartPlan) {
        let identity = try development()
        let folders = DataFolders(identity: identity, home: fake.home)
        try folders.create()
        // With no test home, the home is the real home. With a test home, a folder of the fake
        // stands in for the real home.
        let plan = StartPlan(
            identity: identity, home: fake.home, realHome: testHome ? fake.realHome : fake.home,
            testHome: testHome, folders: folders)
        // The fake speech engine, also with no test home: no test makes the real engine.
        let services = AppServices(
            plan: plan, home: fake.home, environment: environment ?? fake.environment,
            runner: fake.runner, processes: processes, ptySpawner: ptySpawner, clock: clock,
            speechEngine: { _ in FakeSpeechEngine() }, notifier: notifier, poller: poller)
        made.append(services)
        if visible { services.setWindowVisible(true) }
        return (services, plan)
    }

    // Collect the values of an observation, as the shell follows the services: the value of
    // now, then the value after each change. finish() ends the observation.
    func observe<Value: Sendable>(_ changes: Observations<Value, Never>) -> Recorder<Value> {
        let seen = Recorder(following: changes)
        observers.append { seen.stop() }
        return seen
    }

    func finish() async {
        for stop in observers { stop() }
        for services in made { services.stop() }
        for services in made { await services.usageAlertsSave?.value }
        // A held login shell waits for this file.
        try? fake.releaseTheLoginShell()
        await fake.runner.close(within: .seconds(10))
        let saved = await waitUntil { made.allSatisfy { $0.registry?.isSaving != true } }
        if !saved { Issue.record("A save of the registry store did not end in 10 s.") }
        fake.remove()
    }
}

// Run the body with a new scope. Then finish the scope, also when the body throws.
@MainActor
private func withScope(_ body: (TestScope) async throws -> Void) async throws {
    let scope = try TestScope()
    do {
        try await body(scope)
    } catch {
        await scope.finish()
        throw error
    }
    await scope.finish()
}

// A Live details line of the mod for a session, sent now.
private func liveLine(_ sessionId: String) -> String {
    #"{"at":\#(milliseconds()),"kind":"turn.start","seq":1,"sid":"\#(sessionId)","v":1}"#
}

// A Keychain read that finds no login, so a poll sends no request. It runs no program.
private struct NoLogin: CommandRunner {
    func run(_ command: Command) async -> ExecResult {
        ExecResult(.exited(44), stderr: "The item could not be found.")
    }
}

// A fetcher that counts the fetches. With no login, a poll never reaches it.
private final class CountingFetcher: UsageFetcher {
    private let count = Mutex(0)

    var fetches: Int { count.withLock { $0 } }

    func fetch(token: String, timeout: Duration) async -> UsageResponse? {
        count.withLock { $0 += 1 }
        return nil
    }
}

// A poller with no login: a poll ends with no token, sends no request and gives no values.
@MainActor
private func noLoginPoller(_ fetcher: CountingFetcher) -> AccountPoller {
    AccountPoller(
        runner: NoLogin(), fetcher: fetcher, clock: ManualClock(), now: { Date() },
        log: Recorder<AccountUsageEvent>())
}

// A usage line of the session with a 5-hour window at the percent, sent now.
private func usageLine(_ sessionId: String, percent: Double) -> LiveEvent {
    let now = milliseconds()
    let limits = RateLimits(fiveHour: RateWindow(usedPercent: percent, resetsAt: now + 3_600_000))
    return .usage(sessionId: sessionId, at: now, LiveUsage(rateLimits: limits))
}

// Send a line to the Live details socket and read the answer. The read waits up to 30 s: in a
// full parallel run the main actor can stop for some seconds before the server answers.
private func post(_ socketPath: String, _ body: String) async throws -> String {
    let client = try UnixClient(path: socketPath)
    defer { client.close() }
    let head = "POST /v1/event HTTP/1.1\r\nHost: localhost\r\n"
        + "Content-Length: \(body.utf8.count)\r\n\r\n"
    _ = await client.write(Array((head + body).utf8))
    return String(decoding: await client.readToEnd(limit: .seconds(30)) ?? [], as: UTF8.self)
}

private func mode(_ path: String) -> mode_t {
    var info = stat()
    return lstat(path, &info) == 0 ? info.st_mode & 0o777 : 0
}

// The env of the fake with a PATH that has no claude. The start then runs no program.
private func noClaude(_ fake: FakeClaude) -> [String: String] {
    var environment = fake.environment
    environment["PATH"] = "\(fake.folder.appending("home")):/usr/bin:/bin"
    return environment
}

// The calls of the settings effects in a test, in their order: a change of the fake login item,
// an effect that the services give to the app target, or a marker of the test.
private enum EffectCall: Equatable, Sendable {
    case loginItem(on: Bool)
    case app(SettingsEffect)
    case marker(scale: Int)
}

// A login item that changes no real login item. With a failure, each change fails. A test sets
// isOn to act as a change in System Settings.
@MainActor
private final class FakeLoginItem: LoginItemService {
    var isOn: Bool
    var failure: LoginItemError?
    private let calls: Recorder<EffectCall>

    init(isOn: Bool = false, calls: Recorder<EffectCall>) {
        self.isOn = isOn
        self.calls = calls
    }

    func set(_ on: Bool) throws(LoginItemError) {
        calls.record(.loginItem(on: on))
        if let failure { throw failure }
        isOn = on
    }
}

// The value of Start at login in a settings file.
private func savedStartAtLogin(_ file: URL) throws -> Bool {
    try JSONDecoder().decode(Settings.self, from: Data(contentsOf: file)).startAtLogin
}

@MainActor
@Suite("app services", .testTimeLimit, .tags(.realProcess))
struct AppServicesTests {
    @Test func theSessionListShowsTheSessionsOfTheFakeClaude() async throws {
        try await withScope { scope in
            let fake = scope.fake
            let (services, _) = try scope.services()
            #expect(services.sessions.status == .starting)
            await services.start()
            await waitUntil { services.sessions.rows.count == 2 }
            #expect(services.sessions.status == .ready)
            #expect(
                services.sessions.rows.map(\.sessionId).sorted() == [
                    FakeClaude.alpha.sessionId, FakeClaude.beta.sessionId,
                ])
            #expect(fake.runner.refused.isEmpty)
        }
    }

    // The registry of the services reports each poll of the session list to the one health
    // stream of the app, which the Performance monitor of the shell reads.
    @Test func theSessionListPollReachesTheHealthStream() async throws {
        try await withScope { scope in
            let (services, _) = try scope.services(clock: ManualClock())
            let seen = Recorder<HealthEvent>()
            let reader = Task { [events = services.healthEvents] in
                for await event in events { seen.record(event) }
            }
            defer { reader.cancel() }
            await services.start()
            await waitUntil { seen.values.contains(.poll(.sessions, .ok)) }
            #expect(seen.values.contains(.poll(.sessions, .ok)))
        }
    }

    // The next active poll shows a new session. The registry runs on a manual clock: the test
    // moves it to the next poll when the four loops sleep.
    @Test func aNewSessionShowsUpLive() async throws {
        try await withScope { scope in
            let fake = scope.fake
            let clock = ManualClock()
            let (services, _) = try scope.services(clock: clock)
            await services.start()
            let registry = try #require(services.registry)
            await waitUntil { services.sessions.rows.count == 2 }
            try fake.setAgents([FakeClaude.alpha, FakeClaude.beta, FakeClaude.gamma])
            await waitUntil { registry.sleeps == 4 && clock.sleeperCount == 4 }
            clock.advance(by: registry.activeInterval)
            await waitUntil { services.sessions.rows.count == 3 }
            #expect(services.sessions.rows.contains { $0.sessionId == FakeClaude.gamma.sessionId })
        }
    }

    @Test func theRegistryFileIsInTheTestHome() async throws {
        try await withScope { scope in
            let fake = scope.fake
            let (services, plan) = try scope.services()
            await services.start()
            let path = plan.registryFile.path
            #expect(path.hasPrefix(fake.home.path + "/Library/Application Support/"))
            let saved = await waitUntil {
                let data = FileManager.default.contents(atPath: path) ?? Data()
                return String(decoding: data, as: UTF8.self).contains(FakeClaude.alpha.sessionId)
            }
            #expect(saved)
            #expect(mode(path) == 0o600)
        }
    }

    // With no test home, claude comes from the fake login shell, and each claude
    // run gets the child env of the env of that shell: the PATH that only the fake login shell
    // gives, and no variable of a Claude Code session. No variable of the app env goes to claude.
    @Test func aClaudeRunGetsTheChildEnvironment() async throws {
        try await withScope { scope in
            let fake = scope.fake
            #expect(fake.environment["CLAUDECODE"] == "1")
            let (services, plan) = try scope.services(testHome: false)
            #expect(plan.claude == .loginShell)
            await services.start()
            await waitUntil { services.sessions.rows.count == 2 }
            let env = try #require(fake.lastClaudeEnvironment())
            #expect(env["PATH"] == fake.loginPath)
            #expect(env["BIFROST_FAKE_LOGIN"] == "1")
            #expect(env["CLAUDECODE"] == nil)
            #expect(env["CLAUDE_CODE_ENTRYPOINT"] == nil)
            #expect(env["BIFROST_APP_ONLY"] == nil)
            // gh gets the env of the claude runs, with the folder of its caller.
            let folder = URL(filePath: "/nonexistent-bifrost-test/gh", directoryHint: .isDirectory)
            let gh = try #require(services.gh(in: folder))
            #expect(gh.environment["PATH"] == fake.loginPath)
            #expect(gh.environment["GH_PROMPT_DISABLED"] == "1")
            #expect(gh.folder == folder)
            // The fake has no plugin list and the home has no mod, so the server does not listen.
            #expect(services.liveServer?.state.listening != true)
            #expect(fake.runner.refused.isEmpty)
        }
    }

    // An observer of the services sees the two plugin controls come in one step, never one
    // without the other. The plugin list of the Live details start runs before the marketplace
    // list of the skills start. The sources of the live model hold the two controls.
    @Test func oneStepGivesBothControlsAndTheLivePluginListRunsFirst() async throws {
        try await withScope { scope in
            let fake = scope.fake
            let (services, _) = try scope.services()
            let seen = scope.observe(
                Observations { (services.liveControl != nil, services.skillsControl != nil) })
            await services.start()
            #expect(services.skillsControl != nil)
            let sources = try #require(services.liveSources)
            #expect(sources.live === services.liveControl)
            #expect(sources.skills === services.skillsControl)
            await waitUntil { fake.runs().contains("plugin marketplace list --json") }
            let runs = fake.runs()
            let live = try #require(runs.firstIndex(of: "plugin list --json"))
            let skills = try #require(runs.firstIndex(of: "plugin marketplace list --json"))
            #expect(live < skills)
            #expect(seen.values.first.map { $0 == (false, false) } == true)
            #expect(seen.values.allSatisfy { $0.0 == $0.1 })
        }
    }

    // With no claude, the registry, the PTY manager and the Live details server do
    // not start, and the status stays. The list never counts as loaded, so a chat keeps
    // "Waiting for the session list.".
    @Test func aPathWithNoClaudeShowsClaudeNotFound() async throws {
        try await withScope { scope in
            let fake = scope.fake
            var environment = fake.environment
            environment["PATH"] = "\(fake.folder.appending("home")):/usr/bin:/bin"
            let (services, _) = try scope.services(environment: environment)
            await services.start()
            #expect(services.sessions.status == .claudeNotFound)
            #expect(services.registry == nil)
            #expect(services.actions == nil)
            #expect(services.ptys == nil)
            #expect(services.liveControl == nil)
            #expect(services.liveServer == nil)
            #expect(services.skillsControl == nil)
            #expect(services.liveSources == nil)
            #expect(services.gh(in: URL(filePath: "/nonexistent-bifrost-test/gh")) == nil)
            // The start ended with no registry, so no later poll can change the list.
            #expect(services.sessions.status == .claudeNotFound)
            #expect(!services.sessions.loaded)
            #expect(fake.lastClaudeEnvironment() == nil)
            #expect(fake.runner.refused.isEmpty)
        }
    }

    // The start rule of Live details runs at the start of the app: the fake claude has no plugin
    // list, so the server listens when the mod manifest exists, on the shared socket of the test
    // home. A line on it marks its row live. The services run on a manual clock: the test needs
    // only the first poll, the request timeout of the Live details server never ends the
    // request during a stop of the main actor, and the test ends the batch window of the line.
    @Test func theStartRuleRunsAtTheStartOfTheApp() async throws {
        try await withScope { scope in
            let fake = scope.fake
            let clock = ManualClock()
            let (services, _) = try scope.services(clock: clock)
            let manifest = fake.home.appending(path: ".bifrost/mod/.claude-plugin")
            try FileManager.default.createDirectory(
                at: manifest, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: manifest.appending(path: "plugin.json"))
            let socket = services.sharedState.liveSocket.path(percentEncoded: false)
            #expect(socket == fake.home.path + "/.bifrost/live.sock")
            await services.start()
            await waitUntil { services.liveServer?.state == LiveServerState(listening: true) }
            #expect(services.liveServer?.state == LiveServerState(listening: true))
            #expect(fake.runs().contains("plugin list --json"))
            await waitUntil { services.sessions.rows.count == 2 }
            let alpha = FakeClaude.alpha.sessionId
            #expect(services.sessions.rows.first { $0.sessionId == alpha }?.live == false)
            let answer = Task { try await post(socket, liveLine(alpha)) }
            let server = try #require(services.liveServer)
            await waitUntil { server.batchCount == 1 }
            clock.advance(by: .milliseconds(50))
            #expect(try await answer.value.hasPrefix("HTTP/1.1 204 "))
            await waitUntil {
                services.sessions.rows.first { $0.sessionId == alpha }?.live == true
            }
        }
    }

    // A save of the registry store runs off the main actor. A registry.json that does not parse
    // gets a copy before the first save.
    @Test func aRegistryFileThatDoesNotParseGetsACopyBeforeTheFirstSave() async throws {
        try await withScope { scope in
            let (services, plan) = try scope.services()
            try Data("not json".utf8).write(to: plan.registryFile)
            await services.start()
            let copy = plan.registryFile.path + ".unreadable"
            await waitUntil { FileManager.default.fileExists(atPath: copy) }
            #expect(FileManager.default.contents(atPath: copy) == Data("not json".utf8))
        }
    }

    // A stop while the login shells run. The shells end after the stop, and nothing more starts.
    @Test func aStopDuringTheClaudeLookupStartsNothing() async throws {
        try await withScope { scope in
            let fake = scope.fake
            try fake.holdTheLoginShell()
            let (services, _) = try scope.services(testHome: false)
            let start = Task { await services.start() }
            await waitUntil { fake.loginShellWaits }
            services.stop()
            try fake.releaseTheLoginShell()
            await start.value
            #expect(services.registry == nil)
            #expect(services.liveServer == nil)
            #expect(services.sessions.status == .starting)
            // The start ended with no registry, so no later claude run can come.
            #expect(fake.runs().isEmpty)
        }
    }

    // Step 1 of the start: an observer of the services sees the settings store when it opens,
    // before the slow lookup of claude ends. Thus the window applies the settings (the Interface
    // scale, the transparency and the menu keys) before that end.
    @Test func anObserverSeesTheSettingsStoreBeforeTheClaudeLookupEnds() async throws {
        try await withScope { scope in
            let fake = scope.fake
            try fake.holdTheLoginShell()
            let (services, _) = try scope.services(testHome: false)
            let open = scope.observe(Observations { services.settings != nil })
            let start = Task { await services.start() }
            await waitUntil { open.values.last == true }
            // The lookup waits for the held login shell, so the store came before its end.
            await waitUntil { fake.loginShellWaits }
            #expect(services.registry == nil)
            try fake.releaseTheLoginShell()
            await start.value
        }
    }

    // A stop before the start ends starts no loop and no listener.
    @Test func aStopDuringTheStartStartsNothing() async throws {
        try await withScope { scope in
            let fake = scope.fake
            let (services, _) = try scope.services()
            let start = Task { await services.start() }
            // The task of the start has not run yet: a stop during the start.
            services.stop()
            await start.value
            let socket = services.sharedState.liveSocket.path(percentEncoded: false)
            #expect(services.liveServer?.state.listening != true)
            #expect(!FileManager.default.fileExists(atPath: socket))
            // The start ended with no registry, so no later claude run can come.
            #expect(services.registry == nil)
            #expect(services.sessions.status == .starting)
            #expect(fake.runs().isEmpty)
        }
    }

    // A change of the settings reaches the registry: the escalation time and the interval of the
    // active poll. A change of another setting changes neither value. After the stop, no change
    // reaches the registry.
    @Test func aSettingsChangeReachesTheRegistry() async throws {
        try await withScope { scope in
            let (services, _) = try scope.services(clock: ManualClock())
            await services.start()
            let registry = try #require(services.registry)
            let settings = try #require(services.settings)
            #expect(registry.escalation == .seconds(600))
            #expect(registry.activeInterval == .seconds(2))
            try await settings.edit {
                $0.escalationMinutes = 3
                $0.pollSeconds = 5
            }
            await waitUntil {
                    registry.escalation == .seconds(180) && registry.activeInterval == .seconds(5)
                }
            // A change of another setting moves neither value. An observer of the settings that
            // the test makes is the marker: it sees the change after the services do.
            let labels = scope.observe(Observations { settings.settings.labels })
            try await settings.edit { $0.labels = .space }
            await waitUntil { labels.values.last == .space }
            #expect(registry.escalation == .seconds(180))
            #expect(registry.activeInterval == .seconds(5))
            services.stop()
            // An observer of the settings that the test makes is the marker: it sees the change,
            // and the stopped services do not.
            let seen = scope.observe(Observations { settings.settings.escalationMinutes })
            try await settings.edit {
                $0.escalationMinutes = 4
                $0.pollSeconds = 1
            }
            await waitUntil { seen.values.last == 4 }
            #expect(registry.escalation == .seconds(180))
            #expect(registry.activeInterval == .seconds(5))
        }
    }

    // The visibility of the window goes to the registry. A hidden window polls each 15 s, and
    // the window that shows polls at once. The registry runs on a manual clock, so only the
    // window can start the third poll.
    @Test func aWindowThatShowsPollsAtOnce() async throws {
        try await withScope { scope in
            let fake = scope.fake
            let clock = ManualClock()
            let (services, _) = try scope.services(visible: false, clock: clock)
            await services.start()
            let registry = try #require(services.registry)
            // The first active poll and the first --all poll. Then the four loops sleep.
            await waitUntil { services.sessions.rows.count == 2 }
            // The start of Live details also runs claude (the plugin list): only the session
            // lists count here.
            let lists = { fake.runs().filter { $0.hasPrefix("agents") } }
            await waitUntil { lists() == ["agents --json", "agents --json --all"] }
            await waitUntil { registry.sleeps == 4 && clock.sleeperCount == 4 }
            try fake.setAgents([FakeClaude.alpha, FakeClaude.beta, FakeClaude.gamma])
            // 5 s is less than the 15 s of a hidden window and the 10 s of the branch loop.
            clock.advance(by: .seconds(5))
            // The tick loop woke and sleeps again. No other loop was due.
            await waitUntil { clock.sleeperCount == 4 }
            #expect(lists().count == 2)
            #expect(services.sessions.rows.count == 2)
            services.setWindowVisible(true)
            await waitUntil { services.sessions.rows.count == 3 }
            #expect(lists().count == 3)
        }
    }

    // An observer of the session list sees the list of now first (no rows, not loaded), then
    // each update of the registry as loaded rows. The PTY manager of the chats exists when the
    // first rows come. The registry runs on a manual clock: the test moves it to the next poll.
    @Test func anObserverOfTheSessionListSeesEachUpdateAfterThePTYManager() async throws {
        try await withScope { scope in
            let fake = scope.fake
            let clock = ManualClock()
            let (services, _) = try scope.services(clock: clock)
            let lists = scope.observe(
                Observations {
                    (
                        ids: services.sessions.rows.map(\.sessionId).sorted(),
                        loaded: services.sessions.loaded, ptys: services.ptys != nil
                    )
                })
            await waitUntil { !lists.values.isEmpty }
            let first = try #require(lists.values.first)
            #expect(first.ids == [])
            #expect(!first.loaded)
            #expect(!first.ptys)
            await services.start()
            let ids = [FakeClaude.alpha.sessionId, FakeClaude.beta.sessionId].sorted()
            await waitUntil { lists.values.last?.ids == ids }
            // The list loads with the rows of the first active poll, never with no rows.
            #expect(lists.values.first { $0.loaded }?.ids == ids)
            #expect(lists.values.filter { $0.loaded }.allSatisfy { $0.ptys })
            try fake.setAgents([FakeClaude.alpha])
            let registry = try #require(services.registry)
            await waitUntil { registry.sleeps == 4 && clock.sleeperCount == 4 }
            clock.advance(by: registry.activeInterval)
            await waitUntil { lists.values.last?.ids == [FakeClaude.alpha.sessionId] }
        }
    }

    // The two UI stores open from the files of the plan, before start().
    @Test func theUIStoresOpenFromTheFilesOfThePlan() async throws {
        try await withScope { scope in
            let (services, plan) = try scope.services()
            #expect(services.uiState == nil)
            #expect(services.windowState == nil)
            await services.openUIStores()
            let uiState = try #require(services.uiState)
            let windowState = try #require(services.windowState)
            uiState.change { _ = $0.saveLayout("Work", LayoutSnapshot(frames: [], memory: [:])) }
            await uiState.saveNow()
            await windowState.update(mode: .borderless)
            let ui = String(
                decoding: FileManager.default.contents(atPath: plan.uiStateFile.path) ?? Data(),
                as: UTF8.self)
            #expect(ui.contains("\"Work\""))
            let window = String(
                decoding: FileManager.default.contents(atPath: plan.windowStateFile.path)
                    ?? Data(), as: UTF8.self)
            #expect(window.contains("borderless"))
            // A second call opens nothing new.
            await services.openUIStores()
            #expect(services.uiState === uiState)
            #expect(services.windowState === windowState)
        }
    }

    // stop() closes each PTY of the chats. A fake attach through
    // services.ptys gets one SIGHUP, by its pid, and ends. Then the view has no PTY. A close
    // only detaches: no other signal goes out.
    @Test func aStopClosesEachPTYWithASIGHUPToTheAttachChildOnly() async throws {
        try await withScope { scope in
            let fake = scope.fake
            let spawner = RecordingPTYSpawner()
            let (services, _) = try scope.services(ptySpawner: spawner)
            await services.start()
            let ptys = try #require(services.ptys)
            let view = PTYView.chat(try #require(SessionID(FakeClaude.alpha.sessionId)))
            let opened = try await ptys.open(
                .test(view, shortId: "5a0e0001", directory: fake.home.path),
                size: TerminalSize(cols: 80, rows: 24))
            let attach = try #require(opened)
            let pid = attach.pid
            #expect(ptys.attach(view) === attach)
            // The trap of the fake is on when it prints its line.
            var output: [UInt8] = []
            let chunks = attach.output.makeAsyncIterator()
            while !String(decoding: output, as: UTF8.self).contains("FAKE ATTACH 5a0e0001"),
                let chunk = await chunks.next()
            {
                output += chunk
            }
            #expect(String(decoding: output, as: UTF8.self).contains("FAKE ATTACH 5a0e0001"))
            services.stop()
            #expect(ptys.attach(view) == nil)
            #expect(!attach.isOpen)
            #expect(spawner.log.kills == [.init(pid, SIGHUP)])
            await waitUntil { spawner.children.allSatisfy(\.reaped) }
            let hups = (try? String(contentsOfFile: fake.attachHupFile, encoding: .utf8)) ?? ""
            #expect(hups == "hup\n")
        }
    }

    // The stop of the services at a quit stops the dictation, so the microphone of the fake
    // engine closes. A test home uses the fake
    // engine.
    @Test func aStopClosesTheMicrophoneOfADictation() async throws {
        try await withScope { scope in
            let (services, _) = try scope.services()
            let engine = try #require(services.dictation.speechEngine as? FakeSpeechEngine)
            let chat = try #require(SessionID(FakeClaude.alpha.sessionId))
            services.dictation.start(chat: chat)
            await waitUntil { engine.microphoneOpen }
            services.stop()
            #expect(!engine.microphoneOpen)
            #expect(engine.microphoneOpens == 1)
            #expect(engine.microphoneCloses == 1)
            #expect(engine.releases == 1)
            #expect(engine.overlaps == 0)
        }
    }

    // stop() at the quit stops the session commands with the registry: a later command is
    // refused with cancelled, and runs no claude.
    @Test func aSessionCommandAfterTheStopIsCancelled() async throws {
        try await withScope { scope in
            let (services, _) = try scope.services(clock: ManualClock())
            await services.start()
            let actions = try #require(services.actions)
            services.stop()
            var refusal: ActionRefusal?
            do throws(ActionRefusal) {
                _ = try await actions.run(.stop(FakeClaude.alpha.sessionId))
            } catch {
                refusal = error
            }
            #expect(refusal == .cancelled)
            #expect(!scope.fake.runs().contains { $0.hasPrefix("stop") })
        }
    }

    // An observer of the settings sees the settings when the store opens, and then each change.
    // The app delegate follows the settings in this way.
    @Test func anObserverSeesTheSettingsOpenAndEachChange() async throws {
        try await withScope { scope in
            let (services, _) = try scope.services(clock: ManualClock())
            let scales = scope.observe(Observations { services.settings?.settings.interfaceScale })
            await services.start()
            let settings = try #require(services.settings)
            await waitUntil { scales.values.last == 100 }
            try await settings.edit { $0.interfaceScale = 120 }
            await waitUntil { scales.values.last == 120 }
        }
    }

    // A change runs its effects in the order of SettingsEffects: the services change the login
    // item, and the app target gets the menu, the zoom and the updates. The account usage goes to
    // the poller of the services (none here), and the registry follows the escalation time, so
    // these give the app target nothing.
    @Test func aChangeRunsItsEffectsInOrder() async throws {
        try await withScope { scope in
            let (services, _) = try scope.services(environment: noClaude(scope.fake))
            let calls = Recorder<EffectCall>()
            let loginItem = FakeLoginItem(calls: calls)
            await services.start(loginItem: loginItem, effects: { calls.record(.app($0)) })
            let settings = try #require(services.settings)
            try await settings.edit {
                $0.escalationMinutes = 3
                $0.accountUsage = true
                $0.autoUpdate = false
                $0.interfaceScale = 120
                $0.keys = ["close-panel:mod": "Mod+Shift+W"]
                $0.startAtLogin = true
            }
            await waitUntil {
                calls.values == [
                    .loginItem(on: true), .app(.menu), .app(.zoom(scale: 120)),
                    .app(.updates(on: false)),
                ]
            }
            #expect(loginItem.isOn)
        }
    }

    // The open of the settings and a change with no effect run nothing. A zoom after them is the
    // first call.
    @Test func aChangeWithNoEffectRunsNothing() async throws {
        try await withScope { scope in
            let (services, _) = try scope.services(environment: noClaude(scope.fake))
            let calls = Recorder<EffectCall>()
            let loginItem = FakeLoginItem(calls: calls)
            await services.start(loginItem: loginItem, effects: { calls.record(.app($0)) })
            let settings = try #require(services.settings)
            try await settings.edit { $0.labels = .space }
            try await settings.edit { $0.interfaceScale = 120 }
            await waitUntil { !calls.values.isEmpty }
            #expect(calls.values == [.app(.zoom(scale: 120))])
        }
    }

    // After the stop, a change runs no effect. Before the stop, a zoom runs. After it, an
    // observer of the settings that the test makes records a marker in the same stream: it sees
    // the change, and the stopped services do not.
    @Test func noEffectRunsAfterTheStop() async throws {
        try await withScope { scope in
            let (services, _) = try scope.services(environment: noClaude(scope.fake))
            let calls = Recorder<EffectCall>()
            await services.start(effects: { calls.record(.app($0)) })
            let settings = try #require(services.settings)
            try await settings.edit { $0.interfaceScale = 120 }
            await waitUntil { calls.values == [.app(.zoom(scale: 120))] }
            services.stop()
            let changes = Observations { settings.settings.interfaceScale }
            let markers = Task {
                for await scale in changes { calls.record(.marker(scale: scale)) }
            }
            defer { markers.cancel() }
            await waitUntil { calls.values.last == .marker(scale: 120) }
            try await settings.edit { $0.interfaceScale = 140 }
            await waitUntil { calls.values.last == .marker(scale: 140) }
            #expect(
                calls.values == [
                    .app(.zoom(scale: 120)), .marker(scale: 120), .marker(scale: 140),
                ])
        }
    }

    // A login item that cannot change does not stop the effects after it. The setting stays
    // saved, and the services keep the reason until a later change of the login item works.
    @Test func aFailedEffectDoesNotStopTheOthers() async throws {
        try await withScope { scope in
            let (services, _) = try scope.services(environment: noClaude(scope.fake))
            let calls = Recorder<EffectCall>()
            let loginItem = FakeLoginItem(calls: calls)
            loginItem.failure = .needsApproval
            await services.start(loginItem: loginItem, effects: { calls.record(.app($0)) })
            let settings = try #require(services.settings)
            #expect(services.loginItemProblem == nil)
            try await settings.edit {
                $0.startAtLogin = true
                $0.keys = ["close-panel:mod": "Mod+Shift+W"]
                $0.interfaceScale = 120
            }
            await waitUntil {
                calls.values == [.loginItem(on: true), .app(.menu), .app(.zoom(scale: 120))]
            }
            #expect(!loginItem.isOn)
            #expect(settings.settings.startAtLogin)
            #expect(services.loginItemProblem == .needsApproval)
            // A good change clears the problem.
            loginItem.failure = nil
            try await settings.edit { $0.startAtLogin = false }
            await waitUntil { calls.values.last == .loginItem(on: false) }
            #expect(services.loginItemProblem == nil)
        }
    }

    // The user can allow a login item that waits in System Settings. A read of the login item
    // again (when Settings opens or the app becomes active) clears the problem when the real
    // state now matches Start at login. Before the approval the problem stays.
    @Test func aReadAgainClearsTheProblemAfterTheApproval() async throws {
        try await withScope { scope in
            let (services, _) = try scope.services(environment: noClaude(scope.fake))
            let calls = Recorder<EffectCall>()
            let loginItem = FakeLoginItem(calls: calls)
            loginItem.failure = .needsApproval
            // With no settings yet, the read does nothing.
            services.readLoginItemAgain()
            await services.start(loginItem: loginItem, effects: { calls.record(.app($0)) })
            let settings = try #require(services.settings)
            try await settings.edit { $0.startAtLogin = true }
            await waitUntil { services.loginItemProblem == .needsApproval }
            services.readLoginItemAgain()
            #expect(services.loginItemProblem == .needsApproval)
            loginItem.isOn = true
            services.readLoginItemAgain()
            #expect(services.loginItemProblem == nil)
            #expect(calls.values == [.loginItem(on: true)])
        }
    }

    // At the start of a release app, the real state of the login item wins over the file, both
    // ways. The fix saves the setting and does not change the login item again.
    @Test(arguments: [true, false])
    func theRealLoginStateWinsAtTheStartOfARelease(realOn: Bool) async throws {
        try await withScope { scope in
            let (services, plan) = try scope.services(environment: noClaude(scope.fake))
            try Data(#"{"version":1,"startAtLogin":\#(!realOn)}"#.utf8)
                .write(to: plan.settingsFile)
            let calls = Recorder<EffectCall>()
            let loginItem = FakeLoginItem(isOn: realOn, calls: calls)
            await services.start(loginItem: loginItem, effects: { calls.record(.app($0)) })
            let settings = try #require(services.settings)
            #expect(settings.settings.startAtLogin == realOn)
            #expect(try savedStartAtLogin(plan.settingsFile) == realOn)
            // A zoom is the marker: no call of the login item came before it.
            try await settings.edit { $0.interfaceScale = 120 }
            await waitUntil { !calls.values.isEmpty }
            #expect(calls.values == [.app(.zoom(scale: 120))])
        }
    }

    // With no login item, as in a development app, Start at login saves and changes nothing
    // more: the effect reaches neither a login item nor the app target.
    @Test func withNoLoginItemStartAtLoginOnlySaves() async throws {
        try await withScope { scope in
            let (services, plan) = try scope.services(environment: noClaude(scope.fake))
            let calls = Recorder<EffectCall>()
            await services.start(effects: { calls.record(.app($0)) })
            let settings = try #require(services.settings)
            try await settings.edit { $0.startAtLogin = true }
            #expect(try savedStartAtLogin(plan.settingsFile))
            // A zoom is the marker: no call came before it.
            try await settings.edit { $0.interfaceScale = 120 }
            await waitUntil { !calls.values.isEmpty }
            #expect(calls.values == [.app(.zoom(scale: 120))])
        }
    }

    // MARK: - The services of phase 4e

    // The Event log reads the state events of the registry: a Live details line gives one entry
    // with the row ID of its session. The start makes the PR lookup with the env of claude. The
    // mod manifest exists, so the start rule of Live details listens on the shared socket of the
    // test home. The test ends the batch window of the line on the manual clock.
    @Test func theEventLogReadsTheStateEventsOfTheRegistry() async throws {
        try await withScope { scope in
            let clock = ManualClock()
            let (services, _) = try scope.services(clock: clock)
            let manifest = scope.fake.home.appending(path: ".bifrost/mod/.claude-plugin")
            try FileManager.default.createDirectory(
                at: manifest, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: manifest.appending(path: "plugin.json"))
            let socket = services.sharedState.liveSocket.path(percentEncoded: false)
            await services.start()
            #expect(services.prLookup != nil)
            await waitUntil { services.liveServer?.state == LiveServerState(listening: true) }
            await waitUntil { services.sessions.rows.count == 2 }
            #expect(services.eventLog.entries.isEmpty)
            let alpha = FakeClaude.alpha.sessionId
            let answer = Task { try await post(socket, liveLine(alpha)) }
            let server = try #require(services.liveServer)
            await waitUntil { server.batchCount == 1 }
            clock.advance(by: .milliseconds(50))
            #expect(try await answer.value.hasPrefix("HTTP/1.1 204 "))
            await waitUntil { !services.eventLog.entries.isEmpty }
            let entries = services.eventLog.entries
            #expect(
                entries.map(\.kind)
                    == [.event(sessionId: alpha, name: .userPromptSubmit, tool: nil)])
        }
    }

    // A session usage line at 92 % gives the usage notification through the notifier, with the
    // label "usage limit" and no session. A refusal gives one line in the Event log, also for a
    // second refusal. A click asks the shell to open the Usage HUD.
    @Test func theUsageNotificationGoesToTheNotifier() async throws {
        try await withScope { scope in
            let notifier = FakeNotifier()
            let clock = ManualClock()
            let (services, _) = try scope.services(clock: clock, notifier: notifier)
            var clicks = 0
            services.onUsageClick = { clicks += 1 }
            await services.start()
            #expect(services.usageAlerts != nil)
            let registry = try #require(services.registry)
            await waitUntil { services.sessions.rows.count == 2 }
            registry.pushLive(usageLine(FakeClaude.alpha.sessionId, percent: 92))
            await waitUntil { notifier.shown.count == 1 }
            let note = try #require(notifier.shown.first)
            #expect(note.source == .usageLimit)
            #expect(note.title.contains("5-hour") && note.title.hasSuffix(" at 92%"))
            notifier.click(0)
            #expect(clicks == 1)
            notifier.refuse(0)
            notifier.refuse(0)
            services.notificationRefused()
            await waitUntil { !services.eventLog.entries.isEmpty }
            // The gap of the batcher ends, so a second line would be in the entries now.
            let gap = services.eventLog.batchTimer
            clock.advance(by: EventBatcher.gap)
            await gap?.value
            #expect(
                services.eventLog.entries.map(\.kind) == [.notice(EventLog.notificationRefused)])
        }
    }

    // The notifications of Reviews use the hooks that the shell gives: no notification while the
    // window has the focus, a click runs onReviewsClick, and a refusal gives the line of the
    // Event log. The Reviews store is in the test home, and gh is not a program of the fake, so
    // nothing reaches GitHub.
    @Test func theReviewsNotificationsUseTheHooksOfTheWindow() async throws {
        try await withScope { scope in
            let notifier = FakeNotifier()
            let clock = ManualClock()
            let (services, _) = try scope.services(clock: clock, notifier: notifier)
            let window = WindowHooks()
            services.reviewsFocused = { window.focused }
            services.onReviewsClick = { window.clicks += 1 }
            await services.start()
            let parts = try #require(services.reviews)
            #expect(services.sharedState.reviewsFolder.path.hasPrefix(scope.fake.home.path))
            let settings = try #require(services.settings)
            _ = try await settings.edit { $0.reviewsWatch = true }
            #expect(await waitUntil { parts.watcher != nil })
            let watcher = try #require(parts.watcher)
            let pr = try #require(PRKey(text: "owner-a/repo-a#1"))
            watcher.notify(.newRequest(pr))
            #expect(notifier.shown.isEmpty)
            window.focused = false
            watcher.notify(.newRequest(pr))
            #expect(notifier.shown.map(\.source) == [.reviews])
            notifier.click(0)
            #expect(window.clicks == 1)
            notifier.refuse(0)
            await waitUntil { !services.eventLog.entries.isEmpty }
            #expect(
                services.eventLog.entries.map(\.kind) == [.notice(EventLog.notificationRefused)])
            await services.reviews?.closeForQuit().value
        }
    }

    // The poller polls only while Account usage is on: on polls at once, and off stops the
    // poller and clears its values. The poller of the test finds no login, so it sends no
    // request.
    @Test func theAccountUsageSettingStartsAndStopsThePoller() async throws {
        try await withScope { scope in
            let fetcher = CountingFetcher()
            let poller = noLoginPoller(fetcher)
            let (services, _) = try scope.services(
                environment: noClaude(scope.fake), poller: poller)
            await services.start()
            let settings = try #require(services.settings)
            #expect(poller.lastResult == nil)
            #expect(poller.pollTask == nil)
            try await settings.edit { $0.accountUsage = true }
            await waitUntil { poller.lastResult == .noData }
            try await settings.edit { $0.accountUsage = false }
            await waitUntil { poller.lastResult == nil }
            #expect(poller.timerTask == nil)
            #expect(fetcher.fetches == 0)
        }
    }

    // With Account usage on in settings.json, the start polls at once. The stop of the services
    // stops the poller.
    @Test func aStartWithAccountUsageOnPollsAndAStopEndsThePoller() async throws {
        try await withScope { scope in
            let (first, _) = try scope.services(environment: noClaude(scope.fake))
            await first.start()
            try await #require(first.settings).edit { $0.accountUsage = true }
            first.stop()
            let poller = noLoginPoller(CountingFetcher())
            let (services, _) = try scope.services(
                environment: noClaude(scope.fake), poller: poller)
            await services.start()
            await waitUntil { poller.lastResult == .noData }
            services.stop()
            #expect(poller.lastResult == nil)
            #expect(poller.timerTask == nil)
        }
    }
}

// The focus of the window and the clicks on a notification, as the shell gives them to the
// services.
@MainActor
private final class WindowHooks {
    var focused = true
    var clicks = 0
}

// The settings give the escalation time and the poll interval of the registry. The other
// values of the timing stay at their defaults.
@Test func theRegistryValuesComeFromTheSettings() {
    var settings = Settings()
    settings.escalationMinutes = 3
    settings.pollSeconds = 5
    let values = registryValues(settings)
    #expect(values.escalation == .seconds(180))
    var timing = RegistryTiming()
    timing.active = .seconds(5)
    #expect(values.timing == timing)
}

// The shared state comes from the shared home of the plan, also when the home of the services
// is another folder. The services do not start, so they read no file and run no program.
@MainActor
@Test func theSharedStateIsUnderTheSharedHomeOfThePlan() throws {
    let identity = try development()
    let planHome = URL(fileURLWithPath: "/tmp/bifrost-plan-home", isDirectory: true)
    let otherHome = URL(fileURLWithPath: "/tmp/bifrost-other-home", isDirectory: true)
    let plan = StartPlan(
        identity: identity, home: planHome, realHome: otherHome, testHome: true,
        folders: DataFolders(identity: identity, home: planHome))
    let services = AppServices(
        plan: plan, home: otherHome, environment: [:], processes: FakeProcessInspector(),
        speechEngine: { _ in FakeSpeechEngine() }, now: { Date(timeIntervalSince1970: 0) })
    #expect(plan.sharedHome.path == planHome.path)
    #expect(services.sharedState == SharedClaudeState(home: plan.sharedHome))
    #expect(services.sharedState.bifrostHome.path == "/tmp/bifrost-plan-home/.bifrost")
}
