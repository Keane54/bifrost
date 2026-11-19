import BifrostFoundation
import Foundation

// MARK: - The login shell

// One interactive login shell at the start gives the path of claude and the env of each claude
// run. The app can start from Finder or the Dock, so its env has the short launchd PATH, which
// can miss the folder of claude. A login shell without -i does not read .zshrc, and .zshrc can
// add that folder. The first claude call can start the shared background service of Claude Code,
// and each background session gets the env of that service. The path and the env come from the
// same shell and the same small env, so claude runs in the env where the shell found it.
package enum LoginShell {
    // The login shell gets only these variables from the app.
    package static let shellKeys = ["HOME", "USER", "LOGNAME", "SHELL", "LANG", "TMPDIR"]

    static let timeout = Duration.seconds(5)

    // The path of claude, or nil when the app cannot find it, and the env of the claude runs.
    package struct Result: Sendable, Equatable {
        package var claudePath: String?
        package var environment: [String: String]
    }

    // Run the login shell. The shell is shell, else the SHELL of the fallback, else /bin/zsh.
    // When the shell gives no path, the path is the first claude on the PATH of the fallback (the
    // env of the app), else the first runnable known path. The shell gets a small env, so it can
    // miss a claude that only the PATH of the app has. When the shell gives no env, the env is
    // the fallback, and one log line gives the reason and the time that the shell took.
    package static func load(
        runner: any CommandRunner, shell: String?, fallback: [String: String], home: URL,
        isRunnable: (String) -> Bool = ProgramLookup.isRunnable,
        log: any SessionsLog = SystemSessionsLog()
    ) async -> Result {
        let shell = shell ?? fallback["SHELL"] ?? "/bin/zsh"
        let env = fallback.filter { key, _ in shellKeys.contains(key) }
        let clock = ContinuousClock()
        let start = clock.now
        let result = await runner.run(
            Command(
                shell, ["-lic", LoginEnvironmentText.script], environment: env, timeout: timeout))
        let took = clock.now - start
        let path =
            (result.succeeded ? LoginEnvironmentText.claudePath(result.stdout) : nil)
            ?? fallback["PATH"].flatMap {
                ProgramLookup.find("claude", path: $0, isRunnable: isRunnable)
            }
            ?? ClaudeLocator.knownPath(home: home, isRunnable: isRunnable)
        if result.succeeded, let parsed = LoginEnvironmentText.parse(result.stdout) {
            return Result(claudePath: path, environment: parsed)
        }
        log.record(.loginShellFailed(result.end, took: took))
        return Result(claudePath: path, environment: fallback)
    }
}

// MARK: - The path of claude

package enum ClaudeLocator {
    // The first runnable known path of claude, or nil.
    package static func knownPath(home: URL, isRunnable: (String) -> Bool) -> String? {
        let paths = [
            home.appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return paths.first { isRunnable($0) }
    }

    // The first absolute folder of the PATH text that holds a runnable file with this name, or
    // nil (ProgramLookup skips an empty or a relative folder). So the path of claude never
    // depends on the current folder.
    package static func findOnPath(_ name: String, path: String?) -> String? {
        path.flatMap { ProgramLookup.find(name, path: $0) }
    }
}

// MARK: - The claude runner

// Runs claude. Each claude run gets the child env of the base env, the login-shell env. A claude
// run has no TTY, so the env does not set TERM or COLORTERM. claude adds piped stdin to the
// prompt, so a claude run never gets input. A PTY of PTYManager gets this env with TERM and
// COLORTERM.
package struct ClaudeRunner: Sendable {
    package let path: String
    package let environment: [String: String]
    let runner: any CommandRunner

    package init(path: String, baseEnvironment: [String: String], runner: any CommandRunner) {
        self.path = path
        environment = ChildEnvironment.make(from: baseEnvironment, pty: false)
        self.runner = runner
    }

    // A cancel of the calling task stops the run. The kill signal stops the run at the timeout
    // and at a cancel: SIGKILL by default. Give terminate only for a command that a SIGKILL can
    // leave half done. A program that still runs at the end of terminateGrace then gets SIGKILL;
    // nil gives no SIGKILL, and the caller sets its own limit (KillSignal.terminate). waitsForEnd:
    // after a cancel the result comes when claude ended (Command.waitsForEnd).
    package func run(
        _ arguments: [String], directory: String? = nil, timeout: Duration = .seconds(10),
        killSignal: KillSignal = .kill,
        terminateGrace: Duration? = Command.defaultTerminateGrace, waitsForEnd: Bool = false
    ) async -> ExecResult {
        await runner.run(
            Command(
                path, arguments, directory: directory, environment: environment, timeout: timeout,
                killSignal: killSignal, terminateGrace: terminateGrace, waitsForEnd: waitsForEnd))
    }
}

// MARK: - The session list

// Run "claude agents --json", with "--all" when all is true. A run that does not succeed gives
// commandFailed with the trimmed stderr as the detail. When stderr is empty, the detail is the
// text of the end, for example "claude stopped with code <n>." (ErrorText). The parse runs off
// the actor of the caller.
@concurrent package func listAgents(_ claude: ClaudeRunner, all: Bool) async -> AgentList {
    let result = await claude.run(["agents", "--json"] + (all ? ["--all"] : []))
    guard result.succeeded else {
        let text = result.stderr.trimmed()
        let detail = text.isEmpty ? ErrorText.ended("claude", result.end) : text
        return .failed(.commandFailed(detail: detail))
    }
    return AgentList(output: result.stdout)
}
