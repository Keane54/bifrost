import Foundation

// The check of the socket path before a listen. A socket that accepts a connection belongs to
// another program, so the listener never takes it. The listener never removes a file that is not
// a socket.
package enum SocketProbe {
    // The result of a probe of the socket path.
    package enum Result: Sendable, Equatable {
        // No file has the path.
        case free
        // A socket file that no program listens on. The listener can remove it.
        case stale
        // The listener must not listen, for this reason.
        case refused(ListenError)
    }

    // The longest socket path in bytes. The address of a Unix socket (sun_path) has 104 bytes,
    // and the last byte is a NUL.
    static let maxPathBytes = 103
    // The time limit of the connect to an existing socket.
    static let connectLimit = Duration.milliseconds(500)
    // The limit in the English text of an error, for example "500 ms".
    static let connectLimitText = connectLimit.formatted(
        .units(allowed: [.milliseconds], width: .abbreviated)
            .locale(Locale(identifier: "en_US_POSIX")))

    // free when no file has the path, stale when a socket file has no listener, or refused
    // with the reason. The connect waits up to connectLimit, so the probe runs on the blocking
    // executor.
    package static func probe(_ path: String) async -> Result {
        await BlockingExecutor.run { probeNow(path) }
    }

    // Remove the socket file at the path when no program listens on it. A missing file, a file
    // that is not a socket and a socket that takes a connection stay as they are.
    static func removeStaleSocket(_ path: String) async {
        if case .stale = await probe(path) { unlink(path) }
    }

    private static func probeNow(_ path: String) -> Result {
        // The copy of a longer path to the address would trap.
        guard path.utf8.count <= maxPathBytes else { return .refused(.pathTooLong(path)) }
        var info = stat()
        if lstat(path, &info) != 0 {
            let code = errno
            if code == ENOENT { return .free }
            return .refused(.system(.check, path: path, code: code))
        }
        guard info.st_mode & S_IFMT == S_IFSOCK else { return .refused(.notASocket(path)) }
        return connectProbe(path)
    }

    // A non-blocking connect, then a poll with the time limit.
    private static func connectProbe(_ path: String) -> Result {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .refused(.system(.createSocket, path: path, code: errno)) }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        if fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != 0 {
            return .refused(.system(.setUpSocket, path: path, code: errno))
        }
        var address = unixAddress(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        var code = result == 0 ? 0 : errno
        if code == EINPROGRESS {
            let limit = Int32(connectLimit / .milliseconds(1))
            var waiting = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            var ready = poll(&waiting, 1, limit)
            while ready < 0, errno == EINTR {
                ready = poll(&waiting, 1, limit)
            }
            if ready == 0 { return .refused(.noAnswer(path)) }
            if ready < 0 { return .refused(.system(.waitForAnswer, path: path, code: errno)) }
            var failure: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &size)
            code = failure
        }
        switch code {
        case 0: return .refused(.inUse(path))
        case ECONNREFUSED: return .stale
        // The file went away after lstat. The path is free.
        case ENOENT: return .free
        default: return .refused(.system(.connect, path: path, code: code))
        }
    }
}

// The address of a Unix socket. The caller checks that the path has at most maxPathBytes bytes,
// so the NUL at the end stays.
private func unixAddress(_ path: String) -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8.prefix(SocketProbe.maxPathBytes))
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return address
}
