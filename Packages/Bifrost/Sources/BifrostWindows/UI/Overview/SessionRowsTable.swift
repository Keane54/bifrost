// The parts that the two tables of session rows share, the Overview table and the Watchlist: the
// table that sends each pointer event of its rows to its owner, the click rule of a row with the
// hold keys (D8), the icons of the terminal apps, the reload of the rows that changed and the
// selection of the table that follows SelectionModel.
import AppKit
import BifrostLook
import BifrostSessions

// The owner of a table of session rows: it gets each pointer event of the rows, in the
// coordinates of the table.
@MainActor
package protocol SessionRowsPointer: AnyObject {
    // A primary press. A Control-click is a right-click.
    func press(at point: NSPoint)
    // The pointer moved with the primary button down.
    func dragged(to point: NSPoint, event: NSEvent)
    // The release of a primary press, with the click count of the release.
    func release(at point: NSPoint, clicks: Int)
    // A right-click, or a Control-click.
    func rightClick(at point: NSPoint)
}

// A table of session rows. Each mouse event in its rows goes to the table itself, also a press on
// the text of a cell, and the table gives it to its owner: no table selection by the user, no drag
// of rows by the table and no menu of the table.
@MainActor
package class SessionRowsTable: PassiveTableView {
    weak var pointer: (any SessionRowsPointer)?

    override package func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    private func point(_ event: NSEvent) -> NSPoint {
        convert(event.locationInWindow, from: nil)
    }

    // A Control-click is a right-click.
    override package func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            pointer?.rightClick(at: point(event))
            return
        }
        pointer?.press(at: point(event))
    }

    override package func mouseDragged(with event: NSEvent) {
        pointer?.dragged(to: point(event), event: event)
    }

    override package func mouseUp(with event: NSEvent) {
        pointer?.release(at: point(event), clicks: event.clickCount)
    }

    override package func rightMouseDown(with event: NSEvent) {
        pointer?.rightClick(at: point(event))
    }

    // The rows of the table that changed between two lists: all rows when the row IDs or all
    // looks changed (all), else the rows whose value or icon changed.
    func reloadChanged(
        old: [SessionRow]?, new: [SessionRow], oldIcons: [String: AppIcon],
        newIcons: [String: AppIcon], all: Bool, columns: IndexSet
    ) {
        guard let old, !all, old.map(\.sessionId) == new.map(\.sessionId) else {
            reloadData()
            return
        }
        var changed = IndexSet()
        for (index, row) in new.enumerated()
        where row != old[index] || newIcons[row.sessionId] != oldIcons[row.sessionId] {
            changed.insert(index)
        }
        guard !changed.isEmpty else { return }
        reloadData(forRowIndexes: changed, columnIndexes: columns)
    }

    // The selection of the table follows SelectionModel, so VoiceOver tells the selected row. The
    // table selects only through this call: its delegate refuses each selection of the user.
    func showSelection(_ selected: String?, in rows: [SessionRow]) {
        let index = selected.flatMap { id in rows.firstIndex { $0.sessionId == id } }
        let wanted = index.map { IndexSet(integer: $0) } ?? IndexSet()
        guard selectedRowIndexes != wanted else { return }
        selectRowIndexes(wanted, byExtendingSelection: false)
    }
}

extension OverviewModel {
    // The icon of the app that shows each row that has one and is not parked, by row ID.
    package func appIcons(_ rows: [SessionRow]) -> [String: AppIcon] {
        var icons: [String: AppIcon] = [:]
        for row in rows where row.state != .parked {
            icons[row.sessionId] = appIcon(row)
        }
        return icons
    }

    // A click on a session row of an Overview or of the Watchlist. The click selects the row,
    // unless its press claimed a hold key; then the hold command runs on the row and the
    // selection stays (D8). The second click of a double-click also selects the row and opens it,
    // except during a hold. A row that left the session list gets no click.
    package func rowClicked(_ id: String, clicks: Int, filter: WindowKeyFilter?) {
        guard sessions.rows.contains(where: { $0.sessionId == id }) else { return }
        if filter?.rowClick(id) != true { selection.selectedId = id }
        guard clicks == 2, filter?.isHolding != true else { return }
        selection.selectedId = id
        open(id)
    }
}
