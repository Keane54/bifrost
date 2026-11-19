// The trust terminal (docs/behaviour/reviews.md, "Clones and trust") with a real PTY and the fake
// claude of scripts/fake-claude: a run with no arguments prints "FAKE TRUST", logs its folder to
// trust.log and each byte of its input to trust-input.log in the test home. The settle time runs
// on the manual clock. Safety: no test runs the real claude or reads the real ~/.claude.json, and
// each child that a test starts ends before the test ends.
import AppKit
import BifrostSessions
import BifrostTestSupport
import Foundation
import SwiftTerm
import Testing

@testable import BifrostChat

@MainActor
private final class TrustFixture {
    let folder: TemporaryFolder
    let spawner = RecordingPTYSpawner()
    let ptys: PTYManager
    let clock = ManualClock()
    let root: String
    let clone: String
    let (triggers, trigger) = AsyncStream.makeStream(of: Void.self)
    // The answer of the trust read, the count of the reads and the count of the trusted calls.
    var answer = false
    var checks = 0
    var trustedCalls = 0
    private(set) var terminal: TrustTerminal?

    init() throws {
        folder = try TemporaryFolder(short: true)
        let home = folder.path
        let fake = try Repo.fakeClaude()
        let fakeFolder = URL(fileURLWithPath: fake).deletingLastPathComponent().path
        let claude = ClaudeRunner(
            path: fake,
            baseEnvironment: [
                "PATH": "\(fakeFolder):/usr/bin:/bin", "HOME": home, "BIFROST_TEST_HOME": home,
                "LANG": "en_US.UTF-8",
            ], runner: NoRunner())
        ptys = PTYManager(claude: claude, spawner: spawner)
        root = folder.realPath + "/repos"
        clone = root + "/owner-a/repo-a"
        try FileManager.default.createDirectory(atPath: clone, withIntermediateDirectories: true)
    }

    // Open the trust run in the clone and the terminal over it.
    func open() async throws -> TrustTerminal {
        let checked = try #require(
            await TrustRuns.check(
                folder: URL(filePath: clone),
                root: URL(filePath: root, directoryHint: .isDirectory)))
        let run = try #require(
            try await ptys.openTrust(checked, size: TerminalSize(cols: 100, rows: 30)))
        let terminal = TrustTerminal(
            run: run,
            check: { [weak self] in
                guard let self else { return false }
                checks += 1
                return answer
            }, triggers: triggers, onTrusted: { [weak self] in self?.trustedCalls += 1 },
            clock: clock)
        self.terminal = terminal
        return terminal
    }

    var screen: String {
        guard let view = terminal?.view else { return "" }
        return view.visibleRowsText(0..<view.terminalDimensions.rows).joined(separator: "\n")
    }

    func lines(_ name: String) -> [String] {
        let text = try? String(contentsOfFile: folder.appending(name), encoding: .utf8)
        return (text ?? "").split(separator: "\n").map(String.init)
    }

    var input: Data? { FileManager.default.contents(atPath: folder.appending("trust-input.log")) }

    var pids: [pid_t] { spawner.log.pids }

    // Close the terminal and each PTY, wait until each child ended, then remove the home.
    func end() async {
        terminal?.close()
        ptys.closeAll()
        let pids = pids
        await waitUntil { pids.allSatisfy { kill($0, 0) != 0 } }
        folder.remove()
    }
}

@Suite("trust terminal", .serialized, .timeLimit(.minutes(1)), .tags(.realProcess))
@MainActor
struct TrustTerminalTests {
    // claude runs with no arguments in the real folder of the clone, and its output shows in
    // the terminal.
    @Test func theTerminalRunsClaudeInTheClone() async throws {
        let f = try TrustFixture()
        let terminal = try await f.open()
        #expect(await waitUntil { f.screen.contains("FAKE TRUST") })
        #expect(f.spawner.log.arguments == [[]])
        await waitUntil { !f.lines("trust.log").isEmpty }
        #expect(f.lines("trust.log") == [f.clone])
        #expect(terminal.state == .running)
        await f.end()
    }

    // The check runs 500 ms after the last output, on the clock, and not before. It runs again
    // when claude ends.
    @Test func theCheckRunsWhenTheOutputSettles() async throws {
        let f = try TrustFixture()
        let terminal = try await f.open()
        #expect(await waitUntil { f.screen.contains("FAKE TRUST") })
        await f.clock.waitForSleepers(1)
        #expect(f.checks == 0)
        f.clock.advance(by: .milliseconds(499))
        // The timer still sleeps: a settle time below 500 ms would have woken it. The main actor
        // then runs its other work, so a check that the advance woke would run before the expect.
        #expect(f.clock.sleeperCount == 1)
        await f.clock.waitForSleepers(exactly: 1)
        for _ in 0..<20 { await Task.yield() }
        #expect(f.checks == 0)
        f.clock.advance(by: .milliseconds(1))
        #expect(await waitUntil { f.checks == 1 })
        // claude ends by itself (a stop of the child that the test started).
        let pid = try #require(f.pids.first)
        #expect(kill(pid, SIGTERM) == 0)
        #expect(await waitUntil { f.checks == 2 })
        #expect(terminal.state == .ended)
        #expect(f.trustedCalls == 0)
        await f.end()
    }

    // A change event of ~/.claude.json runs the check at once, with no wait for the settle time.
    @Test func theCheckRunsOnATrigger() async throws {
        let f = try TrustFixture()
        let terminal = try await f.open()
        f.trigger.yield()
        #expect(await waitUntil { f.checks == 1 })
        f.trigger.yield()
        #expect(await waitUntil { f.checks == 2 })
        #expect(terminal.state == .running)
        #expect(f.trustedCalls == 0)
        await f.end()
    }

    // A check that sees the trust closes the terminal: its claude gets SIGHUP and ends, and the
    // owner hears it once. The settle timer stops too.
    @Test func aTrustedCloneClosesTheTerminal() async throws {
        let f = try TrustFixture()
        let terminal = try await f.open()
        #expect(await waitUntil { f.screen.contains("FAKE TRUST") })
        f.answer = true
        f.trigger.yield()
        #expect(await waitUntil { f.trustedCalls == 1 })
        #expect(terminal.state == .trusted)
        let pid = try #require(f.pids.first)
        #expect(f.spawner.log.signals.map(\.signal) == [.hangup])
        #expect(f.spawner.log.signals.map(\.pid) == [pid])
        #expect(await waitUntil { kill(pid, 0) != 0 })
        await f.clock.waitUntilNoSleepers()
        #expect(f.checks == 1)
        #expect(f.trustedCalls == 1)
        await f.end()
    }

    // Bifrost never types into the trust terminal: after the output, the settle check, a trigger
    // and the close, the input of claude is empty.
    @Test func theTerminalNeverTypes() async throws {
        let f = try TrustFixture()
        let terminal = try await f.open()
        #expect(await waitUntil { f.screen.contains("FAKE TRUST") })
        await f.clock.waitForSleepers(1)
        f.clock.advance(by: .milliseconds(500))
        #expect(await waitUntil { f.checks == 1 })
        f.trigger.yield()
        #expect(await waitUntil { f.checks == 2 })
        terminal.close()
        #expect(terminal.state == .closed)
        let pid = try #require(f.pids.first)
        #expect(await waitUntil { kill(pid, 0) != 0 })
        #expect(f.input?.isEmpty ?? true)
        #expect(f.trustedCalls == 0)
        await f.end()
    }
}
