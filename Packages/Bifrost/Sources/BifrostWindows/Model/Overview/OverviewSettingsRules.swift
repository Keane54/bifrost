import BifrostKeyboard
import BifrostLayout
import BifrostSessions

// One row of the column list of the Overview Settings panel.
package struct ColumnRow: Sendable, Equatable {
    package let column: OverviewColumn
    package let label: String
    package let visible: Bool
    // True for the kind column: it is always first and always visible.
    package let locked: Bool

    package init(column: OverviewColumn, label: String, visible: Bool, locked: Bool) {
        self.column = column
        self.label = label
        self.visible = visible
        self.locked = locked
    }
}

// The rules of the Overview Settings panel of one Overview. The panel turns, moves and resets a
// column with OverviewConfig.apply, as the tab menu and the table header do. These rules give the
// column list, the next config of a filter switch, the drop of a dragged column row and the
// colour that an arrow key chooses.
package enum OverviewSettingsRules {
    // A release more than this distance outside the list, in layout units, does not move the
    // row. So the user can stop a drag with no change: move the pointer away from the list and
    // release it there.
    package static let dropMargin = 24.0

    // One row for each column, in the order of the tab: the top row is the leftmost column. The
    // kind column has the label "Kind" here, because its header has no text. An unknown tab gives
    // no rows.
    package static func columnRows(_ config: OverviewConfig, tab: String) -> [ColumnRow] {
        guard let tab = config.tabs.first(where: { $0.id == tab }) else { return [] }
        return tab.order.map { column in
            ColumnRow(
                column: column, label: column == .kind ? "Kind" : column.label,
                visible: tab.columns.contains(column), locked: column == .kind)
        }
    }

    // Show or hide the rows of one state. The states stay in the order of TabFilter.allStates.
    package static func showState(
        _ config: OverviewConfig, tab: String, _ state: SessionState, _ on: Bool
    ) -> OverviewConfig {
        withFilter(config, tab) { filter in
            filter.states = TabFilter.allStates.filter {
                $0 == state ? on : filter.states.contains($0)
            }
        }
    }

    // Show or hide the rows of one kind. The kinds stay in the order of TabFilter.allKinds.
    package static func showKind(
        _ config: OverviewConfig, tab: String, _ kind: SessionKind, _ on: Bool
    ) -> OverviewConfig {
        withFilter(config, tab) { filter in
            filter.kinds = TabFilter.allKinds.filter {
                $0 == kind ? on : filter.kinds.contains($0)
            }
        }
    }

    // Show only the rows with a yellow or a red box, or all rows.
    package static func setBoxOnly(_ config: OverviewConfig, tab: String, _ on: Bool)
        -> OverviewConfig
    {
        withFilter(config, tab) { $0.boxOnly = on }
    }

    // Show only the rows on the watchlist, or all rows.
    package static func setWatchedOnly(_ config: OverviewConfig, tab: String, _ on: Bool)
        -> OverviewConfig
    {
        withFilter(config, tab) { $0.watchedOnly = on }
    }

    // True when the point is on the list rect or not more than dropMargin outside it.
    package static func inDropArea(list: LayoutRect, _ point: LayoutPoint) -> Bool {
        point.x >= list.x - dropMargin && point.x <= list.x + list.w + dropMargin
            && point.y >= list.y - dropMargin && point.y <= list.y + list.h + dropMargin
    }

    // The column that a dragged row goes before, for the action moveColumn. nil is the end of
    // the list. The pointer is over the row at the index over, which is kept in the list. The
    // upper half of a row puts the dragged row before it, and the lower half puts it after it. A
    // drop on the dragged row gives its old place, so the order does not change. The kind row is
    // always first, so a row never goes before it.
    package static func dropTarget(
        _ order: [OverviewColumn], dragged: OverviewColumn, over: Int, upperHalf: Bool
    ) -> OverviewColumn? {
        guard !order.isEmpty else { return nil }
        let row = min(max(over, 0), order.count - 1)
        let onSelf = order[row] == dragged
        let place = max(1, upperHalf && !onSelf ? row : row + 1)
        let column = { (index: Int) in order.indices.contains(index) ? order[index] : nil }
        // Before the dragged row itself is the same place as before the row after it.
        return column(place) == dragged ? column(place + 1) : column(place)
    }

    // The colour that an arrow key chooses in the Colour row. Left and right wrap at the ends,
    // and each other key gives the same colour.
    package static func nextColour(_ current: Int, key: KeyName) -> Int {
        let count = OverviewConfig.tabColours
        switch key {
        case .arrowRight: return (current + 1) % count
        case .arrowLeft: return (current + count - 1) % count
        default: return current
        }
    }

    // The config with the changed filter of the tab, through the action setFilter. An unknown
    // tab or a change with no effect gives the same config.
    private static func withFilter(
        _ config: OverviewConfig, _ tab: String, _ change: (inout TabFilter) -> Void
    ) -> OverviewConfig {
        guard var filter = config.tabs.first(where: { $0.id == tab })?.filter else {
            return config
        }
        change(&filter)
        var next = config
        next.apply(.setFilter(tab, filter))
        return next
    }
}
