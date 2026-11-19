import BifrostFoundation
import OSLog

// An event of the sessions for the log. Each message of an error can hold a path, so it is
// private in the log.
package enum SessionsLogEvent: Sendable, Hashable {
    // A loop of the registry failed. The next run tries again.
    case registryLoopFailed(message: String)
    // A list of the sessions failed. The next poll tries again. The Overview shows only the
    // message of the reason, so the log has its detail.
    case agentListFailed(AgentListError)
    // A save of the registry store failed. The next change saves again.
    case registryStoreSaveFailed(message: String)
    // The hidden attach of a send or an Interrupt did not open.
    case hiddenAttachFailed(message: String)
    // The login shell of the start ended like this, and the app uses its own env. .exited(0)
    // means that the output did not parse. took is the time that the shell took.
    case loginShellFailed(ExecEnd, took: Duration)
    // A session command (New session, Stop, Resume, Resume all, Delete, Take control) ended.
    // session is the row ID of the command or of the new session, and nil for Resume all.
    case sessionCommandDone(ActionID, session: String?)
    // A session command was refused or failed with the refusal. session is the row ID of the
    // command, or nil when the command has none. Resume all gives one event for each session
    // that it did not resume.
    case sessionCommandFailed(ActionID, session: String?, ActionRefusal)
    // The claude rm of a Delete ended after its job: the job ended at the limit of the run, at a
    // cancel or at the quit. session is the row ID of the session of the claude rm.
    case claudeRmEndedAfterItsJob(session: String, ExecEnd)
}

// Where the sessions send their events. The app uses SystemSessionsLog. A test records the
// events.
package protocol SessionsLog: Sendable {
    func record(_ event: SessionsLogEvent)
}

// The log of the sessions in the unified log of macOS.
package struct SystemSessionsLog: SessionsLog {
    private static let logger = Logger(bifrost: "sessions")

    package init() {}

    package func record(_ event: SessionsLogEvent) {
        let log = Self.logger
        switch event {
        case .registryLoopFailed(let message):
            log.error(
                "A registry loop failed. The next run tries again. \(message, privacy: .private)")
        case .agentListFailed(let error):
            log.error(
                """
                Bifrost cannot read the session list (\(Self.reason(error), privacy: .public)). \
                The next poll tries again. \(Self.detail(error), privacy: .private)
                """)
        case .registryStoreSaveFailed(let message):
            log.error("Bifrost cannot save the registry store. \(message, privacy: .private)")
        case .hiddenAttachFailed(let message):
            log.error("The hidden attach did not open. \(message, privacy: .private)")
        case .loginShellFailed(let end, let took):
            let time = took.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))
            log.notice(
                """
                Bifrost uses its own env, because the login shell failed \
                (\(Self.reason(end), privacy: .public)). Time: \(time, privacy: .public).
                """)
        case .sessionCommandDone(let command, let session):
            log.notice(
                """
                The session command \(command.rawValue, privacy: .public) ended. \
                Session: \(session ?? "none", privacy: .private).
                """)
        case .sessionCommandFailed(let command, let session, let refusal):
            log.notice(
                """
                The session command \(command.rawValue, privacy: .public) did not end as asked \
                (\(Self.reason(refusal), privacy: .public)). \
                Session: \(session ?? "none", privacy: .private). \
                \(refusal.message, privacy: .private)
                """)
        case .claudeRmEndedAfterItsJob(let session, let end):
            log.notice(
                """
                A claude rm of Delete ended after its job (\(Self.word(end), privacy: .public)). \
                Session: \(session, privacy: .private).
                """)
        }
    }

    // How a program ended, in fixed words and numbers.
    static func word(_ end: ExecEnd) -> String {
        switch end {
        case .exited(let code): "exit code \(code)"
        case .timedOut: "timeout"
        case .signal(let number): "signal \(number)"
        case .overflow: "too much output"
        case .cancelled: "cancelled"
        case .notStarted: "not started"
        }
    }

    // The reason of a failed list, in fixed words.
    private static func reason(_ error: AgentListError) -> String {
        switch error {
        case .emptyOutput: "empty output"
        case .noArray: "no JSON array in the output"
        case .notAnArray: "the output is not an array"
        case .badJSON: "the JSON does not parse"
        case .commandFailed: "claude failed"
        case .claudeNotFound: "claude not found"
        }
    }

    // The detail of a failed list: the text of the decoder or of claude. It can hold a path.
    private static func detail(_ error: AgentListError) -> String {
        switch error {
        case .badJSON(let detail), .commandFailed(let detail): detail
        case .emptyOutput, .noArray, .notAnArray, .claudeNotFound: ""
        }
    }

    // The reason of a refusal in a fixed word: the name of its case, with no data. The data can
    // hold a path or a text of claude, so only the message has it. A case with data has a label.
    // A case with no data prints its name. Another form gives "unknown", so no data can reach
    // the word.
    static func reason(_ refusal: ActionRefusal) -> String {
        let mirror = Mirror(reflecting: refusal)
        if let label = mirror.children.first?.label { return label }
        guard mirror.children.isEmpty else { return "unknown" }
        let name = String(describing: refusal)
        return name.wholeMatch(of: /[a-z][A-Za-z]*/) != nil ? name : "unknown"
    }

    // The reason of a failed login shell.
    private static func reason(_ end: ExecEnd) -> String {
        switch end {
        case .exited(0): "the output did not parse"
        case .exited(let code): "exit code \(code)"
        case .timedOut: "timeout"
        case .signal(let number): "signal \(number)"
        case .overflow: "too much output"
        case .cancelled: "cancelled"
        case .notStarted: "it did not start"
        }
    }
}
