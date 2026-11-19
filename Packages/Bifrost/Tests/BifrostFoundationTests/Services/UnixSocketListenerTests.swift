import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostFoundation

// The shared Unix socket listener. The tests run a real listener in a TemporaryFolder. The
// server tests (LiveServerTests, TestPortServerTests) cover the limits of the connections.

@MainActor
private func makeListener(
    _ path: String, boundStep: UnixSocketListener.BoundStep? = nil
) -> UnixSocketListener {
    UnixSocketListener(
        socketPath: path, limits: .init(maxConnections: 4, requestTimeout: .seconds(5)),
        clock: ManualClock(), boundStep: boundStep)
}

// A handler that closes each connection at once.
private let closeAtOnce: UnixSocketListener.Handler = { _ in }

// A handler that answers the first chunk with the same bytes and "!" at the end.
private let echo: UnixSocketListener.Handler = { connection in
    guard let bytes = await connection.receive() else { return }
    await connection.answer(bytes + Array("!".utf8))
}

private func mode(_ path: String) -> mode_t {
    var info = stat()
    return lstat(path, &info) == 0 ? info.st_mode & 0o777 : 0
}

// The error of a listen, or nil when it listens.
@MainActor
private func listenError(
    _ listener: UnixSocketListener, _ handle: @escaping UnixSocketListener.Handler = closeAtOnce
) async -> ListenError? {
    do {
        try await listener.listen(handle: handle)
        return nil
    } catch {
        return error
    }
}

@MainActor
@Suite("the Unix socket listener", .testTimeLimit)
struct UnixSocketListenerTests {
    @Test func eachConnectionRunsTheHandlerAndClosesWhenItReturns() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let path = folder.appending("run/l.sock")
        let listener = makeListener(path)
        #expect(await listenError(listener, echo) == nil)
        #expect(mode(path) == 0o600)
        #expect(mode(folder.appending("run")) == 0o700)
        for text in ["one", "two"] {
            let client = try UnixClient(path: path)
            _ = await client.write(Array(text.utf8))
            #expect(await client.readToEnd() == Array("\(text)!".utf8))
            client.close()
        }
        #expect(listener.close())
        #expect(await listener.stopped() == nil)
        unlink(path)
    }

    // A close in the same turn as the listen ends the listen before it is ready. close() tells
    // the owner that the listener did not listen, so the owner removes no file. A listener does
    // not listen again.
    @Test func aCloseBeforeTheListenIsReadyEndsTheListen() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let path = folder.appending("l.sock")
        let listener = makeListener(path)
        let listen = Task.immediate { await listenError(listener) }
        #expect(listener.close() == false)
        #expect(await listenError(listener) == .startedBefore(path))
        #expect(await listen.value == .closedBeforeListen(path))
        #expect(!fileExists(path))
        #expect(await listenError(listener) == .startedBefore(path))
    }

    // A close when the listen made the socket file, but before the listen is ready. The bound
    // step holds the listen at that point. The listen ends when the cancel of the listener is
    // complete. The listener removes the stale file of that listen, and the file never gets
    // mode 0600.
    @Test func aCloseAfterTheSocketFileExistsEndsTheListenAndLeavesNoFile() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let path = folder.appending("l.sock")
        let bound = TestGate()
        defer { bound.openAll() }
        let listener = makeListener(path, boundStep: { await bound.pass() })
        let listen = Task.immediate { await listenError(listener) }
        try #require(await bound.waitUntilHolding())
        #expect(fileExists(path))
        #expect(mode(path) != 0o600)
        #expect(listener.close() == false)
        bound.open()
        #expect(await listen.value == .closedBeforeListen(path))
        #expect(!fileExists(path))
    }

    // The probe finds the socket of another program, so the listen fails, and the socket of
    // the other program stays and still answers a connection.
    @Test func theSocketOfAnotherProgramStays() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let path = folder.appending("l.sock")
        let other = try UnixGreeter(path: path, text: "busy")
        defer { other.close() }
        let listener = makeListener(path)
        #expect(await listenError(listener) == .inUse(path))
        #expect(listener.close() == false)
        #expect(fileExists(path))
        let client = try UnixClient(path: path)
        defer { client.close() }
        #expect(await client.readToEnd() == Array("busy".utf8))
    }

    // A stale socket of an earlier run goes, and the listener listens on its path.
    @Test func aStaleSocketGoesAndTheListenerListens() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let path = folder.appending("l.sock")
        try makeStaleSocket(path)
        let listener = makeListener(path)
        #expect(await listenError(listener) == nil)
        #expect(mode(path) == 0o600)
        #expect(listener.close())
        unlink(path)
    }

    // Network gives no descriptor of a connection, so the listener checks the folder: a folder
    // that is a link is refused, and nothing changes in the folder that it points to.
    @Test func aFolderThatIsALinkIsRefused() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let real = folder.appending("real")
        mkdir(real, 0o755)
        symlink(real, folder.appending("run"))
        let path = folder.appending("run/l.sock")
        let listener = makeListener(path)
        #expect(await listenError(listener) == .unsafeFolder(folder.appending("run")))
        #expect(mode(real) == 0o755)
        #expect(!fileExists(folder.appending("real/l.sock")))
    }

    // close() of a listener that listens gives true one time, and stopped() gives no error. The
    // close removes the socket file of its listen.
    @Test func aCloseOfAListenerThatListensGivesTrueAndRemovesItsFile() async throws {
        let folder = try TemporaryFolder(short: true)
        defer { folder.remove() }
        let path = folder.appending("l.sock")
        let listener = makeListener(path)
        #expect(await listenError(listener) == nil)
        let end = Task.immediate { await listener.stopped() }
        #expect(listener.close())
        #expect(await end.value == nil)
        #expect(listener.close() == false)
        #expect(!fileExists(path))
    }

    @Test func eachErrorHasItsText() {
        let path = "/tmp/a"
        #expect(
            ListenError.unsafeSocket(path).message
                == "The socket /tmp/a is not a socket of this user with mode 0600. "
                + "Bifrost closed it.")
        #expect(
            ListenError.notALockFile(path).message
                == "/tmp/a is not a regular file of this user with one link. "
                + "Bifrost did not change it.")
        #expect(ListenError.pathTooLong(path).message == "The socket path is too long: /tmp/a")
        #expect(
            ListenError.notASocket(path).message
                == "/tmp/a exists and is not a socket. Bifrost did not change it.")
        #expect(ListenError.inUse(path).message == "Another program listens on /tmp/a.")
        #expect(
            ListenError.noAnswer(path).message == "The socket /tmp/a did not answer in 500 ms.")
        #expect(
            ListenError.system(.listen, path: path, code: EADDRINUSE).message
                == "Cannot listen on /tmp/a: Address already in use.")
        #expect(
            ListenError.listen(POSIXError(.EIO), path: path)
                == .system(.listen, path: path, code: EIO))
        #expect(ErrorText.of(ListenError.inUse(path)) == "Another program listens on /tmp/a.")
    }
}
