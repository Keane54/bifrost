import BifrostSessions
import Observation

// The selected session. The key commands move the selection, and a focus in a chat window selects
// its session (FocusChange). The rows live only in the session list (user decision, 2026-11-16),
// so the model reads the rows from the list when a key asks, and it keeps no copy of them. The
// order of the rows of an Overview comes from the Overview (OverviewModel.viewRows).
@MainActor
@Observable
public final class SelectionModel {
    // The session ID of the selected row, or nil when no row is selected.
    package var selectedId: String?
    @ObservationIgnored private let list: SessionListModel

    public init(list: SessionListModel) {
        self.list = list
    }

    // The session IDs of all rows of the session list, in the order of the list. A focus in a
    // chat window selects only a session that has a row.
    package var listIds: [String] {
        list.rows.map(\.sessionId)
    }

    // The rows whose chat can open now: an owned session that is not parked. The set comes from
    // the rows of the list at each read. A key does not open the chat of another row.
    package var ownedIds: Set<String> {
        Set(list.rows.lazy.filter(\.isOwnedAndNotParked).map(\.sessionId))
    }

    // True when the selected ID is a row of the session list. A selected ID that is not in the
    // rows is no selection for a key.
    package var hasSelectedRow: Bool {
        guard let selectedId else { return false }
        return list.rows.contains { $0.sessionId == selectedId }
    }

    // The selected row of the session list now, or nil. The Selected Item panel reads it at each
    // change, so it never shows a copy of an old row.
    package var selectedRow: SessionRow? {
        guard let selectedId else { return nil }
        return list.rows.first { $0.sessionId == selectedId }
    }
}
