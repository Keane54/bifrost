import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostApp
@testable import BifrostFoundation

// The debug test port: a Unix socket in the test home. One
// JSON line in, one JSON line out, then the server closes the connection. The tests run the real
// server in a TemporaryFolder test home, never on a real path. The client is UnixClient, with
// the system calls.

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

// The requests that the handler got, and the requests whose answer went to the client.
@MainActor
private final class Requests {
    var handled: [TestPortRequest] = []
    var answered: [TestPortRequest] = []
    let log = ListenerLogRecorder()
    var logs: [ListenerLogEvent] { log.events }
}

// A server on the test port of a plan with the folder as its test home. The handler answers a
// state request with an empty state, and each other request with ok.
@MainActor
private func make(
    _ folder: TemporaryFolder, boundStep: UnixSocketListener.BoundStep? = nil
) throws -> (
    server: TestPortServer, socketPath: String, requests: Requests
) {
    let identity = try #require(AppIdentity(bundleID: "com.example.app.native-dev"))
    let home = URL(fileURLWithPath: folder.path, isDirectory: true)
    let plan = StartPlan(
        identity: identity, home: home, realHome: URL(fileURLWithPath: "/Users/someone"),
        testHome: true, folders: DataFolders(identity: identity, home: home))
    let socketPath = try #require(plan.testPort)
    let requests = Requests()
    let server = TestPortServer(
        socketPath: socketPath,
        handle: { request in
            requests.handled.append(request)
            return request == .state ? ["frames": [], "chats": []] : ["ok": true]
        },
        log: requests.log, boundStep: boundStep)
    server.onAnswered = { requests.answered.append($0) }
    return (server, socketPath, requests)
}

// Send the bytes on a new connection, then end the side of the client. The result is the whole
// answer, until the server closes the connection. The handler runs on the main actor, so the read
// waits up to 30 s, as the request timeout of the server: in a full parallel run the main actor
// can stop for some seconds.
private func exchange(_ path: String, _ text: String, end: Bool = false) async throws -> String {
    let client = try UnixClient(path: path)
    defer { client.close() }
    _ = await client.write(Array(text.utf8))
    if end { client.endWriting() }
    guard let answer = await client.readToEnd(limit: .seconds(30)) else {
        return "no end after 30 s"
    }
    return String(decoding: answer, as: UTF8.self)
}

// The first line of a connection from its chunks: the server gives the bytes until now after
// each chunk.
@Suite("the first line of a test port connection")
struct TestPortFirstLineTests {
    private func feed(_ chunks: [String], end: Bool = false) -> TestPortServer.FirstLine {
        var bytes: [UInt8] = []
        var result = TestPortServer.FirstLine.more
        for chunk in chunks {
            bytes += Array(chunk.utf8)
            result = TestPortServer.firstLine(bytes, ended: false)
            if result != .more { return result }
        }
        return end ? TestPortServer.firstLine(bytes, ended: true) : result
    }

    // A request in two chunks, under the limit, is one line.
    @Test func aLineInTwoChunksIsOneLine() {
        #expect(feed([#"{"op":"#, #""state"}"# + "\r\n"]) == .line(Array(#"{"op":"state"}"#.utf8)))
        #expect(feed([#"{"op":"#]) == .more)
        #expect(feed([#"{"op":"state"}"#], end: true) == .line(Array(#"{"op":"state"}"#.utf8)))
    }

    // A first chunk of exactly the limit with no break waits for more. The break in the next
    // chunk makes the line one byte over the limit: a bad request.
    @Test func aLongLineWithItsBreakInALaterChunkIsTooLong() {
        let limit = String(repeating: "a", count: TestPortServer.lineLimit)
        #expect(feed([limit]) == .more)
        #expect(feed([limit, "a\n"]) == .tooLong)
        #expect(feed([limit, "\n"]) == .line(Array(limit.utf8)))
    }
}

@MainActor
@Suite("test port server", .testTimeLimit)
struct TestPortServerTests {
    // The socket is <test home>/.bifrost-native-dev/test.sock. Only the user may connect: the
    // socket has mode 0600 in a folder with mode 0700. A stop removes the socket.
    @Test func theTestPortSocketIsInTheTestHomeWithMode0600() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let (server, socketPath, requests) = try make(folder)
        defer { server.stop() }
        #expect(socketPath == folder.appending(".bifrost-native-dev/test.sock"))
        #expect(await server.start())
        #expect(mode(socketPath) == 0o600)
        #expect(mode(folder.appending(".bifrost-native-dev")) == 0o700)
        #expect(requests.logs.isEmpty)
        server.stop()
        #expect(!exists(socketPath))
    }

    // A stop during the listen closes the listener. The bound step holds the listen after the
    // bind, so the socket file exists and the listener is not ready. The start gives false when
    // the cancel of the listener is complete, and no socket file stays.
    @Test func aStopDuringTheListenGivesFalseAndLeavesNoSocketFile() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let bound = TestGate()
        defer { bound.openAll() }
        let (server, socketPath, _) = try make(folder, boundStep: { await bound.pass() })
        defer { server.stop() }
        let start = Task.immediate { await server.start() }
        try #require(await bound.waitUntilHolding())
        #expect(exists(socketPath))
        #expect(mode(socketPath) != 0o600)
        server.stop()
        bound.open()
        #expect(await start.value == false)
        #expect(!exists(socketPath))
    }

    // One line in, one line out: the answer of the handler, then the server closes the
    // connection. A second line on the connection gets no second answer.
    @Test func aStateRequestGetsOneAnswerLine() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let (server, socketPath, requests) = try make(folder)
        defer { server.stop() }
        #expect(await server.start())
        let line = #"{"op":"state"}"# + "\n"
        let answer = try await exchange(socketPath, line + line)
        #expect(answer == #"{"chats":[],"frames":[]}"# + "\n")
        #expect(requests.handled == [.state])
        // The server calls onAnswered after the send completes. The client can read the answer
        // and the end of the connection before that call.
        await waitUntil { requests.answered == [.state] }
        // A line with no line break, then the end of the stream of the client, is a request too.
        #expect(try await exchange(socketPath, #"{"op":"quit"}"#, end: true) == "{\"ok\":true}\n")
        #expect(requests.handled == [.state, .quit])
    }

    // A line that is not a request gets the bad request line, and the handler does not get it.
    // A line over the limit gets it too, before its end.
    @Test func aBadLineGetsBadRequest() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let (server, socketPath, requests) = try make(folder)
        defer { server.stop() }
        #expect(await server.start())
        let bad = #"{"error":"bad request"}"# + "\n"
        #expect(try await exchange(socketPath, "state\n") == bad)
        #expect(try await exchange(socketPath, #"{"op":"type","text":"é"}"# + "\n") == bad)
        #expect(try await exchange(socketPath, "", end: true) == bad)
        let long = String(repeating: "a", count: TestPortServer.lineLimit + 1)
        #expect(try await exchange(socketPath, long) == bad)
        #expect(requests.handled.isEmpty)
        #expect(requests.answered.isEmpty)
    }

    // A line over the limit is bad. The line is a good type request. A request under the limit
    // works. TestPortFirstLineTests feed the chunks of a line one at a time.
    @Test func aLongLineGetsBadRequest() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let (server, socketPath, requests) = try make(folder)
        defer { server.stop() }
        #expect(await server.start())
        let bad = #"{"error":"bad request"}"# + "\n"
        let head = #"{"op":"type","text":""#
        let first = head + String(repeating: "a", count: TestPortServer.lineLimit - head.count)
        #expect(try await exchange(socketPath, first + #"a"}"# + "\n") == bad)
        #expect(
            try await exchange(socketPath, #"{"op":"state"}"# + "\n")
                == #"{"chats":[],"frames":[]}"# + "\n")
        #expect(requests.handled == [.state])
    }

    // The server never listens on a socket of another program, and it logs why.
    @Test func aSocketOfAnotherProgramStopsTheStart() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let (server, socketPath, requests) = try make(folder)
        defer { server.stop() }
        mkdir(folder.appending(".bifrost-native-dev"), 0o700)
        let other = try UnixGreeter(path: socketPath, text: "busy")
        defer { other.close() }
        #expect(await server.start() == false)
        #expect(requests.logs == [.notListening(.inUse(socketPath))])
        #expect(exists(socketPath))
    }
}
