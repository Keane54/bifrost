import BifrostFoundation
import BifrostSessions
import Darwin

// A terminal process of the PTY manager: the attach of a chat window or a hidden attach of the
// session input, with the pid of its child.
package struct TerminalProcess: Sendable, Hashable {
    package var view: PTYView
    package var pid: pid_t

    package init(view: PTYView, pid: pid_t) {
        self.view = view
        self.pid = pid
    }
}

// What one tick reads from the app and the system.
package struct AppReading: Sendable {
    package var table: TableRead
    package var terminals: [TerminalProcess]
    // The sessions whose chat panel is open in the window.
    package var chatPanels: Set<SessionID>
    // The use of the Claude sessions, or nil when the read of the table failed (no app process).
    package var sessions: SessionsUse?
}

// The use of one Claude session: its row and the use of its process tree.
package struct SessionUse: Sendable, Equatable {
    package var row: SessionRow
    package var use: Use
}

// A number of sessions and their use together.
package struct SessionGroup: Sendable, Equatable {
    package var count: Int
    package var use: Use

    package init(count: Int, use: Use) {
        self.count = count
        self.use = use
    }
}

// The Claude sessions of the panel: all of them together, the three with the most memory, and
// the others in one group.
package struct SessionsUse: Sendable, Equatable {
    package var total: Use
    package var top: [SessionUse]
    package var more: SessionGroup
}

// The sources of the use of Bifrost and of the Claude sessions (docs/behaviour/health.md,
// "Performance"). The app gives the PTYs of the PTY manager, the rows of the registry and the open
// chat panels. One read of the process table gives the processes.
package struct AppUsage: Sendable {
    // The sessions with their own row in the panel. The others go in the group "more".
    package static let topCount = 3

    // The pid of the app.
    package let app: pid_t
    private let processes: any ProcessSampling
    private let terminals: @MainActor () -> [TerminalProcess]
    private let rows: @MainActor () -> [SessionRow]
    private let chatPanels: @MainActor () -> Set<SessionID>

    package init(
        processes: any ProcessSampling = ProcessTable(), app: pid_t = getpid(),
        terminals: @escaping @MainActor () -> [TerminalProcess],
        rows: @escaping @MainActor () -> [SessionRow],
        chatPanels: @escaping @MainActor () -> Set<SessionID>
    ) {
        self.processes = processes
        self.app = app
        self.terminals = terminals
        self.rows = rows
        self.chatPanels = chatPanels
    }

    // The sources of the app at this time, then one read of the process table at the time of the
    // timeline. The read, the grouping of the table and the use of the sessions (since the
    // earlier read) run off the main actor.
    @MainActor package func read(at time: Duration, since earlier: TableRead?) async -> AppReading {
        let terminals = terminals()
        let rows = rows()
        let chatPanels = chatPanels()
        let own = Set(terminals.map(\.pid) + [app])
        let (table, sessions) = await Self.measure(
            processes, rows: rows, own: own, app: app, at: time, since: earlier)
        return AppReading(
            table: table, terminals: terminals, chatPanels: chatPanels, sessions: sessions)
    }

    @concurrent private static func measure(
        _ processes: any ProcessSampling, rows: [SessionRow], own: Set<pid_t>, app: pid_t,
        at time: Duration, since earlier: TableRead?
    ) async -> (TableRead, SessionsUse?) {
        let read = TableRead(at: time, await processes.read())
        guard read.processes[app] != nil else { return (read, nil) }
        return (read, sessions(rows, in: read, since: earlier, own: own))
    }

    // The use of each session: the process of its row and all the child processes of that
    // process. The processes of Bifrost (own: the app and its chat terminals) and their child
    // processes count for no session. A process counts one time: a session that started inside
    // another session keeps its own processes, because the smaller tree takes its processes
    // first. A row with no pid, or with a process that is not in the table, has no use. The CPU
    // of a process with no earlier CPU time is 0.
    package static func sessions(
        _ rows: [SessionRow], in read: TableRead, since earlier: TableRead?, own: Set<pid_t>
    ) -> SessionsUse {
        var children: [pid_t: [pid_t]] = [:]
        for process in read.processes.values where !own.contains(process.pid) {
            children[process.parent, default: []].append(process.pid)
        }
        let trees: [(row: SessionRow, pids: [pid_t])] = rows.compactMap { row in
            guard let pid = row.pid, !own.contains(pid), read.processes[pid] != nil else {
                return nil
            }
            return (row, tree(of: pid, children: children))
        }
        var counted: Set<pid_t> = []
        var list: [SessionUse] = []
        for (row, pids) in trees.sorted(by: { $0.pids.count < $1.pids.count }) {
            var use = Use.zero
            var found = false
            for pid in pids where !counted.contains(pid) {
                guard let process = read.processes[pid] else { continue }
                counted.insert(pid)
                found = true
                use = use + Use(
                    memory: process.footprint, cpu: read.cpu(of: pid, since: earlier) ?? 0)
            }
            // A row with the pid of an earlier row has no process left.
            if found { list.append(SessionUse(row: row, use: use)) }
        }
        list.sort { $0.use.memory > $1.use.memory }
        let rest = list.dropFirst(topCount)
        return SessionsUse(
            total: list.map(\.use).reduce(.zero, +), top: Array(list.prefix(topCount)),
            more: SessionGroup(count: rest.count, use: rest.map(\.use).reduce(.zero, +)))
    }

    // The process and all its child processes. Each pid is in the list one time.
    private static func tree(of root: pid_t, children: [pid_t: [pid_t]]) -> [pid_t] {
        var seen: Set<pid_t> = []
        var stack = [root]
        var pids: [pid_t] = []
        while let pid = stack.popLast() {
            guard seen.insert(pid).inserted else { continue }
            pids.append(pid)
            stack += children[pid] ?? []
        }
        return pids
    }
}

// Finds the terminal processes with no chat window. A hidden attach of the session input closes
// soon after its last write, so it counts from its start. The attach of a chat counts while no
// chat panel of its session is open. A terminal process is an orphan after 60 s of this state.
package struct OrphanWatch: Sendable {
    package static let after = Duration.seconds(60)

    // The time since when each terminal process has had no chat window.
    private var since: [TerminalProcess: Duration] = [:]

    package init() {}

    // The number of orphans at the time. A terminal process that is gone, or that has its chat
    // window again, starts from 0 the next time.
    package mutating func count(
        _ terminals: [TerminalProcess], chatPanels: Set<SessionID>, at now: Duration
    ) -> Int {
        var next: [TerminalProcess: Duration] = [:]
        var count = 0
        for terminal in terminals {
            if case .chat(let session) = terminal.view, chatPanels.contains(session) { continue }
            let start = since[terminal] ?? now
            next[terminal] = start
            if now - start > Self.after { count += 1 }
        }
        since = next
        return count
    }
}
