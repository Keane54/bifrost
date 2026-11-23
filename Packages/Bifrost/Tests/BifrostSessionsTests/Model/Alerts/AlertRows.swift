import BifrostSessions
import BifrostTestSupport

// The rows of the tests of the box alerts: the rules, the core and the alert service.

// A row with a box. The state is the state that the registry gives with the box: idle for no box
// or a yellow box, and needs you for a red box.
func alertRow(
    _ sessionId: String, _ alert: SessionAlert, name: String? = nil, state: SessionState? = nil,
    lastActivity: Int = 1, busyAt: Int? = nil
) -> SessionRow {
    let standard: SessionState =
        switch alert {
        case .none, .yellow: .idle
        case .red: .needsYou
        }
    var row = SessionRow.test(
        sessionId: sessionId, shortId: nil, name: name ?? "bifrost-test-\(sessionId.suffix(1))",
        state: state ?? standard, lastActivity: lastActivity)
    row.alert = alert
    row.lastBusyAt = busyAt
    return row
}

// The session IDs of count rows, in order.
func alertIds(_ count: Int) -> [String] {
    (0..<count).map { "bbbbbbbb-0000-4000-8000-00000000000\($0)" }
}
