import BifrostModuleHostCore
import Darwin

// The probes of the self-test, run once the sandbox is on. Each one tries something the sandbox
// must refuse, and anything short of a clear refusal counts against the host, so the test fails
// closed.
enum SelfTestProbe {
    static func run() -> SelfTestResult {
        // The descriptors go first, before the other probes open any of their own.
        let fds = descriptors()
        return SelfTestResult(fds: fds, read: fileRead(), socket: connection(), spawn: start())
    }

    // The parent hands over 0 to 2 and nothing else. The sandbox checks a file when it's opened,
    // not when it's read, so a descriptor that leaked in would let the host read what's behind it.
    private static func descriptors() -> SelfTestResult.Outcome {
        let leaked = (3..<max(3, getdtablesize())).contains { descriptor in
            fcntl(descriptor, F_GETFD) != -1 || errno != EBADF
        }
        return leaked ? .open : .closed
    }

    private static func fileRead() -> SelfTestResult.Outcome {
        let descriptor = open("/etc/passwd", O_RDONLY)
        guard descriptor >= 0 else { return .denied }
        close(descriptor)
        return .allowed
    }

    // A TCP connect to port 9 on 127.0.0.1. The sandbox must refuse the socket or the connect with
    // EPERM, and anything else, a refused connection included, means the network is open.
    private static func connection() -> SelfTestResult.Outcome {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return errno == EPERM ? .denied : .allowed }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(9).bigEndian
        address.sin_addr = in_addr(s_addr: in_addr_t(0x7f00_0001).bigEndian)
        let result = withUnsafePointer(to: address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        let failure = result == -1 ? errno : 0
        return failure == EPERM ? .denied : .allowed
    }

    // Any failure to start /usr/bin/true counts as denied. A start that works is reaped, so it
    // leaves no zombie behind.
    private static func start() -> SelfTestResult.Outcome {
        var child: pid_t = 0
        let result = "/usr/bin/true".withCString { path in
            let arguments = [UnsafeMutablePointer(mutating: path), nil]
            return posix_spawn(&child, path, nil, nil, arguments, nil)
        }
        guard result == 0 else { return .denied }
        var status: Int32 = 0
        waitpid(child, &status, 0)
        return .allowed
    }
}
