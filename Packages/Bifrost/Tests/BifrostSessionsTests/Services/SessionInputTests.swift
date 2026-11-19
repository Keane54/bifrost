// The shell of the session input with a real PTY and the fake claude of scripts/fake-claude
// (docs/behaviour/input.md). Safety: no test runs the real claude or attaches to a real
// session. The fake attach writes files only in the test home. The size read uses a fake
// process inspector, so no test reads a process that it did not start. Each child that a test
// starts ends before the test ends.
import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostSessions

private let sessionId = "5a0e0001-0000-4000-8000-000000000001"
private let shortId = "5a0e0001"
private let sessionSize = TerminalSize(cols: 97, rows: 41)

// The session size reader of a test: the fake inspector gives the session size. It reads no
// process.
@MainActor
private func sessionSizes() -> SessionSizeReader {
    SessionSizeReader(inspector: FakeProcessInspector(size: sessionSize))
}

// A terminal model that records the output of the attach and its size. It gives no reply.
@MainActor
private final class HiddenAttachTerminal: HiddenTerminal {
    var size: TerminalSize?
    var fed: [UInt8] = []

    func feed(_ bytes: [UInt8]) -> [UInt8] {
        fed += bytes
        return []
    }
}

// The PTY manager with the fake claude, the session input and the test home.
@MainActor
private final class HiddenAttachFixture {
    let folder: TemporaryFolder
    let spawner = RecordingPTYSpawner()
    let ptys: PTYManager
    let terminal = HiddenAttachTerminal()
    var input: SessionInput?
    var rows: [SessionRow]
    let log = Recorder<SessionsLogEvent>()

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
        rows = [
            SessionRow.test(
                sessionId: sessionId, shortId: ShortID(shortId), name: "fake", pid: 4242, cwd: home,
                lastActivity: 0, startedAt: 0)
        ]
        let terminal = self.terminal
        let input = SessionInput(
            ptys: ptys, sizes: sessionSizes(),
            rows: { [weak self] in self?.rows ?? [] },
            makeTerminal: { size in
                terminal.size = size
                return terminal
            }, clock: ContinuousClock(), log: log)
        self.input = input
    }

    // The bytes that the session got from the attach.
    var sessionInput: [UInt8] {
        let file = folder.appending("attach-input-\(shortId).log")
        return FileManager.default.contents(atPath: file).map { [UInt8]($0) } ?? []
    }

    var attachLines: [String] {
        let text = (try? String(contentsOfFile: folder.appending("attach.log"), encoding: .utf8))
        return (text ?? "").split(separator: "\n").map(String.init)
    }

    // Close each PTY, wait until each child that the test started ended, then remove the home.
    func close() async {
        ptys.closeAll()
        let pids = spawner.log.pids
        await waitUntil(within: .seconds(10)) { pids.allSatisfy { kill($0, 0) != 0 } }
        folder.remove()
    }
}

@Suite("session input shell", .serialized, .timeLimit(.minutes(1)), .tags(.realProcess))
@MainActor
struct SessionInputTests {
    // Cmd+. with no chat window: the session input opens a hidden attach at the session size,
    // the fake attach gets one ESC 300 ms after its first output, and the attach closes 1 s
    // later with SIGHUP to the attach child only. The terminal model got the output of the
    // attach.
    @Test(.tags(.timing))
    func anInterruptWithNoChatWindowSendsOneEscThroughAHiddenAttach() async throws {
        let f = try HiddenAttachFixture()
        let input = try #require(f.input)
        let start = ContinuousClock.now
        var refusal: InputRefusal?
        do throws(InputRefusal) {
            try await input.interrupt(sessionId)
        } catch {
            refusal = error
        }
        let took = ContinuousClock.now - start
        #expect(refusal == nil)
        // The ESC goes 300 ms after the first output, and the close 1 s after the ESC.
        #expect(took >= .milliseconds(1300))
        #expect(f.spawner.log.arguments == [["attach", shortId]])
        #expect(f.spawner.log.opens == [sessionSize])
        #expect(f.terminal.size == sessionSize)
        #expect(f.spawner.log.signals.map(\.signal) == [.hangup])
        let pids = f.spawner.log.pids
        await waitUntil { pids.allSatisfy { kill($0, 0) != 0 } }
        #expect(f.ptys.list().isEmpty)
        // The fake attach logs each byte of its input: one ESC, and nothing more.
        await waitUntil { !f.sessionInput.isEmpty }
        #expect(f.sessionInput == [0x1b])
        #expect(f.attachLines == ["FAKE ATTACH \(shortId)"])
        #expect(String(decoding: f.terminal.fed, as: UTF8.self).contains("FAKE ATTACH \(shortId)"))
        #expect(f.log.values.isEmpty)
        await f.close()
    }

    // A send with no chat window types the paste and the CR through a hidden attach, and the
    // idle call returns after the attach closed.
    @Test func aSendWithNoChatWindowTypesThePasteThroughAHiddenAttach() async throws {
        let f = try HiddenAttachFixture()
        let input = try #require(f.input)
        let sending = Task { () async -> InputRefusal? in
            do throws(InputRefusal) {
                try await input.send(sessionId, "Reply with OK")
                return nil
            } catch {
                return error
            }
        }
        await waitUntil { !f.spawner.log.pids.isEmpty }
        await input.idle(sessionId)
        #expect(f.ptys.list().isEmpty)
        #expect(await sending.value == nil)
        let paste = Array("\u{1b}[200~Reply with OK\u{1b}[201~\r".utf8)
        await waitUntil { f.sessionInput == paste }
        #expect(f.spawner.log.signals.map(\.signal) == [.hangup])
        await f.close()
    }
}
