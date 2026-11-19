import BifrostSessions
import Darwin
import Observation

// The sources of the rows for the tests of the views.

// A source with the rows that a test gives. It is observable, as the registry service is.
@MainActor
@Observable
package final class FakeRowSource: SessionRowSource {
    package private(set) var rows: [SessionRow] = []
    package private(set) var error: AgentListError?
    package private(set) var loaded = false

    package init() {}

    // An update of the list, as an active poll of the registry gives it.
    package func apply(rows: [SessionRow], error: AgentListError?) {
        self.rows = rows
        self.error = error
        loaded = true
    }

    // An update with one idle row for each ID, in this order. An ID in owned is an owned row,
    // and another ID is an external row. With no owned set, each row is owned.
    package func apply(ids: [String], owned: Set<String>? = nil) {
        let rows = ids.map { id in
            SessionRow.test(
                sessionId: id, kind: owned.map { $0.contains(id) } ?? true ? .owned : .external)
        }
        apply(rows: rows, error: nil)
    }
}

extension SessionListModel {
    // A list that reads its rows from the source, for a test of the views.
    package static func reading(_ source: FakeRowSource) -> SessionListModel {
        let list = SessionListModel()
        list.read(from: source)
        return list
    }
}

// The dependencies of a real registry service with a fixed session list. The --all list fails,
// so it changes nothing. No branch, no process table, and a save does nothing.
package struct FixedRegistryDeps: RegistryServiceDeps {
    private let active: [AgentEntry]

    package init(active: [AgentEntry]) {
        self.active = active
    }

    package func listActive() async throws -> AgentList { AgentList(entries: active) }
    package func listAll() async throws -> AgentList {
        .failed(.commandFailed(detail: "not in the test"))
    }
    package func readBranch(_ cwd: String) async throws -> String? { nil }
    package func readTerminalApps(_ pids: [pid_t]) async -> TerminalApps { TerminalApps() }
    package func readAttachClients() async -> [AttachClient] { [] }
    package func saveStore(_ store: RegistryStore) async throws {}
}
