import BifrostFoundation
import Foundation

// MARK: - The terminal app of a process

// One process: its parent PID and its command. The command is the first argument of the
// process, else the path of its executable (ProcessInspector). A fake table of a test also gives
// the arguments and the start time of a process, for the attach clients (attachClients(own:)).
// The walk of the parents uses only the parent PID and the command.
package struct ProcessEntry: Sendable, Equatable {
    package var ppid: pid_t
    package var comm: String
    package var arguments: [String]
    package var started: ProcessStart

    package init(
        ppid: pid_t, comm: String, arguments: [String] = [],
        started: ProcessStart = ProcessStart(seconds: 0, microseconds: 0)
    ) {
        self.ppid = ppid
        self.comm = comm
        self.arguments = arguments
        self.started = started
    }
}

// Processes by PID, for example the processes of a test.
package typealias ProcessTable = [pid_t: ProcessEntry]

// MARK: - The identity of a process

// The start time of a process, as the kernel keeps it (pbi_start_tvsec and pbi_start_tvusec).
// It is only a mark of identity: the system can give the PID of a process that ended to a new
// process, but the new process has another start time.
package struct ProcessStart: Sendable, Hashable, Comparable {
    package var seconds: UInt64
    package var microseconds: UInt64

    package init(seconds: UInt64, microseconds: UInt64) {
        self.seconds = seconds
        self.microseconds = microseconds
    }

    // The earlier start comes first.
    package static func < (a: ProcessStart, b: ProcessStart) -> Bool {
        (a.seconds, a.microseconds) < (b.seconds, b.microseconds)
    }
}

// The command and the start time of one process.
package struct ProcessIdentity: Sendable, Equatable {
    package var command: String
    package var started: ProcessStart

    package init(command: String, started: ProcessStart) {
        self.command = command
        self.started = started
    }

    // True when the last path component of the command is "claude", for example
    // "/Users/x/.local/bin/claude". The command is trimmed first. "claude/" is not claude.
    package var isClaude: Bool { Self.isClaude(command) }

    package static func isClaude(_ command: String) -> Bool {
        command.trimmed().split(separator: "/", omittingEmptySubsequences: false).last == "claude"
    }
}

extension TerminalApp {
    // The most steps of a walk up the parents.
    static let maxParentSteps = 64

    // Walk up the parent PIDs from pid, with process giving each process. The first process in
    // an app bundle gives the app. The walk stops at PID 1 or less, at a missing PID, at a loop,
    // and after 64 steps.
    package static func find(from pid: pid_t, process: (pid_t) -> ProcessEntry?)
        -> TerminalApp?
    {
        var seen: Set<pid_t> = []
        var current = pid
        for _ in 0..<maxParentSteps {
            if current <= 1 || !seen.insert(current).inserted { return nil }
            guard let entry = process(current) else { return nil }
            if let at = entry.comm.firstRange(of: ".app/") {
                let bundle = String(entry.comm[..<entry.comm.index(at.lowerBound, offsetBy: 4)])
                let file = bundle.split(separator: "/", omittingEmptySubsequences: false).last ?? ""
                return TerminalApp(name: String(file.dropLast(4)), bundle: bundle)
            }
            current = entry.ppid
        }
        return nil
    }
}

extension ProcessTable {
    // The terminal app of the process, with the walk of TerminalApp.find.
    package func terminalApp(of pid: pid_t) -> TerminalApp? {
        TerminalApp.find(from: pid) { self[$0] }
    }
}

// MARK: - The attach clients of the background sessions

// The argument of "claude attach <id|name>", as Claude Code reads it. A text of only hex digits
// and "-" can be the start of an ID, so it is the start of a short ID or of a session ID. Each
// other text is the name of a session.
package enum AttachArgument: Sendable, Hashable {
    // The start of an ID, in lower case.
    case idStart(String)
    case name(String)

    // nil for an empty text.
    package init?(_ text: String) {
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        let isIDStart = lower.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "f"),
                UInt8(ascii: "-"):
                true
            default: false
            }
        }
        self = isIDStart ? .idStart(lower) : .name(text)
    }
}

// One process of "claude attach <id|name>": a client that shows a background session in a
// terminal. The service of Claude Code runs the session itself, so the walk up the parents of
// the session process never reaches a terminal app. The walk up the parents of the client does.
package struct AttachClient: Sendable, Equatable {
    package var pid: pid_t
    package var started: ProcessStart
    package var argument: AttachArgument
    // The first app on the walk up the parents (TerminalApp.find). nil: no app holds the
    // client, for example a client in tmux or over ssh.
    package var app: TerminalApp?

    package init(
        pid: pid_t, started: ProcessStart, argument: AttachArgument, app: TerminalApp?
    ) {
        self.pid = pid
        self.started = started
        self.argument = argument
        self.app = app
    }

    // The most arguments of a command line that the scan reads. "claude attach <id|name>" has
    // three, and a few options can come with them.
    package static let maxArguments = 8

    // The argument of a "claude attach" command line, or nil for another command. The last path
    // component of argv[0] is "claude" (as ProcessIdentity.isClaude), argv[1] is "attach", and
    // exactly one of the arguments after it does not start with "-". An option does not count.
    package static func argument(of arguments: [String]) -> AttachArgument? {
        guard arguments.count >= 3, arguments.count <= maxArguments,
            ProcessIdentity.isClaude(arguments[0]), arguments[1] == "attach"
        else { return nil }
        let values = arguments.dropFirst(2).filter { !$0.hasPrefix("-") }
        guard values.count == 1, let value = values.first else { return nil }
        return AttachArgument(value)
    }

    // The client of one process, or nil. nil when the arguments are not "claude attach", and
    // when the walk up the parents reaches own: the process is an attach of Bifrost itself (a
    // chat or the session input), not of a terminal. own is the PID of the app.
    package static func of(
        pid: pid_t, arguments: [String], started: ProcessStart, own: pid_t,
        process: (pid_t) -> ProcessEntry?
    ) -> AttachClient? {
        guard let argument = argument(of: arguments) else { return nil }
        var reachedOwn = false
        let app = TerminalApp.find(from: pid) { next in
            if next == own {
                reachedOwn = true
                return nil
            }
            return process(next)
        }
        if reachedOwn { return nil }
        return AttachClient(pid: pid, started: started, argument: argument, app: app)
    }
}

extension ProcessTable {
    // The attach clients of the table (AttachClient.of), in the order of their PIDs.
    package func attachClients(own: pid_t) -> [AttachClient] {
        keys.sorted().compactMap { pid in
            guard let entry = self[pid] else { return nil }
            return AttachClient.of(
                pid: pid, arguments: entry.arguments, started: entry.started, own: own
            ) { self[$0] }
        }
    }
}
