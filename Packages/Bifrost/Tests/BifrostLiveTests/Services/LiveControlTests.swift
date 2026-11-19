import BifrostFoundation
import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostLive
@testable import BifrostSessions

// The Live details control with real processes: each claude command runs the fake claude of
// scripts/fake-claude in a test home in a short temporary folder, in the test sandbox. The fake
// keeps the plugin state in fake-plugins.json and logs each call in claude-calls.log. The shared
// paths are the paths of the test home, so the server listens on <test home>/.bifrost/live.sock
// and the mod goes to <test home>/.bifrost/mod. The clock of the server and of the plugin limit
// is a ManualClock that no test moves. No test runs the real claude or touches the real home.

private let pluginID = "bifrost-live@bifrost-local"
private let scope = " --scope user --json"
private let sessionId = "73b5ca76-a4a8-4f97-9764-e41657296414"
private let tooOld = "Live details needs Claude Code 2.1.290 or later. This Mac has 2.1.289."

// The events of the server.
@MainActor
private final class Events {
    var all: [LiveEvent] = []
}

// A listener log that records each event.
private final class ListenerEvents: ListenerLog {
    private let recorded = Mutex<[ListenerLogEvent]>([])

    var events: [ListenerLogEvent] { recorded.withLock { $0 } }

    func record(_ event: ListenerLogEvent) { recorded.withLock { $0.append(event) } }
}

// A runner of the plugin commands that runs no program. The plugin list gives the text of
// plugins, and after an install the Live details plugin, on. The marketplace list is empty. Each
// write command waits at the gate, then gives the result line of a good write. writes has each
// write command after its wait. With holdLists, each list read waits for a cancel of its task
// (30 s at most), then ends as cancelled.
private final class HeldWrites: CommandRunner {
    private struct State {
        var plugins: String
        var writes: [String] = []
        var listsWaiting = 0
        var listsCancelled = 0
    }

    let gate = TestGate()
    private let holdLists: Bool
    private let state: Mutex<State>

    // plugins: the output of the plugin list before an install.
    init(plugins: String, holdLists: Bool = false) {
        self.holdLists = holdLists
        state = Mutex(State(plugins: plugins))
    }

    var writes: [String] { state.withLock { $0.writes } }
    // The list reads that wait for a cancel now, and the list reads that a cancel ended.
    var listsWaiting: Int { state.withLock { $0.listsWaiting } }
    var listsCancelled: Int { state.withLock { $0.listsCancelled } }

    func run(_ command: Command) async -> ExecResult {
        let arguments = command.arguments
        switch arguments {
        case ["plugin", "list", "--json"], ["plugin", "marketplace", "list", "--json"]:
            if holdLists { return await waitForCancel() }
            let list = arguments.count == 3 ? state.withLock { $0.plugins } : "[]"
            return ExecResult(.exited(0), stdout: list)
        default:
            await gate.pass()
            state.withLock { s in
                s.writes.append(arguments.joined(separator: " "))
                if arguments.starts(with: ["plugin", "install"]) {
                    s.plugins = #"[{"id":"\#(pluginID)","enabled":true,"readFromFolder":"/x"}]"#
                }
            }
            return ExecResult(.exited(0), stdout: #"{"outcome":"ok"}"#)
        }
    }

    // Wait until the task of the run gets a cancel. The sleep throws at the cancel.
    private func waitForCancel() async -> ExecResult {
        state.withLock { $0.listsWaiting += 1 }
        let cancelled = (try? await Task.sleep(for: .seconds(30))) == nil
        state.withLock { s in
            s.listsWaiting -= 1
            if cancelled { s.listsCancelled += 1 }
        }
        return ExecResult(cancelled ? .cancelled : .exited(1))
    }
}

// The control in a test home, with the fake claude.
@MainActor
private final class Harness {
    let folder: TemporaryFolder
    let home: URL
    let paths: SharedClaudeState
    let lock = SerialLock()
    let log = LiveLogRecorder()
    let listenerLog = ListenerEvents()
    let events = Events()
    let control: LiveControl

    // registry: the live count and the live flags. claude: false gives no claude. modSource: the
    // mod folder of the app, or nil for the folder of the repo. pluginRunner: the runner of the
    // plugin commands, or nil for the fake claude.
    init(
        forceListen: Bool = false, registry: RegistryService? = nil, claude: Bool = true,
        modSource: URL? = nil, pluginRunner: (any CommandRunner)? = nil,
        health: HealthReporter = .none
    ) throws {
        folder = try TemporaryFolder(short: true)
        home = URL(fileURLWithPath: folder.path, isDirectory: true)
        paths = SharedClaudeState(home: home)
        let fake = try Repo.fakeClaude()
        let bin = URL(fileURLWithPath: fake).deletingLastPathComponent().path
        let base = [
            "PATH": "\(bin):/usr/bin:/bin", "HOME": folder.path, "BIFROST_TEST_HOME": folder.path,
            "LANG": "en_US.UTF-8",
        ]
        let normal = ClaudeRunner(path: fake, baseEnvironment: base, runner: ProcessRunner())
        let plugins = ClaudeRunner(
            path: fake, baseEnvironment: PluginCLI.environment(base, testHome: home),
            runner: pluginRunner ?? ProcessRunner())
        let clock = ManualClock()
        let (log, listenerLog, events) = (log, listenerLog, events)
        let source = try modSource ?? Repo.root().appending(path: "App/Bifrost/Resources/live-mod")
        control = LiveControl(
            paths: paths,
            cli: { claude ? PluginCLI(claude: plugins, ids: .live, clock: clock, log: log) : nil },
            version: { await ClaudeVersion.check(normal, minimum: ClaudeVersionCheck.liveMinimum) },
            server: { socket in
                LiveServer(
                    socketPath: socket.path(percentEncoded: false), clock: clock,
                    batchWindow: .zero,
                    onEvents: { lines in
                        events.all += lines
                        registry?.pushLive(lines)
                    }, log: listenerLog)
            },
            registry: registry, modSource: source, lock: lock, forceListen: forceListen, log: log,
            health: health)
    }

    func finish() {
        control.stop()
        folder.remove()
    }

    // Each call of the fake: its arguments, with one space between them.
    var calls: [String] {
        let text = FileManager.default.contents(atPath: folder.appending("claude-calls.log"))
        return String(decoding: text ?? Data(), as: UTF8.self).split(separator: "\n")
            .map(String.init)
    }

    // The calls that change the plugin state: each one ends with --scope user --json.
    var writes: [String] { calls.filter { $0.hasSuffix(scope) } }

    var socket: String { paths.liveSocket.path(percentEncoded: false) }
    // The path of the mod folder with no "/" at its end, as Bifrost gives it to claude.
    var modFolder: String { folder.appending(".bifrost/mod") }

    func write(_ name: String, _ text: String) throws {
        let url = URL(fileURLWithPath: folder.appending(name))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // The plugin state of the fake: the plugin on or off, and the marketplace of Bifrost.
    func installPlugin(enabled: Bool) throws {
        try write(
            "fake-plugins.json",
            """
            {"plugins":[{"id":"\(pluginID)","enabled":\(enabled),"scope":"user",\
            "readFromFolder":"\(modFolder)"}],\
            "marketplaces":[{"name":"bifrost-local","source":"directory","path":"\(modFolder)"}]}
            """)
    }

    // Send a line to the socket and give the status of the answer, or 0 for no answer.
    func post(_ line: String) async throws -> Int {
        let client = try UnixClient(path: socket)
        defer { client.close() }
        let head = "POST /v1/event HTTP/1.1\r\nHost: localhost\r\n"
            + "Content-Length: \(line.utf8.count)\r\n\r\n"
        _ = await client.write(Array((head + line).utf8))
        let answer = String(
            decoding: await client.readToEnd(limit: .seconds(30)) ?? [], as: UTF8.self)
        guard answer.hasPrefix("HTTP/1.1 ") else { return 0 }
        return Int(answer.dropFirst(9).prefix(3)) ?? 0
    }

    // The result of an action.
    func run(_ action: LiveAction) async -> Result<LiveStatus, PluginFailure> {
        do throws(PluginFailure) {
            return .success(try await control.run(action))
        } catch {
            return .failure(error)
        }
    }
}

private func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

private func mode(_ path: String) -> mode_t {
    var info = stat()
    return lstat(path, &info) == 0 ? info.st_mode & 0o777 : 0
}

// A turn.start line of the mod for the session, sent now.
private func line() -> String {
    let now = Int(Date().timeIntervalSince1970 * 1000)
    return #"{"at":\#(now),"kind":"turn.start","seq":1,"sid":"\#(sessionId)","v":1}"#
}

@Suite(
    "the Live details control with the fake claude", .testTimeLimit, .tags(.realProcess))
@MainActor
struct LiveControlTests {
    init() throws { try TestSandbox.require() }

    // MARK: - The start rule

    @Test func withThePluginOnTheStartSyncsTheModAndListens() async throws {
        let h = try Harness()
        defer { h.finish() }
        try h.installPlugin(enabled: true)
        h.control.start()
        let status = await h.control.status()
        #expect(status.plugin == .enabled)
        #expect(status.listening)
        #expect(status.modCurrent)
        #expect(status.error == nil)
        #expect(await FolderSync.modCurrent(source: try modSource(), dest: h.paths.modFolder))
        #expect(h.writes.isEmpty)
    }

    @Test func withThePluginOffOrNotInstalledTheStartDoesNotListen() async throws {
        for installed in [true, false] {
            let h = try Harness()
            defer { h.finish() }
            if installed { try h.installPlugin(enabled: false) }
            h.control.start()
            let status = await h.control.status()
            #expect(status.plugin == (installed ? .disabled : .notInstalled))
            #expect(!status.listening)
            #expect(!exists(h.modFolder))
            #expect(!exists(h.socket))
        }
    }

    // When the plugin list fails, the start listens only when the mod manifest exists.
    @Test func whenThePluginListFailsTheStartListensOnlyWithTheModManifest() async throws {
        for manifest in [false, true] {
            let h = try Harness()
            defer { h.finish() }
            try h.write("fake-plugins-fail", "")
            if manifest { try h.write(".bifrost/mod/.claude-plugin/plugin.json", "{}") }
            h.control.start()
            let status = await h.control.status()
            #expect(status.listening == manifest)
            #expect(status.plugin == .unknown)
            #expect(status.error?.hasPrefix("Bifrost couldn't read the plugin list") == true)
            #expect(
                h.log.events
                    == [
                        .pluginListUnreadable(
                            .unreadableList(
                                .plugin, end: .exited(1),
                                stderr: "fake claude: the plugin list failed"))
                    ])
        }
    }

    // The old mod files still send lines, so a failed copy still listens.
    @Test func aFailedCopyOfTheModStillListens() async throws {
        let missing = URL(fileURLWithPath: "/nonexistent-bifrost-test/live-mod", isDirectory: true)
        let h = try Harness(modSource: missing)
        defer { h.finish() }
        try h.installPlugin(enabled: true)
        h.control.start()
        let status = await h.control.status()
        #expect(status.listening)
        guard case .modCopyFailed? = h.log.events.first else {
            Issue.record("no log of the copy: \(h.log.events)")
            return
        }
    }

    // With forceListen, the start listens with no claude call.
    @Test func forceListenListensAtOnceWithNoClaudeCall() async throws {
        let h = try Harness(forceListen: true)
        defer { h.finish() }
        h.control.start()
        await waitUntil { h.control.server.state.listening }
        #expect(h.control.server.state.listening)
        #expect(h.calls.isEmpty)
    }

    // The start first removes the old hook data in the shared dot folder. The settings have no
    // old hook entry, so bin goes too.
    @Test func theStartRemovesTheOldHookData() async throws {
        let h = try Harness()
        defer { h.finish() }
        for name in ["active", "events/1.json", "sessions/2.json", "bin/bifrost-hook"] {
            try h.write(".bifrost/\(name)", "old")
        }
        h.control.start()
        _ = await h.control.status()
        for name in ["active", "events", "sessions", "bin"] {
            #expect(!exists(h.paths.bifrostHome.appending(path: name).path))
        }
    }

    // MARK: - The listener

    @Test func theListenerUsesTheSharedSocketOfTheHome() async throws {
        let h = try Harness()
        defer { h.finish() }
        try h.installPlugin(enabled: true)
        h.control.start()
        #expect(await h.control.status().listening)
        #expect(h.socket == h.folder.path + "/.bifrost/live.sock")
        #expect(mode(h.socket) == 0o600)
        #expect(mode(h.folder.appending(".bifrost")) == 0o700)
        #expect(exists(h.folder.appending(".bifrost/live.lock")))
        #expect(try await h.post(line()) == 204)
        #expect(h.events.all.count == 1)
    }

    // A linked dot folder stays refused (user decision, 2026-11-17): the status shows the reason.
    @Test func aListenThatTheFolderCheckRefusesShowsItsReason() async throws {
        let h = try Harness(forceListen: true)
        defer { h.finish() }
        let target = h.folder.appending("elsewhere")
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: h.folder.appending(".bifrost"), withDestinationPath: target)
        h.control.start()
        let status = await h.control.status()
        #expect(!status.listening)
        let folder = h.folder.appending(".bifrost")
        #expect(
            status.error
                == "Bifrost doesn't listen in \(folder), because it's a link or another user "
                + "owns it.")
    }

    // Each start of the server tells the health log: the reason of a start that did not listen,
    // or a good start. Turn off tells it that Live details does not listen now, so an old failure
    // no longer applies.
    @Test func eachStartOfTheServerTellsTheHealthLog() async throws {
        let (refusedHealth, refusedEvents) = HealthReporter.make()
        var refusedTold = refusedEvents.makeAsyncIterator()
        let refused = try Harness(forceListen: true, health: refusedHealth)
        defer { refused.finish() }
        let target = refused.folder.appending("elsewhere")
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: refused.folder.appending(".bifrost"), withDestinationPath: target)
        refused.control.start()
        let reason = try #require(await refused.control.status().error)
        #expect(await refusedTold.next() == .liveStart(failed: reason))

        let (health, events) = HealthReporter.make()
        var told = events.makeAsyncIterator()
        let h = try Harness(health: health)
        defer { h.finish() }
        try h.installPlugin(enabled: true)
        h.control.start()
        #expect(await h.control.status().listening)
        #expect(await told.next() == .liveStart(failed: nil))
        _ = try await h.run(.disable).get()
        #expect(await told.next() == .liveStart(failed: nil))
    }

    // A stop cancels the start: a start that a stop cancelled does not listen.
    @Test func aStopCancelsTheStartAndStopsTheServer() async throws {
        let h = try Harness()
        defer { h.finish() }
        try h.installPlugin(enabled: true)
        h.control.start()
        h.control.stop()
        #expect(!(await h.control.status().listening))
        #expect(!exists(h.socket))
        await #expect(throws: PluginFailure.cancelled) { try await h.control.run(.enable) }

        let started = try Harness()
        defer { started.finish() }
        try started.installPlugin(enabled: true)
        started.control.start()
        #expect(await started.control.status().listening)
        started.control.stop()
        #expect(!started.control.server.state.listening)
        #expect(!exists(started.socket))
    }

    // MARK: - The actions

    @Test func aForeignMarketplaceStopsInstallBeforeAnyWrite() async throws {
        let h = try Harness()
        defer { h.finish() }
        try h.write(
            "fake-plugins.json",
            #"{"plugins":[],"marketplaces":[{"name":"bifrost-local","source":"directory","#
                + #""path":"/elsewhere/mod"}]}"#)
        let result = await h.run(.install)
        #expect(
            result == .failure(.foreignMarketplace(name: "bifrost-local", place: "/elsewhere/mod")))
        #expect(
            result.failure?.message
                == "A marketplace with the name bifrost-local already exists at /elsewhere/mod. "
                + "Bifrost did not change it.")
        #expect(h.writes.isEmpty)
        #expect(!exists(h.modFolder))
        #expect(!exists(h.socket))
    }

    @Test func installAddsTheMarketplaceInstallsThePluginAndListens() async throws {
        let h = try Harness()
        defer { h.finish() }
        let status = try await h.run(.install).get()
        #expect(status.plugin == .enabled)
        #expect(status.listening)
        #expect(status.modCurrent)
        #expect(status.versionOk && status.claudeVersion == "2.1.318")
        #expect(
            h.writes == [
                "plugin marketplace add \(h.modFolder)\(scope)",
                "plugin install \(pluginID)\(scope)",
            ])
        #expect(try await h.post(line()) == 204)
    }

    // An install that leaves the plugin off turns it on.
    @Test func installTurnsOnAPluginThatTheInstallLeftOff() async throws {
        let h = try Harness()
        defer { h.finish() }
        try h.write("fake-install-off", "")
        let status = try await h.run(.install).get()
        #expect(status.plugin == .enabled)
        #expect(h.writes.last == "plugin enable \(pluginID)\(scope)")
    }

    @Test func installAndTurnOnRefuseAVersionBelowTheMinimumBeforeAnyChange() async throws {
        let h = try Harness()
        defer { h.finish() }
        try h.installPlugin(enabled: false)
        try h.write("fake-version", "2.1.289 (Claude Code)\n")
        for action in [LiveAction.install, .enable] {
            let result = await h.run(action)
            #expect(result == .failure(.liveVersionTooOld(found: "2.1.289")))
            #expect(result.failure?.message == tooOld)
        }
        #expect(h.calls == ["--version", "--version"])
    }

    @Test func turnOnRefusesAPluginThatIsNotInstalled() async throws {
        let h = try Harness()
        defer { h.finish() }
        let result = await h.run(.enable)
        #expect(result == .failure(.notInstalled(.live)))
        #expect(result.failure?.message == "Live details is not installed.")
        #expect(h.writes.isEmpty)
    }

    @Test func turnOnSyncsTheModAndListens() async throws {
        let h = try Harness()
        defer { h.finish() }
        try h.installPlugin(enabled: false)
        let status = try await h.run(.enable).get()
        #expect(status.plugin == .enabled && status.listening && status.modCurrent)
        #expect(h.writes == ["plugin enable \(pluginID)\(scope)"])
    }

    // Turn off stops the server first, then ends the live flags, so the status shows 0 live
    // sessions at once.
    @Test func turnOffStopsTheListenerAndClearsTheLiveFlags() async throws {
        let registry = try await liveRegistry()
        defer { registry.stop() }
        let h = try Harness(registry: registry)
        defer { h.finish() }
        try h.installPlugin(enabled: true)
        h.control.start()
        #expect(await h.control.status().listening)
        #expect(try await h.post(line()) == 204)
        #expect(registry.liveCount == 1)
        let status = try await h.run(.disable).get()
        #expect(!status.listening)
        #expect(status.liveSessions == 0)
        #expect(registry.liveCount == 0)
        #expect(status.plugin == .disabled)
        #expect(!exists(h.socket))
        #expect(h.writes == ["plugin disable \(pluginID)\(scope)"])
    }

    // Remove also stops the server first and ends the live flags.
    @Test func removeStopsTheListenerAndClearsTheLiveFlags() async throws {
        let registry = try await liveRegistry()
        defer { registry.stop() }
        let h = try Harness(registry: registry)
        defer { h.finish() }
        try h.installPlugin(enabled: true)
        h.control.start()
        #expect(await h.control.status().listening)
        #expect(try await h.post(line()) == 204)
        #expect(registry.liveCount == 1)
        let status = try await h.run(.uninstall).get()
        #expect(!status.listening)
        #expect(status.liveSessions == 0)
        #expect(registry.liveCount == 0)
        #expect(!exists(h.socket))
    }

    // A stop of the app during Install or Turn on ends the action at its next step with no
    // listener. The write that runs still runs to its end.
    @Test func aStopDuringInstallOrTurnOnEndsWithNoListener() async throws {
        let installed =
            #"[{"id":"\#(pluginID)","enabled":false,"readFromFolder":"/x"}]"#
        for (action, plugins) in [(LiveAction.install, "[]"), (.enable, installed)] {
            let runs = HeldWrites(plugins: plugins)
            defer { runs.gate.openAll() }
            let h = try Harness(pluginRunner: runs)
            defer { h.finish() }
            let job = Task { await h.run(action) }
            await runs.gate.waitUntilHolding()
            h.control.stop()
            runs.gate.open()
            #expect(await job.value == .failure(.cancelled))
            #expect(!h.control.server.state.listening)
            #expect(!exists(h.socket))
        }
    }

    // After its first plugin write, an action runs to its end: a cancel of the caller does not
    // end it.
    @Test func aCancelAfterTheFirstWriteRunsTheActionToItsEnd() async throws {
        let installed =
            #"[{"id":"\#(pluginID)","enabled":false,"readFromFolder":"/x"}]"#
        let runs = HeldWrites(plugins: installed)
        defer { runs.gate.openAll() }
        let h = try Harness(pluginRunner: runs)
        defer { h.finish() }
        let job = Task { await h.run(.enable) }
        await runs.gate.waitUntilHolding()
        job.cancel()
        runs.gate.open()
        let status = try await job.value.get()
        #expect(status.listening)
    }

    // The same for Install: a cancel while the marketplace add runs still installs the plugin
    // and listens.
    @Test func aCancelAfterTheMarketplaceAddStillInstallsAndListens() async throws {
        let runs = HeldWrites(plugins: "[]")
        defer { runs.gate.openAll() }
        let h = try Harness(pluginRunner: runs)
        defer { h.finish() }
        let job = Task { await h.run(.install) }
        await runs.gate.waitUntilHolding()
        job.cancel()
        runs.gate.openAll()
        let status = try await job.value.get()
        #expect(status.plugin == .enabled)
        #expect(status.listening)
        #expect(
            runs.writes == [
                "plugin marketplace add \(h.modFolder)\(scope)",
                "plugin install \(pluginID)\(scope)",
            ])
    }

    // Before the first write, a cancel of the caller stops a list read at once: the read ends
    // as cancelled, and the action changes nothing.
    @Test func aCancelStopsAListReadAtOnce() async throws {
        let runs = HeldWrites(plugins: "[]", holdLists: true)
        let h = try Harness(pluginRunner: runs)
        defer { h.finish() }
        let job = Task { await h.run(.install) }
        await waitUntil { runs.listsWaiting == 1 }
        job.cancel()
        #expect(await job.value == .failure(.cancelled))
        #expect(runs.listsCancelled == 1)
        #expect(runs.writes.isEmpty)
        #expect(!exists(h.socket))
    }

    // Turn on removes an old hook install first, and settings that Bifrost cannot read stop it
    // before any change.
    @Test func turnOnRemovesAnOldInstallFirstAndRefusesUnreadableSettings() async throws {
        let h = try Harness()
        defer { h.finish() }
        try h.installPlugin(enabled: false)
        let hook = #"{"type":"command","command":"~/.bifrost/bin/bifrost-hook"}"#
        try h.write(".claude/settings.json", #"{"hooks":{"Stop":[{"hooks":[\#(hook)]}]}}"#)
        let status = try await h.run(.enable).get()
        #expect(!status.oldInstall && status.plugin == .enabled)
        let settings = try String(
            contentsOfFile: h.folder.appending(".claude/settings.json"), encoding: .utf8)
        #expect(settings == "{}\n")

        let other = try Harness()
        defer { other.finish() }
        try other.installPlugin(enabled: false)
        try other.write(".claude/settings.json", "not json")
        guard case .failure(.unreadableSettings(_, keptOldHooks: false)) = await other.run(.enable)
        else {
            Issue.record("no refusal")
            return
        }
        #expect(other.writes.isEmpty)
        #expect(!exists(other.modFolder))
    }

    // A stop before the start, or straight after it, keeps the old hook data: the start does
    // nothing after a stop.
    @Test func aStopBeforeTheStartKeepsTheOldHookData() async throws {
        for stopFirst in [true, false] {
            let h = try Harness()
            defer { h.finish() }
            try h.write(".bifrost/active", "old")
            if stopFirst {
                h.control.stop()
                h.control.start()
            } else {
                h.control.start()
                h.control.stop()
            }
            _ = await h.control.status()
            #expect(exists(h.folder.appending(".bifrost/active")))
        }
    }

    // A registry with one row of the session of line() in its first poll.
    private func liveRegistry() async throws -> RegistryService {
        let registry = RegistryService(
            registry: SessionRegistry(store: RegistryStore(), escalation: .seconds(600)),
            deps: FixedRegistryDeps(active: [
                AgentEntry(
                    sessionId: sessionId, cwd: "/p", isBackground: true, startedAt: 1,
                    name: "bifrost-test-s", status: .idle, pid: 4242, id: nil)
            ]),
            clock: ManualClock())
        registry.start()
        await waitUntil { registry.loaded }
        return registry
    }

    @Test func removeRemovesThePluginTheMarketplaceAndTheModFolder() async throws {
        let h = try Harness()
        defer { h.finish() }
        _ = try await h.run(.install).get()
        let status = try await h.run(.uninstall).get()
        #expect(status.plugin == .notInstalled)
        #expect(!status.listening)
        #expect(!exists(h.modFolder))
        #expect(!exists(h.socket))
        #expect(
            Array(h.writes.suffix(2)) == [
                "plugin uninstall \(pluginID)\(scope)",
                "plugin marketplace remove bifrost-local\(scope)",
            ])
    }

    // Remove never removes a marketplace with another path.
    @Test func removeKeepsTheMarketplaceOfAnotherProgram() async throws {
        let h = try Harness()
        defer { h.finish() }
        try h.write(
            "fake-plugins.json",
            #"{"plugins":[],"marketplaces":[{"name":"bifrost-local","source":"directory","#
                + #""path":"/elsewhere/mod"}]}"#)
        _ = try await h.run(.uninstall).get()
        #expect(h.writes.isEmpty)
    }

    // Settings that Bifrost cannot read stop Install and Turn on before any change. Remove does
    // its plugin steps and rejects at the end.
    @Test func settingsThatBifrostCannotReadStopTheChanges() async throws {
        let h = try Harness()
        defer { h.finish() }
        try h.write(".claude/settings.json", "not json")
        let install = await h.run(.install)
        guard case .failure(.unreadableSettings(let reason, keptOldHooks: false)) = install else {
            Issue.record("no refusal: \(install)")
            return
        }
        #expect(
            install.failure?.message
                == "Bifrost can't read ~/.claude/settings.json, so it didn't change anything. "
                + reason)
        #expect(h.writes.isEmpty)
        #expect(!exists(h.modFolder))

        try h.installPlugin(enabled: true)
        let remove = await h.run(.uninstall)
        guard case .failure(.unreadableSettings(_, keptOldHooks: true)) = remove else {
            Issue.record("no refusal: \(remove)")
            return
        }
        #expect(remove.failure?.message.contains("so it didn't remove the old hooks.") == true)
        #expect(h.writes.contains("plugin uninstall \(pluginID)\(scope)"))
        #expect(!exists(h.modFolder))
    }

    // Install removes an old hook install first, with a backup of the settings.
    @Test func installRemovesAnOldHookInstallFirst() async throws {
        let h = try Harness()
        defer { h.finish() }
        let hook = #"{"type":"command","command":"~/.bifrost/bin/bifrost-hook"}"#
        try h.write(
            ".claude/settings.json",
            #"{"hooks":{"Stop":[{"hooks":[\#(hook)]}]},"model":"opus"}"#)
        let status = try await h.run(.install).get()
        #expect(!status.oldInstall)
        let settings = try String(
            contentsOfFile: h.folder.appending(".claude/settings.json"), encoding: .utf8)
        #expect(settings == "{\n  \"model\": \"opus\"\n}\n")
        let backups = try FileManager.default.contentsOfDirectory(
            atPath: h.folder.appending(".bifrost/backups"))
        #expect(backups.count == 1)
    }

    @Test func withNoClaudeEachActionRefusesAndTheStatusSaysWhy() async throws {
        let h = try Harness(claude: false)
        defer { h.finish() }
        for action in [LiveAction.disable, .uninstall] {
            let result = await h.run(action)
            #expect(result == .failure(.claudeNotFound))
            #expect(result.failure?.message == "claude was not found.")
        }
        let status = await h.control.status()
        #expect(status.plugin == .unknown)
        #expect(status.error == "claude was not found.")
    }

    // MARK: - The lock

    @Test func anActionDuringAnotherChangeIsBusy() async throws {
        let h = try Harness()
        defer { h.finish() }
        let gate = TestGate()
        defer { gate.openAll() }
        let other = Task { [lock = h.lock] in try await lock.run { await gate.pass() } }
        await gate.waitUntilHolding()
        let result = await h.run(.install)
        #expect(result == .failure(.busy))
        #expect(h.calls.isEmpty)
        gate.open()
        try await other.value
    }

    // A cancel of the task of an action ends it between two steps, and nothing changes.
    @Test func aCancelledActionChangesNothing() async throws {
        let h = try Harness()
        defer { h.finish() }
        let install = Task { await h.run(.install) }
        install.cancel()
        #expect(await install.value == .failure(.cancelled))
        #expect(h.writes.isEmpty)
        #expect(!exists(h.socket))
    }
}

extension Result {
    // The error of a failure, or nil.
    fileprivate var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

private func modSource() throws -> URL {
    try Repo.root().appending(path: "App/Bifrost/Resources/live-mod")
}
