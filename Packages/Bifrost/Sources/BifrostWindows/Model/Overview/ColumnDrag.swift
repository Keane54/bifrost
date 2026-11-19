// The rule of a header drag in the Overview table: the place of a dropped column.
package enum ColumnDrag {
    // The column that the dragged column goes before, for the action moveColumn. A drop on a
    // header to the right puts the column after that header. A drop on a header to the left puts
    // it before that header. nil: no move (the kind column, the same column, or a column that is
    // not in the list). .some(nil): to the end.
    package static func dropBefore(
        _ columns: [OverviewColumn], from: OverviewColumn, to: OverviewColumn
    ) -> OverviewColumn?? {
        guard from != .kind, from != to, let fromIndex = columns.firstIndex(of: from),
            let toIndex = columns.firstIndex(of: to)
        else { return nil }
        if fromIndex > toIndex { return .some(to) }
        let next = toIndex + 1
        return .some(next < columns.count ? columns[next] : nil)
    }
}
