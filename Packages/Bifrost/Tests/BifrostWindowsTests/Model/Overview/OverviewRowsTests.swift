import BifrostSessions
import BifrostWindows
import Testing

// The filter and the sort of the Overview rows (the section "Rows" of
// docs/behaviour/overview.md).

// A row for the Overview tests. The name is the ID when the test gives no name.
func overviewRow(
    _ id: String, name: String? = nil, kind: SessionKind = .owned,
    state: SessionState = .working, alert: SessionAlert = .none,
    cwd: String = "/Users/o/Developer/app", priority: SessionPriority? = nil,
    branch: String? = nil, usage: LiveUsage? = nil, lastActivity: Int = 0,
    watch: RowWatch? = nil
) -> SessionRow {
    SessionRow(
        sessionId: id, name: name ?? id, claudeName: name ?? id, kind: kind, cwd: cwd,
        status: .busy, state: state, alert: alert, lastActivity: lastActivity, startedAt: 0,
        usage: usage, branch: branch, priority: priority, watch: watch)
}

// The rows A to G, in the order of the session list.
private let rowA = overviewRow("A")
private let rowB = overviewRow("B", state: .needsYou, alert: .yellow(since: 1))
private let rowC = overviewRow(
    "C", kind: .external, state: .needsYou, alert: .red(.prompt, since: 1))
private let rowD = overviewRow("D", state: .error, alert: .red(.error, since: 1))
private let rowE = overviewRow("E", state: .idle)
private let rowF = overviewRow("F", state: .parked)
private let rowG = overviewRow("G", state: .idle)
private let allRows = [rowA, rowB, rowC, rowD, rowE, rowF, rowG]

private func ids(_ rows: [SessionRow]) -> String { rows.map(\.sessionId).joined() }

private func names(_ rows: [SessionRow]) -> [String] { rows.map(\.name) }

private func sorted(_ rows: [SessionRow], _ column: OverviewColumn, descending: Bool = false)
    -> [SessionRow]
{
    OverviewRows.sort(rows, SortSpec(column: column, descending: descending))
}

private let liveStates: [SessionState] = [.working, .needsYou, .error, .idle]

// A small generator with a fixed algorithm, so a seed gives the same rows on every machine.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("overview rows")
struct OverviewRowsTests {
    @Test func theStandardTabsFilterTheRows() throws {
        let tabs = OverviewConfig.standard.tabs
        #expect(
            tabs.map { ids(OverviewRows.filter(allRows, $0.filter)) }
                == ["ABCDEG", "BCD", "", "A", "EG", "F"])
        let all = try #require(tabs.first)
        #expect(ids(OverviewRows.view(allRows, tab: all)) == "ABCDEG")
    }

    @Test func theWatchedTabShowsTheWatchedRowsOfEveryState() throws {
        let watched = try #require(OverviewConfig.standard.tabs.first { $0.id == "t0" })
        let rows = [
            overviewRow("a"),
            overviewRow("b", watch: RowWatch(colour: .green, order: 0)),
            overviewRow("c", state: .parked, watch: RowWatch(colour: .white, order: 1)),
        ]
        #expect(ids(OverviewRows.filter(rows, watched.filter)) == "bc")
    }

    @Test func watchedOnlyOffShowsTheRowsThatAreNotWatchedToo() {
        let rows = [overviewRow("a"), overviewRow("b", watch: RowWatch(colour: .green, order: 0))]
        let all = TabFilter(states: [.working], kinds: [.owned], boxOnly: false, watchedOnly: false)
        var watched = all
        watched.watchedOnly = true
        #expect(ids(OverviewRows.filter(rows, all)) == "ab")
        #expect(ids(OverviewRows.filter(rows, watched)) == "b")
    }

    @Test func theFilterShowsOnlyItsKinds() {
        func filter(_ kinds: [SessionKind]) -> TabFilter {
            TabFilter(states: liveStates, kinds: kinds, boxOnly: false, watchedOnly: false)
        }
        #expect(ids(OverviewRows.filter(allRows, filter([.owned]))) == "ABDEG")
        #expect(ids(OverviewRows.filter(allRows, filter([.external]))) == "C")
        #expect(ids(OverviewRows.filter(allRows, filter([]))) == "")
    }

    @Test func boxOnlyShowsTheRowsWithAYellowOrARedBox() {
        let filter = TabFilter(
            states: TabFilter.allStates, kinds: TabFilter.allKinds, boxOnly: true,
            watchedOnly: false)
        #expect(ids(OverviewRows.filter(allRows, filter)) == "BCD")
    }

    @Test func theNameSortIsNumericAndIgnoresCase() {
        let rows = [
            overviewRow("a", name: "s10"), overviewRow("b", name: "s2"),
            overviewRow("c", name: "Alpha"), overviewRow("d", name: "alpha"),
        ]
        #expect(ids(sorted(rows, .name)) == "cdba")
    }

    // The order of the English collation with numbers: case and accents do not count, digit runs
    // compare as numbers, and symbols and emoji come before digits and letters.
    @Test func theNameSortFollowsTheEnglishCollation() {
        let input = [
            "item 10", "item 9", "Item 2", "éclair", "Eclair", "eclair", "zebra", "Zebra",
            "😀 smile", "apple", "Äpfel", "app", "a10b", "a9b", "", "résumé", "resume",
            "🚀 launch", "_tmp", "2fa", "10x",
        ]
        let rows = input.enumerated().map { overviewRow("\($0.offset)", name: $0.element) }
        #expect(
            names(sorted(rows, .name)) == [
                "_tmp", "😀 smile", "🚀 launch", "2fa", "10x", "a9b", "a10b", "Äpfel", "app",
                "apple", "éclair", "Eclair", "eclair", "Item 2", "item 9", "item 10", "résumé",
                "resume", "zebra", "Zebra", "",
            ])
        #expect(
            names(sorted(rows, .name, descending: true)) == [
                "zebra", "Zebra", "résumé", "resume", "item 10", "item 9", "Item 2", "éclair",
                "Eclair", "eclair", "apple", "app", "Äpfel", "a10b", "a9b", "10x", "2fa",
                "🚀 launch", "😀 smile", "_tmp", "",
            ])
    }

    @Test func emptyValuesGoLastInBothDirections() {
        let byPriority = [
            overviewRow("a", priority: .p3), overviewRow("b"), overviewRow("c", priority: .p1),
        ]
        #expect(ids(sorted(byPriority, .priority)) == "cab")
        #expect(ids(sorted(byPriority, .priority, descending: true)) == "acb")
        let byBranch = [
            overviewRow("a", branch: "main"), overviewRow("b", branch: ""), overviewRow("c"),
            overviewRow("d", branch: "fix"),
        ]
        #expect(ids(sorted(byBranch, .branch)) == "dabc")
        #expect(ids(sorted(byBranch, .branch, descending: true)) == "adbc")
        let byName = [overviewRow("a", name: ""), overviewRow("b", name: "b")]
        #expect(ids(sorted(byName, .name)) == "ba")
        #expect(ids(sorted(byName, .name, descending: true)) == "ba")
        let byContext = [
            overviewRow("a", usage: LiveUsage(contextPercent: .nan)),
            overviewRow("b", usage: LiveUsage(contextPercent: 10)), overviewRow("c"),
            overviewRow("d", usage: LiveUsage(contextPercent: 50)),
        ]
        #expect(ids(sorted(byContext, .context)) == "bdac")
        #expect(ids(sorted(byContext, .context, descending: true)) == "dbac")
    }

    // 200 seeded rows with few values in each column, so most keys are equal. For each column and
    // each direction, the rows come in the order of their key groups, empty values last, and the
    // rows of one group keep their input order.
    @Test func equalValuesKeepTheInputOrder() {
        // The values of each column, from low to high. Values in one inner list are equal.
        let names: [[String]] = [["a", "A", "á"], ["b", "B"], ["b2"], ["b10"]]
        let priorities: [SessionPriority] = [.p1, .p2, .p3]
        let costs: [Double] = [0.5, 1, 2]
        let activities = [10, 20]
        var rng = SplitMix64(state: 0x00B1_F205_7004_0004)
        var rows: [SessionRow] = []
        // The rank of the value of each row in each column. nil is an empty value.
        var ranks: [OverviewColumn: [Int?]] = [:]
        for index in 0..<200 {
            let nameGroup = Int.random(in: -1..<names.count, using: &rng)
            let priority = Int.random(in: -1..<priorities.count, using: &rng)
            let cost = Int.random(in: -1..<costs.count, using: &rng)
            let activity = Int.random(in: 0..<activities.count, using: &rng)
            let state = Int.random(in: 0..<TabFilter.allStates.count, using: &rng)
            let external = Bool.random(using: &rng)
            let name =
                nameGroup < 0
                ? "" : names[nameGroup][Int.random(in: 0..<names[nameGroup].count, using: &rng)]
            rows.append(
                overviewRow(
                    "\(index)", name: name, kind: external ? .external : .owned,
                    state: TabFilter.allStates[state],
                    priority: priority < 0 ? nil : priorities[priority],
                    usage: LiveUsage(costUsd: cost < 0 ? nil : costs[cost]),
                    lastActivity: activities[activity]))
            ranks[.name, default: []].append(nameGroup < 0 ? nil : nameGroup)
            ranks[.priority, default: []].append(priority < 0 ? nil : priority)
            ranks[.cost, default: []].append(cost < 0 ? nil : cost)
            ranks[.activity, default: []].append(activity)
            // The state order is error, alert, working, idle, parked.
            ranks[.state, default: []].append([2, 1, 0, 3, 4][state])
            ranks[.kind, default: []].append(external ? 1 : 0)
        }
        for (column, rank) in ranks {
            for descending in [false, true] {
                let groups = Set(rank.compactMap { $0 }).sorted()
                let order = descending ? groups.reversed() : groups
                let expected =
                    order.flatMap { group in rows.indices.filter { rank[$0] == group } }
                    + rows.indices.filter { rank[$0] == nil }
                let result = sorted(rows, column, descending: descending)
                #expect(
                    result.map(\.sessionId) == expected.map { "\($0)" },
                    "\(column) descending \(descending)")
            }
        }
    }

    @Test func theStateSortGivesErrorAlertWorkingIdleParked() {
        #expect(ids(sorted(allRows.reversed(), .state)) == "DCBAGEF")
    }

    @Test func theKindSortPutsOwnedSessionsFirst() {
        #expect(ids(sorted(allRows, .kind)) == "ABDEFGC")
        #expect(ids(sorted(allRows, .kind, descending: true)) == "CABDEFG")
    }

    // A box does not move a row: the State column sorts by the state only.
    @Test func aBoxChangeDoesNotMoveARowInTheStateSort() {
        let red = overviewRow("b", state: .needsYou, alert: .red(.prompt, since: 1))
        let yellow = overviewRow("a", state: .needsYou, alert: .yellow(since: 1))
        var turnedRed = yellow
        turnedRed.alert = .red(.escalated, since: 2)
        #expect(ids(sorted([yellow, red], .state)) == "ab")
        #expect(ids(sorted([turnedRed, red], .state)) == "ab")
    }

    @Test func theProjectSortUsesTheProjectLabel() {
        let rows = [
            overviewRow("a", cwd: "/z/b/.claude/worktrees/w"), overviewRow("b", cwd: "/z/a"),
        ]
        #expect(ids(sorted(rows, .project)) == "ba")
    }

    @Test func theModelContextAndActivitySortByTheirValues() {
        let rows = [
            overviewRow(
                "a", usage: LiveUsage(model: "claude-sonnet-4-5", contextPercent: 80),
                lastActivity: 300),
            overviewRow(
                "b", usage: LiveUsage(model: "claude-opus-5-5", contextPercent: 9.5),
                lastActivity: 100),
            overviewRow("c", usage: LiveUsage(contextPercent: 41), lastActivity: 200),
        ]
        #expect(ids(sorted(rows, .model)) == "bac")
        #expect(ids(sorted(rows, .context)) == "bca")
        #expect(ids(sorted(rows, .activity, descending: true)) == "acb")
    }

    @Test func theViewFiltersThenSorts() {
        var tab = OverviewConfig.standard.tabs[0]
        tab.sort = SortSpec(column: .name, descending: true)
        #expect(ids(OverviewRows.view(allRows, tab: tab)) == "GEDCBA")
    }
}
