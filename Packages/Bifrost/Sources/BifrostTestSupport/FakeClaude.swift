import BifrostFoundation
import Foundation
import Synchronization
import Testing

// A fake claude program and a fake login shell in a TemporaryFolder, for the tests of
// AppServices. The folder also holds the test home. The tests never run the real claude or the
// real login shell: the runner of the fake runs only the programs in the folder.
//
// The layout of the folder:
// - bin/claude: the fake claude. It adds its arguments to the lines of claude-runs and writes
//   its env to claude-env. Then it answers "agents --json" and "agents --json --all" with the
//   text of agents.json. "attach <short id>" prints "FAKE ATTACH <short id>" and waits. Its
//   SIGHUP adds the line "hup" to attach-hup, and the fake exits.
// - login/shell: the fake login shell. "-lic 'command -v claude'" prints the path of the fake
//   claude. Another script runs with the fixed env of loginEnvironment. When the file
//   login/hold exists, the shell first makes login/waiting, then waits until login/go exists.
// - home: the test home.
// - real-home: a folder that stands in for the real home. Nothing writes to it.
package struct FakeClaude {
    // One entry of "claude agents --json".
    package struct Agent: Encodable, Sendable {
        package var sessionId: String
        package var cwd: String
        package var kind: String
        package var name: String
        package var status: String
        package var id: String?
        package var pid: Int?
        package var startedAt: Int

        package init(
            sessionId: String, cwd: String, kind: String, name: String, status: String,
            id: String?, pid: Int?, startedAt: Int
        ) {
            self.sessionId = sessionId
            self.cwd = cwd
            self.kind = kind
            self.name = name
            self.status = status
            self.id = id
            self.pid = pid
            self.startedAt = startedAt
        }
    }

    package let folder: TemporaryFolder
    package let runner: GuardRunner

    package var bin: String { folder.appending("bin") }
    package var claude: String { "\(bin)/claude" }
    package var shell: String { folder.appending("login/shell") }
    package var home: URL { URL(fileURLWithPath: folder.appending("home"), isDirectory: true) }
    package var realHome: URL {
        URL(fileURLWithPath: folder.appending("real-home"), isDirectory: true)
    }
    package var agentsFile: String { folder.appending("agents.json") }
    package var envFile: String { folder.appending("claude-env") }
    package var runsFile: String { folder.appending("claude-runs") }
    // The SIGHUPs of the fake attach, one line for each.
    package var attachHupFile: String { folder.appending("attach-hup") }
    // A folder name that only the env of the fake login shell has.
    package var loginOnlyFolder: String { folder.appending("login-only") }
    // The PATH of the env of the fake login shell.
    package var loginPath: String { "\(bin):/usr/bin:/bin:\(loginOnlyFolder)" }

    // The env of the app in a test: the fake folder first on the PATH, the test home as HOME, the
    // fake login shell as SHELL, and the variables of a Claude Code session that must not go to
    // claude.
    package var environment: [String: String] {
        [
            "PATH": "\(bin):/usr/bin:/bin", "HOME": home.path, "SHELL": shell,
            "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli", "BIFROST_APP_ONLY": "1",
        ]
    }

    // The sessions of the fake list.
    package static let alpha = Agent(
        sessionId: "5a0e0001-0000-4000-8000-000000000001", cwd: "/nonexistent-bifrost-fake/alpha",
        kind: "background", name: "fake-alpha", status: "idle", id: "5a0e0001", pid: 99991,
        startedAt: 1_793_900_000_000)
    package static let beta = Agent(
        sessionId: "5a0e0002-0000-4000-8000-000000000002", cwd: "/nonexistent-bifrost-fake/beta",
        kind: "interactive", name: "fake-beta", status: "busy", id: "5a0e0002", pid: 99992,
        startedAt: 1_793_900_001_000)
    package static let gamma = Agent(
        sessionId: "5a0e0003-0000-4000-8000-000000000003", cwd: "/nonexistent-bifrost-fake/gamma",
        kind: "background", name: "fake-gamma", status: "busy", id: "5a0e0003", pid: 99993,
        startedAt: 1_793_900_002_000)

    package init(agents: [Agent] = [Self.alpha, Self.beta]) throws {
        folder = try TemporaryFolder(short: true)
        runner = GuardRunner(allowedFolder: folder.path)
        for name in ["bin", "login", "home"] {
            try FileManager.default.createDirectory(
                atPath: folder.appending(name), withIntermediateDirectories: true)
        }
        try setAgents(agents)
        try Self.writeScript(
            claude,
            Self.claudeScript(
                envFile: envFile, runsFile: runsFile, agentsFile: agentsFile,
                hupFile: attachHupFile))
        try Self.writeScript(
            shell,
            Self.shellScript(
                claude: claude, path: loginPath, home: home, gate: folder.appending("login")))
    }

    // Change the list of the fake claude. The write replaces the file in one step, so a run
    // never reads a part of a file.
    package func setAgents(_ agents: [Agent]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(agents).write(to: URL(fileURLWithPath: agentsFile), options: .atomic)
    }

    // The env of the last claude run, or nil before the first run.
    package func lastClaudeEnvironment() -> [String: String]? {
        guard let data = FileManager.default.contents(atPath: envFile) else { return nil }
        var env: [String: String] = [:]
        for entry in data.split(separator: 0) {
            guard let equals = entry.firstIndex(of: UInt8(ascii: "=")) else { continue }
            let key = String(decoding: entry[..<equals], as: UTF8.self)
            env[key] = String(decoding: entry[(equals + 1)...], as: UTF8.self)
        }
        return env
    }

    // The arguments of each claude run, in the order of the runs.
    package func runs() -> [String] {
        guard let data = FileManager.default.contents(atPath: runsFile) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    // The runs of claude other than the reads that the app makes at its own times: the reads of
    // the session list (agents --json, with --all for the second list), the version check and
    // the status reads of Live details and the skills. A test that checks the commands of an
    // action counts only these runs.
    package func commandRuns() -> [String] {
        runs().filter { !Self.backgroundReads.contains($0) }
    }

    private static let backgroundReads: Set<String> = [
        "agents --json", "agents --json --all", "--version", "plugin list --json",
        "plugin marketplace list --json",
    ]

    // Make each later run of the fake login shell wait until releaseTheLoginShell().
    package func holdTheLoginShell() throws {
        try Data().write(to: URL(fileURLWithPath: folder.appending("login/hold")))
    }

    // True when a run of the fake login shell waits.
    package var loginShellWaits: Bool {
        FileManager.default.fileExists(atPath: folder.appending("login/waiting"))
    }

    package func releaseTheLoginShell() throws {
        try Data().write(to: URL(fileURLWithPath: folder.appending("login/go")))
    }

    package func remove() { folder.remove() }

    // MARK: - The scripts

    private static func writeScript(_ path: String, _ text: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    // The paths are in a TemporaryFolder, so they hold no quote.
    // The attach waits in a loop of short sleeps: a SIGHUP that comes just before a long wait
    // would run its trap only at the end of that wait.
    private static func claudeScript(
        envFile: String, runsFile: String, agentsFile: String, hupFile: String
    ) -> String {
        """
        #!/bin/sh
        echo "$*" >> '\(runsFile)'
        /usr/bin/env -0 > '\(envFile).tmp' && /bin/mv '\(envFile).tmp' '\(envFile)'
        case "$*" in
          'agents --json' | 'agents --json --all') /bin/cat '\(agentsFile)' ;;
          'attach '*)
            trap "echo hup >> '\(hupFile)'; exit 0" HUP
            echo "FAKE ATTACH $2"
            while :; do /bin/sleep 1 </dev/null >/dev/null 2>&1 & wait $!; done ;;
          *) echo "fake claude: unknown command: $*" >&2; exit 2 ;;
        esac

        """
    }

    // Bifrost runs "<shell> -lic <script>". The env of a login shell is the fixed env here, with
    // CLAUDECODE as a Claude Code session can give it.
    private static func shellScript(
        claude: String, path: String, home: URL, gate: String
    ) -> String {
        """
        #!/bin/sh
        if [ -e '\(gate)/hold' ]; then
          : > '\(gate)/waiting'
          while [ ! -e '\(gate)/go' ]; do /bin/sleep 0.02; done
        fi
        if [ "$2" = 'command -v claude' ]; then
          echo 'a banner line of the shell'
          echo '\(claude)'
          exit 0
        fi
        exec /usr/bin/env -i PATH='\(path)' HOME='\(home.path)' CLAUDECODE=1 \\
          CLAUDE_CODE_ENTRYPOINT=cli BIFROST_FAKE_LOGIN=1 /bin/sh -c "$2"

        """
    }
}

// Runs the programs in one folder with the real runner. It refuses each other program, for
// example the real claude, a real shell, git and ps, and records it. A refused program gives
// the result of a program that did not start. After close(within:), the runner starts no
// program, so a test can remove the folder when the runs in progress end.
//
// Each program gets a time limit of at least 30 s. The limits of the app (for example 5 s for a
// login shell) are for the Mac of a user. On a test host under load, the start of a program can
// take more than 5 s, and then the app takes its fallback in place of the fake. No test that
// uses this runner waits for a time limit.
package final class GuardRunner: CommandRunner {
    private struct State {
        var refused: [String] = []
        // The runs that started and did not end.
        var running = 0
        var closed = false
    }

    // The shortest time limit of a program of this runner.
    package static let minimumTimeout = Duration.seconds(30)

    private let allowedFolder: String
    private let real = ProcessRunner()
    private let state = Mutex(State())

    package init(allowedFolder: String) {
        self.allowedFolder = allowedFolder
    }

    // The executables that the runner refused before the close, in the order of the calls.
    package var refused: [String] { state.withLock { $0.refused } }

    package func run(_ command: Command) async -> ExecResult {
        let starts = state.withLock { s in
            if s.closed { return false }
            guard command.executable.hasPrefix(allowedFolder + "/") else {
                s.refused.append(command.executable)
                return false
            }
            s.running += 1
            return true
        }
        guard starts else {
            return ExecResult(.notStarted, stderr: "refused by the test")
        }
        var slow = command
        slow.timeout = max(command.timeout, Self.minimumTimeout)
        let result = await real.run(slow)
        state.withLock { $0.running -= 1 }
        return result
    }

    // Refuse each later run, then wait until the runs in progress end, for at most limit. The
    // result is true when no run is in progress.
    // At the limit the wait records an issue at the line of the caller.
    @discardableResult
    package func close(
        within limit: Duration, sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        state.withLock { $0.closed = true }
        let end = ContinuousClock.now + limit
        while state.withLock({ $0.running }) > 0 {
            if ContinuousClock.now >= end {
                Issue.record(
                    "A run of the fake did not end in \(limit).", sourceLocation: sourceLocation)
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}
