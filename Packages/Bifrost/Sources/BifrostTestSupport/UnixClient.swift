import Foundation
import Synchronization

// Clients and servers of Unix sockets for the tests, with the system calls and no framework.
// So a test of LiveServer does not use the code that it tests. The calls of a client that wait
// run on a global dispatch queue, not on the threads of Swift concurrency, and each wait has a
// time limit, so a failed test does not hang. The greeter waits on its own thread until its
// close.

package struct SocketFailure: Error {
    package var call: String
    package var code: Int32
}

// The address of a Unix socket path of at most 103 bytes.
private func unixAddress(_ path: String) -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(path.utf8.prefix(103))
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return address
}

private func setFlag(_ fd: Int32, _ option: Int32) {
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, option, &on, socklen_t(MemoryLayout<Int32>.size))
}

private func setTimeLimit(_ fd: Int32, _ option: Int32, _ limit: Duration) {
    let (seconds, attoseconds) = limit.components
    var value = timeval(
        tv_sec: Int(seconds), tv_usec: Int32(attoseconds / 1_000_000_000_000))
    setsockopt(fd, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<timeval>.size))
}

// A new stream socket of the Unix domain, with no SIGPIPE.
private func unixSocket() throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketFailure(call: "socket", code: errno) }
    setFlag(fd, SO_NOSIGPIPE)
    return fd
}

// Run bind or connect with the address of path. A failure closes the socket.
private func call(
    _ name: String, _ fd: Int32, _ path: String,
    _ body: (Int32, UnsafePointer<sockaddr>, socklen_t) -> Int32
) throws {
    var address = unixAddress(path)
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if result != 0 {
        let code = errno
        close(fd)
        throw SocketFailure(call: name, code: code)
    }
}

// A socket that listens on path. The socket file stays until a test removes it.
private func listeningSocket(_ path: String) throws -> Int32 {
    let fd = try unixSocket()
    try call("bind", fd, path) { bind($0, $1, $2) }
    if listen(fd, 8) != 0 {
        let code = errno
        close(fd)
        throw SocketFailure(call: "listen", code: code)
    }
    return fd
}

// Run a call that waits on a global dispatch queue.
private func offThePool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: work()) }
    }
}

// One connection to a Unix socket.
package struct UnixClient: Sendable {
    package let fd: Int32

    package init(path: String) throws {
        let fd = try unixSocket()
        try call("connect", fd, path) { connect($0, $1, $2) }
        self.fd = fd
    }

    // Write all bytes. False when the server closed the connection first, or after 5 s.
    package func write(_ bytes: [UInt8]) async -> Bool {
        await offThePool { [fd] in
            setTimeLimit(fd, SO_SNDTIMEO, .seconds(5))
            var sent = 0
            while sent < bytes.count {
                let count = bytes[sent...].withUnsafeBytes {
                    Darwin.write(fd, $0.baseAddress, $0.count)
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                sent += count
            }
            return true
        }
    }

    // The bytes until the server closes the connection, or nil when a read waits longer than
    // limit.
    package func readToEnd(limit: Duration = .seconds(5)) async -> [UInt8]? {
        await offThePool { [fd] in
            setTimeLimit(fd, SO_RCVTIMEO, limit)
            var result: [UInt8] = []
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(fd, $0.baseAddress, $0.count)
                }
                if count > 0 {
                    result.append(contentsOf: buffer[0..<count])
                } else if count == 0 {
                    return result
                } else if errno != EINTR {
                    // ECONNRESET is a close. EAGAIN is the time limit.
                    return errno == ECONNRESET ? result : nil
                }
            }
        }
    }

    // End the side of the client: the server reads the end of the stream.
    package func endWriting() { shutdown(fd, SHUT_WR) }

    package func close() { Darwin.close(fd) }
}

// A server on a Unix socket, as another program has one: it writes the text to each connection
// and then closes the connection. It answers each connection until close(). It has no time
// limit, so a slow test does not connect after the greeter stopped. A test does not count the
// connections of the code that it tests.
package final class UnixGreeter: Sendable {
    // The write end of the pipe that stops the loop, or nil after close().
    private let stopEnd: Mutex<Int32?>

    package init(path: String, text: String) throws {
        let fd = try listeningSocket(path)
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw SocketFailure(call: "pipe", code: code)
        }
        // A child process of another test does not get the pipe. A write after the end of the
        // loop fails with EPIPE, not SIGPIPE.
        for end in ends { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(ends[1], F_SETNOSIGPIPE, 1)
        stopEnd = Mutex(ends[1])
        let bytes = Array(text.utf8)
        let readEnd = ends[0]
        Thread.detachNewThread { greet(fd, until: readEnd, with: bytes) }
    }

    // Write one byte to the pipe, so the loop stops and closes the listening socket. A second
    // call does nothing.
    package func close() {
        let end = stopEnd.withLock { end in
            let fd = end
            end = nil
            return fd
        }
        guard let end else { return }
        var byte: UInt8 = 0
        _ = Darwin.write(end, &byte, 1)
        Darwin.close(end)
    }
}

// Answer each connection on fd until the pipe stop has a byte, then close fd and stop. The loop
// owns the two descriptors, so no other thread closes them while the poll waits.
private func greet(_ fd: Int32, until stop: Int32, with text: [UInt8]) {
    defer {
        Darwin.close(fd)
        Darwin.close(stop)
    }
    while true {
        var waits = [
            pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
            pollfd(fd: stop, events: Int16(POLLIN), revents: 0),
        ]
        if poll(&waits, 2, -1) < 0 {
            if errno == EINTR { continue }
            return
        }
        if waits[1].revents != 0 || waits[0].revents & Int16(POLLIN) == 0 { return }
        let client = accept(fd, nil, nil)
        if client < 0 {
            if errno == EINTR || errno == ECONNABORTED { continue }
            return
        }
        // The client socket gets SO_NOSIGPIPE from the listening socket. A client that closed
        // before the accept (a probe) makes the write fail with EPIPE, and the loop continues.
        _ = text.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
        Darwin.close(client)
    }
}

// Make a stale socket file at path: a socket that listened and then closed. Nothing listens, so
// a connect gets ECONNREFUSED.
package func makeStaleSocket(_ path: String) throws {
    close(try listeningSocket(path))
}
