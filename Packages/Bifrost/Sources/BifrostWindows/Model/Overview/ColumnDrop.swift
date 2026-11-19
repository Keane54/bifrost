import BifrostLayout

// The drop place of a dragged row of the column list of the Overview Settings panel, for the
// action moveColumn. The point is in layout units, from the top left of the first row. Each row
// is 22 units high. A point above the rows is on the upper half of the first row, and a point
// below them on the lower half of the last row.
package struct ColumnDrop: Equatable, Sendable {
    package static let rowHeight = 22.0
    // The space above and below the rows in the list, in layout units. The drop area of
    // OverviewSettingsRules.inDropArea includes it.
    package static let listPadding = 4.0

    package let column: OverviewColumn
    // The column that the row goes before. nil is the end of the list.
    package let before: OverviewColumn?
    // False when the point is more than dropMargin outside the list: a release moves nothing.
    package let inside: Bool

    // nil for the kind row: it cannot move. rows is the size of the rows, and order the column
    // order of the list now.
    package init?(
        column: OverviewColumn, at point: LayoutPoint, rows: LayoutSize, order: [OverviewColumn]
    ) {
        guard column != .kind, !order.isEmpty else { return nil }
        let row = (point.y / Self.rowHeight).rounded(.down)
        let over = row.isNaN ? 0 : Int(min(max(row, 0), Double(order.count - 1)))
        let upperHalf = point.y < (Double(over) + 0.5) * Self.rowHeight
        self.column = column
        before = OverviewSettingsRules.dropTarget(
            order, dragged: column, over: over, upperHalf: upperHalf)
        let padding = Self.listPadding
        let list = LayoutRect(x: 0, y: -padding, w: rows.w, h: rows.h + 2 * padding)
        inside = OverviewSettingsRules.inDropArea(list: list, point)
    }

    // The move of a release on the tab, or nil when the release moves nothing.
    package func action(tab: String) -> OverviewAction? {
        inside ? .moveColumn(tab, column, before: before) : nil
    }
}
