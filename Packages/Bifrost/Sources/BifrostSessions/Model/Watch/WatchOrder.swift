// The order rules of the Watchlist (docs/behaviour/panels.md, "The Watchlist"): the watched rows
// in watch order, the place of a drop, the move and cancel rules, and the text of an empty
// Watchlist. The rules are pure. The colour of Add to watchlist with no colour choice is
// RunPlan.defaultWatchColour.
import BifrostFoundation

package enum WatchOrder {
    // The watched rows, in watch order.
    package static func watched(_ rows: [SessionRow]) -> [SessionRow] {
        rows.filter { $0.watch != nil }.sorted { ($0.watch?.order ?? 0) < ($1.watch?.order ?? 0) }
    }

    // The session that the dragged row goes before, or nil for the end of the list. The pointer
    // is over the row at the index over. The upper half of a row puts the dragged row before it,
    // and the lower half puts it after it. A drop on the dragged row gives the place that it has
    // now: the place before the row that follows it.
    package static func dropTarget(
        _ order: [String], dragged: String, over: Int, upperHalf: Bool
    ) -> String? {
        guard !order.isEmpty else { return nil }
        let index = min(max(over, 0), order.count - 1)
        let onSelf = order[index] == dragged
        let at = upperHalf && !onSelf ? index : index + 1
        let before = order.indices.contains(at) ? order[at] : nil
        // The place before the dragged row itself is the place before the row after it.
        guard before == dragged else { return before }
        return order.indices.contains(at + 1) ? order[at + 1] : nil
    }

    // True when a drop of the row before the session changes the order. A drop at the place that
    // the row has now, or a row that is not in the list, is not a move.
    package static func isMove(_ order: [String], dragged: String, before: String?) -> Bool {
        guard let at = order.firstIndex(of: dragged) else { return false }
        let next = order.indices.contains(at + 1) ? order[at + 1] : nil
        return before != next
    }

    // True when the release of a drag must move the row. A cancelled drag never moves.
    package static func shouldMove(
        _ order: [String], dragged: String, before: String?, cancelled: Bool
    ) -> Bool {
        !cancelled && isMove(order, dragged: dragged, before: before)
    }

    // The text of an empty Watchlist. It names the menu item with the label of the label set.
    package static func emptyText(_ labels: LabelSet) -> String {
        "Nothing on your watchlist yet. Right-click a session and choose "
            + "\(ActionID.watchAdd.label(labels))."
    }
}
