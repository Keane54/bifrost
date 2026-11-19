import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostFoundation
@testable import BifrostSessions

private let ok = ExecResult(.exited(0))

// A runner that waits until the task is cancelled, or 10 s. It tells if the task was cancelled.
private struct CancelProbe: CommandRunner {
    func run(_ command: Command) async -> ExecResult {
        try? await Task.sleep(for: .seconds(10))
        return Task.isCancelled ? ExecResult(.cancelled) : ok
    }
}

// The runs of claude: the program, the env, the time limit and the output.

@Suite("running Claude", .testTimeLimit, .tags(.realProcess))
struct ClaudeRunnerTests {
    @Test("the Claude run uses the base environment without the removed variables")
    func childEnvironment() async {
        let runner = FakeRunner(ok)
        let env = ["CLAUDECODE": "1", "PATH": "/login"]
        _ = await ClaudeRunner(path: "/c", baseEnvironment: env, runner: runner).run(["--version"])
        #expect(runner.commands.first?.environment == ["PATH": "/login"])
    }

    @Test
    func argumentsAndFolder() async {
        let runner = FakeRunner(ok)
        let claude = ClaudeRunner(path: "/bin/claude", baseEnvironment: [:], runner: runner)
        _ = await claude.run(["agents", "--json"], directory: "/tmp")
        let command = runner.commands.first
        #expect(
            command?.executable == "/bin/claude" && command?.arguments == ["agents", "--json"]
                && command?.directory == "/tmp")
    }

    // claude adds piped stdin to the prompt. So a claude run never gets input. The Swift run has
    // no input parameter, so a caller cannot pass one.
    @Test("the Claude run never passes input")
    func noInput() async {
        let runner = FakeRunner(ok)
        let claude = ClaudeRunner(path: "/bin/claude", baseEnvironment: [:], runner: runner)
        _ = await claude.run(["-p"], directory: "/w")
        #expect(runner.commands.first?.input == nil)
        #expect(runner.commands.first?.directory == "/w")
    }

    // A claude run stops with SIGKILL by default. A run that a SIGKILL can leave half done gives
    // SIGTERM.
    @Test func theKillSignalReachesTheCommand() async {
        let runner = FakeRunner(ok)
        let claude = ClaudeRunner(path: "/bin/claude", baseEnvironment: [:], runner: runner)
        _ = await claude.run(["stop", "abcd1234"])
        _ = await claude.run(["rm", "abcd1234"], timeout: .seconds(600), killSignal: .terminate)
        _ = await claude.run(
            ["rm", "abcd1234"], killSignal: .terminate, terminateGrace: .seconds(30))
        _ = await claude.run(["rm", "abcd1234"], killSignal: .terminate, terminateGrace: nil)
        #expect(runner.commands.map(\.killSignal) == [.kill, .terminate, .terminate, .terminate])
        #expect(runner.commands.map(\.timeout).prefix(2) == [.seconds(10), .seconds(600)])
        #expect(
            runner.commands.map(\.terminateGrace) == [
                .seconds(5), .seconds(5), .seconds(30), nil,
            ])
    }

    // The cancel of the task of the claude run reaches the runner.
    @Test("the Claude run passes the cancel signal to the process")
    func cancel() async {
        let claude = ClaudeRunner(path: "/bin/claude", baseEnvironment: [:], runner: CancelProbe())
        let task = Task { await claude.run(["-p"]) }
        task.cancel()
        #expect(await task.value.end == .cancelled)
    }
}

// The path of claude: the PATH search of the login environment.

private let shellPath = ExecResult(.exited(0), stdout: "/Users/test/.local/bin/claude\n")
private let shellFailed = ExecResult(.exited(1))
private let testHome = URL(fileURLWithPath: "/Users/test", isDirectory: true)

// The output of the one login shell: the path of claude between the claude markers, then
// recorded output of "/usr/bin/env -0" between the env markers.
private let claudeMarker = LoginEnvironmentText.claudeMarker
private let marker = LoginEnvironmentText.marker

// env -i PATH=/login /usr/bin/env -0
private let loginPath = "PATH=/login\u{0}"

private func shellOutput(claude: String = "/Users/test/.local/bin/claude\n", _ env: String)
    -> ExecResult
{
    ExecResult(
        .exited(0),
        stdout: "banner\n\(claudeMarker)\(claude)\(claudeMarker)\(marker)\(env)\(marker)")
}

// The end of the login shell of a log event of a failed shell, or nil.
private func failedEnd(_ event: SessionsLogEvent?) -> ExecEnd? {
    guard case .loginShellFailed(let end, _)? = event else { return nil }
    return end
}

// The one login shell of the start gives the path of claude and the env of the claude runs.
@Suite("the login shell", .testTimeLimit, .tags(.realProcess))
struct LoginShellTests {
    private func load(
        _ result: ExecResult, shell: String? = "/bin/zsh", fallback: [String: String] = [:],
        isRunnable: (String) -> Bool = { _ in false },
        log: Recorder<SessionsLogEvent> = Recorder<SessionsLogEvent>()
    ) async -> (LoginShell.Result, FakeRunner) {
        let runner = FakeRunner(result)
        let loaded = await LoginShell.load(
            runner: runner, shell: shell, fallback: fallback, home: testHome,
            isRunnable: isRunnable, log: log)
        return (loaded, runner)
    }

    // One interactive login shell with a small env gives both values.
    @Test func oneLoginShellGivesThePathOfClaudeAndTheEnv() async {
        let fallback = ["CLAUDECODE": "1", "HOME": "/h", "PATH": "/fb", "USER": "u"]
        let (loaded, runner) = await load(shellOutput(loginPath), fallback: fallback)
        #expect(loaded.claudePath == "/Users/test/.local/bin/claude")
        #expect(loaded.environment == ["PATH": "/login"])
        #expect(runner.commands.count == 1)
        let command = runner.commands.first
        #expect(command?.executable == "/bin/zsh")
        #expect(command?.arguments == ["-lic", LoginEnvironmentText.script])
        #expect(command?.timeout == .seconds(5))
        #expect(command?.environment == ["HOME": "/h", "USER": "u"])
    }

    @Test func noPathWhenTheShellAndTheKnownPathsDoNotFindClaude() async {
        let (failed, _) = await load(shellFailed)
        #expect(failed.claudePath == nil)
        let (none, _) = await load(shellOutput(claude: "", loginPath))
        #expect(none.claudePath == nil)
        // An alias is not a path.
        let (alias, _) = await load(shellOutput(claude: "claude: aliased to x\n", loginPath))
        #expect(alias.claudePath == nil)
    }

    @Test func theFirstRunnableKnownPathWinsWhenTheShellGivesNoPath() async {
        let local = "/Users/test/.local/bin/claude"
        let runnable = { (path: String) in path == local || path == "/usr/local/bin/claude" }
        let (failed, _) = await load(shellFailed, isRunnable: runnable)
        #expect(failed.claudePath == local)
        let (empty, _) = await load(shellOutput(claude: "\n", loginPath), isRunnable: runnable)
        #expect(empty.claudePath == local)
    }

    // The shell gets a small env, so it can miss a claude that only the PATH of the app has.
    // That claude comes before the known paths. A relative folder of the PATH is skipped.
    @Test func aClaudeOnThePathOfTheAppComesBeforeTheKnownPaths() async {
        let app = "/app/bin/claude"
        let runnable = { (path: String) in path == app || path == "/Users/test/.local/bin/claude" }
        let fallback = ["PATH": "bin:/nowhere:/app/bin"]
        let (failed, _) = await load(shellFailed, fallback: fallback, isRunnable: runnable)
        #expect(failed.claudePath == app)
        let (empty, _) = await load(
            shellOutput(claude: "\n", loginPath), fallback: fallback, isRunnable: runnable)
        #expect(empty.claudePath == app)
        let (noPath, _) = await load(shellFailed, isRunnable: runnable)
        #expect(noPath.claudePath == "/Users/test/.local/bin/claude")
    }

    @Test func theKnownPathsAreNotCheckedWhenTheShellFindsClaude() async {
        let checked = Mutex<[String]>([])
        _ = await load(
            shellOutput(loginPath),
            isRunnable: { path in
                checked.withLock { $0.append(path) }
                return true
            })
        #expect(checked.withLock { $0 }.isEmpty)
    }

    @Test func aFailedShellGivesTheFallbackEnvAndOneLogLine() async {
        let log = Recorder<SessionsLogEvent>()
        let (loaded, _) = await load(
            ExecResult(.exited(1), stderr: "x"), shell: nil, fallback: ["PATH": "/fb"], log: log)
        #expect(loaded.environment == ["PATH": "/fb"])
        #expect(log.values.count == 1)
        #expect(failedEnd(log.values.first) == .exited(1), "\(log.values)")
    }

    @Test func aShellTimeoutIsLogged() async {
        let log = Recorder<SessionsLogEvent>()
        _ = await load(ExecResult(.timedOut), shell: nil, fallback: ["PATH": "/fb"], log: log)
        #expect(log.values.count == 1)
        #expect(failedEnd(log.values.first) == .timedOut, "\(log.values)")
    }

    @Test func outputWithNoEnvMarkersFallsBackAndIsLogged() async {
        let log = Recorder<SessionsLogEvent>()
        let (loaded, _) = await load(
            ExecResult(.exited(0), stdout: "banner only"), shell: nil, fallback: ["PATH": "/fb"],
            log: log)
        #expect(loaded.environment == ["PATH": "/fb"])
        #expect(log.values.count == 1)
        #expect(failedEnd(log.values.first) == .exited(0), "\(log.values)")
    }

    @Test func aGoodEnvLogsNothing() async {
        let log = Recorder<SessionsLogEvent>()
        let (loaded, _) = await load(shellOutput(loginPath), shell: nil, log: log)
        #expect(loaded.environment == ["PATH": "/login"])
        #expect(log.values.isEmpty)
    }

    // With no shell, the login shell is the SHELL of the fallback, then /bin/zsh.
    @Test func theShellComesFromTheFallbackThenZsh() async {
        let (_, bash) = await load(
            shellOutput(loginPath), shell: nil, fallback: ["SHELL": "/bin/bash"])
        let (_, zsh) = await load(shellOutput(loginPath), shell: nil)
        #expect(bash.commands.map(\.executable) == ["/bin/bash"])
        #expect(zsh.commands.map(\.executable) == ["/bin/zsh"])
    }

    // The script runs in a plain shell (not a login shell), with a small env. The parser reads
    // the env of that shell, and the path of a program on its PATH.
    @Test func theScriptGivesTheEnvAndThePathOfClaude() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let folder = temp.url
        let claude = folder.appendingPathComponent("claude")
        try Data("#!/bin/sh\n".utf8).write(to: claude)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: claude.path)
        let command = Command(
            "/bin/sh", ["-c", LoginEnvironmentText.script],
            environment: ["PATH": "\(folder.path):/usr/bin:/bin", "X": "a=b", "NL": "one\ntwo"],
            // Wide, so a slow start on a test host under load does not count.
            timeout: .seconds(60))
        let result = await ProcessRunner().run(command)
        let env = LoginEnvironmentText.parse(result.stdout)
        #expect(env?["PATH"] == "\(folder.path):/usr/bin:/bin")
        #expect(env?["X"] == "a=b")
        #expect(env?["NL"] == "one\ntwo")
        #expect(LoginEnvironmentText.claudePath(result.stdout) == claude.path)
    }

    // The PATH search is the one program lookup (ProgramLookupTests), so the path
    // of claude never depends on the current folder. No PATH gives no path.
    @Test func findOnPathUsesTheProgramLookup() throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let folder = temp.url
        let claude = folder.appendingPathComponent("claude")
        try Data("#!/bin/sh\n".utf8).write(to: claude)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: claude.path)
        let path = "rel:/nowhere:\(folder.path)"
        #expect(ClaudeLocator.findOnPath("claude", path: path) == claude.path)
        #expect(ClaudeLocator.findOnPath("claude", path: "/nowhere") == nil)
        #expect(ClaudeLocator.findOnPath("claude", path: nil) == nil)
    }
}

// The list of the agents: "claude agents --json" and its parse.

@Suite("agent listing", .testTimeLimit, .tags(.realProcess))
struct ListAgentsTests {
    @Test("agent listing adds --all only when asked")
    func addsAll() async {
        let runner = FakeRunner(ExecResult(.exited(0), stdout: "[]"))
        let claude = ClaudeRunner(path: "/bin/claude", baseEnvironment: [:], runner: runner)
        _ = await listAgents(claude, all: false)
        _ = await listAgents(claude, all: true)
        #expect(
            runner.commands.map(\.arguments) == [
                ["agents", "--json"],
                ["agents", "--json", "--all"],
            ])
    }

    @Test
    func stderrIsTheDetailOfTheError() async {
        let runner = FakeRunner(ExecResult(.exited(1), stderr: "boom"))
        let claude = ClaudeRunner(path: "/bin/claude", baseEnvironment: [:], runner: runner)
        #expect(await listAgents(claude, all: false) == .failed(.commandFailed(detail: "boom")))
    }

    // "claude agents --json" has the default time limit of 10 s.
    @Test func listAgentsWaitsAtMost10Seconds() async {
        let runner = FakeRunner(ExecResult(.exited(0), stdout: "[]"))
        let claude = ClaudeRunner(path: "/bin/claude", baseEnvironment: [:], runner: runner)
        _ = await listAgents(claude, all: false)
        #expect(runner.commands.map(\.timeout) == [.seconds(10)])
    }

    // With no stderr, the detail of the error names the exit code.
    @Test func noStderrGivesTheExitCode() async {
        let runner = FakeRunner(ExecResult(.exited(2), stderr: " \n"))
        let claude = ClaudeRunner(path: "/bin/claude", baseEnvironment: [:], runner: runner)
        #expect(
            await listAgents(claude, all: false)
                == .failed(.commandFailed(detail: "claude stopped with code 2.")))
    }

    // With no claude, the lists fail with "claude not found" and run nothing.
    @Test func noClaudeGivesClaudeNotFound() async throws {
        let runner = FakeRunner(ExecResult(.exited(0), stdout: "[]"))
        let deps = RegistrySystemDeps(
            claude: nil, runner: runner, skipRoots: [], saver: .noFile)
        #expect(try await deps.listActive() == .failed(.claudeNotFound))
        #expect(try await deps.listAll() == .failed(.claudeNotFound))
        #expect(runner.commands.isEmpty)
    }

    // Each claude run of the registry gets the child env of the base env.
    @Test func theRegistryRunsClaudeWithTheChildEnvironment() async throws {
        let runner = FakeRunner(ExecResult(.exited(0), stdout: "[]"))
        let base = ["CLAUDECODE": "1", "PATH": "/login", "WARP_HONOR_PS1": "0"]
        let claude = ClaudeRunner(path: "/bin/claude", baseEnvironment: base, runner: runner)
        let deps = RegistrySystemDeps(
            claude: claude, runner: runner, skipRoots: [], saver: .noFile)
        _ = try await deps.listActive()
        #expect(runner.commands.map(\.environment) == [["PATH": "/login"]])
    }
}
