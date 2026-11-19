import BifrostFoundation
import BifrostSessions

// One tab of an Overview: its name, colour, filter, columns, widths and sort.
package struct OverviewTab: Sendable, Equatable {
    // "t" and 1 to 4 digits. The standard Watched tab is t0, and an added tab gets the number
    // nextTab of the config, which starts at 1, so an added tab never clashes with it.
    package let id: String
    package var name: String
    // An index of the tab colours, from 0 to OverviewConfig.tabColours - 1.
    package var colour: Int
    package var filter: TabFilter
    // The visible columns in the display order. The kind column is always first.
    package var columns: [OverviewColumn]
    // All columns in the display order, also the hidden columns. The kind column is always
    // first. A hidden column keeps its place, and shows at that place when the user turns it on.
    // The visible columns are always in this order.
    package var order: [OverviewColumn]
    // The widths that the user set. A column with no width has its default width.
    package var widths: [OverviewColumn: Double]
    // The sort column is always visible.
    package var sort: SortSpec
    // The fields of the saved tab that this app does not know. The JSON form writes them again.
    package var unknown = UnknownFields()

    package init(
        id: String, name: String, colour: Int, filter: TabFilter,
        columns: [OverviewColumn] = OverviewColumn.defaultVisible,
        order: [OverviewColumn] = OverviewColumn.allCases, widths: [OverviewColumn: Double] = [:],
        sort: SortSpec = SortSpec(column: .name)
    ) {
        self.id = id
        self.name = name
        self.colour = colour
        self.filter = filter
        self.columns = columns
        self.order = order
        self.widths = widths
        self.sort = sort
    }

    // The columns of the table: the visible columns in the tab order, each with its width.
    package var tableColumns: [(column: OverviewColumn, width: Double)] {
        columns.map { ($0, widths[$0] ?? $0.defaultWidth) }
    }

    // A hidden column never sorts, because the sort column shows the sort mark. When the sort
    // column is hidden, the tab sorts by Name ascending if Name is visible, else by the first
    // visible column after kind, ascending. The kind column is always visible, so it is the last
    // choice.
    fileprivate mutating func keepSortVisible() {
        guard !columns.contains(sort.column) else { return }
        let column = columns.contains(.name) ? .name : (columns.count > 1 ? columns[1] : .kind)
        sort = SortSpec(column: column)
    }
}

// The reason why a control of the tab bar, the tab menu or the Overview Settings panel is off.
// The tooltip of the control shows the message.
package enum OverviewRefusal: Error, Sendable, Equatable {
    // Remove tab on the last tab.
    case lastTab
    // Add tab with the most tabs.
    case maxTabs
    // The check box and the drag of the kind column.
    case kindColumn
    // Reset on a tab with the default columns and filter.
    case defaultTab

    package var message: String {
        switch self {
        case .lastTab: "The Overview needs at least one tab."
        case .maxTabs: "The Overview can have up to \(OverviewConfig.maxTabs) tabs."
        case .kindColumn: "The kind column always stays first and on."
        case .defaultTab: "This tab already has the default columns and filter."
        }
    }
}

// A change of an Overview config, from the tab bar, the tab menu, the table header or the
// Overview Settings panel. A tab is named by its ID.
package enum OverviewAction: Sendable, Equatable {
    case addTab
    case removeTab(String)
    case renameTab(String, name: String)
    // Swap the tab with the tab at by places from it (-1: left, 1: right).
    case moveTab(String, by: Int)
    case activate(String)
    case setFilter(String, TabFilter)
    case toggleColumn(String, OverviewColumn)
    // Move the column before another column of the order. nil moves it to the end.
    case moveColumn(String, OverviewColumn, before: OverviewColumn?)
    case resetTab(String)
    case setTabColour(String, Int)
    case setWidths(String, [OverviewColumn: Double])
    case sortBy(String, OverviewColumn)
    // Rename the set of tabs.
    case rename(String)
}

// The config of one Overview: its named set of tabs and the active tab. Only standard, parse and
// apply make or change a config, so a config always has at least one tab and its active ID is
// the ID of a tab: the parse refuses a config with no good tab, and the last tab cannot go.
package struct OverviewConfig: Sendable, Equatable {
    package static let maxTabs = 12, maxTabName = 24, maxSetName = 40
    // The colours that the user can choose for a tab. The first defaultTabColours are the
    // automatic colours of new tabs.
    package static let tabColours = 12, defaultTabColours = 6
    // A tab ID has at most 4 digits.
    private static let maxTabNumber = 9999

    package private(set) var name: String
    package private(set) var tabs: [OverviewTab]
    package private(set) var active: String
    // The number of the next added tab.
    package private(set) var nextTab: Int
    // The fields of the saved config that this app does not know. The JSON form writes them
    // again.
    package var unknown = UnknownFields()

    private init(
        name: String, tabs: [OverviewTab], active: String, nextTab: Int,
        unknown: UnknownFields = UnknownFields()
    ) {
        self.name = name
        self.tabs = tabs
        self.active = active
        self.nextTab = nextTab
        self.unknown = unknown
    }

    // The config of an Overview with no saved config.
    package static let standard = OverviewConfig(
        name: "Default",
        tabs: [
            standardTab(1, "All", TabFilter(states: liveStates)),
            standardTab(2, "Alerts", TabFilter(states: liveStates, boxOnly: true)),
            // The Watched tab shows the watched rows of every state.
            standardTab(
                0, "Watched", TabFilter(states: TabFilter.allStates, watchedOnly: true),
                colour: watchedColour),
            standardTab(3, "Working", TabFilter(states: [.working])),
            standardTab(4, "Idle", TabFilter(states: [.idle])),
            standardTab(5, "Parked", TabFilter(states: [.parked])),
        ],
        active: "t1", nextTab: 6)

    // The tab with the active ID. A config always has that tab, so the first tab is only a
    // fallback.
    package var activeTab: OverviewTab {
        tabs.first { $0.id == active } ?? tabs[0]
    }

    // Apply the action. The result is true when the config changed. An action with an unknown
    // tab, a bad value or no effect changes nothing.
    @discardableResult
    package mutating func apply(_ action: OverviewAction) -> Bool {
        let old = self
        switch action {
        case .addTab: addTab()
        case .removeTab(let id): removeTab(id)
        case .renameTab(let id, let name):
            let trimmed = name.trimmed()
            guard Self.isGood(trimmed, limit: Self.maxTabName) else { break }
            editTab(id) { $0.name = trimmed }
        case .moveTab(let id, let by): moveTab(id, by: by)
        case .activate(let id):
            if tabs.contains(where: { $0.id == id }) { active = id }
        case .setFilter(let id, let filter): editTab(id) { $0.filter = filter }
        case .toggleColumn(let id, let column): toggleColumn(id, column)
        case .moveColumn(let id, let column, let before): moveColumn(id, column, before: before)
        case .resetTab(let id): resetTab(id)
        case .setTabColour(let id, let colour):
            guard (0..<Self.tabColours).contains(colour) else { break }
            editTab(id) { $0.colour = colour }
        case .setWidths(let id, let widths):
            editTab(id) { tab in
                for (column, width) in widths where width.isFinite {
                    tab.widths[column] = OverviewColumn.clamp(width: width)
                }
            }
        case .sortBy(let id, let column):
            editTab(id) { tab in
                // A hidden column never sorts.
                guard tab.columns.contains(column) else { return }
                tab.sort =
                    tab.sort.column == column
                    ? SortSpec(column: column, descending: !tab.sort.descending)
                    : SortSpec(column: column, descending: column.sortsDescendingFirst)
            }
        case .rename(let name):
            let trimmed = name.trimmed()
            if Self.isGood(trimmed, limit: Self.maxSetName) { self.name = trimmed }
        }
        return self != old
    }

    // True when the action changes the config. A control whose action changes nothing is off,
    // for example Reset to default on a tab with the default columns and filter.
    package func changes(_ action: OverviewAction) -> Bool {
        var copy = self
        return copy.apply(action)
    }

    // MARK: - The actions

    private mutating func addTab() {
        let number = nextTab
        let id = "t\(number)"
        guard tabs.count < Self.maxTabs, (1...Self.maxTabNumber).contains(number),
            !tabs.contains(where: { $0.id == id })
        else { return }
        tabs.append(
            OverviewTab(
                id: id, name: "Tab \(number)", colour: (number - 1) % Self.defaultTabColours,
                filter: TabFilter(states: Self.liveStates)))
        active = id
        nextTab = number + 1
    }

    // The tab goes, except the last tab. When it was active, the tab to its left becomes
    // active, or the first tab.
    private mutating func removeTab(_ id: String) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if active == id { active = tabs[max(0, index - 1)].id }
    }

    private mutating func moveTab(_ id: String, by: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let (to, overflow) = from.addingReportingOverflow(by)
        guard !overflow, tabs.indices.contains(to) else { return }
        tabs.swapAt(from, to)
    }

    // A column that the user turns on shows at its place in the order. The kind column stays.
    private mutating func toggleColumn(_ id: String, _ column: OverviewColumn) {
        guard column != .kind else { return }
        editTab(id) { tab in
            if tab.columns.contains(column) {
                tab.columns.removeAll { $0 == column }
            } else {
                tab.columns = tab.order.filter { $0 == column || tab.columns.contains($0) }
            }
            tab.keepSortVisible()
        }
    }

    // The move changes the order of all columns, so a hidden column can move too. The kind
    // column stays first: a move before it puts the column directly after it.
    private mutating func moveColumn(
        _ id: String, _ column: OverviewColumn, before: OverviewColumn?
    ) {
        guard column != .kind, column != before else { return }
        editTab(id) { tab in
            guard tab.order.contains(column) else { return }
            if let before, !tab.order.contains(before) { return }
            var order = tab.order.filter { $0 != column }
            let place = before.map { max(1, order.firstIndex(of: $0) ?? order.count) }
            order.insert(column, at: place ?? order.count)
            guard order != tab.order else { return }
            tab.columns = order.filter { tab.columns.contains($0) }
            tab.order = order
        }
    }

    // The reset gives the tab its default columns, order, widths and filter. It keeps the name
    // and the colour, and it changes the sort only when the reset hides the sort column.
    private mutating func resetTab(_ id: String) {
        editTab(id) { tab in
            let filter = Self.defaultFilter(tab.id)
            let isDefault =
                tab.columns == OverviewColumn.defaultVisible
                && tab.order == OverviewColumn.allCases && tab.widths.isEmpty
                && tab.filter == filter
            guard !isDefault else { return }
            tab.columns = OverviewColumn.defaultVisible
            tab.order = OverviewColumn.allCases
            tab.widths = [:]
            tab.filter = filter
            tab.keepSortVisible()
        }
    }

    private mutating func editTab(_ id: String, _ change: (inout OverviewTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        change(&tabs[index])
    }

    // MARK: - The standard tabs

    // The states of a tab that shows the sessions that run.
    private static let liveStates: [SessionState] = [.working, .needsYou, .error, .idle]
    // The colour of the Watched tab: an automatic colour that no other standard tab has.
    private static let watchedColour = 5

    // The colour of a standard tab follows its number.
    private static func standardTab(
        _ number: Int, _ name: String, _ filter: TabFilter, colour: Int? = nil
    ) -> OverviewTab {
        OverviewTab(id: "t\(number)", name: name, colour: colour ?? number - 1, filter: filter)
    }

    // The filter of a standard tab. A tab that the user added has the filter of All.
    private static func defaultFilter(_ id: String) -> TabFilter {
        standard.tabs.first { $0.id == id }?.filter ?? TabFilter(states: liveStates)
    }

    // A trimmed name of 1 to limit Characters, as for the layout names of the same file.
    private static func isGood(_ name: String, limit: Int) -> Bool {
        (1...limit).contains(name.count)
    }
}

// MARK: - The saved config

extension OverviewConfig {
    // The known keys of a saved config and of a saved tab. Each other key is an unknown field.
    private static let configKeys: Set<String> = ["active", "name", "nextTab", "tabs"]
    private static let tabKeys: Set<String> = [
        "color", "columns", "filter", "id", "name", "order", "sort", "widths",
    ]

    // The text of a state in the saved config. SessionState has no text form, so this is the one
    // place of these texts: the parse and the JSON form both use it.
    package static func fileText(_ state: SessionState) -> String {
        switch state {
        case .working: "working"
        case .needsYou: "needs-you"
        case .error: "error"
        case .idle: "idle"
        case .parked: "parked"
        }
    }

    // The text of a kind in the saved config.
    package static func fileText(_ kind: SessionKind) -> String {
        switch kind {
        case .owned: "owned"
        case .external: "external"
        }
    }

    // The config in a saved value of ui-state.json, or nil when the value has no good tab. A bad
    // part of a good config gets its default value:
    // - A tab goes when its ID is not "t" and 1 to 4 digits, when its name is not 1 to 24
    //   Characters after the trim, or when an earlier tab has its ID. The parse keeps the first 12
    //   tabs. A tab t2 with the old name "Needs you" gets the name "Alerts".
    // - A bad colour gives the automatic colour of the place of the tab.
    // - The columns keep their known IDs, with no repeat, after the kind column. A missing list
    //   gives the default columns. The order keeps its known IDs, then the visible columns, then
    //   the other columns in the default order. So a tab from before the order keeps its columns.
    // - The filter keeps its known states and kinds in their order, with no repeat. A filter with
    //   no list of kinds shows both kinds. boxOnly and watchedOnly are true only for true.
    // - A width needs a known column and a number. The parse rounds it and keeps it in the limits.
    // - A bad sort gives Name ascending. A sort on a hidden column moves to a visible column.
    // - The set name is the trimmed name of 1 to 40 Characters, else "Default". A bad active ID
    //   gives the first tab. nextTab is a whole number from 1 to 9999, and at least the highest
    //   tab number plus 1, so an added tab never gets the ID of a saved tab. After a saved tab
    //   t9999, nextTab is 10000 and no tab can be added.
    // - The config and each tab keep their unknown fields. The filter and the sort do not.
    package static func parse(_ value: JSONValue?) -> OverviewConfig? {
        guard let fields = value?.object, let saved = fields["tabs"]?.array else { return nil }
        var tabs: [OverviewTab] = []
        for item in saved {
            guard tabs.count < maxTabs else { break }
            guard let tab = parseTab(item, place: tabs.count),
                !tabs.contains(where: { $0.id == tab.id })
            else { continue }
            tabs.append(tab)
        }
        guard let first = tabs.first else { return nil }
        let name = fields["name"]?.string?.trimmed() ?? ""
        let highest = tabs.map { tabNumber($0.id) }.max() ?? 0
        let savedNext = fields["nextTab"]?.wholeNumber.flatMap {
            (1...maxTabNumber).contains($0) ? $0 : nil
        }
        let active = fields["active"]?.string.flatMap { id in
            tabs.contains { $0.id == id } ? id : nil
        }
        return OverviewConfig(
            name: isGood(name, limit: maxSetName) ? name : "Default", tabs: tabs,
            active: active ?? first.id, nextTab: max(savedNext ?? 0, highest + 1),
            unknown: UnknownFields(fields, known: configKeys))
    }

    // The saved form of the config, with the field names of the file and the unknown fields.
    package var json: JSONValue {
        .object(
            unknown.merged(with: [
                "active": .string(active), "name": .string(name), "nextTab": .int(nextTab),
                "tabs": .array(tabs.map(Self.tabJSON)),
            ]))
    }

    private static func tabJSON(_ tab: OverviewTab) -> JSONValue {
        let widths = tab.widths.map { ($0.key.rawValue, JSONValue.number($0.value)) }
        let known: [String: JSONValue] = [
            "color": .int(tab.colour),
            "columns": .array(tab.columns.map { .string($0.rawValue) }),
            "filter": .object([
                "boxOnly": .bool(tab.filter.boxOnly),
                "kinds": .array(tab.filter.kinds.map { .string(fileText($0)) }),
                "states": .array(tab.filter.states.map { .string(fileText($0)) }),
                "watchedOnly": .bool(tab.filter.watchedOnly),
            ]),
            "id": .string(tab.id),
            "name": .string(tab.name),
            "order": .array(tab.order.map { .string($0.rawValue) }),
            "sort": .object([
                "column": .string(tab.sort.column.rawValue), "desc": .bool(tab.sort.descending),
            ]),
            "widths": .object(Dictionary(uniqueKeysWithValues: widths)),
        ]
        return .object(tab.unknown.merged(with: known))
    }

    private static func parseTab(_ value: JSONValue, place: Int) -> OverviewTab? {
        guard let fields = value.object, let id = fields["id"]?.string, isTabID(id),
            let savedName = fields["name"]?.string
        else { return nil }
        let trimmed = savedName.trimmed()
        guard isGood(trimmed, limit: maxTabName) else { return nil }
        // The second standard tab had the name "Needs you" before. Only that tab gets the new
        // name.
        let name = id == "t2" && trimmed == "Needs you" ? "Alerts" : trimmed
        let colour = fields["color"]?.wholeNumber.flatMap {
            (0..<tabColours).contains($0) ? $0 : nil
        }
        let savedColumns = fields["columns"]?.array
        let columns = parseColumns(savedColumns)
        // A missing list gives the default columns in the default order, as in a new tab.
        let order = parseOrder(fields["order"]?.array, visible: savedColumns == nil ? [] : columns)
        var tab = OverviewTab(
            id: id, name: name, colour: colour ?? place % defaultTabColours,
            filter: parseFilter(fields["filter"]), columns: order.filter(columns.contains),
            order: order, widths: parseWidths(fields["widths"]), sort: parseSort(fields["sort"]))
        tab.keepSortVisible()
        tab.unknown = UnknownFields(fields, known: tabKeys)
        return tab
    }

    // "t" and 1 to 4 ASCII digits.
    private static func isTabID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        let digits = UInt8(ascii: "0")...UInt8(ascii: "9")
        return bytes.first == UInt8(ascii: "t") && (2...5).contains(bytes.count)
            && bytes.dropFirst().allSatisfy(digits.contains)
    }

    private static func tabNumber(_ id: String) -> Int {
        Int(id.dropFirst()) ?? 0
    }

    private static func parseColumns(_ saved: [JSONValue]?) -> [OverviewColumn] {
        guard let saved else { return OverviewColumn.defaultVisible }
        var columns: [OverviewColumn] = [.kind]
        for case let id? in saved.map(savedColumn) where !columns.contains(id) {
            columns.append(id)
        }
        return columns
    }

    private static func parseOrder(_ saved: [JSONValue]?, visible: [OverviewColumn])
        -> [OverviewColumn]
    {
        var order: [OverviewColumn] = [.kind]
        let candidates = (saved ?? []).compactMap(savedColumn) + visible + OverviewColumn.allCases
        for column in candidates where !order.contains(column) {
            order.append(column)
        }
        return order
    }

    private static func parseFilter(_ value: JSONValue?) -> TabFilter {
        let fields = value?.object ?? [:]
        let state = { (text: String) in TabFilter.allStates.first { fileText($0) == text } }
        let kind = { (text: String) in TabFilter.allKinds.first { fileText($0) == text } }
        return TabFilter(
            states: known(fields["states"]?.array ?? [], state),
            // A filter from before the kinds, or with a damaged kind list, shows both kinds.
            kinds: fields["kinds"]?.array.map { known($0, kind) } ?? TabFilter.allKinds,
            boxOnly: fields["boxOnly"] == .bool(true),
            // A filter from before the watchlist shows the rows that are not watched too.
            watchedOnly: fields["watchedOnly"] == .bool(true))
    }

    // The known values of a list, in the order of the list, with no repeat.
    private static func known<Value: Equatable>(
        _ items: [JSONValue], _ value: (String) -> Value?
    ) -> [Value] {
        var result: [Value] = []
        for case let found? in items.map({ $0.string.flatMap(value) })
        where !result.contains(found) {
            result.append(found)
        }
        return result
    }

    private static func parseWidths(_ value: JSONValue?) -> [OverviewColumn: Double] {
        var widths: [OverviewColumn: Double] = [:]
        for (key, saved) in value?.object ?? [:] {
            guard let column = OverviewColumn(rawValue: key), let width = saved.finiteNumber else {
                continue
            }
            widths[column] = OverviewColumn.clamp(width: width)
        }
        return widths
    }

    private static func parseSort(_ value: JSONValue?) -> SortSpec {
        guard let fields = value?.object, let column = fields["column"].flatMap(savedColumn)
        else {
            return SortSpec(column: .name)
        }
        return SortSpec(column: column, descending: fields["desc"] == .bool(true))
    }

    private static func savedColumn(_ value: JSONValue) -> OverviewColumn? {
        value.string.flatMap(OverviewColumn.init(rawValue:))
    }
}
