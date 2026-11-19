import BifrostTestSupport
import Foundation
import Network
import Synchronization
import Testing

@testable import BifrostFoundation
@testable import BifrostLive
@testable import BifrostSessions

// The socket tests of the Live details server. They run the real server (LiveServer) on a Unix
// socket in a TemporaryFolder, never on a real path. The client is UnixClient, with the system
// calls. The clock of the request timeout is a ManualClock, so only a test moves it.
//
// The server calls onEvent before it closes the connection. So when a client sees the end of
// the answer, each event is in the list, and a test does not wait for it.

private let sessionId = "73b5ca76-a4a8-4f97-9764-e41657296414"
private let good =
    #"{"at":1000,"kind":"turn.complete","reason":"answer","seq":1,"sid":"\#(sessionId)","v":1}"#

private let closed = LiveServerState(listening: false)
private let open = LiveServerState(listening: true)

// The answers of the server.
private let noContent = "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
private let badRequest =
    "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
private let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
private let payloadTooLarge =
    "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

// A request as the HTTP client of Node sends it: a Host line and the length of the body.
private func request(_ method: String, _ target: String, _ body: String = "") -> [UInt8] {
    let length = body.utf8.count
    return bytes("\(method) \(target) HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(length)"
        + "\r\n\r\n\(body)")
}

// Send the bytes on a new connection. The result is the whole answer, until the server closes
// the connection.
private func exchange(_ path: String, _ data: [UInt8]) async throws -> String {
    let client = try UnixClient(path: path)
    defer { client.close() }
    _ = await client.write(data)
    guard let answer = await client.readToEnd() else { return "no end after 5 s" }
    return String(decoding: answer, as: UTF8.self)
}

// The status of the answer to one request, or 0 for no answer.
private func send(
    _ path: String, _ method: String, _ target: String, _ body: String = ""
) async throws -> Int {
    let answer = try await exchange(path, request(method, target, body))
    guard answer.hasPrefix("HTTP/1.1 ") else { return 0 }
    return Int(answer.dropFirst(9).prefix(3)) ?? 0
}

private func mode(_ path: String) -> mode_t {
    var info = stat()
    return lstat(path, &info) == 0 ? info.st_mode & 0o777 : 0
}

private func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

// A listener log that records each event.
private final class ListenerLogRecorder: ListenerLog {
    private let recorded = Mutex<[ListenerLogEvent]>([])

    var events: [ListenerLogEvent] { recorded.withLock { $0 } }

    func record(_ event: ListenerLogEvent) { recorded.withLock { $0.append(event) } }
}

@MainActor
private final class Events {
    var all: [LiveEvent] = []
    // Each call of onEvents.
    var batches: [[LiveEvent]] = []
    let log = ListenerLogRecorder()
    var logs: [ListenerLogEvent] { log.events }
}

// The points of a start where a test stops the server.
enum StopPoint: CaseIterable, Sendable {
    // Before the task of the start runs.
    case beforeTheStart
    // The listen made the socket file, and the listener is not ready (the bound step).
    case afterTheBind
    // The server listens.
    case listening
}

// The bound step of the listener of a server. It holds the listen after the bind while a test
// gives it a gate. A test can also give it a job for the next turn of the main actor: the step
// returns at once, and the listener applies the ready state in the same turn (the socket file
// gets mode 0600). So the job runs after the ready state and before the listen gives its result
// in a later turn. The main actor runs its jobs in the order of their arrival.
@MainActor
final class BoundHold {
    var gate: TestGate?
    var nextTurn: (@MainActor () -> Void)?

    func step() async {
        await gate?.pass()
        if let job = nextTurn {
            nextTurn = nil
            Task { @MainActor in job() }
        }
    }
}

// What a failure of the listener at the end of a listen found.
@MainActor
private final class Failure {
    let came = TestSignal()
    // The mode of the socket file just before the failure, and true when the file is there just
    // after it.
    var modeBefore: mode_t = 0
    var fileAfter = true
    // The start that began at once after the failure, in the same turn of the main actor.
    var next: Task<LiveServerState, Never>?
}

// A server on <folder>/run/l.sock. Its wall clock gives 1005 ms after 1970. Its batch window is
// zero unless a test gives one, so a line goes to the events in the next turn of the main actor.
@MainActor
private func make(
    _ folder: TemporaryFolder, clock: ManualClock = ManualClock(),
    requestTimeout: Duration = .seconds(5), batchWindow: Duration = .zero,
    socketPath: String? = nil, hold: BoundHold? = nil
) -> (server: LiveServer, socketPath: String, events: Events) {
    let path = socketPath ?? folder.appending("run/l.sock")
    let events = Events()
    var step: UnixSocketListener.BoundStep?
    if let hold { step = { await hold.step() } }
    let server = LiveServer(
        socketPath: path, clock: clock, now: { Date(timeIntervalSince1970: 1.005) },
        requestTimeout: requestTimeout, batchWindow: batchWindow,
        onEvents: { lines in
            events.all += lines
            events.batches.append(lines)
        }, log: events.log, boundStep: step)
    return (server, path, events)
}

// Make the folder of the socket with mode 0700.
private func makeRunFolder(_ folder: TemporaryFolder) throws -> String {
    let run = folder.appending("run")
    try FileManager.default.createDirectory(
        atPath: run, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return run
}

private func isSocket(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK
}

@MainActor
@Suite("Live server", .timeLimit(.minutes(1)))
struct LiveServerTests {
    @Test("the server listens on a socket with mode 0600 in a directory with mode 0700")
    func startListens() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let (server, socketPath, _) = make(folder)
        defer { server.stop() }
        #expect(await server.start() == open)
        #expect(mode(socketPath) == 0o600)
        #expect(mode(folder.appending("run")) == 0o700)
        #expect(await server.start() == open)
        #expect(server.state == open)
    }

    @Test("a good line gives 204 and one event")
    func aGoodLine() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let (server, socketPath, events) = make(folder)
        defer { server.stop() }
        _ = await server.start()
        #expect(try await send(socketPath, "POST", "/v1/event", good) == 204)
        #expect(events.all.count == 1)
        if case .state(let event)? = events.all.first {
            #expect(event.name == .stop)
        } else {
            Issue.record("no state event: \(events.all)")
        }
    }

    @Test("a bad line answers 204 and makes no event")
    func aBadLine() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let (server, socketPath, events) = make(folder)
        defer { server.stop() }
        _ = await server.start()
        #expect(try await send(socketPath, "POST", "/v1/event", "not json") == 204)
        #expect(events.all.isEmpty)
    }

    @Test
    func anotherPathOrMethod() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let (server, socketPath, events) = make(folder)
        defer { server.stop() }
        _ = await server.start()
        #expect(try await send(socketPath, "GET", "/v1/event") == 404)
        #expect(try await send(socketPath, "POST", "/other", good) == 404)
        #expect(events.all.isEmpty)
    }

    @Test("a body over 65536 bytes answers 413 and makes no event")
    func aBodyOver65536() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let (server, socketPath, events) = make(folder)
        defer { server.stop() }
        _ = await server.start()
        let large = String(repeating: "x", count: 70_000)
        #expect(try await send(socketPath, "POST", "/v1/event", large) == 413)
        let head = "POST /v1/event HTTP/1.1\r\nHost: bifrost\r\nContent-Length: 70000\r\n\r\n"
        let raw = try await exchange(socketPath, bytes(head + large))
        #expect(raw.hasPrefix("HTTP/1.1 413"))
        #expect(events.all.isEmpty)
    }

    @Test
    func aRequestWithNoEnd() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let clock = ManualClock()
        let (server, socketPath, events) = make(
            folder, clock: clock, requestTimeout: .milliseconds(200))
        defer { server.stop() }
        _ = await server.start()
        let client = try UnixClient(path: socketPath)
        defer { client.close() }
        let head = "POST /v1/event HTTP/1.1\r\nHost: bifrost\r\nContent-Length: 500\r\n\r\n"
        _ = await client.write(bytes(head + #"{"v":"#))
        await clock.waitForSleepers(1)
        // 1 ms before the timeout, the connection is open: a read waits.
        clock.advance(by: .milliseconds(199))
        #expect(await client.readToEnd(limit: .milliseconds(100)) == nil)
        clock.advance(by: .milliseconds(1))
        // The server closes the connection with no answer.
        #expect(await client.readToEnd() == [])
        #expect(events.all.isEmpty)
    }

    @Test
    func startReplacesAStaleSocket() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let (server, socketPath, _) = make(folder)
        defer { server.stop() }
        mkdir(folder.appending("run"), 0o700)
        try makeStaleSocket(socketPath)
        #expect(exists(socketPath))
        #expect(await server.start() == open)
    }

    @Test
    func startDoesNotTakeASocketThatAnswers() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let (server, socketPath, events) = make(folder)
        defer { server.stop() }
        mkdir(folder.appending("run"), 0o700)
        // The other program answers each connection until the test ends.
        let other = try UnixGreeter(path: socketPath, text: "hi")
        defer { other.close() }
        let text = "Another program listens on \(socketPath)."
        #expect(await server.start() == LiveServerState(listening: false, error: text))
        // The server logs why it does not listen.
        #expect(events.logs == [.notListening(.inUse(socketPath))])
        server.stop()
        #expect(try await exchange(socketPath, []) == "hi")
    }

    @Test
    func startNeverDeletesAFile() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let (server, socketPath, _) = make(folder)
        defer { server.stop() }
        mkdir(folder.appending("run"), 0o700)
        try "keep me".write(toFile: socketPath, atomically: false, encoding: .utf8)
        let text = "\(socketPath) exists and is not a socket. Bifrost did not change it."
        #expect(await server.start() == LiveServerState(listening: false, error: text))
        // A stop clears the error.
        server.stop()
        #expect(server.state == closed)
        #expect(try String(contentsOfFile: socketPath, encoding: .utf8) == "keep me")
    }

    @Test
    func stopClosesTheServer() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let clock = ManualClock()
        let (server, socketPath, _) = make(folder, clock: clock)
        defer { server.stop() }
        // A stop before a start does nothing.
        server.stop()
        #expect(server.state == closed)
        _ = await server.start()
        let client = try UnixClient(path: socketPath)
        defer { client.close() }
        // The timer of the connection waits, so the server has the connection.
        await clock.waitForSleepers(1)
        server.stop()
        #expect(!exists(socketPath))
        #expect(server.state.listening == false)
        #expect(await client.readToEnd() == [])
        // A second stop does nothing.
        server.stop()
        #expect(server.state == closed)
    }

    // The first start runs until it waits, then the stop, then the second start. Task.immediate
    // runs the first start at once until its first wait. A yield does not make sure of that
    // order under load. The second start waits until the first start ends, so one socket file
    // stays.
    @Test
    func aStopThenAStartWithoutWaiting() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let (server, _, _) = make(folder)
        defer { server.stop() }
        let first = Task.immediate { await server.start() }
        server.stop()
        let second = await server.start()
        #expect(await first.value == closed)
        #expect(second == open)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.appending("run"))
        // The lock file stays beside the socket.
        #expect(names.sorted() == ["l.lock", "l.sock"])
    }

    // A second start while a start runs waits for it. Two listens on one path cannot both
    // listen, so two good results show one prepare and one listen.
    @Test
    func twoStartsAtOnceGiveOneListener() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let (server, socketPath, events) = make(folder)
        defer { server.stop() }
        let first = Task.immediate { await server.start() }
        let second = await server.start()
        #expect(await first.value == open)
        #expect(second == open)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.appending("run"))
        // The lock file stays beside the socket.
        #expect(names.sorted() == ["l.lock", "l.sock"])
        #expect(try await send(socketPath, "POST", "/v1/event", good) == 204)
        #expect(events.all.count == 1)
    }

    // A stop at each point of a start: before the start runs, after the bind, and when the
    // server listens. The start gives "not listening", or "listening" when it ended before the
    // stop. After the stop, no listener and no socket file stay.
    @Test(arguments: StopPoint.allCases)
    func aStopAtEachPointOfAStartLeavesNoListener(_ point: StopPoint) async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let hold = BoundHold()
        let (server, socketPath, _) = make(folder, hold: hold)
        defer { server.stop() }
        let start = try await stop(server, at: point, hold)
        #expect(await start.value == (point == .listening ? open : closed))
        #expect(server.state == closed)
        #expect(!exists(socketPath))
    }

    // A start at once after a stop at each point of a start listens. It waits until the
    // cancelled start ends, so its probe does not find the socket of the old listen.
    @Test(arguments: StopPoint.allCases)
    func aStartAfterAStopAtEachPointListens(_ point: StopPoint) async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let hold = BoundHold()
        let (server, socketPath, _) = make(folder, hold: hold)
        defer { server.stop() }
        let first = try await stop(server, at: point, hold)
        #expect(await server.start() == open)
        #expect(server.state == open)
        #expect(exists(socketPath))
        #expect(try await send(socketPath, "POST", "/v1/event", good) == 204)
        _ = await first.value
        server.stop()
    }

    // Start the server and stop it at the point. The result is the task of the start.
    private func stop(_ server: LiveServer, at point: StopPoint, _ hold: BoundHold)
        async throws -> Task<LiveServerState, Never>
    {
        let gate = TestGate()
        defer { gate.openAll() }
        if point == .afterTheBind { hold.gate = gate }
        defer { hold.gate = nil }
        let start = Task.immediate { await server.start() }
        switch point {
        case .beforeTheStart:
            server.stop()
        case .afterTheBind:
            try #require(await gate.waitUntilHolding())
            server.stop()
        case .listening:
            #expect(await start.value == open)
            server.stop()
        }
        return start
    }

    // A stop before the task of a start runs cancels it. That start does nothing: it does not
    // make the folder of the socket, it does not probe, and it does not listen.
    @Test func aStartThatAStopCancelsBeforeItRunsDoesNothing() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let (server, _, _) = make(folder)
        defer { server.stop() }
        let start = Task.immediate { await server.start() }
        server.stop()
        #expect(await start.value == closed)
        #expect(!exists(folder.appending("run")))
        #expect(server.state == closed)
    }

    // The server holds the listener from the start of its listen. A stop when the listen made
    // the socket file, but before the listen is ready, closes the listener at once: the listen
    // never gets ready, so the file never gets mode 0600. The bound step holds the listen at
    // that point. The start ends when the cancel of the listener is complete, and no socket file
    // stays.
    @Test func aStopDuringTheListenEndsTheListenBeforeItIsReady() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let hold = BoundHold()
        let gate = TestGate()
        defer { gate.openAll() }
        hold.gate = gate
        let (server, socketPath, _) = make(folder, hold: hold)
        defer { server.stop() }
        let start = Task.immediate { await server.start() }
        try #require(await gate.waitUntilHolding())
        #expect(exists(socketPath))
        #expect(mode(socketPath) != 0o600)
        server.stop()
        gate.open()
        #expect(await start.value == closed)
        #expect(!exists(socketPath))
        hold.gate = nil
        #expect(await server.start() == open)
        #expect(try await send(socketPath, "POST", "/v1/event", good) == 204)
    }

    // A failed start keeps its error until the result of the next start. The next start tries
    // again.
    @Test
    func aFailedStartIsTriedAgainByTheNextStart() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let (server, socketPath, _) = make(folder)
        defer { server.stop() }
        mkdir(folder.appending("run"), 0o700)
        try "x".write(toFile: socketPath, atomically: false, encoding: .utf8)
        let text = "\(socketPath) exists and is not a socket. Bifrost did not change it."
        let failed = LiveServerState(listening: false, error: text)
        #expect(await server.start() == failed)
        // A failed start after a stop does not set the error.
        server.stop()
        let cancelled = Task.immediate { await server.start() }
        server.stop()
        #expect(await cancelled.value == closed)
        #expect(server.state == closed)
        #expect(await server.start() == failed)
        unlink(socketPath)
        let again = Task.immediate { await server.start() }
        #expect(server.state == failed)
        #expect(await again.value == open)
        #expect(server.state == open)
    }
}

@MainActor
@Suite("the rules of the Live details server", .timeLimit(.minutes(1)))
struct LiveServerRuleTests {
    // The server makes each missing folder of the socket path with mode 0700. Then it sets the
    // mode of the folder of the socket. The folder "a" comes from the first mkdir, and "a/b"
    // from the mkdir after its parent.
    @Test func eachNewFolderOfTheSocketPathGetsMode0700() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let (server, socketPath, _) = make(folder, socketPath: folder.appending("a/b/c/l.sock"))
        defer { server.stop() }
        #expect(await server.start() == open)
        #expect(mode(folder.appending("a")) == 0o700)
        #expect(mode(folder.appending("a/b")) == 0o700)
        #expect(mode(folder.appending("a/b/c")) == 0o700)
        #expect(mode(socketPath) == 0o600)
    }

    // sun_path has 104 bytes with the NUL at its end. A longer path gives an
    // error, not a trap. A path of exactly 103 bytes listens.
    @Test func aSocketPathOver103BytesGivesAnError() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let base = folder.path + "/"
        let fits = base + String(repeating: "s", count: 103 - base.utf8.count)
        let (server, _, _) = make(folder, socketPath: fits)
        defer { server.stop() }
        #expect(fits.utf8.count == 103)
        #expect(await server.start() == open)
        server.stop()
        let long = base + String(repeating: "t", count: 104 - base.utf8.count)
        let (other, _, _) = make(folder, socketPath: long)
        defer { other.stop() }
        let text = "The socket path is too long: \(long)"
        #expect(await other.start() == LiveServerState(listening: false, error: text))
        #expect(!exists(long))
    }

    // With 64 open connections, the server closes a new one at once. A connection that ends
    // makes room for a new one. The count of the refused connections goes to the log one minute
    // after the first of them, or at the stop.
    @Test func the65thOpenConnectionClosesAtOnce() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let clock = ManualClock()
        let (server, socketPath, events) = make(folder, clock: clock)
        defer { server.stop() }
        _ = await server.start()
        var clients: [UnixClient] = []
        defer { for client in clients { client.close() } }
        // Each open connection has a timer, so the count of sleepers is the count of
        // connections that the server has.
        for count in 1...64 {
            clients.append(try UnixClient(path: socketPath))
            await clock.waitForSleepers(count)
        }
        let extra = try UnixClient(path: socketPath)
        defer { extra.close() }
        #expect(await extra.readToEnd() == [])
        // The 64 timers and the minute of the count of refused connections.
        await clock.waitForSleepers(exactly: 65)
        #expect(events.logs.isEmpty)
        let last = clients[63]
        _ = await last.write(request("POST", "/v1/event", good))
        #expect(await last.readToEnd() == bytes(noContent))
        // A connection that got its answer can end on the client before the server drops it.
        await clock.waitForSleepers(exactly: 64)
        #expect(clock.sleeperCount == 64)
        #expect(try await exchange(socketPath, request("POST", "/v1/event", good)) == noContent)
        #expect(events.all.count == 2)
        clock.advance(by: .seconds(60))
        await waitUntil { events.logs == [.refusedConnections(1)] }
        #expect(events.logs == [.refusedConnections(1)])
    }

    // Only the holder of the lock file probes and listens: a second server on the same socket,
    // for example the Dev and the Release app at the same time, does not listen and does not
    // change the socket of the first. When the first stops, the second can listen.
    @Test func aSecondServerOnTheSameSocketFindsTheLockAndDoesNotListen() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let (first, socketPath, events) = make(folder)
        defer { first.stop() }
        let (second, _, _) = make(folder)
        defer { second.stop() }
        #expect(await first.start() == open)
        let text = "Another program listens on \(socketPath)."
        #expect(await second.start() == LiveServerState(listening: false, error: text))
        second.stop()
        #expect(try await send(socketPath, "POST", "/v1/event", good) == 204)
        #expect(events.all.count == 1)
        first.stop()
        #expect(await second.start() == open)
    }

    // A stop removes only the socket file of its own listen: a file that another program put at
    // the path stays.
    @Test func aStopKeepsAFileThatAnotherProgramPutAtTheSocketPath() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let (server, socketPath, _) = make(folder)
        defer { server.stop() }
        #expect(await server.start() == open)
        unlink(socketPath)
        try Data("other".utf8).write(to: URL(fileURLWithPath: socketPath))
        server.stop()
        #expect(FileManager.default.contents(atPath: socketPath) == Data("other".utf8))
    }

    // At the ready state the listener sets the mode with no follow of a link and checks the
    // file: a link at the socket path fails the listen, and its target keeps its mode.
    @Test func aLinkAtTheSocketPathAtTheReadyStateFailsTheListen() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let hold = BoundHold()
        let gate = TestGate()
        defer { gate.openAll() }
        hold.gate = gate
        let (server, socketPath, _) = make(folder, hold: hold)
        defer { server.stop() }
        let target = folder.appending("target")
        try Data("t".utf8).write(to: URL(fileURLWithPath: target))
        chmod(target, 0o644)
        let start = Task { await server.start() }
        await gate.waitUntilHolding()
        unlink(socketPath)
        symlink(target, socketPath)
        gate.open()
        let text = "The socket \(socketPath) is not a socket of this user with mode 0600. "
            + "Bifrost closed it."
        #expect(await start.value == LiveServerState(listening: false, error: text))
        #expect(mode(target) == 0o644)
    }

    // A folder whose access list allows another user is refused, also with the mode 0700.
    @Test func aFolderWhoseAccessListAllowsAnotherUserIsRefused() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let run = folder.appending("run")
        try FileManager.default.createDirectory(atPath: run, withIntermediateDirectories: true)
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone allow list,search", run]
        try chmod.run()
        chmod.waitUntilExit()
        #expect(chmod.terminationStatus == 0)
        let (server, socketPath, _) = make(folder)
        defer { server.stop() }
        let text =
            "Bifrost doesn't listen in \(run), because its access list can let other users in."
        #expect(await server.start() == LiveServerState(listening: false, error: text))
        #expect(!exists(socketPath))
    }

    // Only the holder of the lock file probes and removes a stale socket. A lock that another
    // holds gives inUse and keeps the stale socket. After the release, the server takes the
    // lock, removes the stale socket and listens.
    @Test func aHeldLockKeepsAStaleSocketUntilTheRelease() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let run = try makeRunFolder(folder)
        let (server, socketPath, _) = make(folder)
        defer { server.stop() }
        try makeStaleSocket(socketPath)
        let held = Darwin.open("\(run)/l.lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        #expect(held >= 0 && flock(held, LOCK_EX | LOCK_NB) == 0)
        let text = "Another program listens on \(socketPath)."
        #expect(await server.start() == LiveServerState(listening: false, error: text))
        #expect(isSocket(socketPath))
        close(held)
        #expect(await server.start() == open)
    }

    // A stale socket of another program that comes at the path after the start stays at the
    // stop: the stop removes only the socket file of its own listen.
    @Test func aForeignStaleSocketAfterTheStartSurvivesTheStop() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let (server, socketPath, _) = make(folder)
        defer { server.stop() }
        #expect(await server.start() == open)
        unlink(socketPath)
        try makeStaleSocket(socketPath)
        server.stop()
        #expect(isSocket(socketPath))
    }

    // A link, a FIFO or a file with a second link at the path of the lock file gives
    // notALockFile, and the server changes nothing: no socket, and the item and its target stay.
    @Test func aLockPathThatIsNotAPlainFileOfTheUserChangesNothing() async throws {
        for kind in ["link", "fifo", "hard link"] {
            let folder = try TemporaryFolder(short: true)
            defer { folder.remove() }
            let run = try makeRunFolder(folder)
            let lock = "\(run)/l.lock"
            let target = folder.appending("target")
            try Data("t".utf8).write(to: URL(fileURLWithPath: target))
            switch kind {
            case "link": symlink(target, lock)
            case "fifo": mkfifo(lock, 0o600)
            default: link(target, lock)
            }
            let (server, socketPath, _) = make(folder)
            defer { server.stop() }
            let text =
                "\(lock) is not a regular file of this user with one link. "
                + "Bifrost did not change it."
            let state = await server.start()
            #expect(state == LiveServerState(listening: false, error: text), "\(kind)")
            #expect(!exists(socketPath))
            #expect(exists(lock))
            #expect(FileManager.default.contents(atPath: target) == Data("t".utf8))
        }
    }

    // The first line of a batch starts a wait of the batch window on the clock. The lines in the
    // window go to onEvents in one call, in the order of their arrival, and each answer comes
    // after that call.
    @Test func theLinesOfOneBatchWindowGoToOnEventsInOneCallInOrder() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let clock = ManualClock()
        let (server, socketPath, events) = make(
            folder, clock: clock, batchWindow: .milliseconds(50))
        defer { server.stop() }
        _ = await server.start()
        var answers: [Task<Int, any Error>] = []
        for seq in 1...3 {
            let line = good.replacingOccurrences(of: #""seq":1"#, with: #""seq":\#(seq)"#)
            answers.append(Task { try await send(socketPath, "POST", "/v1/event", line) })
            await waitUntil { server.batchCount == seq }
        }
        #expect(events.batches.isEmpty)
        clock.advance(by: .milliseconds(50))
        for answer in answers { #expect(try await answer.value == 204) }
        #expect(events.batches.count == 1)
        let order = events.all.compactMap { line -> Int? in
            if case .state(let event) = line { return event.seq }
            return nil
        }
        #expect(order == [1, 2, 3])
    }

    // One request for each connection: the server closes the connection after its answer, so
    // a second request on the connection gets no answer. A bad request, and a form that the mod
    // does not send (chunks, HTTP/1.0), close the connection with no answer.
    @Test func everyAnswerClosesTheConnection() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let (server, socketPath, events) = make(folder)
        defer { server.stop() }
        _ = await server.start()
        let cases: [(request: [UInt8], answer: String)] = [
            (request("POST", "/v1/event", good), noContent),
            (request("GET", "/v1/event"), notFound),
            (bytes("POST /v1/event HTTP/1.1\r\nHost: b\r\nContent-Length: 70000\r\n\r\n"),
                payloadTooLarge),
            (bytes("POST /v1/event HTTP/1.1\r\nContent-Length: 2\r\n\r\nhi"), badRequest),
            (bytes("POST /v1/event HTTP/1.1\nHost: b\n\n"), ""),
            (bytes("POST /v1/event HTTP/1.1\r\nHost: b\r\nTransfer-Encoding: chunked\r\n\r\n"
                + "2\r\nhi\r\n0\r\n\r\n"), ""),
            (bytes("POST /v1/event HTTP/1.0\r\nContent-Length: 2\r\n\r\nhi"), ""),
        ]
        for item in cases {
            #expect(try await exchange(socketPath, item.request + item.request) == item.answer)
        }
        #expect(events.all.count == 1)
    }

    // Node answers 400 to an HTTP/1.1 request with no Host line.
    @Test func anHTTP11RequestWithNoHostGets400() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let (server, socketPath, events) = make(folder)
        defer { server.stop() }
        _ = await server.start()
        let length = good.utf8.count
        let http11 = "POST /v1/event HTTP/1.1\r\nContent-Length: \(length)\r\n\r\n\(good)"
        #expect(try await exchange(socketPath, bytes(http11)) == badRequest)
        #expect(events.all.isEmpty)
    }

    // Another method or target gets 404 at the end of the head. The
    // server does not wait for the body, and the size of the body does not matter.
    @Test func anotherMethodOrTargetGets404AtTheEndOfTheHead() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let clock = ManualClock()
        let (server, socketPath, events) = make(folder, clock: clock)
        defer { server.stop() }
        _ = await server.start()
        let partial = "POST /other HTTP/1.1\r\nHost: b\r\nContent-Length: 500\r\n\r\n{\"v\":"
        #expect(try await exchange(socketPath, bytes(partial)) == notFound)
        let large = "GET /v1/event HTTP/1.1\r\nHost: b\r\nContent-Length: 70000\r\n\r\n"
        #expect(try await exchange(socketPath, bytes(large)) == notFound)
        #expect(events.all.isEmpty)
    }

    // A client that ends its side of the connection before the request is complete gets no
    // answer, and the server closes the connection at once, as Node does.
    @Test func aClientThatEndsAnOpenRequestGetsNoAnswer() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let clock = ManualClock()
        let (server, socketPath, events) = make(folder, clock: clock)
        defer { server.stop() }
        _ = await server.start()
        let client = try UnixClient(path: socketPath)
        defer { client.close() }
        let head = "POST /v1/event HTTP/1.1\r\nHost: b\r\nContent-Length: 500\r\n\r\n"
        _ = await client.write(bytes(head + #"{"v":"#))
        client.endWriting()
        #expect(await client.readToEnd() == [])
        #expect(clock.sleeperCount == 0)
        #expect(events.all.isEmpty)
    }

    // An error of the folder names the folder and gives the text of the system (user decision,
    // 2026-11-15). A file at the folder path gives EEXIST. A path through a file gives ENOTDIR.
    // A parent that the user cannot write gives EACCES, with the path of the folder, not of the
    // parent.
    @Test func aFolderErrorNamesTheFolderAndTheReason() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        try "x".write(toFile: folder.appending("run"), atomically: false, encoding: .utf8)
        let (file, _, _) = make(folder)
        defer { file.stop() }
        let atFile = "Cannot create the folder \(folder.appending("run")): File exists."
        #expect(await file.start() == LiveServerState(listening: false, error: atFile))
        let (through, _, _) = make(folder, socketPath: folder.appending("run/a/l.sock"))
        defer { through.stop() }
        let throughFile =
            "Cannot create the folder \(folder.appending("run/a")): Not a directory."
        #expect(await through.start() == LiveServerState(listening: false, error: throughFile))
        mkdir(folder.appending("ro"), 0o500)
        defer { chmod(folder.appending("ro"), 0o700) }
        let (denied, _, _) = make(folder, socketPath: folder.appending("ro/a/run/l.sock"))
        defer { denied.stop() }
        let noWrite =
            "Cannot create the folder \(folder.appending("ro/a/run")): Permission denied."
        #expect(await denied.start() == LiveServerState(listening: false, error: noWrite))
    }

    // The probe gives the text of a failed connect, with the path and the text of the system. A
    // socket with mode 0000 refuses the connect with EACCES.
    @Test func aConnectErrorNamesTheSocketAndTheReason() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let (server, socketPath, _) = make(folder)
        defer { server.stop() }
        mkdir(folder.appending("run"), 0o700)
        let other = try UnixGreeter(path: socketPath, text: "hi")
        defer { other.close() }
        chmod(socketPath, 0o000)
        let text = "Cannot connect to \(socketPath): Permission denied."
        #expect(await server.start() == LiveServerState(listening: false, error: text))
        #expect(exists(socketPath))
    }

    // Each call of the server and of the probe has its own action, then the path and the text
    // of the system (user decision, 2026-11-15). A rare error number has the same form.
    @Test func eachCallOfTheServerHasItsOwnAction() {
        let path = "/tmp/a"
        func text(_ code: Int32, _ call: SystemCall) -> String {
            ErrorText.system(code, call: call, path: path)
        }
        #expect(
            text(EACCES, .createFolder) == "Cannot create the folder /tmp/a: Permission denied.")
        #expect(
            text(ENOENT, .setPermissions)
                == "Cannot set the permissions of /tmp/a: No such file or directory.")
        #expect(text(ENOTDIR, .check) == "Cannot check /tmp/a: Not a directory.")
        #expect(text(EACCES, .remove) == "Cannot remove /tmp/a: Permission denied.")
        #expect(text(EADDRINUSE, .listen) == "Cannot listen on /tmp/a: Address already in use.")
        #expect(text(ECONNREFUSED, .connect) == "Cannot connect to /tmp/a: Connection refused.")
        #expect(
            text(EMFILE, .createSocket)
                == "Cannot create a socket for /tmp/a: Too many open files.")
        #expect(
            text(EBADF, .setUpSocket)
                == "Cannot set up the socket for /tmp/a: Bad file descriptor.")
        #expect(
            text(EINTR, .waitForAnswer)
                == "Cannot get an answer from /tmp/a: Interrupted system call.")
        #expect(
            text(ENAMETOOLONG, .createFolder)
                == "Cannot create the folder /tmp/a: File name too long.")
        #expect(text(EIO, .createFolder) == "Cannot create the folder /tmp/a: Input/output error.")
    }

    // When the listener fails after the listen, the server logs it, goes to the
    // error state and closes. A later start listens again.
    @Test func aListenerFailureAfterTheListenGivesAnErrorAndALogLine() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let clock = ManualClock()
        let (server, socketPath, events) = make(folder, clock: clock)
        defer { server.stop() }
        #expect(await server.start() == open)
        let client = try UnixClient(path: socketPath)
        defer { client.close() }
        await clock.waitForSleepers(1)
        server.listenerFailed(.system(.listen, path: socketPath, code: EPERM))
        let text = "Cannot listen on \(socketPath): Operation not permitted."
        #expect(server.state == LiveServerState(listening: false, error: text))
        #expect(events.logs == [.failed(.system(.listen, path: socketPath, code: EPERM))])
        // A second failure changes nothing.
        server.listenerFailed(.system(.listen, path: socketPath, code: EIO))
        #expect(server.state == LiveServerState(listening: false, error: text))
        #expect(events.logs.count == 1)
        #expect(!exists(socketPath))
        #expect(await client.readToEnd() == [])
        #expect(await server.start() == open)
        #expect(try await send(socketPath, "POST", "/v1/event", good) == 204)
    }

    // A failure of the listener during the listen: the listen made the socket file and is not
    // ready (the bound step holds it). The failure ends the start as a stop does: the start gives
    // the error, and the server logs it. A start at once after the failure listens again.
    @Test func aListenerFailureDuringTheListenEndsTheStart() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let hold = BoundHold()
        let gate = TestGate()
        defer { gate.openAll() }
        hold.gate = gate
        let (server, socketPath, events) = make(folder, hold: hold)
        defer { server.stop() }
        let failed = LiveServerState(error: "Cannot listen on \(socketPath): Input/output error.")
        let start = Task.immediate { await server.start() }
        try #require(await gate.waitUntilHolding())
        #expect(exists(socketPath))
        #expect(mode(socketPath) != 0o600)
        server.listenerFailed(.system(.listen, path: socketPath, code: EIO))
        #expect(events.logs == [.failed(.system(.listen, path: socketPath, code: EIO))])
        hold.gate = nil
        let next = Task.immediate { await server.start() }
        gate.open()
        #expect(await start.value == failed)
        #expect(await next.value == open)
        #expect(server.state == open)
        #expect(exists(socketPath))
        #expect(try await send(socketPath, "POST", "/v1/event", good) == 204)
        #expect(events.logs.count == 1)
    }

    // A failure of the listener at the end of the listen: the listen is ready (the socket file
    // has mode 0600), and the start did not go on yet. The failure closes the listener and
    // removes the socket file. The start gives the error. A start at once after the failure does
    // not wait for the result of the failed start: it listens again.
    @Test func aListenerFailureAtTheEndOfTheListenGivesTheError() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let hold = BoundHold()
        let (server, socketPath, events) = make(folder, hold: hold)
        defer { server.stop() }
        let failed = LiveServerState(error: "Cannot listen on \(socketPath): Input/output error.")
        let failure = Failure()
        hold.nextTurn = {
            failure.modeBefore = mode(socketPath)
            server.listenerFailed(.system(.listen, path: socketPath, code: EIO))
            failure.fileAfter = exists(socketPath)
            failure.next = Task.immediate { await server.start() }
            failure.came.send()
        }
        let start = Task.immediate { await server.start() }
        try #require(await failure.came.wait(for: "the failure after the ready state"))
        #expect(failure.modeBefore == 0o600)
        #expect(!failure.fileAfter)
        #expect(await start.value == failed)
        #expect(events.logs == [.failed(.system(.listen, path: socketPath, code: EIO))])
        #expect(await failure.next?.value == open)
        #expect(try await send(socketPath, "POST", "/v1/event", good) == 204)
    }

    // The shell closes the old listener and listens again on one socket file.
    @Test func aStartAfterAStopListensOnTheSocketAgain() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let (server, socketPath, events) = make(folder)
        defer { server.stop() }
        #expect(await server.start() == open)
        server.stop()
        #expect(!exists(socketPath))
        #expect(await server.start() == open)
        #expect(try await send(socketPath, "POST", "/v1/event", good) == 204)
        #expect(events.all.count == 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.appending("run"))
        #expect(names.sorted() == ["l.lock", "l.sock"])
    }
}
