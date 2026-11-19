import Foundation

// The value types of the session registry. A wall time from Claude Code, the mod or the clock is
// milliseconds since 1970 as Int (row D1 of docs/ports/registry). A time span of a rule is a
// Duration.

extension Date {
    // The wall time in whole milliseconds since 1970, the form of the registry (row D1), of the
    // JSON of Claude Code and of the lines of the mod. It rounds down, so the milliseconds of now
    // are never later than now.
    package var millisecondsSince1970: Int { Int((timeIntervalSince1970 * 1000).rounded(.down)) }
}

package enum SessionState: Sendable {
    case working
    case needsYou
    case error
    case idle
    case parked
}

// The cause of a red box.
package enum SessionBoxReason: Sendable {
    case prompt, escalated, error
}

// The alert box of a row, with the time of the box in milliseconds since 1970. Only a red box
// has a cause.
package enum SessionAlert: Sendable, Equatable {
    case none
    case yellow(since: Int)
    case red(SessionBoxReason, since: Int)

    // The time of the box, or nil for no box.
    package var since: Int? {
        switch self {
        case .none: nil
        case .yellow(let since), .red(_, let since): since
        }
    }

    // A red box of a prompt blocks Send message, Run slash command, Compact and Rename
    // (docs/behaviour/input.md, The text plan), because typed text can answer the prompt by
    // accident. An escalated yellow box and an error box do not block.
    package var blocksPrompt: Bool {
        if case .red(.prompt, _) = self { true } else { false }
    }
}

package enum SessionKind: Sendable {
    case owned, external
}

// The priority of a session. 1 is the highest.
package enum SessionPriority: Int, Codable, Sendable, CaseIterable {
    case p1 = 1, p2, p3, p4, p5
}

// The colours of a watched session, in the order of the colour picker.
package enum WatchColour: String, Codable, Sendable, CaseIterable {
    case darkRed = "dark-red"
    case red
    case amber
    case yellow
    case green
    case lightBlue = "light-blue"
    case darkBlue = "dark-blue"
    case white

    // The names that earlier versions saved, and the colour that replaces each name.
    static let oldNames: [String: WatchColour] = [
        "blue": .darkBlue, "cyan": .lightBlue, "green": .green, "lime": .green,
        "orange": .amber, "pink": .red, "purple": .darkBlue, "white": .white,
    ]

    // A colour name of the store file: a current name, or an old name that maps to a colour.
    init?(storedName: String) {
        if let colour = WatchColour(rawValue: storedName) {
            self = colour
        } else if let colour = Self.oldNames[storedName] {
            self = colour
        } else {
            return nil
        }
    }
}

package enum HookEventName: String, Sendable, CaseIterable {
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case permissionRequest = "PermissionRequest"
    case postToolUse = "PostToolUse"
    case notification = "Notification"
    case stop = "Stop"
    case stopFailure = "StopFailure"
    // No hook has this name. The mod gives it for a turn that the user stopped.
    case turnAborted = "TurnAborted"
}

// One state event of a session, from the Live details mod.
package struct HookEvent: Sendable, Equatable {
    package var name: HookEventName
    package var sessionId: String
    package var at: Int
    // The order number of the mod for one session. Only lines of the mod have it.
    package var seq: Int?
    package var cwd: String?
    package var toolName: String?
    package var notificationType: String?
    package var lastAssistantMessage: String?
    // The reason of a SessionEnd, for example "clear". A /clear keeps the process.
    package var reason: String?

    package init(
        _ name: HookEventName, _ sessionId: String, at: Int, seq: Int? = nil, cwd: String? = nil,
        toolName: String? = nil, notificationType: String? = nil,
        lastAssistantMessage: String? = nil, reason: String? = nil
    ) {
        self.name = name
        self.sessionId = sessionId
        self.at = at
        self.seq = seq
        self.cwd = cwd
        self.toolName = toolName
        self.notificationType = notificationType
        self.lastAssistantMessage = lastAssistantMessage
        self.reason = reason
    }
}

// The status of a session in "claude agents --json". unknown is the value for no status and for
// a status that this version does not know.
package enum AgentStatus: String, Sendable, Decodable {
    case busy, waiting, idle, unknown

    package init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        self = AgentStatus(rawValue: text) ?? .unknown
    }
}

// One entry of "claude agents --json".
package struct AgentEntry: Sendable, Equatable {
    package var sessionId: String
    package var cwd: String
    // True for a background job. Each other kind is an interactive session.
    package var isBackground: Bool
    package var startedAt: Int
    package var name: String
    package var status: AgentStatus
    // Missing for about 2.5 s after a start, and after a stop.
    package var pid: pid_t?
    // The short ID. An id that is not a short ID is no short ID.
    package var id: ShortID?
    // Comes with the status waiting.
    package var waitingFor: String?

    package init(
        sessionId: String, cwd: String = "", isBackground: Bool = false, startedAt: Int = 0,
        name: String = "", status: AgentStatus = .unknown, pid: pid_t? = nil,
        id: ShortID? = nil,
        waitingFor: String? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.isBackground = isBackground
        self.startedAt = startedAt
        self.name = name
        self.status = status
        self.pid = pid
        self.id = id
        self.waitingFor = waitingFor
    }
}

// The reason why Bifrost cannot read the list of the sessions. The data of a case is for the
// log only, because it can hold a path or the text of claude. The Overview shows the message.
package enum AgentListError: Error, Sendable, Hashable {
    // claude wrote no text.
    case emptyOutput
    // No line of the output starts with "[".
    case noArray
    // The JSON value is not an array.
    case notAnArray
    // The JSON does not parse. The detail is the text of the decoder.
    case badJSON(detail: String)
    // The run of claude did not succeed. The detail is the trimmed stderr, or the text of the end
    // when stderr is empty.
    case commandFailed(detail: String)
    // The app did not find claude.
    case claudeNotFound

    // The text of the error line of the Overview. It never holds the detail.
    package var message: String {
        switch self {
        case .emptyOutput:
            "Bifrost can't read your sessions right now because Claude Code sent an empty list. "
                + "It'll keep trying."
        case .noArray, .notAnArray, .badJSON:
            "Bifrost can't read your sessions right now because it doesn't understand the list "
                + "from Claude Code. It'll keep trying."
        case .commandFailed:
            "Bifrost can't read your sessions right now because Claude Code ran into a problem. "
                + "It'll keep trying."
        case .claudeNotFound:
            "Bifrost can't find Claude Code. Install it, then open Bifrost again."
        }
    }

    // The reason as a clause after "because", for a text that says what the failed list stopped.
    // It never holds the detail.
    package var cause: String {
        switch self {
        case .emptyOutput: "Claude Code sent an empty list of sessions"
        case .noArray, .notAnArray, .badJSON:
            "it doesn't understand the list of sessions from Claude Code"
        case .commandFailed: "Claude Code ran into a problem"
        case .claudeNotFound: "it can't find Claude Code"
        }
    }
}

// A list of the sessions from "claude agents --json", or the reason why there is no list.
package enum AgentList: Sendable, Equatable {
    // partial is true when the parser skipped an entry, so the list can miss a session that
    // exists.
    case parsed(entries: [AgentEntry], partial: Bool)
    case failed(AgentListError)

    // A parsed list.
    package init(entries: [AgentEntry] = [], partial: Bool = false) {
        self = .parsed(entries: entries, partial: partial)
    }

    // The entries of a parsed list. A failed list has no entries.
    package var entries: [AgentEntry] {
        if case .parsed(let entries, _) = self { entries } else { [] }
    }

    // True when the parser skipped an entry.
    package var partial: Bool {
        if case .parsed(_, let partial) = self { partial } else { false }
    }

    // The reason of a failed list, or nil.
    package var error: AgentListError? {
        if case .failed(let error) = self { error } else { nil }
    }
}

// One usage window of the plan. resetsAt is in milliseconds.
package struct RateWindow: Sendable, Equatable {
    package var usedPercent: Double
    package var resetsAt: Int

    package init(usedPercent: Double, resetsAt: Int) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    // The time of a reset time in milliseconds since 1970, or nil (row V2 of
    // docs/ports/live/DELIBERATE-DIFFERENCES.md). The form is ISO 8601: the date, T, the time, an
    // optional fraction, and Z or an offset. The time rounds to the nearest millisecond. The
    // usage lines of the mod and the answer of the account usage both use it.
    package static func resetTime(_ text: String) -> Int? {
        guard let date = try? resetTimeStyle.parse(text) else { return nil }
        return Int(exactly: (date.timeIntervalSince1970 * 1000).rounded())
    }
}

private let resetTimeStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

// The usage windows of the plan. A plan can lack a window.
package struct RateLimits: Sendable, Equatable {
    package var fiveHour: RateWindow?
    package var sevenDay: RateWindow?

    package init(fiveHour: RateWindow? = nil, sevenDay: RateWindow? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }
}

// One usage line of the Live details mod.
package struct LiveUsage: Sendable, Equatable {
    package var model: String?
    package var contextPercent: Double?
    package var contextTokens: Int?
    package var contextWindow: Int?
    package var costUsd: Double?
    package var rateLimits: RateLimits?
    package var version: String?
    package var effort: String?
    package var permissionMode: String?
    // A path from another program: no code uses it yet. A later use must first resolve the links
    // and accept only a regular .jsonl file of this user below <shared home>/.claude/projects/,
    // and must never give it to a shell.
    package var transcriptPath: String?

    package init(
        model: String? = nil, contextPercent: Double? = nil, contextTokens: Int? = nil,
        contextWindow: Int? = nil, costUsd: Double? = nil, rateLimits: RateLimits? = nil,
        version: String? = nil, effort: String? = nil, permissionMode: String? = nil,
        transcriptPath: String? = nil
    ) {
        self.model = model
        self.contextPercent = contextPercent
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.costUsd = costUsd
        self.rateLimits = rateLimits
        self.version = version
        self.effort = effort
        self.permissionMode = permissionMode
        self.transcriptPath = transcriptPath
    }
}

// One line of the Live details mod: a state event or a usage line.
package enum LiveEvent: Sendable, Equatable {
    case state(HookEvent)
    case usage(sessionId: String, at: Int, LiveUsage)
}

// The newest rate limits, chosen from the usage lines of all sessions.
package struct UsageSnapshot: Sendable, Equatable {
    package var sessionId: String
    package var name: String
    package var updatedAt: Int
    package var limits: RateLimits

    package init(sessionId: String, name: String, updatedAt: Int, limits: RateLimits) {
        self.sessionId = sessionId
        self.name = name
        self.updatedAt = updatedAt
        self.limits = limits
    }
}

// A Delete of a session whose worktree another session uses. sessionId is the row ID. worktree
// is the worktree root. job is the short ID of the row at the defer.
package struct DeferredDelete: Codable, Sendable, Equatable {
    package var sessionId: String
    package var shortId: ShortID
    package var worktree: String
    package var job: ShortID?

    package init(sessionId: String, shortId: ShortID, worktree: String, job: ShortID? = nil) {
        self.sessionId = sessionId
        self.shortId = shortId
        self.worktree = worktree
        self.job = job
    }
}

// One entry of the watchlist. The array order of the watchlist is its order on the screen.
package struct WatchEntry: Codable, Sendable, Equatable {
    package var sessionId: String
    package var colour: WatchColour

    package init(_ sessionId: String, _ colour: WatchColour) {
        self.sessionId = sessionId
        self.colour = colour
    }
}

// The terminal app that holds a session process.
package struct TerminalApp: Sendable, Equatable {
    package var name: String
    package var bundle: String

    package init(name: String, bundle: String) {
        self.name = name
        self.bundle = bundle
    }
}

// The terminal apps of a read of PIDs (ProcessInspector.terminalApps): the app of each PID that
// has one, and each PID with no app. A PID that the read cannot see has no app.
package struct TerminalApps: Sendable, Equatable {
    package var apps: [pid_t: TerminalApp]
    package var noApp: Set<pid_t>

    package init(apps: [pid_t: TerminalApp] = [:], noApp: Set<pid_t> = []) {
        self.apps = apps
        self.noApp = noApp
    }

    // The apps of the PIDs that find gives. A PID that find gives no app for has no app.
    package init(of pids: [pid_t], find: (pid_t) -> TerminalApp?) {
        self.init()
        for pid in pids {
            if let app = find(pid) { apps[pid] = app } else { noApp.insert(pid) }
        }
    }
}

// The colour and the 0-based place of a watched row.
package struct RowWatch: Sendable, Equatable {
    package var colour: WatchColour
    package var order: Int

    package init(colour: WatchColour, order: Int) {
        self.colour = colour
        self.order = order
    }
}

// Whether the active list has a row (docs/behaviour/live.md, "Live state is a hint, not an
// authority"). An entry stays in the active list with no pid and no status for about 2.5 s after
// a start, and with no pid after a stop.
package enum ActiveListing: Sendable, Hashable {
    // The last active list does not have the row.
    case notListed
    // The last active list has the row.
    case listed
    // An --all read added the row with no pid, and no active list of a later turn came yet. The
    // --all list can show a session that starts before an active list has it, so the row counts
    // as listed until such an active list also lacks it.
    case unconfirmed
}

// One row of the session list.
public struct SessionRow: Sendable, Equatable {
    // The row ID: the first session ID that Bifrost saw for the session. It never changes.
    public var sessionId: String
    // The session ID of the conversation that the row shows now, when it is not sessionId.
    package var currentId: String?
    // For an owned row: the session ID that Resume passes, when Bifrost knows it.
    package var resumeId: String?
    package var shortId: ShortID?
    // The local name when one exists, else claudeName.
    package var name: String
    package var claudeName: String
    package var kind: SessionKind
    package var pid: pid_t?
    package var cwd: String
    // The status of the last sample. A parked row has the status unknown.
    package var status: AgentStatus
    package var listing: ActiveListing
    package var waitingFor: String?
    package var state: SessionState
    // The alert box. A row with a box flashes.
    package var alert: SessionAlert
    package var lastMessage: String?
    package var lastActivity: Int
    package var startedAt: Int
    // The last usage line of the mod for the session, when the row gets its live lines.
    package var usage: LiveUsage?
    // True when the mod sent a line for the session in the last 90 s.
    package var live: Bool
    package var branch: String?
    package var worktree: String?
    package var priority: SessionPriority?
    package var watch: RowWatch?
    // True for a parked row that Resume all resumes.
    package var resumable: Bool
    // True for a review session of a PR.
    package var prSession: Bool
    package var terminalApp: String?

    package init(
        sessionId: String, currentId: String? = nil, resumeId: String? = nil,
        shortId: ShortID? = nil, name: String, claudeName: String, kind: SessionKind,
        pid: pid_t? = nil, cwd: String, status: AgentStatus, listing: ActiveListing = .notListed,
        waitingFor: String? = nil,
        state: SessionState, alert: SessionAlert = .none, lastMessage: String? = nil,
        lastActivity: Int, startedAt: Int, usage: LiveUsage? = nil, live: Bool = false,
        branch: String? = nil,
        worktree: String? = nil, priority: SessionPriority? = nil, watch: RowWatch? = nil,
        resumable: Bool = false, prSession: Bool = false, terminalApp: String? = nil
    ) {
        self.sessionId = sessionId
        self.currentId = currentId
        self.resumeId = resumeId
        self.shortId = shortId
        self.name = name
        self.claudeName = claudeName
        self.kind = kind
        self.pid = pid
        self.cwd = cwd
        self.status = status
        self.listing = listing
        self.waitingFor = waitingFor
        self.state = state
        self.alert = alert
        self.lastMessage = lastMessage
        self.lastActivity = lastActivity
        self.startedAt = startedAt
        self.usage = usage
        self.live = live
        self.branch = branch
        self.worktree = worktree
        self.priority = priority
        self.watch = watch
        self.resumable = resumable
        self.prSession = prSession
        self.terminalApp = terminalApp
    }
}

extension SessionRow {
    // The display name of the model of the usage line, for example "Opus 5.5".
    package var model: String? { usage?.model.map(modelName) }

    // True when the row counts as listed: the active list has it, or no later active list
    // confirmed the --all read that added it.
    package var listedActive: Bool { listing != .notListed }
}
