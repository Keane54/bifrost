// The PTY manager and its attach objects (docs/behaviour/pty.md), with a fake spawner. The
// events of a child reach the attach in a later turn of the main actor, so each test waits for
// the reader, the exit or the drain that it checks.
import BifrostFoundation
import BifrostTestSupport
import Dispatch
import Foundation
import Synchronization
import Testing

@testable import BifrostSessions

private let size = TerminalSize(cols: 100, rows: 30)
private let v1: SessionID = "00000000-0000-4000-8000-0000000000a1"
private let v2: SessionID = "00000000-0000-4000-8000-0000000000a2"
private let v3: SessionID = "00000000-0000-4000-8000-0000000000a3"
private let va: SessionID = "00000000-0000-4000-8000-00000000000a"
private let vb: SessionID = "00000000-0000-4000-8000-00000000000b"

@MainActor
private func manager(
    _ spawner: FakeSpawner, path: String = "/bin/claude", environment: [String: String] = [:]
) -> PTYManager {
    let claude = ClaudeRunner(path: path, baseEnvironment: environment, runner: NoRunner())
    return PTYManager(claude: claude, spawner: spawner)
}

@MainActor
private func open(_ m: PTYManager, _ view: PTYView, _ shortId: ShortID = "0000aaaa") async throws
    -> PTYAttach?
{
    try await m.open(.test(view, shortId: shortId, directory: "/tmp"), size: size)
}

// Reads the output and then the exit of one attach, as an owner reads them.
@MainActor
private final class Reader {
    private(set) var chunks: [[UInt8]] = []
    private(set) var ended = false
    // The exit code, or nil when a close came first.
    private(set) var code: Int32?
    // For each chunk, the bytes that still wait in the child when the reader takes the chunk.
    private(set) var waitingSeen: [Int] = []

    init(_ attach: PTYAttach, child: FakeChild? = nil) {
        Task {
            for await chunk in attach.output {
                chunks.append(chunk)
                if let child { waitingSeen.append(child.waiting) }
            }
            code = await attach.exit
            ended = true
        }
    }

    var texts: [String] { chunks.map { String(decoding: $0, as: UTF8.self) } }
}

@MainActor
@Suite("PTY manager", .testTimeLimit)
struct PTYManagerTests {
    // The manager makes the arguments of claude: "attach" and the short ID, nothing else.
    @Test func anOpenSpawnsClaudeAttachWithTheShortIDTheSizeAndTERM() async throws {
        let spawner = FakeSpawner()
        let m = manager(spawner)
        let attach = try #require(try await open(m, .chat(v1), "abcd1234"))
        #expect(attach.pid == 4242)
        #expect(attach.view == .chat(v1))
        #expect(attach.isOpen)
        let spawn = try #require(spawner.spawns.first)
        #expect(spawn.program == "/bin/claude")
        #expect(spawn.arguments == ["attach", "abcd1234"])
        #expect(spawn.size == TerminalSize(cols: 100, rows: 30))
        #expect(spawn.directory == "/tmp")
        #expect(spawn.environment["TERM"] == "xterm-256color")
        #expect(spawn.environment["COLORTERM"] == "truecolor")
    }

    // A spawn can wait a long time (the endpoint scanner checks each program start), so it runs
    // on the blocking executor, never on a thread of the cooperative pool.
    @Test func theSpawnRunsOnTheBlockingExecutor() async throws {
        let spawner = FakeSpawner()
        let label = Mutex<String?>(nil)
        spawner.holdNext(nil) { _ in
            label.withLock { $0 = String(cString: __dispatch_queue_get_label(nil)) }
        }
        _ = try #require(try await open(manager(spawner), .chat(v1)))
        #expect(label.withLock { $0 } == "bifrost.blocking")
    }

    @Test func theChildGetsTheBaseEnvironmentWithoutTheRemovedVariables() async throws {
        let spawner = FakeSpawner()
        let m = manager(spawner, environment: ["PATH": "/login", "WARP_X": "1"])
        _ = try await open(m, .chat(v1))
        #expect(
            spawner.spawns.first?.environment
                == ["COLORTERM": "truecolor", "PATH": "/login", "TERM": "xterm-256color"])
    }

    @Test func theOutputComesToTheAttachInOrder() async throws {
        let spawner = FakeSpawner()
        let attach = try #require(try await open(manager(spawner), .chat(v1)))
        let reader = Reader(attach)
        spawner.fakes[0].emitData("hi")
        await waitUntil { reader.texts == ["hi"] }
        spawner.fakes[0].emitData(" there")
        await waitUntil { reader.texts == ["hi", " there"] }
        #expect(!reader.ended)
    }

    // Each drain takes at most drainLimit bytes and is one element of the output. The bytes
    // keep their order.
    @Test func eachChunkIsAtMostTheDrainLimitAndTheBytesKeepTheirOrder() async throws {
        let spawner = FakeSpawner()
        let attach = try #require(try await open(manager(spawner), .chat(v1)))
        let reader = Reader(attach)
        let bytes = (0..<700_000).map { UInt8(truncatingIfNeeded: $0 * 7) }
        spawner.fakes[0].emitBytes(bytes)
        await waitUntil { reader.chunks.reduce(0) { $0 + $1.count } == bytes.count }
        #expect(reader.chunks.map(\.count) == [262_144, 262_144, 175_712])
        #expect(reader.chunks.flatMap { $0 } == bytes)
        #expect(spawner.fakes[0].waiting == 0)
    }

    // The child keeps its bytes until the reader asks for the next chunk, and each ask takes one
    // drain. So the reader gets one chunk in each turn of the main actor, and no chunk waits in
    // a buffer of the attach.
    @Test func theChildKeepsItsBytesUntilTheReaderAsks() async throws {
        let spawner = FakeSpawner()
        let attach = try #require(try await open(manager(spawner), .chat(v1)))
        let reader = Reader(attach, child: spawner.fakes[0])
        spawner.fakes[0].emitBytes(Array(repeating: 0x61, count: 700_000))
        await waitUntil { reader.waitingSeen.count == 3 }
        #expect(reader.waitingSeen == [437_856, 175_712, 0])
        #expect(spawner.fakes[0].drains == 3)
    }

    // A cancel of the task of the reader ends its output, as for each async sequence. The attach
    // stays open.
    @Test func aCancelOfTheReaderEndsItsOutput() async throws {
        let spawner = FakeSpawner()
        let attach = try #require(try await open(manager(spawner), .chat(v1)))
        let reads = TestSignal()
        let reading = Task {
            var chunks = 0
            reads.send()
            for await _ in attach.output { chunks += 1 }
            return chunks
        }
        // The reader runs on the main actor: it waits for output when the test sees the signal.
        await reads.wait(for: "the start of the reader")
        reading.cancel()
        #expect(await reading.value == 0)
        #expect(attach.isOpen)
    }

    // The exit comes after the last output. Then the attach and its view have no PTY.
    @Test func theExitComesAfterTheLastOutputAndEndsTheAttach() async throws {
        let spawner = FakeSpawner()
        let m = manager(spawner)
        let attach = try #require(try await open(m, .chat(v1)))
        let reader = Reader(attach)
        spawner.fakes[0].emitData("bye")
        spawner.fakes[0].emitExit(1)
        await waitUntil { reader.ended }
        #expect(reader.texts == ["bye"])
        #expect(reader.ended)
        #expect(reader.code == 1)
        #expect(!attach.isOpen)
        #expect(!attach.write(Array("x".utf8)))
        #expect(spawner.fakes[0].written.isEmpty)
        #expect(m.attach(.chat(v1)) == nil)
        #expect(m.list().isEmpty)
    }

    @Test func anOpenOfAViewClosesItsOldAttachFirst() async throws {
        let spawner = FakeSpawner()
        let m = manager(spawner)
        let old = try #require(try await open(m, .chat(v1)))
        let reader = Reader(old)
        let new = try #require(try await open(m, .chat(v1)))
        #expect(spawner.fakes[0].signals == [.hangup])
        #expect(spawner.fakes.count == 2)
        #expect(!old.isOpen)
        #expect(m.attach(.chat(v1)) === new)
        #expect(new.write(Array("x".utf8)))
        #expect(!old.write(Array("y".utf8)))
        #expect(spawner.fakes[1].written == [Array("x".utf8)])
        #expect(spawner.fakes[0].written.isEmpty)
        await waitUntil { reader.ended }
        #expect(reader.code == nil)
    }

    // The output and the exit of an old child reach no attach. The attach still drains the
    // output of the old child and drops it.
    @Test func theOutputAndTheExitOfAnOldChildGoNowhere() async throws {
        let spawner = FakeSpawner()
        let m = manager(spawner)
        let old = try #require(try await open(m, .chat(v1)))
        let oldReader = Reader(old)
        let new = try #require(try await open(m, .chat(v1)))
        let newReader = Reader(new)
        spawner.fakes[0].emitData("old")
        spawner.fakes[0].emitExit(0)
        // The old child ends the old reader with no exit code and drops its late bytes.
        await waitUntil { oldReader.ended && spawner.fakes[0].waiting == 0 }
        #expect(oldReader.chunks.isEmpty)
        #expect(oldReader.code == nil)
        #expect(spawner.fakes[0].waiting == 0)
        #expect(newReader.chunks.isEmpty)
        #expect(!newReader.ended)
        #expect(new.isOpen)
        spawner.fakes[1].emitData("new")
        await waitUntil { newReader.texts == ["new"] }
        #expect(new.write(Array("x".utf8)))
        #expect(spawner.fakes[1].written == [Array("x".utf8)])
    }

    // A close ends the output at once, and the exit gives nil. The later output is drained and
    // dropped, so it does not grow until the exit.
    @Test func aCloseEndsTheOutputAndTheExitGoesNowhere() async throws {
        let spawner = FakeSpawner()
        let m = manager(spawner)
        let attach = try #require(try await open(m, .chat(v1)))
        let reader = Reader(attach)
        attach.close()
        #expect(spawner.fakes[0].signals == [.hangup])
        #expect(!attach.isOpen)
        #expect(m.attach(.chat(v1)) == nil)
        spawner.fakes[0].emitData("late")
        await waitUntil { spawner.fakes[0].drains == 1 }
        #expect(spawner.fakes[0].waiting == 0)
        spawner.fakes[0].emitExit(0)
        await waitUntil { reader.ended }
        #expect(reader.chunks.isEmpty)
        #expect(reader.ended)
        #expect(reader.code == nil)
        #expect(await attach.exit == nil)
    }

    // The bytes that wait for the reader at a close go nowhere: the close drains and drops them.
    @Test func aCloseDropsTheBytesThatWaitForTheReader() async throws {
        let spawner = FakeSpawner()
        let attach = try #require(try await open(manager(spawner), .chat(v1)))
        spawner.fakes[0].emitData("unread")
        #expect(spawner.fakes[0].waiting == 6)
        attach.close()
        await waitUntil { spawner.fakes[0].waiting == 0 }
        var chunks = 0
        for await _ in attach.output { chunks += 1 }
        #expect(chunks == 0)
    }

    // The only signals of a close are SIGHUP and SIGTERM. The type has no other value.
    @Test func aCloseSendsSIGHUPOrTheGivenSignalToItsChildOnly() async throws {
        #expect(CloseSignal.allCases == [.hangup, .terminate])
        #expect(CloseSignal.hangup.number == SIGHUP)
        #expect(CloseSignal.terminate.number == SIGTERM)
        let spawner = FakeSpawner()
        let m = manager(spawner)
        let first = try #require(try await open(m, .chat(v1)))
        let second = try #require(try await open(m, .chat(v2)))
        first.close()
        #expect(spawner.fakes[0].signals == [.hangup])
        #expect(spawner.fakes[1].signals.isEmpty)
        second.close(signal: .terminate)
        #expect(spawner.fakes[1].signals == [.terminate])
    }

    // A second close sends nothing. A close after the exit (the reap) sends nothing, so no
    // signal goes to a pid that the system can give to a new process.
    @Test func noSignalGoesAfterACloseOrAfterTheExit() async throws {
        let spawner = FakeSpawner()
        let m = manager(spawner)
        let first = try #require(try await open(m, .chat(v1)))
        let second = try #require(try await open(m, .chat(v2)))
        first.close()
        first.close(signal: .terminate)
        #expect(spawner.fakes[0].signals == [.hangup])
        spawner.fakes[1].emitExit(0)
        // The exit of the attach shows that the manager got the exit of its child.
        #expect(await second.exit == 0)
        second.close()
        m.closeAll()
        #expect(spawner.fakes[1].signals.isEmpty)
        spawner.fakes[0].emitExit(0)
        first.close()
        m.closeAll()
        #expect(spawner.fakes[0].signals == [.hangup])
        #expect(spawner.fakes.map(\.signalsAfterExit) == [0, 0])
    }

    // closeAll sends SIGHUP to each child, also when one child ended and the manager did not see
    // its exit yet: a signal cannot fail.
    @Test func closeAllClosesEachAttach() async throws {
        let spawner = FakeSpawner()
        let m = manager(spawner)
        var attaches: [PTYAttach] = []
        for view in [PTYView.chat(v1), .chat(v2), .chat(v3)] {
            attaches.append(try #require(try await open(m, view)))
        }
        spawner.fakes[0].reap()
        m.closeAll()
        for fake in spawner.fakes { #expect(fake.signals == [.hangup]) }
        #expect(attaches.allSatisfy { !$0.isOpen })
        #expect(m.list().isEmpty)
    }

    @Test func aResizeBelowOneDoesNothing() async throws {
        let spawner = FakeSpawner()
        let attach = try #require(try await open(manager(spawner), .chat(v1)))
        attach.resize(TerminalSize(cols: 0, rows: 24))
        attach.resize(TerminalSize(cols: 80, rows: 0))
        #expect(spawner.fakes[0].resizes.isEmpty)
        attach.resize(TerminalSize(cols: 80, rows: 24))
        #expect(spawner.fakes[0].resizes == [TerminalSize(cols: 80, rows: 24)])
        attach.close()
        attach.resize(TerminalSize(cols: 90, rows: 30))
        #expect(spawner.fakes[0].resizes == [TerminalSize(cols: 80, rows: 24)])
    }

    // The list has each open attach one time, in the order of the views. A close and an exit
    // remove an attach.
    @Test func theListHasEachOpenAttachOnceInTheOrderOfTheViews() async throws {
        let spawner = FakeSpawner(firstPid: 100)
        let m = manager(spawner)
        #expect(m.list().isEmpty)
        _ = try await open(m, .chat(vb))
        _ = try await open(m, .input("a"))
        _ = try await open(m, .chat(va))
        // A second open of the chat view of b replaces its attach.
        let b = try #require(try await open(m, .chat(vb)))
        #expect(m.list().map(\.view) == [.chat(va), .chat(vb), .input("a")])
        #expect(m.list().map(\.pid) == [102, 103, 101])
        b.close()
        #expect(m.list().map(\.view) == [.chat(va), .input("a")])
        spawner.fakes[2].emitExit(0)
        await waitUntil { m.list().map(\.view) == [.input("a")] }
        #expect(m.attach(.input("a"))?.pid == 101)
    }

    // A chunk with ESC [ 2 J has a full redraw. A sequence that two chunks split is missed.
    @Test func aChunkWithESCBracket2JHasAFullRedraw() {
        #expect(!PTYAttach.hasFullRedraw(Array("plain".utf8)))
        #expect(PTYAttach.hasFullRedraw(Array("x\u{1b}[2Jy".utf8)))
        #expect(!PTYAttach.hasFullRedraw(Array("\u{1b}[2".utf8)))
        #expect(!PTYAttach.hasFullRedraw(Array("J".utf8)))
    }

    // A spawn error throws, and the view has no attach. The open closed the old attach of the
    // view first.
    @Test func aSpawnErrorThrowsAndTheViewHasNoAttach() async throws {
        let spawner = FakeSpawner()
        let m = manager(spawner)
        let old = try #require(try await open(m, .chat(v1)))
        let error = PTYError(message: "Cannot start /bin/claude: No such file or directory.")
        spawner.failNext(error)
        await #expect(throws: error) { try await open(m, .chat(v1)) }
        #expect(m.attach(.chat(v1)) == nil)
        #expect(!old.isOpen)
        #expect(spawner.fakes[0].signals == [.hangup])
    }
}

// The spawn runs off the main actor, and the open ends in a later turn of the main actor. A
// cancel of the open task, a closeAll or a newer open of the view during the spawn closes the
// new child.
@MainActor
@Suite("PTY manager spawn", .testTimeLimit)
struct PTYManagerSpawnTests {
    // The spawn waits at its gate until the main actor opens the gate, or the gate limit. The main
    // actor sees the spawn wait, so it ran during the spawn, and the spawn did not run on the
    // main thread. A spawn on the main actor would hold the main actor until the time limit.
    @Test func theMainActorRunsDuringTheSpawn() async throws {
        let spawner = FakeSpawner()
        let gate = TestGate()
        defer { gate.openAll() }
        spawner.holdNext(gate)
        let m = manager(spawner)
        let opening = Task { try await open(m, .chat(v1)) }
        await gate.waitUntilHolding()
        #expect(gate.holding == 1)
        #expect(m.attach(.chat(v1)) == nil)
        #expect(m.list().isEmpty)
        gate.open()
        #expect(try await opening.value?.pid == 4242)
        #expect(!gate.ranOnTheMainThread)
        #expect(m.attach(.chat(v1))?.pid == 4242)
    }

    // A cancel of the open task during the spawn cancels the open. When the spawn ends, the new
    // child gets SIGHUP at once, the open gives nil, and the view has no attach. The output of
    // that child is drained and dropped.
    @Test func aCancelDuringTheSpawnEndsTheNewChild() async throws {
        let spawner = FakeSpawner()
        let gate = TestGate()
        defer { gate.openAll() }
        spawner.holdNext(gate)
        let m = manager(spawner)
        let opening = Task { try await open(m, .chat(v1)) }
        await gate.waitUntilHolding()
        opening.cancel()
        gate.open()
        #expect(try await opening.value == nil)
        let child = try #require(spawner.fakes.first)
        #expect(child.signals == [.hangup])
        #expect(m.attach(.chat(v1)) == nil)
        #expect(m.list().isEmpty)
        child.emitData("late")
        await waitUntil { child.waiting == 0 }
        // The closed child got its one SIGHUP above. No later call signals a closed attach
        // (noSignalGoesAfterACloseOrAfterTheExit).
        #expect(child.signals == [.hangup])
    }

    // closeAll during a spawn cancels the open too.
    @Test func closeAllDuringTheSpawnEndsTheNewChild() async throws {
        let spawner = FakeSpawner()
        let gate = TestGate()
        defer { gate.openAll() }
        spawner.holdNext(gate)
        let m = manager(spawner)
        let opening = Task { try await open(m, .chat(v1)) }
        await gate.waitUntilHolding()
        m.closeAll()
        gate.open()
        #expect(try await opening.value == nil)
        #expect(spawner.fakes.map(\.signals) == [[.hangup]])
        #expect(m.list().isEmpty)
    }

    // An open whose task is cancelled before the spawn starts no child. It still closes the old
    // attach of the view first.
    @Test func aCancelledOpenStartsNoChildButClosesTheOldAttach() async throws {
        let spawner = FakeSpawner()
        let m = manager(spawner)
        let old = try #require(try await open(m, .chat(v1)))
        let opening = Task { try await open(m, .chat(v1)) }
        opening.cancel()
        #expect(try await opening.value == nil)
        #expect(spawner.spawns.count == 1)
        #expect(spawner.fakes[0].signals == [.hangup])
        #expect(!old.isOpen)
        #expect(m.attach(.chat(v1)) == nil)
        // A later open of the view starts a child as usual.
        #expect(try await open(m, .chat(v1))?.pid == 4243)
        #expect(spawner.spawns.count == 2)
    }

    // A newer open of the view during the spawn of an older open: the newer child gets the view.
    // The older child gets SIGHUP when its spawn ends, and its output and its exit go nowhere.
    // The newer child gets no signal and keeps its output.
    @Test func aNewerOpenDuringTheSpawnKeepsTheNewerChild() async throws {
        let spawner = FakeSpawner()
        let gate = TestGate()
        defer { gate.openAll() }
        spawner.holdNext(gate)
        let m = manager(spawner)
        let older = Task { try await open(m, .chat(v1)) }
        await gate.waitUntilHolding()
        let newer = try #require(try await open(m, .chat(v1)))
        let reader = Reader(newer)
        #expect(newer.pid == 4242)
        #expect(m.list().map(\.pid) == [4242])
        gate.open()
        #expect(try await older.value == nil)
        let fakes = spawner.fakes
        try #require(fakes.count == 2)
        // The newer spawn ended first, so it has the first pid.
        #expect(fakes[0].signals.isEmpty)
        #expect(fakes[1].signals == [.hangup])
        #expect(m.attach(.chat(v1)) === newer)
        fakes[1].emitData("old")
        fakes[1].emitExit(0)
        fakes[0].emitData("new")
        await waitUntil { reader.texts == ["new"] && fakes[1].waiting == 0 }
        #expect(!reader.ended)
        #expect(fakes[1].waiting == 0)
        #expect(newer.write(Array("x".utf8)))
        #expect(fakes[0].written == [Array("x".utf8)])
    }

    // The output and the exit of a child that come before its spawn ends wait for the end of the
    // open. Then they come in later turns of the main actor: the caller gets the open attach
    // first.
    @Test func theEventsOfTheSpawnTimeComeAfterTheOpen() async throws {
        let spawner = FakeSpawner()
        let m = manager(spawner)
        spawner.holdNext(nil) { child in child.emitData("early") }
        let first = try #require(try await open(m, .chat(v1)))
        let firstReader = Reader(first)
        #expect(first.pid == 4242)
        await waitUntil { firstReader.texts == ["early"] }
        spawner.holdNext(nil) { child in
            child.emitData("last")
            child.emitExit(3)
        }
        let second = try #require(try await open(m, .chat(v2)))
        #expect(second.isOpen)
        #expect(m.attach(.chat(v2)) === second)
        let secondReader = Reader(second)
        await waitUntil { secondReader.ended }
        #expect(secondReader.texts == ["last"])
        #expect(secondReader.code == 3)
        #expect(m.attach(.chat(v2)) == nil)
    }
}

// The trust run (docs/behaviour/pty.md, "The trust run"): claude with no arguments in a folder
// that TrustRuns.check allowed. It is never one of the attaches of the views.
@MainActor
@Suite("PTY manager trust run", .testTimeLimit)
struct PTYManagerTrustTests {
    // A folder below a root in a temporary folder, and its check.
    private struct Clone {
        let folder: TemporaryFolder
        let run: CheckedTrustRun

        init() async throws {
            folder = try TemporaryFolder()
            let root = folder.realPath + "/repos"
            try FileManager.default.createDirectory(
                atPath: root + "/owner/repo", withIntermediateDirectories: true)
            run = try #require(
                await TrustRuns.check(
                    folder: URL(filePath: root + "/owner/repo"),
                    root: URL(filePath: root, directoryHint: .isDirectory)))
        }
    }

    @Test func aTrustRunIsNeverInTheList() async throws {
        let clone = try await Clone()
        defer { clone.folder.remove() }
        let spawner = FakeSpawner()
        let m = manager(spawner)
        let chat = try #require(try await open(m, .chat(v1)))
        let run = try #require(try await m.openTrust(clone.run, size: size))
        #expect(run.isOpen)
        let spawn = try #require(spawner.spawns.last)
        #expect(spawn.program == "/bin/claude")
        #expect(spawn.arguments == [])
        #expect(spawn.directory == clone.run.folder)
        #expect(spawn.environment["TERM"] == "xterm-256color")
        #expect(m.list().map(\.view) == [.chat(v1)])
        #expect(m.list().allSatisfy { $0 === chat })
        #expect(m.attach(.chat(v1)) === chat)
        // The output and the input of the run go only to the run.
        #expect(run.write(Array("y".utf8)))
        #expect(spawner.fakes[1].written == [Array("y".utf8)])
        #expect(spawner.fakes[0].written.isEmpty)
    }

    @Test func closeAllClosesTheTrustRun() async throws {
        let clone = try await Clone()
        defer { clone.folder.remove() }
        let spawner = FakeSpawner()
        let m = manager(spawner)
        let run = try #require(try await m.openTrust(clone.run, size: size))
        var chunks: [[UInt8]] = []
        var ended = false
        Task {
            for await chunk in run.output { chunks.append(chunk) }
            ended = true
        }
        spawner.fakes[0].emitData("trust?")
        await waitUntil { chunks == [Array("trust?".utf8)] }
        m.closeAll()
        #expect(spawner.fakes[0].signals == [.hangup])
        #expect(!run.isOpen)
        #expect(!run.write(Array("x".utf8)))
        await waitUntil { ended }
        #expect(await run.exit == nil)
    }

    @Test func aSecondTrustRunClosesTheFirst() async throws {
        let clone = try await Clone()
        defer { clone.folder.remove() }
        let spawner = FakeSpawner()
        let m = manager(spawner)
        let first = try #require(try await m.openTrust(clone.run, size: size))
        let second = try #require(try await m.openTrust(clone.run, size: size))
        #expect(spawner.fakes[0].signals == [.hangup])
        #expect(!first.isOpen)
        #expect(second.isOpen)
        #expect(spawner.fakes[1].signals.isEmpty)
        // The exit of the second run ends it, with its code.
        spawner.fakes[1].emitExit(0)
        #expect(await second.exit == 0)
        #expect(!second.isOpen)
    }
}
