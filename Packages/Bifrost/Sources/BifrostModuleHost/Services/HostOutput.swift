import BifrostModuleHostCore
import Foundation

// How the host ends. It writes nothing on the way out, so the parent tells the cases apart by
// the exit code alone.
enum HostExit: Int32 {
    case inputClosed = 0
    case sandboxFailed = 71
    case selfTestFailed = 72
    case badLine = 73

    // _exit skips the atexit handlers, so the reader thread can end the host while the main
    // thread is inside JavaScript without the two racing over teardown. Every line goes out
    // through write, so there's no buffer left to flush.
    func end() -> Never {
        _exit(rawValue)
    }
}

// Writes the host's lines to stdout. Only the main actor writes, so two lines never interleave,
// and these lines are the only output the host ever has.
@MainActor
enum HostOutput {
    static func send(_ reply: HostReply) {
        // Only a batch can fail to encode, on a number that isn't finite, and a batch only ever
        // comes from JSON.stringify, which writes no such number.
        guard var bytes = try? reply.encoded() else { return }
        bytes.append(UInt8(ascii: "\n"))
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let rest = UnsafeRawBufferPointer(rebasing: buffer[offset...])
                let count = write(1, rest.baseAddress, rest.count)
                if count < 0 {
                    // Any error but an interrupt means the parent has gone, the same as an EOF.
                    if errno == EINTR { continue }
                    HostExit.inputClosed.end()
                }
                offset += count
            }
        }
    }
}
