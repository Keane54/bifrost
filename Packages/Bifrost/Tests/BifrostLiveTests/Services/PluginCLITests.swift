import BifrostFoundation
import BifrostLive
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

// The claude plugin commands of Live details and of the skills. The fake runner runs no program,
// so no test installs, turns on, turns off or removes a real plugin. The clock of the time limit
// is a ManualClock.

private let liveID = "bifrost-live@bifrost-local"
private let scope = ["--scope", "user", "--json"]
private let pluginList =
    #"[{"id":"bifrost-live@bifrost-local","version":"1.0.0","scope":"user","enabled":true,"#
    + #""installPath":"","readFromFolder":"/h/.bifrost/mod"}]"#
private let okLine = #"{"outcome":"ok"}"#

// A read command: a 30 s limit and SIGKILL, as each read of claude.
private func read(_ arguments: [String]) -> Command {
    Command(
        FakeRunner.claudePath, arguments, environment: [:], timeout: .seconds(30),
        killSignal: .kill)
}

// A write command: a 30 s limit and SIGTERM, then SIGKILL after the grace of the runner.
private func write(_ arguments: [String]) -> Command {
    Command(
        FakeRunner.claudePath, arguments, environment: [:], timeout: .seconds(30),
        killSignal: .terminate)
}

private func cli(
    _ runs: FakeRunner, ids: PluginIDs = .live, clock: any Clock<Duration> = ManualClock(),
    log: any LiveLog = LiveLogRecorder()
) -> PluginCLI {
    PluginCLI(claude: runs.claude(), ids: ids, clock: clock, log: log)
}

@Suite("The claude plugin commands")
struct PluginCLITests {
    // MARK: - The IDs and the limits

    @Test func theIDsAndTheLimitsAreTheValuesOfThePlugins() {
        #expect(PluginIDs.live.plugin == "bifrost-live@bifrost-local")
        #expect(PluginIDs.live.marketplace == "bifrost-local")
        #expect(PluginIDs.skills.plugin == "bifrost@bifrost-skills")
        #expect(PluginIDs.skills.marketplace == "bifrost-skills")
        #expect(PluginCLI.timeout == .seconds(30))
        #expect(PluginCLI.grace == .seconds(10))
    }

    // MARK: - The lists

    @Test func pluginReadsThePluginListAndFindsThePlugin() async throws {
        let runs = FakeRunner(ExecResult(.exited(0), stdout: pluginList))
        let entry = try await cli(runs).plugin()
        #expect(entry == PluginEntry(enabled: true, folder: "/h/.bifrost/mod", errors: []))
        #expect(runs.commands == [read(["plugin", "list", "--json"])])
    }

    @Test func pluginGivesNilWhenTheListHasNoPlugin() async throws {
        let empty = FakeRunner(ExecResult(.exited(0), stdout: "[]"))
        #expect(try await cli(empty).plugin() == nil)
        let other = FakeRunner(
            ExecResult(.exited(0), stdout: #"[{"id":"x@y","enabled":true}]"#))
        #expect(try await cli(other).plugin() == nil)
    }

    @Test func pluginSkipsTextBeforeTheList() async throws {
        let runs = FakeRunner(ExecResult(.exited(0), stdout: "Update available\n\(pluginList)"))
        #expect(try await cli(runs).plugin()?.enabled == true)
    }

    @Test func aListThatFailsNamesItsList() async {
        let runs = FakeRunner(ExecResult(.exited(1), stderr: "boom"))
        await #expect(
            throws: PluginFailure.unreadableList(.plugin, end: .exited(1), stderr: "boom")
        ) {
            try await cli(runs).plugin()
        }
        await #expect(
            throws: PluginFailure.unreadableList(.marketplace, end: .exited(1), stderr: "boom")
        ) {
            try await cli(runs).marketplace()
        }
    }

    @Test func marketplaceReadsTheMarketplaceListAndFindsBifrostLocal() async throws {
        let runs = FakeRunner(
            ExecResult(
                .exited(0),
                stdout: #"[{"name":"bifrost-local","source":"directory","path":"/h/m"}]"#))
        let entry = try await cli(runs).marketplace()
        #expect(entry == MarketplaceEntry(source: "directory", path: "/h/m"))
        #expect(runs.commands == [read(["plugin", "marketplace", "list", "--json"])])
    }

    // MARK: - The write commands

    @Test(arguments: [
        ("addMarketplace", ["plugin", "marketplace", "add", "/h/.bifrost/mod"]),
        ("install", ["plugin", "install", liveID]),
        ("enable", ["plugin", "enable", liveID]),
        ("disable", ["plugin", "disable", liveID]),
        ("uninstall", ["plugin", "uninstall", liveID]),
        ("removeMarketplace", ["plugin", "marketplace", "remove", "bifrost-local"]),
    ])
    func eachWriteCommandHasItsArgumentsAndSIGTERMAtTheLimit(
        _ command: String, _ arguments: [String]
    ) async throws {
        let runs = FakeRunner(ExecResult(.exited(0), stdout: okLine))
        try await run(command, on: cli(runs))
        #expect(runs.commands == [write(arguments + scope)])
    }

    // Run the write command with this name.
    private func run(_ command: String, on cli: PluginCLI) async throws(PluginFailure) {
        switch command {
        case "addMarketplace":
            try await cli.addMarketplace(
                URL(filePath: "/h/.bifrost/mod", directoryHint: .isDirectory))
        case "install": try await cli.install()
        case "enable": try await cli.enable()
        case "disable": try await cli.disable()
        case "uninstall": try await cli.uninstall()
        default: try await cli.removeMarketplace()
        }
    }

    @Test func theSkillsIDsGoToTheirCommands() async throws {
        let runs = FakeRunner(ExecResult(.exited(0), stdout: okLine))
        let skills = cli(runs, ids: .skills)
        try await skills.install()
        try await skills.removeMarketplace()
        #expect(
            runs.commands.map(\.arguments) == [
                ["plugin", "install", "bifrost@bifrost-skills"] + scope,
                ["plugin", "marketplace", "remove", "bifrost-skills"] + scope,
            ])
    }

    @Test func theSkillsListsFindTheSkillsPluginAndMarketplace() async throws {
        let plugins = FakeRunner(
            ExecResult(
                .exited(0),
                stdout: #"[{"id":"bifrost-live@bifrost-local","enabled":true},"#
                    + #"{"id":"bifrost@bifrost-skills"}]"#))
        #expect(
            try await cli(plugins, ids: .skills).plugin()
                == PluginEntry(enabled: false, folder: nil, errors: []))
        let marketplaces = FakeRunner(
            ExecResult(
                .exited(0),
                stdout: #"[{"name":"bifrost-local","source":"directory","path":"/a"},"#
                    + #"{"name":"bifrost-skills","source":"directory","path":"/b"}]"#))
        #expect(
            try await cli(marketplaces, ids: .skills).marketplace()
                == MarketplaceEntry(source: "directory", path: "/b"))
    }

    @Test func enableAndDisablePassForAPluginInTheGoalState() async throws {
        let line =
            #"{"command":"enable","outcome":"failed","message":"Plugin is already enabled","#
            + #""failureCode":"already_in_goal_state","alreadyInGoalState":true}"#
        let runs = FakeRunner(ExecResult(.exited(1), stdout: line))
        try await cli(runs).enable()
        try await cli(runs).disable()
    }

    @Test func aFailedResultRejectsWithItsMessage() async {
        let line = #"{"command":"install","outcome":"failed","message":"Plugin not found"}"#
        let runs = FakeRunner(ExecResult(.exited(1), stdout: line))
        await #expect(throws: PluginFailure.refused("Plugin not found")) {
            try await cli(runs).install()
        }
    }

    @Test func addMarketplacePassesTheFolderWithNoSlashAtTheEnd() async throws {
        let runs = FakeRunner(ExecResult(.exited(0), stdout: okLine))
        try await cli(runs).addMarketplace(URL(filePath: "/h/my mod/", directoryHint: .isDirectory))
        let arguments = runs.commands.map(\.arguments)
        #expect(arguments == [["plugin", "marketplace", "add", "/h/my mod"] + scope])
    }

    @Test(arguments: [
        URL(string: "mod")!, URL(filePath: "mod"), URL(string: "https://example.invalid/mod")!,
        URL(filePath: "/h/a\nb"), URL(filePath: "/h/a\rb"), URL(filePath: "/h/a\r\nb"),
    ])
    func addMarketplaceRefusesAFolderThatIsNotAnAbsolutePathWithNoLineBreak(_ folder: URL) async {
        let runs = FakeRunner(ExecResult(.exited(0), stdout: okLine))
        await #expect(throws: PluginFailure.badFolder) {
            try await cli(runs).addMarketplace(folder)
        }
        #expect(runs.commands.isEmpty)
    }

    @Test func aValueThatStartsWithADashNeverBecomesAnOption() async {
        let runs = FakeRunner(ExecResult(.exited(0), stdout: okLine))
        let bad = cli(runs, ids: PluginIDs(plugin: "--help", marketplace: "-x"))
        await #expect(throws: PluginFailure.optionLike("--help")) { try await bad.install() }
        await #expect(throws: PluginFailure.optionLike("--help")) { try await bad.enable() }
        await #expect(throws: PluginFailure.optionLike("--help")) { try await bad.disable() }
        await #expect(throws: PluginFailure.optionLike("--help")) { try await bad.uninstall() }
        await #expect(throws: PluginFailure.optionLike("-x")) { try await bad.removeMarketplace() }
        #expect(runs.commands.isEmpty)
    }

    // MARK: - The time limit

    @Test func aCommandOrAListThatTheLimitStoppedRejectsWithTheTimeoutText() async {
        let runs = FakeRunner(ExecResult(.timedOut, stdout: okLine))
        await #expect(throws: PluginFailure.timedOut) { try await cli(runs).install() }
        await #expect(throws: PluginFailure.timedOut) { try await cli(runs).plugin() }
        await #expect(throws: PluginFailure.timedOut) { try await cli(runs).marketplace() }
    }

    @Test func aCancelOfTheCallerStopsAList() async {
        let runs = FakeRunner(ExecResult(.exited(0), stdout: pluginList))
        runs.hold()
        defer { runs.release() }
        let plugins = cli(runs)
        let read = Task { try await plugins.plugin() }
        await runs.held.wait(for: "the held list")
        read.cancel()
        await #expect(throws: PluginFailure.cancelled) { try await read.value }
    }

    @MainActor
    @Test func aCancelOfTheCallerNeverEndsAWriteAndTheLockStaysHeld() async throws {
        let runs = FakeRunner(ExecResult(.exited(0), stdout: okLine))
        runs.hold()
        defer { runs.release() }
        let plugins = cli(runs)
        let lock = SerialLock()
        let install = Task {
            try await lock.run { () throws(PluginFailure) in try await plugins.install() }
        }
        await runs.held.wait(for: "the held install")
        install.cancel()
        // The write still runs, so the lock stays held.
        await #expect(throws: PluginFailure.busy) { try await lock.run {} }
        runs.release()
        // claude ended the write, so the caller gets its result and not a cancel.
        try await install.value
        #expect(runs.commands.count == 1)
        #expect(try await lock.run { "next" } == "next")
    }

    @MainActor
    @Test func aWriteCommandThatHangsRejectsAfter40sAndFreesTheLock() async throws {
        let runs = FakeRunner(ExecResult(.exited(0), stdout: okLine))
        runs.hold()
        let clock = ManualClock()
        let log = LiveLogRecorder()
        let plugins = cli(runs, clock: clock, log: log)
        let lock = SerialLock()
        let disable = Task {
            try await lock.run { () throws(PluginFailure) in try await plugins.disable() }
        }
        await runs.held.wait(for: "the held disable")
        await clock.waitForSleepers(1)

        clock.advance(by: .seconds(40) - .milliseconds(1))
        // The limit still waits, so the command still holds the lock.
        #expect(clock.sleeperCount == 1)
        await #expect(throws: PluginFailure.busy) { try await lock.run {} }

        clock.advance(by: .milliseconds(1))
        await #expect(throws: PluginFailure.timedOut) { try await disable.value }
        #expect(try await lock.run { "next" } == "next")
        #expect(log.events == [.writeHung(command: "disable")])
    }

    // A write that claude ends by itself 30 s or more after its start gets a log line, also with
    // code 0. A quick write gets none.
    @Test func aWriteThatEndsAfter30sIsLoggedAlsoWithCode0() async throws {
        let runs = FakeRunner(ExecResult(.exited(0), stdout: okLine))
        let clock = ManualClock()
        let log = LiveLogRecorder()
        let plugins = cli(runs, clock: clock, log: log)
        try await plugins.enable()
        #expect(log.events.isEmpty)
        runs.hold()
        let disable = Task { try await plugins.disable() }
        await runs.held.wait(for: "the held disable")
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(31))
        runs.release()
        try await disable.value
        #expect(log.events == [.writeEndedLate(command: "disable", after: .seconds(31))])
    }

    // MARK: - The test home

    @Test func aTestHomeRunsThePluginCommandsWithItsHome() async throws {
        let base = [
            "HOME": "/Users/someone", "PATH": "/usr/bin", "CLAUDE_CONFIG_DIR": "/elsewhere",
            "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli",
        ]
        let home = URL(filePath: "/nonexistent-bifrost-test/home", directoryHint: .isDirectory)
        let runs = FakeRunner { command in
            ExecResult(.exited(0), stdout: command.arguments.contains("list") ? "[]" : okLine)
        }
        let plugins = PluginCLI(
            claude: runs.claude(environment: PluginCLI.environment(base, testHome: home)),
            ids: .live, clock: ManualClock())
        _ = try await plugins.plugin()
        _ = try await plugins.marketplace()
        try await plugins.install()
        try await plugins.addMarketplace(home.appending(path: ".bifrost/mod"))
        let environments = runs.commands.map { $0.environment ?? [:] }
        #expect(environments.count == 4)
        for environment in environments {
            #expect(environment["HOME"] == "/nonexistent-bifrost-test/home")
            #expect(environment["CLAUDE_CONFIG_DIR"] == "/nonexistent-bifrost-test/home/.claude")
            #expect(environment["PATH"] == "/usr/bin")
            // The child env rule still removes the variables of a Claude Code session.
            #expect(environment["CLAUDECODE"] == nil)
            #expect(!environment.keys.contains { $0.hasPrefix("CLAUDE_CODE_") })
        }
    }

    @Test func withNoTestHomeThePluginEnvironmentStaysAsItIs() {
        let base = ["HOME": "/Users/someone", "CLAUDE_CONFIG_DIR": "/elsewhere"]
        #expect(PluginCLI.environment(base, testHome: nil) == base)
    }
}
