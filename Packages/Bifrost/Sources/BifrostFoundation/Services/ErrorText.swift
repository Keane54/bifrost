import Foundation
import Network

// MARK: - The calls of the system

// A call of the system that can fail. Each call has the action at the start of its error text.
public enum SystemCall: Sendable, Equatable {
    // The read of a file.
    case read
    // The safe write of a file (JSONFile.write).
    case save
    // The copy of a file to the target path.
    case copy(to: String)
    // The rename of a file to the target path.
    case rename(to: String)
    // The make of a folder.
    case createFolder
    // The change of the mode of a file or a folder.
    case setPermissions
    // The check of the type of a file (lstat).
    case check
    // The removal of a file.
    case remove
    // The listen of a server on a socket.
    case listen
    // The connect to a socket, and the three steps of the connect of the probe: the make of the
    // socket, the set-up of the socket and the wait for the answer.
    case connect
    case createSocket
    case setUpSocket
    case waitForAnswer
    // The lock of the lock file of a socket.
    case lock

    // The action and the path, for example "Cannot create the folder /a".
    func subject(_ path: String) -> String {
        switch self {
        case .read: "Cannot read \(path)"
        case .save: "Cannot save \(path)"
        case .copy(let target): "Cannot copy \(path) to \(target)"
        case .rename(let target): "Cannot rename \(path) to \(target)"
        case .createFolder: "Cannot create the folder \(path)"
        case .setPermissions: "Cannot set the permissions of \(path)"
        case .check: "Cannot check \(path)"
        case .remove: "Cannot remove \(path)"
        case .listen: "Cannot listen on \(path)"
        case .connect: "Cannot connect to \(path)"
        case .lock: "Cannot lock \(path)"
        case .createSocket: "Cannot create a socket for \(path)"
        case .setUpSocket: "Cannot set up the socket for \(path)"
        case .waitForAnswer: "Cannot get an answer from \(path)"
        }
    }
}

// MARK: - The failure of a file call

// The failure of a call of the system on a file or a folder of a store: the call, the path and
// the error number, or the text of another error. message is the native text (ErrorText).
public enum FileError: MessageError, Equatable, Sendable {
    case system(SystemCall, path: String, code: Int32)
    case other(String)

    // The failure of a call on a path. A system error (a POSIXError, or a Cocoa error with an
    // underlying POSIX error) gives system. Another error gives its text.
    package init(_ error: any Error, call: SystemCall, path: String) {
        if let code = ErrorText.posixCode(of: error) {
            self = .system(call, path: path, code: code)
        } else {
            self = .other(ErrorText.of(error))
        }
    }

    public var message: String {
        switch self {
        case .system(let call, let path, let code): ErrorText.system(code, call: call, path: path)
        case .other(let text): text
        }
    }
}

// MARK: - The texts of the errors

// An error that has its own text for the user. ErrorText gives the message of the error as it
// is, for example a FileError, a ListenError or a RegistryFailure of BifrostSessions.
package protocol MessageError: Error {
    var message: String { get }
}

// The one form of the error texts (user decision, 2026-11-15: error texts are native Swift
// texts). The log lines, the Live details status, the error of a failed save and the stderr of a
// program that fails use these texts:
// - A system call: "<action> <path>: <reason>.", for example
//   "Cannot create the folder /a: Permission denied.". The reason is the text of the system for
//   the error number (strerror_r). The text has no POSIX error name.
// - A program: "<program> stopped with code <n>.", "<program> stopped with signal <n>.",
//   "<program> did not finish within <n> s." (the time limit stopped it) or
//   "Cannot start <program>: <reason>.".
// - An error with its own message (MessageError, for example a failure of the registry) gives
//   its message. Another error gives its localizedDescription.
// The text never has the debug text of an NSError, for example a memory address.
package enum ErrorText {
    // The text of a failed system call with its error number.
    static func system(_ code: Int32, call: SystemCall, path: String) -> String {
        "\(call.subject(path)): \(reason(code))."
    }

    // The text of an error of a system call. A system error (a POSIXError, or a Cocoa error with
    // an underlying POSIX error) gives the form of system(_:call:path:).
    package static func of(_ error: any Error, call: SystemCall, path: String) -> String {
        if let failure = error as? any MessageError { return failure.message }
        guard let code = posixCode(of: error) else { return error.localizedDescription }
        return system(code, call: call, path: path)
    }

    // The text of an error with no known call. A system error gives its reason, for example
    // "Permission denied.".
    package static func of(_ error: any Error) -> String {
        if let failure = error as? any MessageError { return failure.message }
        guard let code = posixCode(of: error) else { return error.localizedDescription }
        return "\(reason(code))."
    }

    // A program that ended with an exit code that is not 0.
    package static func stopped(_ program: String, code: Int32) -> String {
        "\(program) stopped with code \(code)."
    }

    // The text of a run that did not succeed and gave no stderr.
    package static func ended(_ program: String, _ end: ExecEnd) -> String {
        switch end {
        case .exited(let code): stopped(program, code: code)
        case .signal(let number): stopped(program, signal: number)
        case .timedOut: "\(program) did not finish in time."
        case .overflow: "\(program) gave more output than the limit."
        case .cancelled: stoppedText
        case .notStarted: "Cannot start \(program)."
        }
    }

    // A program that a signal ended.
    static func stopped(_ program: String, signal: Int32) -> String {
        "\(program) stopped with signal \(signal)."
    }

    // A program that the time limit of its run stopped. The limit is in seconds, with at most
    // three decimals and no zero at the end, for example "5", "0.1" or "2.25".
    static func timedOut(_ program: String, limit: Duration) -> String {
        "\(program) did not finish within \(seconds(limit)) s."
    }

    // The seconds of a duration, rounded down to whole milliseconds.
    static func seconds(_ duration: Duration) -> String {
        let milliseconds = max(0, duration / .milliseconds(1))
        let whole = Int(milliseconds) / 1000
        let part = Int(milliseconds) % 1000
        guard part > 0 else { return "\(whole)" }
        var digits = String(part)
        digits = String(repeating: "0", count: 3 - digits.count) + digits
        while digits.hasSuffix("0") { digits.removeLast() }
        return "\(whole).\(digits)"
    }

    // A program that did not start, with the error number. When the folder of the run is the
    // problem, the text names the folder: "Cannot start <program> in <folder>: <reason>.".
    package static func notStarted(
        _ program: String, in folder: String? = nil, code: Int32
    ) -> String {
        start(program, in: folder, reason(code))
    }

    // A program that did not start, with the error of the start. A system error gives the text
    // of the system. Another error gives its localizedDescription.
    static func notStarted(_ program: String, error: any Error) -> String {
        start(program, in: nil, posixCode(of: error).map(reason) ?? error.localizedDescription)
    }

    // The text of the system for an error number, for example "Permission denied". strerror can
    // write to one shared buffer, so it is not safe on many threads. strerror_r writes to a
    // local buffer. An unknown number gives "Unknown error: <n>".
    package static func reason(_ code: Int32) -> String {
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: 256) { buffer in
            guard let start = buffer.baseAddress, strerror_r(code, start, buffer.count) != ERANGE
            else { return "Unknown error: \(code)" }
            return String(cString: start)
        }
    }

    // The POSIX error number of a POSIXError, of a POSIX error of Network (NWError), of an
    // NSError in the POSIX domain, or of the underlying error of a Cocoa error. nil for another
    // error.
    static func posixCode(of error: any Error) -> Int32? {
        if let error = error as? POSIXError { return error.code.rawValue }
        if case .posix(let code) = error as? NWError { return code.rawValue }
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain { return Int32(exactly: error.code) }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
            underlying.domain == NSPOSIXErrorDomain
        else { return nil }
        return Int32(exactly: underlying.code)
    }

    // "Cannot start <program>: <reason>." with one full stop at the end.
    private static func start(_ program: String, in folder: String?, _ reason: String) -> String {
        let subject = folder.map { "Cannot start \(program) in \($0)" } ?? "Cannot start \(program)"
        return reason.hasSuffix(".") ? "\(subject): \(reason)" : "\(subject): \(reason)."
    }
}
