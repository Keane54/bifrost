import BifrostFoundation
import BifrostKeyboard
import BifrostLayout
import BifrostSessions
import BifrostTestSupport
import BifrostWindows
import Testing

// The rules of the Overview Settings panel: the column list, the filter switches, the drop of a
// column row and the colour keys (the section "Overview Settings" of docs/behaviour/overview.md).
// The panel turns, moves and resets a column with OverviewConfig.apply, so these tests only check
// that the column rows follow.

private typealias Rules = OverviewSettingsRules

private let standard = OverviewConfig.standard

private func tab(_ config: OverviewConfig, _ id: String = "t1") throws -> OverviewTab {
    try #require(config.tabs.first { $0.id == id })
}

private func applying(_ actions: OverviewAction..., to start: OverviewConfig = standard)
    -> OverviewConfig
{
    var config = start
    for action in actions { config.apply(action) }
    return config
}

private func rows(_ config: OverviewConfig, _ id: String = "t1") -> [ColumnRow] {
    Rules.columnRows(config, tab: id)
}

// The order of the column rows in the drop tests: the visible columns of a new tab.
private let order: [OverviewColumn] = [.kind, .name, .state, .project, .activity]

// One row of a table: a drag of a column row over a row, and the column that it goes before.
private struct DropCase: Sendable, CustomTestStringConvertible {
    let name: String
    let dragged: OverviewColumn
    let over: Int
    let upperHalf: Bool
    let before: OverviewColumn?
    var testDescription: String { name }
}

private let dropCases: [DropCase] = [
    DropCase(
        name: "down: the lower half of a row puts it after that row", dragged: .name, over: 3,
        upperHalf: false, before: .activity),
    DropCase(
        name: "down: the upper half of a row puts it before that row", dragged: .name, over: 3,
        upperHalf: true, before: .project),
    DropCase(
        name: "up: the upper half of a row puts it before that row", dragged: .activity, over: 1,
        upperHalf: true, before: .name),
    DropCase(
        name: "up: the lower half of a row puts it after that row", dragged: .activity, over: 1,
        upperHalf: false, before: .state),
    DropCase(
        name: "the upper half of the dragged row is its old place", dragged: .state, over: 2,
        upperHalf: true, before: .project),
    DropCase(
        name: "the lower half of the dragged row is its old place", dragged: .state, over: 2,
        upperHalf: false, before: .project),
    DropCase(
        name: "the lower half of the row above the dragged row is its old place",
        dragged: .state, over: 1, upperHalf: false, before: .project),
    DropCase(
        name: "the last row dropped on itself stays at the end", dragged: .activity, over: 4,
        upperHalf: true, before: nil),
    DropCase(
        name: "the lower half of the last row is the end", dragged: .name, over: 4,
        upperHalf: false, before: nil),
    DropCase(
        name: "a row after the last row is the end", dragged: .name, over: 99, upperHalf: false,
        before: nil),
    DropCase(
        name: "the upper half of the kind row puts it after kind", dragged: .project, over: 0,
        upperHalf: true, before: .name),
    DropCase(
        name: "the lower half of the kind row puts it after kind", dragged: .project, over: 0,
        upperHalf: false, before: .name),
    DropCase(
        name: "a row above the list puts it after kind", dragged: .project, over: -3,
        upperHalf: true, before: .name),
    DropCase(
        name: "the first row dropped on kind keeps its place", dragged: .name, over: 0,
        upperHalf: true, before: .state),
]

@Suite("overview settings rules")
struct OverviewSettingsRulesTests {
    // MARK: - The column list

    @Test func theColumnRowsAreAllColumnsInTabOrderWithKindLocked() {
        let list = rows(standard)
        #expect(list.map(\.column) == OverviewColumn.allCases)
        #expect(
            list.map(\.label) == [
                "Kind", "Name", "Priority", "State", "Project", "Branch", "Model", "Context %",
                "Cost", "Activity",
            ])
        #expect(list.filter(\.visible).map(\.column) == OverviewColumn.defaultVisible)
        #expect(list.filter(\.locked).map(\.column) == [.kind])
        #expect(list.first == ColumnRow(column: .kind, label: "Kind", visible: true, locked: true))
        #expect(rows(standard, "nope").isEmpty)
    }

    @Test func aTurnedOnColumnStaysInItsPlaceInTheList() throws {
        let on = applying(.toggleColumn("t1", .cost))
        #expect(rows(on).map(\.column) == rows(standard).map(\.column))
        #expect(rows(on).first { $0.column == .cost }?.visible == true)
        #expect(try tab(on).columns == [.kind, .name, .state, .project, .cost, .activity])
        let off = applying(.toggleColumn("t1", .cost), to: on)
        #expect(rows(off) == rows(standard))
    }

    // A hidden column keeps its new place, and shows there when the user turns it on.
    @Test func aMovedColumnShowsAtItsNewPlaceAndAResetGivesTheDefaultList() throws {
        let moved = applying(.moveColumn("t1", .cost, before: .state))
        #expect(
            rows(moved).map(\.column) == [
                .kind, .name, .priority, .cost, .state, .project, .branch, .model, .context,
                .activity,
            ])
        #expect(try tab(moved).columns == OverviewColumn.defaultVisible)
        let shown = applying(.toggleColumn("t1", .cost), to: moved)
        #expect(try tab(shown).columns == [.kind, .name, .cost, .state, .project, .activity])
        #expect(rows(applying(.resetTab("t1"), to: shown)) == rows(standard))
    }

    // MARK: - The filter switches

    @Test func showStateKeepsTheFixedOrderOfTheStates() throws {
        let parked = Rules.showState(standard, tab: "t1", .parked, true)
        #expect(try tab(parked).filter.states == [.working, .needsYou, .error, .idle, .parked])
        let noIdle = Rules.showState(standard, tab: "t1", .idle, false)
        #expect(try tab(noIdle).filter.states == [.working, .needsYou, .error])
        // A saved filter in another order gets the fixed order at its next change.
        let saved = try #require(
            OverviewConfig.parse([
                "tabs": [["id": "t1", "name": "A", "filter": ["states": ["idle", "working"]]]]
            ]))
        let error = Rules.showState(saved, tab: "t1", .error, true)
        #expect(try tab(error).filter.states == [.working, .error, .idle])
    }

    @Test func showKindKeepsTheFixedOrderOfTheKinds() throws {
        let owned = Rules.showKind(standard, tab: "t1", .external, false)
        #expect(try tab(owned).filter.kinds == [.owned])
        let both = Rules.showKind(owned, tab: "t1", .external, true)
        #expect(try tab(both).filter.kinds == [.owned, .external])
        let none = Rules.showKind(owned, tab: "t1", .owned, false)
        #expect(try tab(none).filter.kinds.isEmpty)
    }

    @Test func theAlertAndWatchedSwitchesSetTheFilter() throws {
        #expect(try tab(Rules.setBoxOnly(standard, tab: "t1", true)).filter.boxOnly)
        #expect(try !tab(Rules.setBoxOnly(standard, tab: "t2", false), "t2").filter.boxOnly)
        #expect(try tab(Rules.setWatchedOnly(standard, tab: "t1", true)).filter.watchedOnly)
        #expect(try !tab(Rules.setWatchedOnly(standard, tab: "t0", false), "t0").filter.watchedOnly)
    }

    @Test func aSwitchChangesOnlyTheFilterOfItsTab() throws {
        let changed = Rules.setBoxOnly(standard, tab: "t3", true)
        var expected = try tab(standard, "t3")
        expected.filter.boxOnly = true
        #expect(try tab(changed, "t3") == expected)
        #expect(changed.tabs.filter { $0.id != "t3" } == standard.tabs.filter { $0.id != "t3" })
    }

    @Test func aSwitchWithNoEffectOrAnUnknownTabGivesTheSameConfig() {
        #expect(Rules.showState(standard, tab: "t1", .working, true) == standard)
        #expect(Rules.showState(standard, tab: "t1", .parked, false) == standard)
        #expect(Rules.showKind(standard, tab: "t1", .owned, true) == standard)
        #expect(Rules.setBoxOnly(standard, tab: "t2", true) == standard)
        #expect(Rules.setWatchedOnly(standard, tab: "t0", true) == standard)
        #expect(Rules.showState(standard, tab: "nope", .parked, true) == standard)
        #expect(Rules.showKind(standard, tab: "nope", .owned, false) == standard)
        #expect(Rules.setBoxOnly(standard, tab: "nope", true) == standard)
        #expect(Rules.setWatchedOnly(standard, tab: "nope", true) == standard)
    }

    // A reset gives back the filter of the standard tab, or the filter of All for an added tab.
    @Test func aResetGivesBackTheDefaultFilterOfTheTab() throws {
        let watched = Rules.showState(standard, tab: "t0", .working, false)
        let resetWatched = applying(.resetTab("t0"), to: watched)
        #expect(try tab(resetWatched, "t0").filter == tab(standard, "t0").filter)
        let added = applying(.addTab)
        let changed = Rules.showState(added, tab: "t6", .working, false)
        let resetAdded = applying(.resetTab("t6"), to: changed)
        #expect(try tab(resetAdded, "t6").filter == tab(standard).filter)
    }

    // MARK: - The drop of a column row

    @Test func aReleaseCountsUpTo24UnitsOutsideTheList() {
        #expect(Rules.dropMargin == 24)
        let list = rect(h: 200, w: 300, x: 100, y: 50)
        #expect(Rules.inDropArea(list: list, point(x: 250, y: 150)))
        #expect(Rules.inDropArea(list: list, point(x: 100 - 24, y: 50 - 24)))
        #expect(Rules.inDropArea(list: list, point(x: 400 + 24, y: 250 + 24)))
        #expect(!Rules.inDropArea(list: list, point(x: 100 - 25, y: 150)))
        #expect(!Rules.inDropArea(list: list, point(x: 400 + 25, y: 150)))
        #expect(!Rules.inDropArea(list: list, point(x: 250, y: 50 - 25)))
        #expect(!Rules.inDropArea(list: list, point(x: 250, y: 250 + 25)))
    }

    @Test("the column that a dropped row goes before", arguments: dropCases)
    private func dropTarget(_ item: DropCase) {
        let before = Rules.dropTarget(
            order, dragged: item.dragged, over: item.over, upperHalf: item.upperHalf)
        #expect(before == item.before)
    }

    @Test func aDropTargetWithMoveColumnGivesTheOrderOfTheDrop() throws {
        let allColumns = try tab(standard).order
        let before = Rules.dropTarget(allColumns, dragged: .activity, over: 2, upperHalf: true)
        let moved = applying(.moveColumn("t1", .activity, before: before))
        #expect(try tab(moved).columns == [.kind, .name, .activity, .state, .project])
        let place = try #require(allColumns.firstIndex(of: .state))
        let same = Rules.dropTarget(allColumns, dragged: .state, over: place, upperHalf: true)
        #expect(applying(.moveColumn("t1", .state, before: same)) == standard)
    }

    @Test func anEmptyOrderGivesTheEnd() {
        #expect(Rules.dropTarget([], dragged: .name, over: 0, upperHalf: true) == nil)
    }

    // MARK: - The colour keys

    @Test func theArrowKeysChooseTheNextColourAndWrapAtTheEnds() {
        #expect(Rules.nextColour(11, key: .arrowRight) == 0)
        #expect(Rules.nextColour(0, key: .arrowLeft) == 11)
        #expect(Rules.nextColour(3, key: .arrowRight) == 4)
        #expect(Rules.nextColour(3, key: .arrowLeft) == 2)
        #expect(Rules.nextColour(3, key: .enter) == 3)
        #expect(Rules.nextColour(3, key: .arrowUp) == 3)
        #expect(Rules.nextColour(3, key: .arrowDown) == 3)
    }
}
