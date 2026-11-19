import BifrostFoundation
import BifrostSessions
import Foundation
import Synchronization

// The Live details server: an HTTP server on a Unix socket. It receives the lines of the Live
// details mod. The socket, the listener and the connections are the shared UnixSocketListener.
// Each connection runs off the main actor, so the parse of a request does not load it.
//
// Start and stop:
// - start() prepares the path (the folder with mode 0700, the lock of <name>.lock beside the
//   socket, the probe, the removal of a stale socket), then listens (the socket file gets mode
//   0600). A start while the server listens gives the state at once. A start while a start runs
//   waits for it, so two starts give one listener. A second app on the same socket finds the
//   lock held and does not listen (inUse).
// - The server holds the listener from the start of its listen. So a stop or a failure during
//   the listen closes it. The listen then ends when the cancel of the listener is complete, and
//   the listener removes the socket file of that listen.
// - stop() cancels the start that runs, closes the listener and its connections, and removes
//   the socket file of its listen (the listener checks the device and the inode). After a stop
//   the state has no error. A second stop does nothing.
// - A start that a stop cancelled gives "not listening". A start that a stop cancelled before
//   it ran does nothing. A start after a stop waits until the cancelled start ends, so its probe
//   never finds the socket of the old listen.
// - A start that does not listen (for example, another program listens on the path) logs one
//   line with the reason and gives the error state.
// - When the listener fails, the server logs one line, ends a start that runs as a stop does,
//   closes, and goes to the error state (docs/behaviour/live.md, Starting and stopping). The
//   start that ran gives the error. A later start listens again.
//
// Each connection takes one request (HTTPRequestParser), then the server closes it:
// - POST /v1/event answers 204. The server reads the body as UTF-8 (a bad byte becomes U+FFFD)
//   and gives the line to onEvents, if the line is good, before it answers and closes the
//   connection. The first line of a batch starts a wait of batchWindow (50 ms) on the clock. The
//   lines that come in that time go to onEvents as one batch, in the order of their arrival, so a
//   flood of lines makes at most one change of the registry each 50 ms.
// - Another method or target answers 404 at the end of the head.
// - A body over 65,536 bytes answers 413. An HTTP/1.1 request with no Host line answers 400.
// - A bad request, a client that ends its side before the request is complete, and a request
//   that is not complete after requestTimeout close with no answer.
// With 64 open connections, the server closes a new connection at once. It counts these
// connections and logs one line with the count at most each minute. No log line has the text of a
// line of the mod.

package struct LiveServerState: Sendable, Equatable {
    package var listening: Bool
    // The reason of a start that did not listen, or of a failure of the listener.
    package var error: String?

    package init(listening: Bool = false, error: String? = nil) {
        self.listening = listening
        self.error = error
    }
}

// The limit of open connections.
private let maxConnections = 64

// The answer to a good request.
private let noContent = Array("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n".utf8)

// The event of a connection, and the wait of that connection: it answers after the delivery.
private struct Delivery: Sendable {
    var event: LiveEvent
    var done: CheckedContinuation<Void, Never>
}

@MainActor
package final class LiveServer {
    package private(set) var state = LiveServerState()
    private let socketPath: String
    private let clock: any Clock<Duration>
    // The clock as the time since the init. The end of a batch window is a time on it.
    private let timeline: Timeline
    private let now: @Sendable () -> Date
    private let requestTimeout: Duration
    private let batchWindow: Duration
    private let onEvents: ([LiveEvent]) -> Void
    private let log: any ListenerLog
    // The start that runs. A second start waits for it.
    private var starting: Task<LiveServerState, Never>?
    // The last start that a stop cancelled. The next start waits until it ends.
    private var cancelled: Task<LiveServerState, Never>?
    // The listener from the start of its listen until the close. It keeps the connections.
    private var listener: UnixSocketListener?
    // The wait for the end of the listener that listens. A failure of the listener ends it.
    private var watch: Task<Void, Never>?
    // The events of the connections of the listener, in the order of their arrival. One task on
    // the main actor takes them into the batch, so the registry gets them in that order.
    private var deliveries: AsyncStream<Delivery>.Continuation?
    // The events of the batch, and the task that gives them to onEvents at the end of the batch
    // window.
    private var batch: [Delivery] = []
    private var flush: Task<Void, Never>?
    // The count of the connections that the listener closed at once, and the task that logs it
    // after one minute.
    private let refusals = RefusalCount()
    private var refusalReport: Task<Void, Never>?
    private let boundStep: UnixSocketListener.BoundStep?

    // now gives the wall time of the receipt of a line. The clock is for the request timeout, for
    // the batch window and for the minute of the count of refused connections. A batch window of
    // zero gives each batch in the next turn of the main actor. log gets one event for each start
    // that does not listen, for each failure of the listener after the listen, and for the count
    // of refused connections. Only a test gives a bound step (UnixSocketListener.BoundStep).
    package init(
        socketPath: String, clock: any Clock<Duration>,
        now: @escaping @Sendable () -> Date = Date.init,
        requestTimeout: Duration = .seconds(5), batchWindow: Duration = .milliseconds(50),
        onEvents: @escaping ([LiveEvent]) -> Void,
        log: any ListenerLog = SystemListenerLog(category: "live", server: "Live details"),
        boundStep: UnixSocketListener.BoundStep? = nil
    ) {
        self.boundStep = boundStep
        self.socketPath = socketPath
        self.clock = clock
        timeline = Timeline(clock)
        self.now = now
        self.requestTimeout = requestTimeout
        self.batchWindow = batchWindow
        self.onEvents = onEvents
        self.log = log
    }

    // The lock file of a socket: <name>.lock beside <name>.sock, for example live.lock.
    nonisolated static func lockPath(of socketPath: String) -> String {
        (socketPath.hasSuffix(".sock") ? String(socketPath.dropLast(5)) : socketPath) + ".lock"
    }

    // Listen on the socket, and give the state.
    package func start() async -> LiveServerState {
        if state.listening { return state }
        if let starting { return await starting.value }
        let task = Task { [previous = cancelled] in
            // A cancelled start closes what it opened before this start probes the path.
            _ = await previous?.value
            return await self.open()
        }
        starting = task
        cancelled = nil
        let result = await task.value
        if starting == task { starting = nil }
        return result
    }

    // Close the server and its connections. A start that runs then gives "not listening".
    package func stop() {
        endStart()
        closeListener()
        state = LiveServerState()
        // The count of the refused connections goes to the log now.
        refusalReport?.cancel()
    }

    // Cancel the start that runs. It gives the state of the server when it ends. The next start
    // waits until it ends.
    private func endStart() {
        guard let starting else { return }
        starting.cancel()
        cancelled = starting
        self.starting = nil
    }

    // Prepare the path and listen. A stop or a failure of the listener cancels the start. Then
    // the result is the state that they set, and no listener and no socket file of this start
    // stay.
    private func open() async -> LiveServerState {
        // A start that a stop cancelled before it ran does nothing.
        if Task.isCancelled { return state }
        let refused: @Sendable () -> Void = { [refusals] in
            guard refusals.add() else { return }
            Task { @MainActor [weak self] in self?.reportRefusals() }
        }
        let created = UnixSocketListener(
            socketPath: socketPath, lockPath: Self.lockPath(of: socketPath),
            limits: .init(maxConnections: maxConnections, requestTimeout: requestTimeout),
            clock: clock, refused: refused, boundStep: boundStep)
        // The server holds the listener before the listen, so a stop or a failure during the
        // listen closes it, and the close ends the listen.
        listener = created
        let (events, deliveries) = AsyncStream.makeStream(of: Delivery.self)
        self.deliveries = deliveries
        Task { [weak self] in
            for await delivery in events {
                // After a stop or a failure, an event of the old listener goes nowhere.
                guard let self, listener === created else {
                    delivery.done.resume()
                    continue
                }
                // The first event of a batch starts the batch window. The events that come in it
                // go to onEvents as one batch at its end.
                batch.append(delivery)
                if flush == nil { flush = startFlush() }
            }
        }
        let deliver: @Sendable (LiveEvent) async -> Void = { event in
            await withCheckedContinuation { done in
                if case .terminated = deliveries.yield(Delivery(event: event, done: done)) {
                    done.resume()
                }
            }
        }
        do {
            try await created.listen(handle: Self.connection(now: now, deliver: deliver))
        } catch {
            // A listen that failed made no socket file for the server to remove, and it has no
            // connections.
            deliveries.finish()
            if listener === created {
                listener = nil
                self.deliveries = nil
            }
            // A stop or a failure of the listener set the state.
            if Task.isCancelled { return state }
            log.record(.notListening(error))
            state = LiveServerState(error: error.message)
            return state
        }
        if Task.isCancelled { return state }
        watch = Task { [weak self] in
            if let error = await created.stopped() { self?.listenerFailed(error) }
        }
        state = LiveServerState(listening: true)
        return state
    }

    // The listener failed. It takes no more connections, so the server logs the error, ends a
    // start that runs as a stop does, closes, and goes to the error state
    // (docs/behaviour/live.md, Starting and stopping). The watch of the listener calls this
    // function. A test can call it with an error.
    func listenerFailed(_ error: ListenError) {
        guard listener != nil else { return }
        log.record(.failed(error))
        endStart()
        closeListener()
        state = LiveServerState(error: error.message)
    }

    // Close the listener and each connection. A listener that listened made the socket file, so
    // the server removes it at once. A listen that the close ends removes a stale socket of that
    // listen when the cancel is complete. So the server never removes the socket of another
    // program, for example after a race for the path.
    private func closeListener() {
        watch = nil
        // The task of the events ends when it has each event that waits.
        deliveries?.finish()
        deliveries = nil
        // The events of the batch go nowhere, and their connections close.
        flush?.cancel()
        flush = nil
        let waiting = batch
        batch = []
        for delivery in waiting { delivery.done.resume() }
        guard let listener else { return }
        self.listener = nil
        // A listener that listened removes its own socket file.
        listener.close()
    }

    // The number of the events in the batch. A test waits for it.
    var batchCount: Int { batch.count }

    // Wait for the end of the batch window, then give the batch. The end of the window is the
    // time of the first line plus batchWindow, so the window ends also when the clock moves
    // before the task starts its wait. A close cancels the wait, and the cancelled task gives
    // nothing.
    private func startFlush() -> Task<Void, Never> {
        let end = timeline.now() + batchWindow
        return Task { [timeline, batchWindow] in
            if batchWindow > .zero { try? await timeline.sleep(until: end) }
            if Task.isCancelled { return }
            self.deliverBatch()
        }
    }

    // Give the batch to onEvents, then let its connections answer.
    private func deliverBatch() {
        flush = nil
        let waiting = batch
        batch = []
        if !waiting.isEmpty { onEvents(waiting.map(\.event)) }
        for delivery in waiting { delivery.done.resume() }
    }

    // Log the count of the refused connections one minute after the first of them, or at the
    // stop.
    private func reportRefusals() {
        guard refusalReport == nil else { return }
        refusalReport = Task { [clock, refusals, log] in
            try? await clock.sleep(for: .seconds(60))
            let count = refusals.take()
            if count > 0 { log.record(.refusedConnections(count)) }
            self.refusalReport = nil
        }
    }

    // The work of one connection, off the main actor: one request (HTTPRequestParser), then the
    // answer and the close. The event of a good line goes to onEvents before the answer.
    nonisolated private static func connection(
        now: @escaping @Sendable () -> Date,
        deliver: @escaping @Sendable (LiveEvent) async -> Void
    ) -> UnixSocketListener.Handler {
        { connection in
            var parser = HTTPRequestParser()
            // A client that ends its side before the request is complete gets no answer.
            while let bytes = await connection.receive() {
                switch parser.feed(bytes) {
                case .needMore:
                    continue
                case .event(let body):
                    // The server reads the body as UTF-8. A bad byte becomes U+FFFD.
                    // The mod gives its times in milliseconds since 1970 (the wire form).
                    let receivedAt = now().millisecondsSince1970
                    if let event = LiveEvent(body: body, receivedAt: receivedAt) {
                        await deliver(event)
                    }
                    await connection.answer(noContent)
                case .refused(.noHost):
                    await connection.answer(refusal("400 Bad Request"))
                case .refused(.notFound):
                    await connection.answer(refusal("404 Not Found"))
                case .refused(.tooLarge):
                    await connection.answer(refusal("413 Payload Too Large"))
                case .refused(.bad):
                    break
                }
                return
            }
        }
    }
}

// An answer with no body. Only the 204 has no Content-Length line.
private func refusal(_ status: String) -> [UInt8] {
    Array("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
}

// The count of the connections that the listener closed at once. The queue of the listener adds
// to it, and the log task takes it.
private final class RefusalCount: Sendable {
    private let count = Mutex(0)

    // Add one. True for the first refusal after the last take.
    func add() -> Bool {
        count.withLock {
            $0 += 1
            return $0 == 1
        }
    }

    // The count since the last take. The count goes back to 0.
    func take() -> Int {
        count.withLock {
            let value = $0
            $0 = 0
            return value
        }
    }
}
