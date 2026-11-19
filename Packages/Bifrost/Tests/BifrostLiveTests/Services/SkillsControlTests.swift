import BifrostFoundation
import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostLive
@testable import BifrostSessions

// The skills control with real processes (docs/behaviour/skills.md, The skills control): each
// claude command runs the fake claude of scripts/fake-claude in a test home in a short temporary
// folder, in the test sandbox. The fake keeps the plugin state in fake-plugins.json and logs each
// call in claude-calls.log. The shared paths are the paths of the test home, so the skills go to
// <test home>/.bifrost/skills. The clock of the plugin limit is a ManualClock that no test moves.
// No test runs the real claude or touches the real home.

private let pluginID = "bifrost@bifrost-skills"
private let livePluginID = "bifrost-live@bifrost-local"
private let scope = " --scope user --json"

// A listener log that keeps nothing: no test here reads the log of the Live details server.
private struct NoListenerLog: ListenerLog {
    func record(_ event: ListenerLogEvent) {}
}

// A runner of the plugin commands that runs no program. It keeps a small plugin state: the
// marketplace list gives the text of markets, and the plugin list has the skills plugin after an
// install (off, as with fake-install-off) and on after an enable. Each command for which hold is
// true waits at the gate first. writes has each write command after its wait.
private final class PluginRuns: CommandRunner {
    private struct State {
        var installed: Bool
        var enabled = false
        var writes: [String] = []
    }

    let gate = TestGate()
    private let markets: String
    private let hold: @Sendable ([String]) -> Bool
    private let state: Mutex<State>

    init(
        markets: String = "[]", installed: Bool = false,
        hold: @escaping @Sendable ([String]) -> Bool = { _ in false }
    ) {
        self.markets = markets
        self.hold = hold
        state = Mutex(State(installed: installed))
    }

    var writes: [String] { state.withLock { $0.writes } }

    func run(_ command: Command) async -> ExecResult {
        let arguments = command.arguments
        if hold(arguments) { await gate.pass() }
        switch arguments {
        case ["plugin", "list", "--json"]:
            let list = state.withLock { s in
                s.installed ? #"[{"id":"\#(pluginID)","enabled":\#(s.enabled)}]"# : "[]"
            }
            return ExecResult(.exited(0), stdout: list)
        case ["plugin", "marketplace", "list", "--json"]:
            return ExecResult(.exited(0), stdout: markets)
        default:
            state.withLock { s in
                s.writes.append(arguments.joined(separator: " "))
                if arguments.contains("install") { s.installed = true }
                if arguments.contains("enable") { s.enabled = true }
            }
            return ExecResult(.exited(0), stdout: #"{"outcome":"ok"}"#)
        }
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
    let clock = ManualClock()
    let source: URL
    let control: SkillsControl
    private let fake: String
    private let base: [String: String]

    // claude: false gives no claude. source: the skills folder of the app, or nil for the folder
    // of the repo. pluginRunner: the runner of the plugin commands, or nil for the fake claude.
    init(
        claude: Bool = true, source: URL? = nil, pluginRunner: (any CommandRunner)? = nil
    ) throws {
        folder = try TemporaryFolder(short: true)
        home = URL(fileURLWithPath: folder.path, isDirectory: true)
        paths = SharedClaudeState(home: home)
        fake = try Repo.fakeClaude()
        let bin = URL(fileURLWithPath: fake).deletingLastPathComponent().path
        base = [
            "PATH": "\(bin):/usr/bin:/bin", "HOME": folder.path, "BIFROST_TEST_HOME": folder.path,
            "LANG": "en_US.UTF-8",
        ]
        self.source = try source ?? skillsSource()
        let plugins = ClaudeRunner(
            path: fake, baseEnvironment: PluginCLI.environment(base, testHome: home),
            runner: pluginRunner ?? ProcessRunner())
        let (clock, log) = (clock, log)
        control = SkillsControl(
            paths: paths,
            cli: {
                claude ? PluginCLI(claude: plugins, ids: .skills, clock: clock, log: log) : nil
            },
            source: self.source, lock: lock, log: log)
    }

    func finish() {
        control.stop()
        folder.remove()
    }

    // A Live details control in the same test home, with the same lock.
    func liveControl() throws -> LiveControl {
        let plugins = ClaudeRunner(
            path: fake, baseEnvironment: PluginCLI.environment(base, testHome: home),
            runner: ProcessRunner())
        let normal = ClaudeRunner(path: fake, baseEnvironment: base, runner: ProcessRunner())
        let (clock, log) = (clock, log)
        return LiveControl(
            paths: paths,
            cli: { PluginCLI(claude: plugins, ids: .live, clock: clock, log: log) },
            version: { await ClaudeVersion.check(normal, minimum: ClaudeVersionCheck.liveMinimum) },
            server: { socket in
                LiveServer(
                    socketPath: socket.path(percentEncoded: false), clock: clock,
                    onEvents: { _ in }, log: NoListenerLog())
            },
            registry: nil, modSource: try modSource(), lock: lock, forceListen: false, log: log)
    }

    // Each call of the fake: its arguments, with one space between them.
    var calls: [String] {
        let text = FileManager.default.contents(atPath: folder.appending("claude-calls.log"))
        return String(decoding: text ?? Data(), as: UTF8.self).split(separator: "\n")
            .map(String.init)
    }

    // The calls that change the plugin state: each one ends with --scope user --json.
    var writes: [String] { calls.filter { $0.hasSuffix(scope) } }

    // The path of the skills folder with no "/" at its end, as Bifrost gives it to claude.
    var skillsFolder: String { folder.appending(".bifrost/skills") }

    func write(_ name: String, _ text: String) throws {
        let url = URL(fileURLWithPath: folder.appending(name))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // The plugin state of the fake. plugin: the skills plugin on or off, or nil for no plugin.
    // readFrom: the folder that the plugin reads. market: the path of the marketplace
    // bifrost-skills, or nil for no marketplace. extra: more JSON items for the two lists.
    func state(
        plugin enabled: Bool?, readFrom: String? = nil, market: String?,
        extraPlugins: String = "", extraMarkets: String = ""
    ) throws {
        var plugins: [String] = []
        if let enabled {
            let folder = (readFrom ?? skillsFolder).jsonText
            plugins.append(
                #"{"id":"\#(pluginID)","enabled":\#(enabled),"scope":"user","#
                    + #""readFromFolder":\#(folder)}"#)
        }
        var markets: [String] = []
        if let market {
            markets.append(
                #"{"name":"bifrost-skills","source":"directory","path":\#(market.jsonText)}"#)
        }
        if !extraPlugins.isEmpty { plugins.append(extraPlugins) }
        if !extraMarkets.isEmpty { markets.append(extraMarkets) }
        try write(
            "fake-plugins.json",
            #"{"plugins":[\#(plugins.joined(separator: ","))],"#
                + #""marketplaces":[\#(markets.joined(separator: ","))]}"#)
    }

    // The skills plugin of Bifrost, installed from the skills folder, on or off.
    func installPlugin(enabled: Bool) throws {
        try state(plugin: enabled, market: skillsFolder)
    }

    // A marketplace bifrost-skills of another program, at the path or with a source and no path,
    // with the skills plugin on.
    func foreignMarketplace(path: String?) throws {
        if let path {
            try state(plugin: true, market: path)
        } else {
            try state(
                plugin: true, market: nil,
                extraMarkets: #"{"name":"bifrost-skills","source":"github"}"#)
        }
    }

    // True when the skills folder has the files of the skills folder of the app.
    func folderCurrent() async -> Bool {
        await FolderSync.skillsCurrent(source: source, dest: paths.skillsFolder)
    }

    // The result of an action.
    func run(_ action: LiveAction) async -> Result<SkillsStatus, PluginFailure> {
        do throws(PluginFailure) {
            return .success(try await control.run(action))
        } catch {
            return .failure(error)
        }
    }
}

extension String {
    // The JSON text of the string. The test paths have no quote and no backslash.
    fileprivate var jsonText: String { "\"\(self)\"" }
}

private func skillsSource() throws -> URL {
    try Repo.root().appending(path: "App/Bifrost/Resources/bifrost-skills")
}

private func modSource() throws -> URL {
    try Repo.root().appending(path: "App/Bifrost/Resources/live-mod")
}

// A skills folder of the app that does not exist.
private let missingSource = URL(
    fileURLWithPath: "/nonexistent-bifrost-test/bifrost-skills", isDirectory: true)

private func foreignText(_ place: String) -> String {
    "A marketplace with the name bifrost-skills already exists at \(place). "
        + "Bifrost did not change it."
}

@Suite("the skills control with the fake claude", .timeLimit(.minutes(1)), .tags(.realProcess))
@MainActor
struct SkillsControlTests {
    init() throws { try TestSandbox.require() }

    // MARK: - The start rule

    // The app starts Live details first, then the skills. Both starts wait for the change that
    // holds the lock, then run in the order of their calls, one at a time.
    @Test func theSkillsStartRunsAfterTheLiveStartInTheLock() async throws {
        let h = try Harness()
        defer { h.finish() }
        let mod = h.folder.appending(".bifrost/mod")
        try h.state(
            plugin: true, market: h.skillsFolder,
            extraPlugins: #"{"id":"\#(livePluginID)","enabled":true,"scope":"user","#
                + #""readFromFolder":\#(mod.jsonText)}"#,
            extraMarkets: #"{"name":"bifrost-local","source":"directory","path":\#(mod.jsonText)}"#
        )
        let live = try h.liveControl()
        defer { live.stop() }
        let gate = TestGate()
        defer { gate.openAll() }
        let other = Task { [lock = h.lock] in try await lock.run { await gate.pass() } }
        await gate.waitUntilHolding()
        live.start()
        h.control.start()
        await waitUntil { h.lock.waiting == 2 }
        #expect(h.calls.isEmpty)
        gate.open()
        try await other.value
        await h.lock.afterFirst {}
        // The start of Live details reads the plugin list. Then the skills start reads the
        // marketplace list and the plugin list.
        #expect(
            h.calls == [
                "plugin list --json", "plugin marketplace list --json", "plugin list --json",
            ])
        #expect(live.server.state.listening)
        #expect(await FolderSync.modCurrent(source: try modSource(), dest: h.paths.modFolder))
        #expect(await h.folderCurrent())
        #expect(h.log.events.isEmpty)
    }

    // An installed plugin gets the files of the app, on or off. An extra file goes.
    @Test(arguments: [true, false])
    func theStartSyncsTheFolderOfAnInstalledPlugin(enabled: Bool) async throws {
        let h = try Harness()
        defer { h.finish() }
        try h.installPlugin(enabled: enabled)
        if enabled { try h.write(".bifrost/skills/old.txt", "old") }
        h.control.start()
        let status = await h.control.status()
        #expect(status.plugin == (enabled ? .enabled : .disabled))
        #expect(status.folderCurrent)
        #expect(status.error == nil)
        #expect(await h.folderCurrent())
        #expect(h.writes.isEmpty)
        #expect(h.log.events.isEmpty)
    }

    @Test func withNoPluginTheStartWritesNothing() async throws {
        let h = try Harness()
        defer { h.finish() }
        h.control.start()
        let status = await h.control.status()
        #expect(status.plugin == .notInstalled)
        #expect(!status.folderCurrent)
        #expect(!fileExists(h.skillsFolder))
        #expect(h.writes.isEmpty)
        #expect(h.log.events.isEmpty)
    }

    // The marketplace of another program is not Bifrost's: the start writes nothing and does not
    // log, also for a marketplace with no path.
    @Test(arguments: ["/elsewhere/skills", nil])
    func aForeignMarketplaceStopsTheStartWithNoWriteAndNoLog(path: String?) async throws {
        let h = try Harness()
        defer { h.finish() }
        try h.foreignMarketplace(path: path)
        h.control.start()
        _ = await h.control.status()
        #expect(!fileExists(h.skillsFolder))
        #expect(h.writes.isEmpty)
        #expect(h.log.events.isEmpty)
    }

    @Test func aFailedListStopsTheStartWithOneLogLine() async throws {
        let h = try Harness()
        defer { h.finish() }
        try h.installPlugin(enabled: true)
        try h.write("fake-plugins-fail", "")
        h.control.start()
        _ = await h.control.status()
        #expect(!fileExists(h.skillsFolder))
        #expect(
            h.log.events
                == [
                    .skillsStartFailed(
                        .unreadableList(
                            .marketplace, end: .exited(1),
                            stderr: "fake claude: the plugin list failed"))
                ])
    }

    @Test func withNoClaudeTheStartWritesNothingAndLogsOneLine() async throws {
        let h = try Harness(claude: false)
        defer { h.finish() }
        h.control.start()
        _ = await h.control.status()
        #expect(!fileExists(h.skillsFolder))
        #expect(h.log.events == [.skillsStartFailed(.claudeNotFound)])
    }

    @Test func aFailedSyncAtTheStartLogsOneLine() async throws {
        let h = try Harness(source: missingSource)
        defer { h.finish() }
        try h.installPlugin(enabled: true)
        h.control.start()
        _ = await h.control.status()
        #expect(!fileExists(h.skillsFolder))
        #expect(
            h.log.events
                == [
                    .skillsStartFailed(
                        .folder(SyncFailure(message: "The skills folder in the app has no files.")))
                ])
    }

    // A stop cancels the start, and no action runs after it.
    @Test func aStopCancelsTheStart() async throws {
        let h = try Harness()
        defer { h.finish() }
        try h.installPlugin(enabled: true)
        h.control.start()
        h.control.stop()
        await h.lock.afterFirst {}
        #expect(!fileExists(h.skillsFolder))
        #expect(h.calls.isEmpty)
        #expect(h.log.events.isEmpty)
        #expect(await h.run(.enable) == .failure(.cancelled))
    }

    // MARK: - The actions

    // The sync comes before the marketplace add, because claude reads the manifest of the
    // marketplace from the folder.
    @Test func installSyncsTheFolderAddsTheMarketplaceAndInstallsThePlugin() async throws {
        let h = try Harness()
        defer { h.finish() }
        let status = try await h.run(.install).get()
        #expect(
            h.writes == [
                "plugin marketplace add \(h.skillsFolder)\(scope)",
                "plugin install \(pluginID)\(scope)",
            ])
        #expect(status.plugin == .enabled)
        #expect(status.folderCurrent)
        #expect(status.error == nil)
        #expect(!status.skills.isEmpty)
        #expect(status.skills == (try await SkillsList.list(h.source)))
        #expect(await h.folderCurrent())
    }

    @Test func installAddsNoMarketplaceThatIsAlreadyBifrosts() async throws {
        let h = try Harness()
        defer { h.finish() }
        try h.state(plugin: nil, market: h.skillsFolder)
        _ = try await h.run(.install).get()
        #expect(h.writes == ["plugin install \(pluginID)\(scope)"])
    }

    // An installed plugin that is off gets no second install: Install turns it on.
    @Test func installTurnsOnAPluginThatIsOff() async throws {
        let h = try Harness()
        defer { h.finish() }
        try h.installPlugin(enabled: false)
        let status = try await h.run(.install).get()
        #expect(h.writes == ["plugin enable \(pluginID)\(scope)"])
        #expect(status.plugin == .enabled)
    }

    // An install that leaves the plugin off reads it again and turns it on.
    @Test func installTurnsOnAPluginThatTheInstallLeftOff() async throws {
        let h = try Harness()
        defer { h.finish() }
        try h.write("fake-install-off", "")
        let status = try await h.run(.install).get()
        #expect(
            h.writes == [
                "plugin marketplace add \(h.skillsFolder)\(scope)",
                "plugin install \(pluginID)\(scope)", "plugin enable \(pluginID)\(scope)",
            ])
        #expect(status.plugin == .enabled)
    }

    // A plugin that is on needs no command, but the folder gets the files of the app.
    @Test func installOfAPluginThatIsOnOnlySyncsTheFolder() async throws {
        let h = try Harness()
        defer { h.finish() }
        try h.installPlugin(enabled: true)
        _ = try await h.run(.install).get()
        #expect(h.writes.isEmpty)
        #expect(await h.folderCurrent())
    }

    // Each action refuses a marketplace bifrost-skills of another program with its text, before
    // any change. The other folder and the skills folder stay as they were.
    @Test func eachActionRefusesAForeignMarketplaceAndWritesNothing() async throws {
        let h = try Harness()
        defer { h.finish() }
        let other = h.folder.appending("other")
        try h.write("other/keep.txt", "mine")
        try await FolderSync.syncSkills(source: h.source, dest: h.paths.skillsFolder)
        try h.foreignMarketplace(path: other)
        for action in [LiveAction.install, .enable, .disable, .uninstall] {
            let result = await h.run(action)
            #expect(
                result == .failure(.foreignMarketplace(name: "bifrost-skills", place: other)))
            #expect(result.failure?.message == foreignText(other))
        }
        #expect(h.writes.isEmpty)
        #expect(fileExists(other + "/keep.txt"))
        #expect(await h.folderCurrent())
    }

    // A marketplace with no path names its source.
    @Test func aForeignMarketplaceWithNoPathNamesItsSource() async throws {
        let h = try Harness()
        defer { h.finish() }
        try h.foreignMarketplace(path: nil)
        for action in [LiveAction.install, .uninstall] {
            let result = await h.run(action)
            #expect(result.failure?.message == foreignText("github"))
        }
        #expect(h.writes.isEmpty)
        #expect(!fileExists(h.skillsFolder))
    }

    @Test func turnOnRefusesAPluginThatIsNotInstalled() async throws {
        let h = try Harness()
        defer { h.finish() }
        let result = await h.run(.enable)
        #expect(result == .failure(.notInstalled(.skills)))
        #expect(result.failure?.message == "Bifrost skills are not installed.")
        #expect(h.writes.isEmpty)
        #expect(!fileExists(h.skillsFolder))
    }

    @Test func turnOnSyncsTheFolderAndTurnsThePluginOn() async throws {
        let h = try Harness()
        defer { h.finish() }
        try h.installPlugin(enabled: false)
        try await FolderSync.syncSkills(source: h.source, dest: h.paths.skillsFolder)
        try h.write(".bifrost/skills/extra.txt", "x")
        let status = try await h.run(.enable).get()
        #expect(h.writes == ["plugin enable \(pluginID)\(scope)"])
        #expect(status.plugin == .enabled)
        #expect(status.folderCurrent)
        #expect(!fileExists(h.skillsFolder + "/extra.txt"))
    }

    @Test func turnOffTurnsOffAnInstalledPlugin() async throws {
        let h = try Harness()
        defer { h.finish() }
        try h.installPlugin(enabled: true)
        let status = try await h.run(.disable).get()
        #expect(h.writes == ["plugin disable \(pluginID)\(scope)"])
        #expect(status.plugin == .disabled)
    }

    @Test func turnOffWithNoPluginRunsNoCommand() async throws {
        let h = try Harness()
        defer { h.finish() }
        let status = try await h.run(.disable).get()
        #expect(h.writes.isEmpty)
        #expect(status.plugin == .notInstalled)
    }

    @Test func removeRemovesThePluginTheMarketplaceAndTheFolder() async throws {
        let h = try Harness()
        defer { h.finish() }
        _ = try await h.run(.install).get()
        let status = try await h.run(.uninstall).get()
        #expect(
            Array(h.writes.suffix(2)) == [
                "plugin uninstall \(pluginID)\(scope)",
                "plugin marketplace remove bifrost-skills\(scope)",
            ])
        #expect(status.plugin == .notInstalled)
        #expect(!status.folderCurrent)
        #expect(!fileExists(h.skillsFolder))
    }

    // A marketplace path with a "/" at its end names the skills folder too.
    @Test func aMarketplacePathWithASlashAtItsEndIsBifrosts() async throws {
        let h = try Harness()
        defer { h.finish() }
        try h.state(plugin: true, market: h.skillsFolder + "/")
        try await FolderSync.syncSkills(source: h.source, dest: h.paths.skillsFolder)
        _ = try await h.run(.uninstall).get()
        #expect(
            h.writes == [
                "plugin uninstall \(pluginID)\(scope)",
                "plugin marketplace remove bifrost-skills\(scope)",
            ])
        #expect(!fileExists(h.skillsFolder))
    }

    // With no plugin and no marketplace, Remove runs no command but removes the folder.
    @Test func removeWithNoPluginRunsNoCommandAndRemovesTheFolder() async throws {
        let h = try Harness()
        defer { h.finish() }
        try h.write(".bifrost/skills/old.txt", "old")
        _ = try await h.run(.uninstall).get()
        #expect(h.writes.isEmpty)
        #expect(!fileExists(h.skillsFolder))
    }

    // A failed sync stops Install before any plugin write.
    @Test func aFailedSyncStopsInstallBeforeTheMarketplaceAdd() async throws {
        let h = try Harness(source: missingSource)
        defer { h.finish() }
        let result = await h.run(.install)
        #expect(
            result
                == .failure(
                    .folder(SyncFailure(message: "The skills folder in the app has no files."))))
        #expect(h.writes.isEmpty)
        #expect(!fileExists(h.skillsFolder))
    }

    // A failed removal of the folder rejects Remove with its text, after the plugin steps.
    @Test func aFailedRemovalOfTheFolderRejectsRemove() async throws {
        let h = try Harness()
        defer { h.finish() }
        _ = try await h.run(.install).get()
        let locked = h.skillsFolder + "/skills"
        #expect(chmod(locked, 0o500) == 0)
        defer { chmod(locked, 0o700) }
        let result = await h.run(.uninstall)
        guard case .failure(.folder(let failure)) = result else {
            Issue.record("no refusal: \(result)")
            return
        }
        #expect(result.failure?.message == failure.message)
        #expect(failure.message.contains("Permission denied"))
        #expect(
            Array(h.writes.suffix(2)) == [
                "plugin uninstall \(pluginID)\(scope)",
                "plugin marketplace remove bifrost-skills\(scope)",
            ])
        #expect(fileExists(h.skillsFolder))
    }

    // The place of another program's marketplace loses its unsafe characters (cleanText) in the
    // refusal and in the status: a bidi control, a line separator and a soft hyphen go. The case
    // keeps the place as the list gave it.
    @Test func theForeignPlaceLosesItsHiddenCharacters() async throws {
        let place = "/elsewhere/\u{202E}sk\u{2028}il\u{AD}ls"
        let runs = PluginRuns(
            markets: #"[{"name":"bifrost-skills","source":"directory","path":"\#(place)"}]"#,
            installed: true)
        let h = try Harness(pluginRunner: runs)
        defer { h.finish() }
        let result = await h.run(.install)
        #expect(result == .failure(.foreignMarketplace(name: "bifrost-skills", place: place)))
        #expect(result.failure?.message == foreignText("/elsewhere/skills"))
        #expect(await h.control.status().error == foreignText("/elsewhere/skills"))
        #expect(runs.writes.isEmpty)
    }

    @Test func withNoClaudeEachActionRefusesAndTheStatusSaysWhy() async throws {
        let h = try Harness(claude: false)
        defer { h.finish() }
        for action in [LiveAction.install, .enable, .disable, .uninstall] {
            let result = await h.run(action)
            #expect(result == .failure(.claudeNotFound))
            #expect(result.failure?.message == "claude was not found.")
        }
        #expect(!fileExists(h.skillsFolder))
        let status = await h.control.status()
        #expect(status.plugin == .unknown)
        #expect(status.error == "claude was not found.")
    }

    // MARK: - The status

    // The skills come from the skills folder of the app, also with no plugin.
    @Test func theStatusWithNoPluginListsTheSkillsOfTheApp() async throws {
        let h = try Harness()
        defer { h.finish() }
        let status = await h.control.status()
        #expect(
            status
                == SkillsStatus(
                    plugin: .notInstalled, folderCurrent: false,
                    skills: try await SkillsList.list(h.source), error: nil))
        #expect(!status.skills.isEmpty)
    }

    // A failed list makes the state unknown. A failed read of the skills gives no skills, and its
    // text comes after the text of the list.
    @Test func theStatusGivesTheTextsOfAFailedListAndAFailedSkillsRead() async throws {
        let h = try Harness(source: missingSource)
        defer { h.finish() }
        try h.write("fake-plugins-fail", "")
        let status = await h.control.status()
        #expect(status.plugin == .unknown)
        #expect(status.skills.isEmpty)
        let list = PluginFailure.unreadableList(
            .plugin, end: .exited(1), stderr: "fake claude: the plugin list failed")
        let skills = missingSource.appending(path: "skills").path(percentEncoded: false)
        #expect(
            status.error
                == "\(list.message) Bifrost couldn't read its skills. Cannot read \(skills): "
                + "No such file or directory.")
    }

    // Only an installed plugin shows the marketplace of another program in the status.
    @Test func theStatusShowsAForeignMarketplaceOnlyWithAnInstalledPlugin() async throws {
        let h = try Harness()
        defer { h.finish() }
        try h.foreignMarketplace(path: "/elsewhere/skills")
        #expect(await h.control.status().error == foreignText("/elsewhere/skills"))
        try h.state(plugin: nil, market: "/elsewhere/skills")
        #expect(await h.control.status().error == nil)
        try h.installPlugin(enabled: true)
        #expect(await h.control.status().error == nil)
    }

    // folderCurrent needs a current folder, and a plugin that reads it (or a list with no
    // folder).
    @Test func folderCurrentNeedsThePluginToReadTheSkillsFolder() async throws {
        let h = try Harness()
        defer { h.finish() }
        try await FolderSync.syncSkills(source: h.source, dest: h.paths.skillsFolder)
        try h.state(plugin: true, readFrom: h.folder.appending("other"), market: h.skillsFolder)
        #expect(!(await h.control.status().folderCurrent))
        try h.installPlugin(enabled: true)
        #expect(await h.control.status().folderCurrent)
        try h.write(
            "fake-plugins.json",
            #"{"plugins":[{"id":"\#(pluginID)","enabled":true,"scope":"user"}],"marketplaces":[]}"#)
        #expect(await h.control.status().folderCurrent)
    }

    // MARK: - The lock

    @Test func anActionDuringAnotherChangeIsBusy() async throws {
        let h = try Harness()
        defer { h.finish() }
        let gate = TestGate()
        defer { gate.openAll() }
        let other = Task { [lock = h.lock] in try await lock.run { await gate.pass() } }
        await gate.waitUntilHolding()
        for action in [LiveAction.install, .uninstall] {
            #expect(await h.run(action) == .failure(.busy))
        }
        #expect(h.calls.isEmpty)
        #expect(!fileExists(h.skillsFolder))
        gate.open()
        try await other.value
    }

    // An action that comes during the start waits for it, then runs.
    @Test func anActionDuringTheStartWaitsForIt() async throws {
        let h = try Harness()
        defer { h.finish() }
        try h.installPlugin(enabled: false)
        h.control.start()
        let status = try await h.run(.enable).get()
        #expect(status.plugin == .enabled)
        #expect(h.calls.prefix(2) == ["plugin marketplace list --json", "plugin list --json"])
    }

    // After its first plugin write, an action runs to its end: a cancel of the caller while the
    // marketplace add runs still installs the plugin and turns it on.
    @Test func aCancelAfterTheMarketplaceAddStillInstallsAndTurnsOn() async throws {
        let runs = PluginRuns(hold: { $0.contains("add") })
        defer { runs.gate.openAll() }
        let h = try Harness(pluginRunner: runs)
        defer { h.finish() }
        let job = Task { await h.run(.install) }
        await runs.gate.waitUntilHolding()
        job.cancel()
        runs.gate.open()
        let status = try await job.value.get()
        #expect(status.plugin == .enabled)
        #expect(
            runs.writes == [
                "plugin marketplace add \(h.skillsFolder)\(scope)",
                "plugin install \(pluginID)\(scope)", "plugin enable \(pluginID)\(scope)",
            ])
    }

    // The stop of the app at the same point ends the action at its next step. The write that runs
    // still runs to its end.
    @Test func aStopAfterTheMarketplaceAddEndsTheActionAtItsNextStep() async throws {
        let runs = PluginRuns(hold: { $0.contains("add") })
        defer { runs.gate.openAll() }
        let h = try Harness(pluginRunner: runs)
        defer { h.finish() }
        let job = Task { await h.run(.install) }
        await runs.gate.waitUntilHolding()
        h.control.stop()
        runs.gate.open()
        #expect(await job.value == .failure(.cancelled))
        #expect(runs.writes == ["plugin marketplace add \(h.skillsFolder)\(scope)"])
    }

    // A stop while the first list read runs ends the action before any change.
    @Test func aStopBetweenTwoStepsChangesNothing() async throws {
        let runs = PluginRuns(hold: { $0 == ["plugin", "marketplace", "list", "--json"] })
        defer { runs.gate.openAll() }
        let h = try Harness(pluginRunner: runs)
        defer { h.finish() }
        let job = Task { await h.run(.install) }
        await runs.gate.waitUntilHolding()
        h.control.stop()
        runs.gate.open()
        #expect(await job.value == .failure(.cancelled))
        #expect(runs.writes.isEmpty)
        #expect(!fileExists(h.skillsFolder))
    }

    // A cancel before the first write ends the action, and nothing changes.
    @Test func aCancelledActionChangesNothing() async throws {
        let h = try Harness()
        defer { h.finish() }
        let install = Task { await h.run(.install) }
        install.cancel()
        #expect(await install.value == .failure(.cancelled))
        #expect(h.writes.isEmpty)
        #expect(!fileExists(h.skillsFolder))
    }
}

extension Result {
    // The error of a failure, or nil.
    fileprivate var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
