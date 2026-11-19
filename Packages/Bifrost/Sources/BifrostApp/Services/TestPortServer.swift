// The debug test port (docs/behaviour/shell.md, "The test port"): a Unix socket in the test home.
// The smoke test drives the app with it. It can type into a session, so:
// - only a Debug build has this code (#if DEBUG), and the app makes and starts it inside #if DEBUG
//   too;
// - the app starts it only when StartPlan.testPort has a socket: the development app with a test
//   home, in its own dot folder, never in the real home or in a folder of the Electron app;
// - the socket has mode 0600 in a folder with mode 0700 that the user owns and that is not a link
//   (the shared UnixSocketListener).
//
// Each connection takes one line: one JSON object (TestPortMessage), up to a line break or the end
// of the stream of the client. The server gives the request to handle and sends the answer as one
// JSON line, then closes the connection. A line that is not a request gets the bad request line,
// and handle does not get it. The server logs no request and no answer: a request can hold text for
// a session.
#if DEBUG
import BifrostFoundation
import Foundation

@MainActor
public final class TestPortServer {
    // The most bytes of a line, with no line break. A longer line is a bad request.
    nonisolated static let lineLimit = 65_536
    // The time limit of one connection: the line and the answer. A type request of a long text
    // can take a few seconds.
    static let requestTimeout = Duration.seconds(30)
    static let maxConnections = 8

    private enum Phase {
        case waiting, starting, listening, stopped
    }

    private let socketPath: String
    private let handle: (TestPortRequest) async -> JSONValue
    private let log: any ListenerLog
    private let clock: any Clock<Duration>
    private var phase = Phase.waiting
    private var listener: UnixSocketListener?
    // The wait for the end of the listener that listens. A failure of the listener ends it.
    private var watch: Task<Void, Never>?
    // The request of each answer, after the send of the answer. The quit request of the app uses
    // it, so the client gets the answer before the app stops.
    public var onAnswered: ((TestPortRequest) -> Void)?
    private let boundStep: UnixSocketListener.BoundStep?

    // handle gets each request and gives its answer. The server logs one event when it does not
    // listen, or when its listener fails.
    public convenience init(
        socketPath: String, handle: @escaping (TestPortRequest) async -> JSONValue
    ) {
        self.init(
            socketPath: socketPath, handle: handle,
            log: SystemListenerLog(category: "test-port", server: "Test port"))
    }

    // A test gives its own log, and can give a bound step (UnixSocketListener.BoundStep).
    package init(
        socketPath: String, handle: @escaping (TestPortRequest) async -> JSONValue,
        log: any ListenerLog, boundStep: UnixSocketListener.BoundStep? = nil
    ) {
        self.socketPath = socketPath
        self.handle = handle
        self.log = log
        self.boundStep = boundStep
        clock = ContinuousClock()
    }

    // Listen on the socket. True when the server listens. A second call gives the state of the
    // first. After stop(), the server does not listen again.
    public func start() async -> Bool {
        guard phase == .waiting else { return phase == .listening }
        phase = .starting
        let created = UnixSocketListener(
            socketPath: socketPath,
            limits: .init(
                maxConnections: Self.maxConnections, requestTimeout: Self.requestTimeout),
            clock: clock, boundStep: boundStep)
        listener = created
        // A connection of an old listener gets no answer after a stop.
        let respond: @Sendable (TestPortRequest) async -> [UInt8]? = {
            [weak self, weak created] request in
            guard let created else { return nil }
            return await self?.respond(to: request, from: created)
        }
        let answered: @Sendable (TestPortRequest) async -> Void = {
            [weak self, weak created] request in
            guard let created else { return }
            await self?.answered(request, from: created)
        }
        do {
            try await created.listen(
                handle: Self.connection(respond: respond, answered: answered))
        } catch {
            // A stop during the listen closed the listener.
            guard phase == .starting else { return false }
            listener = nil
            return notListening(error)
        }
        guard phase == .starting else { return false }
        phase = .listening
        watch = Task { [weak self] in
            if let error = await created.stopped() { self?.listenerFailed(error) }
        }
        return true
    }

    // Close the server and its connections. The listener removes the socket that it listened
    // on, also when the start did not go on yet. A listen that the close ends removes its own
    // file when the cancel is complete.
    public func stop() {
        phase = .stopped
        watch = nil
        listener?.close()
        listener = nil
    }

    private func notListening(_ error: ListenError) -> Bool {
        phase = .stopped
        log.record(.notListening(error))
        return false
    }

    // The listener failed after the listen. The server closes and removes its socket.
    private func listenerFailed(_ error: ListenError) {
        guard phase == .listening else { return }
        log.record(.failed(error))
        stop()
    }

    // The answer line of a request, or nil when the server stopped or closed that listener,
    // also during the work of the request.
    private func respond(
        to request: TestPortRequest, from source: UnixSocketListener
    ) async -> [UInt8]? {
        guard listener === source else { return nil }
        let value = await handle(request)
        guard listener === source else { return nil }
        return Array(TestPortMessage.answer(value).utf8)
    }

    private func answered(_ request: TestPortRequest, from source: UnixSocketListener) {
        if listener === source { onAnswered?(request) }
    }

    // MARK: - The line of a connection

    // The work of one connection, off the main actor: one line, then the answer and the close.
    nonisolated private static func connection(
        respond: @escaping @Sendable (TestPortRequest) async -> [UInt8]?,
        answered: @escaping @Sendable (TestPortRequest) async -> Void
    ) -> UnixSocketListener.Handler {
        { connection in
            var bytes: [UInt8] = []
            let text: [UInt8]
            reading: while true {
                let chunk = await connection.receive()
                bytes += chunk ?? []
                switch firstLine(bytes, ended: chunk == nil) {
                case .more: continue
                case .tooLong: return await connection.answer(bad)
                case .line(let line):
                    text = line
                    break reading
                }
            }
            guard let string = String(validating: text, as: UTF8.self),
                let request = TestPortMessage.request(string)
            else { return await connection.answer(bad) }
            guard let answer = await respond(request) else { return }
            await connection.answer(answer)
            await answered(request)
        }
    }

    // The first line of a connection, from the bytes that came until now.
    enum FirstLine: Equatable {
        // No line break yet, and the stream goes on.
        case more
        // The part before the break, or each byte when no break came, is over the limit. A line
        // is bad also when its break comes in a later chunk.
        case tooLong
        // The line, with no break and no CR at its end. The end of the stream also ends a line.
        case line([UInt8])
    }

    nonisolated static func firstLine(_ bytes: [UInt8], ended: Bool) -> FirstLine {
        let end = bytes.firstIndex(of: UInt8(ascii: "\n"))
        if (end ?? bytes.count) > lineLimit { return .tooLong }
        guard end != nil || ended else { return .more }
        var text = bytes[..<(end ?? bytes.endIndex)]
        if text.last == UInt8(ascii: "\r") { text = text.dropLast() }
        return .line(Array(text))
    }

    nonisolated private static let bad = Array(TestPortMessage.badRequest.utf8)
}
#endif
