import BifrostFoundation
import BifrostSessions
import Foundation

// The IDs of one plugin of Bifrost and of the marketplace that holds it.
package struct PluginIDs: Sendable, Equatable {
    // The ID of the plugin, "<name>@<marketplace>".
    package let plugin: String
    package let marketplace: String

    // The Live details mod.
    package static let live = PluginIDs(
        plugin: "bifrost-live@bifrost-local", marketplace: "bifrost-local")
    // The Bifrost skills.
    package static let skills = PluginIDs(
        plugin: "bifrost@bifrost-skills", marketplace: "bifrost-skills")

    package init(plugin: String, marketplace: String) {
        self.plugin = plugin
        self.marketplace = marketplace
    }
}

// The claude plugin commands for one plugin of Bifrost (docs/behaviour/live.md, The plugin
// commands). Two list commands read the state, and the write commands change the plugin files
// and the settings of Claude Code. The commands run off the actor of the caller.
//
// Each command has a time limit of 30 s. A command that the limit stopped rejects with timedOut,
// because its output is not complete.
//
// A list command gets SIGKILL at the limit, and a cancel of the caller stops it at once.
//
// A write command gets SIGTERM at the limit, because a SIGKILL can leave a change half done. A
// write command that still runs at the end of the grace of the runner
// (Command.defaultTerminateGrace, 5 s) gets SIGKILL. A write that ends 30 s or more after its
// start gets a log line, also when it ends with code 0. A write command runs in a task of its own,
// so a cancel of the caller (also at the quit of the app) never stops it: the caller waits until
// the process has ended, and the lock of the changes stays held until then. Thus no old command
// changes the settings after the lock is free. Only one more end is possible: when the result
// has not come 10 s after the SIGTERM (grace), the command rejects with timedOut and the run is
// cancelled. Thus a hung command frees the lock after 40 s at the latest. A write that still runs
// when the app quits gets no SIGTERM and no SIGKILL from Bifrost: it runs on to its own end
// (docs/behaviour/live.md, Time limits).
//
// Only fixed values go to claude as arguments: the IDs of PluginIDs and the absolute path of the
// marketplace folder. A value that starts with "-" never goes to claude, because claude would
// read it as an option.
package struct PluginCLI: Sendable {
    package static let timeout = Duration.seconds(30)
    package static let grace = Duration.seconds(10)
    private static let scope = ["--scope", "user", "--json"]

    private let claude: ClaudeRunner
    // The IDs of the plugin and of its marketplace.
    let ids: PluginIDs
    private let clock: any Clock<Duration>
    private let log: any LiveLog

    // claude: the runner of the plugin commands, with the env of environment(_:testHome:).
    // clock: the clock of the limit of 40 s and of the time of a write. The app gives a
    // SuspendingClock, so the time while the Mac sleeps does not count for the limit: a command
    // that the sleep of the Mac stopped does not lose its result at the wake. A test gives a
    // manual clock. log: gets the ends of the time limit of a write.
    package init(
        claude: ClaudeRunner, ids: PluginIDs, clock: any Clock<Duration>,
        log: any LiveLog = SystemLiveLog()
    ) {
        self.claude = claude
        self.ids = ids
        self.clock = clock
        self.log = log
    }

    // The base env of the runner of the plugin commands. In a test home, each plugin command
    // gets HOME and CLAUDE_CONFIG_DIR of the test home, so it changes only files under the test
    // home. Without a test home, the env stays as it is. The other claude calls keep the env of
    // the app, so the session list stays the real one.
    package static func environment(
        _ base: [String: String], testHome: URL?
    ) -> [String: String] {
        guard let testHome else { return base }
        var environment = base
        environment["HOME"] = testHome.path
        environment["CLAUDE_CONFIG_DIR"] =
            testHome.appendingPathComponent(".claude", isDirectory: true).path
        return environment
    }

    // MARK: - The lists

    // The entry of the plugin in the plugin list, or nil when the list does not have it.
    @concurrent package func plugin() async throws(PluginFailure) -> PluginEntry? {
        let result = try await read(["plugin", "list", "--json"])
        let items = try PluginText.list(result, name: .plugin)
        return items.first { $0["id"] == .string(ids.plugin) }.map(PluginEntry.init)
    }

    // The entry of the marketplace in the marketplace list, or nil when the list does not have
    // it.
    @concurrent package func marketplace() async throws(PluginFailure) -> MarketplaceEntry? {
        let result = try await read(["plugin", "marketplace", "list", "--json"])
        let items = try PluginText.list(result, name: .marketplace)
        return items.first { $0["name"] == .string(ids.marketplace) }.map(MarketplaceEntry.init)
    }

    // MARK: - The write commands

    // Add the folder as the marketplace. The folder must be a file URL with no base URL (a URL
    // with a base is relative, also when its path is absolute), an absolute path and no line
    // break. The path has no "/" at the end.
    @concurrent package func addMarketplace(_ folder: URL) async throws(PluginFailure) {
        let path = folder.path
        let lineBreak = path.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
        guard folder.isFileURL, folder.baseURL == nil, path.hasPrefix("/"), !lineBreak else {
            throw .badFolder
        }
        try await write(["marketplace", "add"], path)
    }

    @concurrent package func install() async throws(PluginFailure) {
        try await write(["install"], ids.plugin)
    }

    @concurrent package func enable() async throws(PluginFailure) {
        try await write(["enable"], ids.plugin)
    }

    @concurrent package func disable() async throws(PluginFailure) {
        try await write(["disable"], ids.plugin)
    }

    @concurrent package func uninstall() async throws(PluginFailure) {
        try await write(["uninstall"], ids.plugin)
    }

    @concurrent package func removeMarketplace() async throws(PluginFailure) {
        try await write(["marketplace", "remove"], ids.marketplace)
    }

    // MARK: - The runs

    // Run a list command. A run that the limit or a cancel stopped gives no output to read.
    private func read(_ arguments: [String]) async throws(PluginFailure) -> ExecResult {
        let result = await claude.run(arguments, timeout: Self.timeout)
        try Self.checkEnd(result)
        return result
    }

    // Run "claude plugin <verb> <value> --scope user --json" and check its result line. The
    // two ends of the time limit, and an end at 30 s or more, get a log line with fixed words.
    private func write(_ verb: [String], _ value: String) async throws(PluginFailure) {
        guard !value.hasPrefix("-") else { throw .optionLike(value) }
        let arguments = ["plugin"] + verb + [value] + Self.scope
        let command = verb.joined(separator: " ")
        var ended: ExecResult?
        let elapsed = await clock.measure { ended = await runToEnd(arguments) }
        guard let result = ended else {
            log.record(.writeHung(command: command))
            throw .timedOut
        }
        if result.end == .timedOut {
            log.record(.writeTimedOut(command: command))
        } else if elapsed >= Self.timeout {
            log.record(.writeEndedLate(command: command, after: elapsed))
        }
        try Self.checkEnd(result)
        try PluginText.check(result)
    }

    // The end of a run that the limit or a cancel stopped.
    private static func checkEnd(_ result: ExecResult) throws(PluginFailure) {
        switch result.end {
        case .timedOut: throw .timedOut
        case .cancelled: throw .cancelled
        default: break
        }
    }

    // Run a write command to its end, with SIGTERM at the limit. The run is a task of its own,
    // so a cancel of the caller does not reach it, and the caller waits for the end also after a
    // cancel. The result is nil when the run has not ended at the limit plus the grace. Then
    // the limit cancels the run, and the runner stops it at once.
    private func runToEnd(_ arguments: [String]) async -> ExecResult? {
        let (claude, clock) = (self.claude, self.clock)
        let run = Task {
            await claude.run(arguments, timeout: Self.timeout, killSignal: .terminate)
        }
        let limit = Task {
            do {
                try await clock.sleep(for: Self.timeout + Self.grace)
            } catch {
                return false
            }
            run.cancel()
            return true
        }
        // A wait for the value of a task does not end at a cancel of the caller.
        let result = await run.value
        limit.cancel()
        // Only the limit cancels the run. A run that ended before the limit keeps its result.
        let stoppedByLimit = await limit.value && result.end == .cancelled
        return stoppedByLimit ? nil : result
    }
}
