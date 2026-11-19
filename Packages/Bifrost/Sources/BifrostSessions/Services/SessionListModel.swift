import Observation

// The status of the session list.
package enum SessionListStatus: Sendable, Equatable {
    // The app starts, and no list came yet.
    case starting
    // The app cannot find claude. The registry does not start (docs/behaviour/shell.md, The
    // start order).
    case claudeNotFound
    // The last update had no error.
    case ready
    // The last update had this error. The rows of the update stay on screen.
    case failed(AgentListError)
}

// The one place of the rows of the sessions and of the state of their list. The app gives the
// registry service. A test of the views gives a fake.
@MainActor
package protocol SessionRowSource: AnyObject, Observable {
    // The rows after the last change.
    var rows: [SessionRow] { get }
    // The error of the last active poll, or nil.
    var error: AgentListError? { get }
    // True when the first active poll ended.
    var loaded: Bool { get }
}

extension RegistryService: SessionRowSource {}

// The session list that the window shows. It keeps no copy of the rows: it reads them from their
// one source, the registry service, so a change of the registry is in the list in the same turn
// (user decision, 2026-11-16). Each read goes through Observation, so the shell, the panels and
// the chats see each change. The init is synchronous, so the window can show the "starting"
// status at once (docs/behaviour/shell.md, The start order).
@MainActor
@Observable
public final class SessionListModel {
    // The source of the rows, from the step of the start that made the registry.
    private var source: (any SessionRowSource)?
    private var claudeNotFound = false

    package init() {}

    // The rows of the source from its first active poll. No rows before it, and none with no
    // claude.
    public var rows: [SessionRow] {
        guard !claudeNotFound, let source, source.loaded else { return [] }
        return source.rows
    }

    // The status of the list. The rows of a poll with an error stay on screen. The status
    // "claude not found" never changes: with no claude, nothing more starts.
    package var status: SessionListStatus {
        if claudeNotFound { return .claudeNotFound }
        guard let source, source.loaded else { return .starting }
        return source.error.map(SessionListStatus.failed) ?? .ready
    }

    // True from the first active poll of the registry. Until then a chat shows "Waiting for the
    // session list.". With no claude, the list never loads.
    public var loaded: Bool {
        switch status {
        case .ready, .failed: true
        case .starting, .claudeNotFound: false
        }
    }

    // Read the rows and the error from the source from now on. After "claude not found" the list
    // reads nothing.
    package func read(from source: any SessionRowSource) {
        guard !claudeNotFound else { return }
        self.source = source
    }

    // The app cannot find claude. This status stays until the app quits.
    package func claudeMissing() {
        source = nil
        claudeNotFound = true
    }
}
