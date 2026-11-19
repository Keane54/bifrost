import BifrostSessions
import Foundation

// The filter of an Overview tab: the rows of these states and kinds. boxOnly shows only the rows
// with an alert box, and watchedOnly shows only the rows on the watchlist.
package struct TabFilter: Sendable, Equatable {
    // All states and all kinds, in the order of the filter lists.
    package static let allStates: [SessionState] = [.working, .needsYou, .error, .idle, .parked]
    package static let allKinds: [SessionKind] = [.owned, .external]

    package var states: [SessionState]
    package var kinds: [SessionKind]
    package var boxOnly: Bool
    package var watchedOnly: Bool

    package init(
        states: [SessionState], kinds: [SessionKind] = allKinds, boxOnly: Bool = false,
        watchedOnly: Bool = false
    ) {
        self.states = states
        self.kinds = kinds
        self.boxOnly = boxOnly
        self.watchedOnly = watchedOnly
    }
}

// The sort of an Overview tab: one column and its direction.
package struct SortSpec: Sendable, Equatable {
    package var column: OverviewColumn
    package var descending: Bool

    package init(column: OverviewColumn, descending: Bool = false) {
        self.column = column
        self.descending = descending
    }
}

// The rows of an Overview tab: the filter, then the sort.
package enum OverviewRows {
    package static func filter(_ rows: [SessionRow], _ filter: TabFilter) -> [SessionRow] {
        rows.filter { row in
            filter.states.contains(row.state) && filter.kinds.contains(row.kind)
                && (!filter.boxOnly || row.alert != .none)
                && (!filter.watchedOnly || row.watch != nil)
        }
    }

    // The rows sorted by the column of the sort. An empty value goes last in both directions.
    // Rows with equal values keep their input order in both directions: the sort compares the
    // input places of two equal values, so the result does not depend on the sort algorithm.
    package static func sort(_ rows: [SessionRow], _ sort: SortSpec) -> [SessionRow] {
        let keyed = rows.enumerated().map { (place: $0.offset, key: key($0.element, sort.column)) }
        let ordered = keyed.sorted { first, second in
            switch (first.key, second.key) {
            case (nil, nil): return first.place < second.place
            case (nil, _): return false
            case (_, nil): return true
            case (let one?, let two?):
                let result = one.compared(with: two)
                guard result != .orderedSame else { return first.place < second.place }
                return (result == .orderedAscending) != sort.descending
            }
        }
        return ordered.map { rows[$0.place] }
    }

    package static func view(_ rows: [SessionRow], tab: OverviewTab) -> [SessionRow] {
        sort(filter(rows, tab.filter), tab.sort)
    }

    // The value of a row in a column, or nil for an empty value: no value, an empty text or a
    // number that is not a number.
    private static func key(_ row: SessionRow, _ column: OverviewColumn) -> SortKey? {
        switch column {
        case .kind: .number(row.kind == .owned ? 0 : 1)
        case .name: text(row.name)
        case .priority: row.priority.map { .number(Double($0.rawValue)) }
        case .state: .number(stateRank(row.state))
        case .project: text(OverviewFormat.projectLabel(row.cwd))
        case .branch: text(row.branch)
        case .model: text(row.model)
        case .context: number(row.usage?.contextPercent)
        case .cost: number(row.usage?.costUsd)
        case .activity: .number(Double(row.lastActivity))
        }
    }

    private static func text(_ value: String?) -> SortKey? {
        guard let value, !value.isEmpty else { return nil }
        return .text(value)
    }

    private static func number(_ value: Double?) -> SortKey? {
        guard let value, !value.isNaN else { return nil }
        return .number(value)
    }

    // The State column sorts by the state only, not by the box, so a yellow box that changes to
    // red does not move the row.
    private static func stateRank(_ state: SessionState) -> Double {
        switch state {
        case .error: 0
        case .needsYou: 1
        case .working: 2
        case .idle: 3
        case .parked: 4
        }
    }
}

// The sort value of a row in one column. All values of one column have the same case.
private enum SortKey {
    case number(Double)
    case text(String)

    // The text compare of English with numbers: case and accents do not count, and a run of
    // digits compares as a number. Row OV1 of docs/ports/overview/DELIBERATE-DIFFERENCES.md lists
    // the rare names that have a different order on purpose.
    private static let textOptions: String.CompareOptions = [
        .caseInsensitive, .diacriticInsensitive, .numeric,
    ]
    private static let english = Locale(identifier: "en")

    func compared(with other: SortKey) -> ComparisonResult {
        switch (self, other) {
        case (.number(let one), .number(let two)):
            one < two ? .orderedAscending : one > two ? .orderedDescending : .orderedSame
        case (.text(let one), .text(let two)):
            one.compare(two, options: Self.textOptions, range: nil, locale: Self.english)
        case (.number, .text), (.text, .number):
            .orderedSame
        }
    }
}
