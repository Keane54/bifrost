import BifrostSessions
import Darwin
import Foundation

extension SessionRow {
    // A row for a test: an owned, idle session "alpha" with the short ID "aaaaaaaa" and no box. A
    // test names only the values that it needs.
    package static func test(
        sessionId: String = "s1", shortId: ShortID? = "aaaaaaaa", name: String = "alpha",
        claudeName: String? = nil, kind: SessionKind = .owned, pid: pid_t? = nil,
        cwd: String = "/p", state: SessionState = .idle, lastActivity: Int = 1,
        startedAt: Int = 1
    ) -> SessionRow {
        SessionRow(
            sessionId: sessionId, shortId: shortId, name: name, claudeName: claudeName ?? name,
            kind: kind, pid: pid, cwd: cwd, status: .idle, state: state,
            lastActivity: lastActivity, startedAt: startedAt)
    }
}

// The colour of the alert box of a row, for a test that checks only the colour.
package enum AlertColour: Sendable {
    case none, yellow, red
}

extension SessionAlert {
    package var colour: AlertColour {
        switch self {
        case .none: .none
        case .yellow: .yellow
        case .red: .red
        }
    }

    // The cause of a red box, or nil.
    package var reason: SessionBoxReason? {
        if case .red(let reason, _) = self { reason } else { nil }
    }

    // True for a row with a box: the row flashes.
    package var flashes: Bool { self != .none }
}

extension CheckedAttach {
    // A checked attach for a test that opens a PTY with no session list: the check of one owned
    // row of the session of the view, with the short ID, in the folder. The check gives the root
    // folder to a hidden attach (PTYView.input).
    package static func test(
        _ view: PTYView, shortId: ShortID, directory: String = "/"
    ) -> CheckedAttach {
        let row = SessionRow.test(sessionId: view.session, shortId: shortId, cwd: directory)
        do {
            return try AttachRules.check([row], view: view, shortId: shortId)
        } catch {
            preconditionFailure("The check of a test attach failed: \(error)")
        }
    }
}

extension RegistryStore {
    // The store of the text of a store file, for a test of the decoder. Text that is not JSON,
    // and JSON that is not an object, give an empty store.
    package static func load(from data: Data) -> RegistryStore {
        (try? JSONDecoder().decode(RegistryStore.self, from: data)) ?? RegistryStore()
    }
}
