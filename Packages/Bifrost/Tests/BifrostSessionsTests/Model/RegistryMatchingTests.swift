import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostSessions

// Rows, names, and one row across /clear or a restart.

// Real entries of claude agents --json (test of 2026-11-06, claude 2.1.319). The parser of the
// app reads the entries, so a null pid or status is the same as in the app.
private struct ClearFixture {
    var before: AgentEntry
    var after: AgentEntry
    var stoppedAfterClear: AgentEntry

    init() throws {
        let data = try Fixture.data("clear-agents.json")
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let running = try #require(root["clearRunning"] as? [String: Any])
        func parsed(_ list: Any?) throws -> AgentEntry {
            let json = try JSONSerialization.data(withJSONObject: try #require(list))
            let list = AgentList(output: String(decoding: json, as: UTF8.self))
            return try #require(list.entries.first)
        }
        before = try parsed(running["before"])
        after = try parsed(running["after"])
        stoppedAfterClear = try parsed(root["stoppedAfterClear"])
    }
}

@Suite("brief")
struct BriefTests {
    @Test("a background entry makes an owned row")
    func ownedRow() {
        var r = SessionRegistry(store: RegistryStore(), escalation: .seconds(600))
        r.applyAgents([bg()], sampledAt: 100)
        let row = r.rows().first
        #expect(
            row?.kind == .owned && row?.name == "alpha" && row?.sessionId == "s1"
                && row?.shortId == "aaaaaaaa" && row?.state == .idle)
    }

    @Test("an entry without a PID stays as a row")
    func noPid() {
        var r = registry()
        r.applyAgents([bg(pid: nil, status: .unknown)], sampledAt: 100)
        let rows = r.rows()
        #expect(rows.count == 1)
        #expect(rows.first?.pid == nil)
    }

    @Test("an external session that ends is removed")
    func externalGoes() {
        var r = registry()
        r.applyAgents([bg(id: nil, background: false)], sampledAt: 100)
        #expect(r.rows().count == 1)
        r.applyAgents([], sampledAt: 200)
        #expect(r.rows() == [])
    }

    @Test("an owned session in the full list is parked and keeps its stored name")
    func ownedParked() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        r.applyAgents([], sampledAt: 200)
        r.applyAllAgents([bg(name: "", pid: nil, status: .unknown)], complete: true)
        #expect(r.rows().count == 1)
        let row = r.rows().first
        #expect(
            row?.alert.colour == AlertColour.none
                && row?.name == "alpha"
                && row?.state == .parked)
    }

    @Test("a started session that is not active and not in the full list is parked")
    func startedParked() {
        var r = registry(RegistryStore(names: ["s9": "nine"]))
        r.markStarted("s9")
        r.applyAgents([], sampledAt: 100)
        r.applyAllAgents([], complete: true)
        #expect(r.rows().count == 1)
        let row = r.rows().first
        #expect(
            row?.alert.colour == AlertColour.none && row?.kind == .owned && row?.name == "nine"
                && row?.sessionId == "s9" && row?.state == .parked)
    }

    @Test
    func shortIdName() {
        var r = registry()
        r.applyAgents([bg(name: "aaaaaaaa")], sampledAt: 100)
        #expect(r.store().names["s1"] == nil)
    }

    @Test("an early event applies later or drops after 60 s")
    func pendingEvent() {
        var r = registry()
        r.applyEvents([ev(.stop, "s1", 10)], now: 10)
        #expect(r.rows() == [])
        r.applyAgents([bg()], sampledAt: 20)
        #expect(r.rows().first?.alert.colour == .yellow)

        var other = registry()
        other.applyEvents([ev(.stop, "s2", 10)], now: 10)
        other.tick(now: 70_011)
        other.applyAgents([bg(sessionId: "s2")], sampledAt: 70_012)
        #expect(other.rows().first?.alert.colour == AlertColour.none)
    }

    @Test("a new status from the poll sets the last activity to the sample time")
    func statusActivity() {
        var r = registry()
        r.applyAgents([bg(status: .idle)], sampledAt: 100)
        #expect(r.rows().first?.lastActivity == 1)
        r.applyAgents([bg(status: .busy)], sampledAt: 200)
        #expect(r.rows().first?.lastActivity == 200)
        r.applyAgents([bg(status: .busy)], sampledAt: 300)
        #expect(r.rows().first?.lastActivity == 200)
        r.applyAgents([bg(status: .idle)], sampledAt: 400)
        #expect(r.rows().first?.lastActivity == 400)
    }

    @Test
    func laterHookWins() {
        var r = registry()
        r.applyAgents([bg(status: .idle)], sampledAt: 100)
        r.applyAgents([bg(status: .busy)], sampledAt: 200)
        r.applyEvents([ev(.stop, "s1", 250)], now: 250)
        #expect(r.rows().first?.lastActivity == 250)
    }

    @Test
    func usageAndBranch() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        r.applyEvents([ev(.stop, "s1", 300)], now: 300)
        r.applyUsage(
            "s1", LiveUsage(model: "claude-opus-5-5", contextPercent: 42, costUsd: 1.5), at: 500)
        r.applyBranch("/p", "main")
        let row = r.rows().first
        #expect(
            row?.branch == "main" && row?.usage?.contextPercent == 42 && row?.usage?.costUsd == 1.5
                && row?.lastActivity == 300 && row?.model == "Opus 5.5")
        r.applyEvents([ev(.userPromptSubmit, "s1", 900)], now: 900)
        #expect(r.rows().first?.lastActivity == 900)
        r.applyBranch("/p", nil)
        #expect(r.rows().first?.branch == nil)
    }

    @Test("a tick escalates and the box keeps flashing")
    func tickEscalates() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 0)
        r.applyEvents([ev(.stop, "s1", 0)], now: 0)
        r.tick(now: 600_000)
        #expect(r.rows().first?.alert.colour == .red)
        #expect(r.rows().first?.alert.flashes == true)
        r.applyEvents([ev(.userPromptSubmit, "s1", 600_001)], now: 600_001)
        #expect(
            r.rows().first?.alert.colour == AlertColour.none
                && r.rows().first?.alert.flashes == false)
    }
}

@Suite("names")
struct NameTests {
    @Test("the name comes from the entry, then the short ID, then the session ID")
    func nameOrder() {
        var r = registry()
        r.applyAgents(
            [
                bg(name: "one"), bg(id: "bbbbbbbb", name: "bbbbbbbb", sessionId: "s2"),
                bg(id: nil, name: "", sessionId: "abcdefghijkl"),
            ],
            sampledAt: 100)
        let names = Dictionary(uniqueKeysWithValues: r.rows().map { ($0.sessionId, $0.name) })
        #expect(names == ["abcdefghijkl": "abcdefgh", "s1": "one", "s2": "bbbbbbbb"])
    }

    @Test("the stored name comes before the short ID")
    func storedFirst() {
        var r = registry(RegistryStore(names: ["s1": "stored"]))
        r.applyAgents([bg(name: "")], sampledAt: 100)
        #expect(r.rows().first?.name == "stored")
    }

    @Test("the name of a new entry replaces the stored name")
    func newReplaces() {
        var r = registry(RegistryStore(names: ["s1": "old"]))
        r.applyAgents([bg(name: "new")], sampledAt: 100)
        #expect(r.rows().first?.name == "new")
        #expect(r.store().names == ["s1": "new"])
    }

    @Test
    func emptyNotStored() {
        var r = registry()
        r.applyAgents([bg(name: "")], sampledAt: 100)
        #expect(r.rows().first?.name == "aaaaaaaa")
        #expect(r.store().names == [:])
    }
}

@Suite("rows")
struct RowTests {
    @Test("rows sort by start time, then session ID")
    func sorted() {
        var r = registry()
        r.applyAgents(
            [
                bg(sessionId: "c", startedAt: 5), bg(sessionId: "b", startedAt: 9),
                bg(sessionId: "a", startedAt: 5),
            ], sampledAt: 100)
        #expect(r.ids == ["a", "c", "b"])
    }

    @Test("a row holds the entry fields and the machine fields")
    func fullRow() {
        var r = registry()
        r.applyAgents([bg(status: .waiting, waitingFor: "permission prompt")], sampledAt: 100)
        #expect(
            r.rows().first
                == SessionRow(
                    sessionId: "s1", shortId: "aaaaaaaa", name: "alpha", claudeName: "alpha",
                    kind: .owned, pid: 5,
                    cwd: "/p", status: .waiting, listing: .listed,
                    waitingFor: "permission prompt", state: .needsYou,
                    alert: .red(.prompt, since: 100), lastActivity: 1, startedAt: 1))
    }

    // A row is listed while the last active list has it, also with no pid and no status, as in
    // the 2.5 s or so after a start. A row of the --all list that an active list of a later turn
    // lacks is not listed.
    @Test("a row is listed while the active list has it")
    func listedActive() {
        var r = registry()
        r.applyAgents([bg(pid: nil, status: .unknown)], sampledAt: 100)
        #expect(r.row("s1")?.listing == .listed)
        var parked = registry()
        parked.applyAgents([], sampledAt: 300, turn: 2)
        parked.applyAllAgents([bg(pid: nil, status: .unknown)], complete: true, turn: 1)
        #expect(parked.row("s1")?.state == .parked)
        #expect(parked.row("s1")?.listing == .notListed)
    }

    // The --all list can have a new background entry with no pid before an active list has it,
    // for example a session that starts. Its new parked row counts as listed until an active
    // list of a later turn in the lock of the lists also lacks it. An active list of an earlier
    // turn does not count, also when it comes later.
    @Test("a new row of the --all list is listed until a later active list lacks it")
    func listedUntilALaterActiveListLacksIt() {
        var r = registry()
        r.applyAgents([], sampledAt: 100, turn: 1)
        r.applyAllAgents([bg(pid: nil, status: .unknown)], complete: true, turn: 3)
        #expect(r.row("s1")?.state == .parked)
        #expect(r.row("s1")?.listing == .unconfirmed)
        r.applyAgents([], sampledAt: 150, turn: 2)
        #expect(r.row("s1")?.listing == .unconfirmed)
        r.applyAgents([], sampledAt: 300, turn: 4)
        #expect(r.row("s1")?.listing == .notListed)
    }

    // The turns order the lists, not the wall times: an active list with an earlier sample time
    // but a later turn ends the mark. A list with no turn comes after each list before it.
    @Test("the turns of the lists order the marks, not the wall times")
    func theTurnsOrderTheMarks() {
        var r = registry()
        r.applyAgents([], sampledAt: 500, turn: 1)
        r.applyAllAgents([bg(pid: nil, status: .unknown)], complete: true, turn: 2)
        #expect(r.row("s1")?.listing == .unconfirmed)
        r.applyAgents([], sampledAt: 400, turn: 3)
        #expect(r.row("s1")?.listing == .notListed)
        var later = registry()
        later.applyAgents([], sampledAt: 100)
        later.applyAllAgents([bg(pid: nil, status: .unknown)], complete: true)
        #expect(later.row("s1")?.listing == .unconfirmed)
        later.applyAgents([], sampledAt: 50)
        #expect(later.row("s1")?.listing == .notListed)
    }

    @Test("a red row has the cause of its box and other rows have none")
    func boxReason() {
        var r = registry()
        r.applyAgents(
            [bg(), bg(sessionId: "s2", startedAt: 2), bg(sessionId: "s3", startedAt: 3)],
            sampledAt: 0)
        r.applyEvents([ev(.stop, "s1", 0), ev(.permissionRequest, "s2", 0)], now: 0)
        r.applyEvents([ev(.stopFailure, "s3", 0)], now: 0)
        #expect(
            r.rows().map(\.alert.colour) == [.yellow, .red, .red]
                && r.rows().map(\.alert.reason) == [nil, .prompt, .error])
        #expect(r.rows().first?.alert.reason == nil)
        r.tick(now: 600_000)
        #expect(r.rows().first?.alert.colour == .red)
        #expect(r.rows().first?.alert.reason == .escalated)
        r.applyEvents([ev(.userPromptSubmit, "s1", 700_000)], now: 700_000)
        #expect(r.rows().first?.alert.colour == AlertColour.none)
        #expect(r.rows().first?.alert.reason == nil)
    }

    @Test("the row holds the last assistant message")
    func lastMessage() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        r.applyEvents([HookEvent(.stop, "s1", at: 200, lastAssistantMessage: "Done.")], now: 200)
        #expect(r.rows().first?.lastMessage == "Done.")
    }

    @Test("each cwd is listed once and an empty cwd is skipped")
    func cwds() {
        var r = registry()
        r.markStarted("s9")
        r.applyAgents(
            [bg(), bg(sessionId: "s2"), bg(cwd: "/q", sessionId: "s3", startedAt: 2)],
            sampledAt: 100)
        #expect(r.cwds() == ["/p", "/q"])
    }

    @Test("a row that shows later with the same cwd also gets the branch")
    func branchLater() {
        var r = registry()
        r.applyBranch("/p", "HEAD")
        r.applyAgents([bg()], sampledAt: 100)
        #expect(r.rows().first?.branch == "HEAD")
    }
}

@Suite("carrying values over")
struct CarryOverTests {
    private func four(_ store: RegistryStore = RegistryStore()) -> SessionRegistry {
        var r = registry(store)
        r.applyAgents(
            ["s1", "s2", "s3", "s4"].enumerated().map { i, id in
                bg(id: ShortID("0000000\(i)"), name: id, pid: 5 + pid_t(i), sessionId: id)
            },
            sampledAt: 100)
        return r
    }

    @Test("the priority moves to the new session")
    func movesPriority() {
        var r = four()
        _ = r.setPriority("s2", .p2)
        #expect(r.carryOver(from: "s2", to: "s4") == true)
        #expect(r.store().priorities == ["s4": .p2])
    }

    @Test("the watch entry moves to the same place with the same colour")
    func movesWatch() {
        var r = four()
        _ = r.watchAdd("s1", .red)
        _ = r.watchAdd("s2", .amber)
        _ = r.watchAdd("s3", .green)
        #expect(r.carryOver(from: "s2", to: "s4") == true)
        #expect(
            r.store().watch == [
                WatchEntry("s1", .red), WatchEntry("s4", .amber), WatchEntry("s3", .green),
            ])
    }

    @Test("the new session keeps its own values when the old one has none")
    func keepsNew() {
        var r = four()
        _ = r.setPriority("s4", .p3)
        _ = r.watchAdd("s4", .green)
        let before = r.store()
        #expect(r.carryOver(from: "s2", to: "s4") == true)
        #expect(r.store().priorities == ["s4": .p3])
        #expect(r.store().watch == [WatchEntry("s4", .green)])
        #expect(r.store() == before)
    }

    @Test("the moved watch entry replaces an earlier entry of the new session")
    func replacesEarlier() {
        var r = four()
        _ = r.watchAdd("s2", .red)
        _ = r.watchAdd("s3", .green)
        _ = r.watchAdd("s4", .darkBlue)
        #expect(r.carryOver(from: "s2", to: "s4") == true)
        #expect(r.store().watch == [WatchEntry("s4", .red), WatchEntry("s3", .green)])
    }

    @Test("an unknown ID gives false and changes nothing")
    func unknown() {
        var r = four()
        _ = r.setPriority("s2", .p2)
        _ = r.watchAdd("s2", .red)
        let before = r.store()
        #expect(r.carryOver(from: "s2", to: "nope") == false)
        #expect(r.carryOver(from: "nope", to: "s4") == false)
        #expect(r.store() == before)
    }

    @Test("moved values are still there after a store reload")
    func survivesReload() {
        var r = four()
        _ = r.setPriority("s2", .p2)
        _ = r.watchAdd("s2", .red)
        _ = r.carryOver(from: "s2", to: "s4")
        let again = four(r.store())
        #expect(again.row("s4")?.priority == .p2)
        #expect(again.store().watch == [WatchEntry("s4", .red)])
        #expect(again.store().priorities == ["s4": .p2])
    }
}

@Suite("local name")
struct AliasTests {
    @Test("a local name shows in the row and keeps the Claude Code name")
    func shows() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        #expect(r.rows().first?.claudeName == "alpha")
        #expect(r.rows().first?.name == "alpha")
        #expect(r.setAlias("s1", "Work") == true)
        #expect(r.rows().first?.claudeName == "alpha")
        #expect(r.rows().first?.name == "Work")
        #expect(r.store().aliases == ["s1": "Work"])
    }

    @Test("a new local name replaces the old name")
    func replaces() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        _ = r.setAlias("s1", "Work")
        _ = r.setAlias("s1", "Home")
        #expect(r.rows().first?.name == "Home")
        #expect(r.store().aliases == ["s1": "Home"])
    }

    @Test("null, an empty name or the Claude Code name clears the local name")
    func clears() {
        for clear in [nil, "", "   ", "alpha", " alpha "] as [String?] {
            var r = registry()
            r.applyAgents([bg()], sampledAt: 100)
            _ = r.setAlias("s1", "Work")
            #expect(r.setAlias("s1", clear) == true)
            #expect(r.rows().first?.claudeName == "alpha")
            #expect(r.rows().first?.name == "alpha")
            #expect(r.store().aliases == [:])
        }
    }

    @Test("the same value leaves the store unchanged")
    func same() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        _ = r.setAlias("s1", "Work")
        let named = r.store()
        _ = r.setAlias("s1", "Work")
        #expect(r.store() == named)
        _ = r.setAlias("s1", nil)
        let unnamed = r.store()
        _ = r.setAlias("s1", nil)
        #expect(r.store() == unnamed)
    }

    @Test("a local name is refused for an unknown session or a bad name")
    func refuses() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        #expect(r.setAlias("nope", "x") == false)
        #expect(r.setAlias("s1", "a\u{1b}b") == false)
        #expect(r.store().aliases == [:])
    }

    @Test("the store hands the local name to a new registry")
    func fromStore() {
        var r = registry(RegistryStore(aliases: ["s1": "Work"]))
        r.applyAgents([bg()], sampledAt: 100)
        #expect(r.rows().first?.claudeName == "alpha")
        #expect(r.rows().first?.name == "Work")
    }

    @Test("usage shows the local name")
    func usageName() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        r.applyUsage("s1", LiveUsage(rateLimits: RateLimits(sevenDay: win(10, 9000))), at: 1000)
        #expect(r.usage()?.name == "alpha")
        _ = r.setAlias("s1", "Work")
        #expect(r.usage()?.name == "Work")
    }

    @Test
    func sameAsNew() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        _ = r.setAlias("s1", "Work")
        r.applyAgents([bg(name: "Work")], sampledAt: 200)
        #expect(r.rows().first?.claudeName == "Work")
        #expect(r.rows().first?.name == "Work")
        #expect(r.store().aliases == [:])
        r.applyAgents([bg(name: "Other")], sampledAt: 300)
        #expect(r.rows().first?.claudeName == "Other")
        #expect(r.rows().first?.name == "Other")
    }

    @Test("a new Claude Code name from a poll leaves the local name")
    func keepsLocal() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        _ = r.setAlias("s1", "Work")
        r.applyAgents([bg(name: "beta")], sampledAt: 200)
        #expect(r.rows().first?.claudeName == "beta")
        #expect(r.rows().first?.name == "Work")
    }

    @Test("a local name works for a parked row")
    func parkedRow() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        r.applyAgents([], sampledAt: 200)
        r.applyAllAgents([bg(name: "", pid: nil, status: .unknown)], complete: true)
        #expect(r.rows().first?.state == .parked)
        #expect(r.setAlias("s1", "Work") == true)
        #expect(r.rows().first?.claudeName == "alpha")
        #expect(r.rows().first?.name == "Work")
    }

    @Test("two counted full lists forget a session that has only a local name")
    func onlyLocal() {
        var r = registry(RegistryStore(aliases: ["ghost": "Old"]))
        r.applyAgents([bg()], sampledAt: 100)
        r.applyAllAgents([bg(), another], complete: true)
        #expect(r.store().aliases == ["ghost": "Old"])
        r.applyAllAgents([bg(), another], complete: true)
        #expect(r.store().aliases == [:])
    }
}

@Suite("one row across /clear")
struct ClearJobTests {
    private let f: ClearFixture
    private var ORIGINAL: String { f.before.sessionId }
    private var CLEARED: String { f.after.sessionId }
    private let short8: ShortID = "2f493bf0"
    // A stopped job: the --all entry has the original session ID, no pid and no status (test 3).
    private var stopped: AgentEntry { f.before.with { $0.pid = nil; $0.status = .unknown } }
    // claude --continue in a terminal of the project picks the conversation after the clear.
    private var terminal: AgentEntry {
        AgentEntry(
            sessionId: CLEARED, cwd: f.before.cwd, isBackground: false, startedAt: 9,
            name: "bifrost-test-cl1", status: .idle, pid: 777)
    }

    init() throws { f = try ClearFixture() }

    // Give the row a local name, a priority, a watch entry and the started mark.
    private func giveValues(_ r: inout SessionRegistry, _ id: String) {
        #expect(r.setAlias(id, "Work") == true)
        #expect(r.setPriority(id, .p2) == true)
        #expect(r.watchAdd(id, .amber) == true)
        r.markStarted(id)
    }

    // A job that ran, then got a /clear.
    private func cleared() -> SessionRegistry {
        var r = registry()
        r.applyAgents([f.before], sampledAt: 100)
        giveValues(&r, ORIGINAL)
        r.applyAgents([f.after], sampledAt: 2100)
        return r
    }

    @Test("a real /clear changes only the session ID")
    func realClear() {
        #expect(f.after.with { $0.sessionId = ORIGINAL } == f.before)
        #expect(CLEARED != ORIGINAL)
        #expect(f.before.id == short8)
    }

    @Test
    func keepsOneRow() {
        let r = cleared()
        let rows = r.rows()
        #expect(rows.count == 1)
        let row = rows.first
        #expect(
            row?.claudeName == "bifrost-test-cl1" && row?.currentId == CLEARED
                && row?.name == "Work" && row?.priority == .p2
                && row?.resumeId == ORIGINAL && row?.sessionId == ORIGINAL && row?.shortId == short8
                && row?.state == .idle
                && row?.watch == RowWatch(colour: .amber, order: 0))
        let store = r.store()
        #expect(
            store.aliases == [ORIGINAL: "Work"] && store.current == [ORIGINAL: CLEARED]
                && store.jobs == [ORIGINAL: short8]
                && store.lastActive == [ORIGINAL] && store.priorities == [ORIGINAL: .p2]
                && store.started == [ORIGINAL]
                && store.watch == [WatchEntry(ORIGINAL, .amber)])
    }

    @Test("a row without a /clear has no current ID")
    func noCurrentId() {
        var r = registry()
        r.applyAgents([f.before], sampledAt: 100)
        #expect(r.rows().first?.currentId == nil)
        #expect(r.rows().first?.resumeId == ORIGINAL)
        #expect(r.store().current == [:])
    }

    @Test("the full list while the job runs gives no second row")
    func noSecondRow() {
        var r = cleared()
        r.applyAllAgents([f.after], complete: true)
        r.applyAllAgents([f.after], complete: true)
        #expect(r.ids == [ORIGINAL])
        #expect(r.store().aliases == [ORIGINAL: "Work"])
    }

    @Test
    func stoppedSameRow() {
        var r = cleared()
        r.applyAgents([], sampledAt: 4100)
        r.applyAllAgents([stopped], complete: true)
        r.applyAllAgents([stopped], complete: true)
        let rows = r.rows()
        #expect(rows.count == 1)
        let row = rows.first
        #expect(
            row?.currentId == CLEARED && row?.name == "Work" && row?.priority == .p2
                && row?.resumeId == ORIGINAL
                && row?.sessionId == ORIGINAL && row?.state == .parked)
    }

    @Test
    func firstSeenAfterClear() {
        // The real --all entry of test 3 has no cwd. The running entry is the same job before stop.
        let real = f.stoppedAfterClear
        let running = real.with {
            $0.cwd = "/w"
            $0.name = "bifrost-test-cl3"
            $0.pid = 4000
            $0.sessionId = "c1ea4ed0-0000-4000-8000-000000000001"
            $0.status = .idle
        }
        var r = registry()
        r.applyAgents([running], sampledAt: 100)
        r.applyAllAgents([running], complete: true)
        // The row ID is the first ID that Bifrost saw. No ID starts with the short ID yet, so
        // Bifrost does not know the ID that resumes the job.
        #expect(r.rows().first?.sessionId == running.sessionId)
        #expect(r.rows().first?.state == .idle)
        #expect(r.rows().first?.resumeId == nil)
        r.applyAgents([], sampledAt: 2100)
        r.applyAllAgents([real], complete: true)
        let rows = r.rows()
        #expect(rows.count == 1)
        #expect(
            rows.first?.resumeId == real.sessionId && rows.first?.sessionId == running.sessionId
                && rows.first?.state == .parked)
    }

    @Test
    func resumesByAllId() {
        // Bifrost did not see this case. The spec says: use the ID of the stopped job in --all.
        let job = bg(id: "abcd1234", pid: nil, sessionId: CLEARED, status: .unknown)
        var r = registry()
        r.applyAgents([job.with { $0.pid = 300; $0.status = .idle }], sampledAt: 100)
        #expect(r.rows().first?.resumeId == nil)
        r.applyAgents([], sampledAt: 2100)
        r.applyAllAgents([job], complete: true)
        #expect(r.rows().first?.resumeId == CLEARED)
        #expect(r.rows().first?.state == .parked)
    }

    @Test("a listed ID that does not start with the short ID never replaces one that does")
    func neverReplaces() {
        // Bifrost first saw the job after its /clear, so the row ID is the ID after the clear.
        var r = registry()
        r.applyAgents([f.after], sampledAt: 100)
        r.applyAgents([], sampledAt: 2100)
        r.applyAllAgents([stopped], complete: true)
        #expect(r.rows().first?.resumeId == ORIGINAL)
        #expect(r.rows().first?.sessionId == CLEARED)
        // A later entry of the same job without a pid has the ID after the /clear.
        r.applyAllAgents([f.after.with { $0.pid = nil; $0.status = .unknown }], complete: true)
        #expect(r.rows().first?.resumeId == ORIGINAL)
        #expect(r.rows().first?.sessionId == CLEARED)
    }

    @Test
    func terminalOwnRow() {
        var r = cleared()
        r.applyAgents([], sampledAt: 4100)
        r.applyAllAgents([stopped], complete: true)
        r.applyAgents([terminal], sampledAt: 6100)
        r.applyAgents([terminal], sampledAt: 8100)
        let rows = r.rows()
        #expect(rows.count == 2)
        let mine = rows.first { $0.sessionId == ORIGINAL }
        #expect(
            mine?.kind == .owned && mine?.name == "Work" && mine?.resumeId == ORIGINAL
                && mine?.shortId == short8 && mine?.state == .parked)
        let other = rows.first { $0.sessionId != ORIGINAL }
        #expect(other?.kind == .external)
        #expect(other?.pid == 777)
        #expect(other?.state == .idle)
        #expect(other?.priority == nil)
        // The live lines of the conversation go to the process that runs it.
        r.applyUsage(CLEARED, LiveUsage(costUsd: 2), at: 8200)
        let after = r.rows()
        #expect(after.first { $0.sessionId != ORIGINAL }?.usage?.costUsd == 2)
        #expect(after.first { $0.sessionId == ORIGINAL }?.usage?.costUsd == nil)
    }

    @Test
    func wakesWithTerminal() {
        var r = cleared()
        r.applyAgents([], sampledAt: 4100)
        r.applyAllAgents([stopped], complete: true)
        r.applyAgents([terminal], sampledAt: 6100)
        let woken = f.after.with { $0.pid = 22400 }
        r.applyAgents([woken, terminal], sampledAt: 8100)
        r.applyAgents([woken, terminal], sampledAt: 10_100)
        let before = r.store()
        r.applyAgents([woken, terminal], sampledAt: 12_100)
        #expect(r.store() == before)
        let rows = r.rows()
        #expect(rows.count == 2)
        let mine = rows.first { $0.sessionId == ORIGINAL }
        #expect(
            mine?.currentId == CLEARED && mine?.kind == .owned && mine?.name == "Work"
                && mine?.pid == 22400)
        #expect(rows.first { $0.sessionId != ORIGINAL }?.pid == 777)
        // A restart gives the same two rows.
        var next = registry(r.store())
        next.applyAgents([woken, terminal], sampledAt: 100)
        let got = next.rows().map { "\($0.sessionId == ORIGINAL) \($0.name) \($0.pid ?? 0)" }
        #expect(got == ["false bifrost-test-cl1 777", "true Work 22400"])
    }

    @Test("two jobs of one conversation do not move the current ID at each poll")
    func twoJobs() {
        var r = cleared()
        // claude --bg --resume <ID after the clear>, typed by hand, starts a second job (test 4).
        let copy = f.after.with { $0.id = "1db82d17"; $0.pid = 23000 }
        r.applyAgents([f.after, copy], sampledAt: 4100)
        r.applyAgents([f.after, copy], sampledAt: 6100)
        let before = r.store()
        r.applyAgents([f.after, copy], sampledAt: 8100)
        #expect(r.store() == before)
        let rows = r.rows()
        #expect(rows.count == 2)
        let mine = rows.first { $0.sessionId == ORIGINAL }
        #expect(mine?.name == "Work")
        #expect(mine?.shortId == short8)
        #expect(rows.first { $0.sessionId != ORIGINAL }?.shortId == "1db82d17")
        // The row that had the conversation first keeps its live lines.
        r.applyUsage(CLEARED, LiveUsage(costUsd: 3), at: 8200)
        #expect(r.rows().first { $0.sessionId == ORIGINAL }?.usage?.costUsd == 3)
        #expect(r.rows().first { $0.sessionId != ORIGINAL }?.usage?.costUsd == nil)
    }

    @Test
    func storeOfMain() {
        // Main kept the values on the original ID and made a new row for the ID after the clear.
        var r = registry(
            RegistryStore(
                aliases: [ORIGINAL: "Work"], lastActive: [CLEARED],
                names: [CLEARED: "bifrost-test-cl1", ORIGINAL: "bifrost-test-cl1"],
                started: [ORIGINAL], priorities: [ORIGINAL: .p2],
                watch: [WatchEntry(ORIGINAL, .amber)]))
        r.applyAgents([f.after], sampledAt: 100)
        let rows = r.rows()
        #expect(
            rows.count == 1 && rows.first?.sessionId == ORIGINAL && rows.first?.currentId == CLEARED
                && rows.first?.name == "Work" && rows.first?.state == .idle)
        #expect(r.store().jobs == [ORIGINAL: short8])
    }

    @Test("the original ID does not take a job from another folder")
    func otherFolder() {
        var r = registry(RegistryStore(priorities: [ORIGINAL: .p2]))
        r.applyAgents(
            [
                f.before.with {
                    $0.cwd = "/a"; $0.id = "ffffffff"; $0.sessionId = ORIGINAL
                }
            ], sampledAt: 100)
        r.applyAgents([f.after.with { $0.cwd = "/b" }], sampledAt: 2100)
        #expect(r.row(CLEARED)?.priority == nil)
    }

    @Test
    func liveCheckWake() {
        var r = cleared()
        r.applyAgents([], sampledAt: 4100)
        r.applyAllAgents([stopped], complete: true)
        // About 5 s: --all has the original ID with no pid.
        r.applyAllAgents([stopped], complete: true)
        #expect(r.rows().first?.currentId == CLEARED)
        #expect(r.rows().first?.state == .parked)
        // Then the ID after the clear with a pid and no status, for about 1 s.
        let waking = f.after.with { $0.pid = 8989; $0.status = .unknown }
        r.applyAllAgents([waking], complete: true)
        r.applyAgents([waking], sampledAt: 6100)
        #expect(r.rows().count == 1)
        #expect(
            r.rows().first?.alert.colour == AlertColour.none && r.rows().first?.currentId == CLEARED
                && r.rows().first?.pid == 8989)
        #expect(r.rows().first?.state != .parked)
        r.applyAgents([waking.with { $0.status = .idle }], sampledAt: 7100)
        #expect(r.rows().first?.alert.colour == AlertColour.none)
        #expect(r.rows().first?.state == .idle)
    }

    @Test
    func noPidNoChange() {
        var r = cleared()
        r.applyAgents([], sampledAt: 4100)
        let before = r.store()
        r.applyAgents([stopped], sampledAt: 6100)
        #expect(r.rows().first?.currentId == CLEARED)
        #expect(r.rows().first?.sessionId == ORIGINAL)
        #expect(r.store().current == [ORIGINAL: CLEARED])
        #expect(r.store() == before)
    }

    @Test("two /clear calls between two polls give the last ID and drop the middle lines")
    func twoClears() {
        let middleId = "aaaaaaaa-0000-4000-8000-00000000000a"
        let lastId = "bbbbbbbb-0000-4000-8000-00000000000b"
        var r = cleared()
        r.applyUsage(
            middleId, LiveUsage(rateLimits: RateLimits(sevenDay: win(50, 9_000_000_000_000))),
            at: 2500)
        let last = f.after.with { $0.sessionId = lastId }
        r.applyAgents([last], sampledAt: 4100)
        #expect(
            r.rows().first?.currentId == lastId && r.rows().first?.name == "Work"
                && r.rows().first?.sessionId == ORIGINAL)
        #expect(r.store().current == [ORIGINAL: lastId])
        // The middle ID has no row, so its line is kept but its rate limits do not count.
        #expect(r.usageLines[middleId] != nil)
        #expect(r.usage() == nil)
        r.applyAllAgents([last], complete: true)
        r.applyAllAgents([last], complete: true)
        #expect(r.usageLines[middleId] == nil)
        #expect(r.rows().count == 1)
    }

    @Test
    func wokenSameRow() {
        var r = cleared()
        r.applyAgents([], sampledAt: 4100)
        r.applyAllAgents([stopped], complete: true)
        // claude --bg --resume <original ID> wakes the job. The active list shows the ID after the
        // clear, with a new pid.
        r.applyAgents([f.after.with { $0.pid = 22400 }], sampledAt: 6100)
        #expect(r.rows().count == 1)
        let row = r.rows().first
        #expect(
            row?.currentId == CLEARED && row?.name == "Work" && row?.pid == 22400
                && row?.sessionId == ORIGINAL && row?.state == .idle)
    }

    @Test("a restart during a job after a /clear maps the entry to the stored row")
    func restartRunning() {
        var next = registry(cleared().store())
        next.applyAgents([f.after], sampledAt: 100)
        #expect(next.rows().count == 1)
        let row = next.rows().first
        #expect(
            row?.currentId == CLEARED && row?.name == "Work" && row?.priority == .p2
                && row?.sessionId == ORIGINAL
                && row?.watch == RowWatch(colour: .amber, order: 0))
    }

    @Test
    func restartShortOnly() {
        var store = cleared().store()
        for rowId in store.current.keys { store[row: rowId].current = nil }
        var next = registry(store)
        next.applyAgents([f.after], sampledAt: 100)
        let rows = next.rows()
        #expect(
            rows.count == 1 && rows.first?.sessionId == ORIGINAL && rows.first?.currentId == CLEARED
                && rows.first?.name == "Work")
    }

    @Test("a restart after the stop maps the listed entry to the stored row")
    func restartStopped() {
        var r = cleared()
        r.applyAgents([], sampledAt: 4100)
        var next = registry(r.store())
        next.applyAgents([], sampledAt: 100)
        next.applyAllAgents([stopped], complete: true)
        let rows = next.rows()
        #expect(
            rows.count == 1 && rows.first?.sessionId == ORIGINAL && rows.first?.resumeId == ORIGINAL
                && rows.first?.name == "Work"
                && rows.first?.state == .parked)
    }

    @Test("live lines of the current ID change the row")
    func liveLines() {
        var r = cleared()
        r.applyEvents([ev(.stop, CLEARED, 3000)], now: 3000)
        r.applyUsage(CLEARED, LiveUsage(model: "claude-haiku-5-5", costUsd: 0.5), at: 3000)
        let row = r.rows().first
        #expect(
            row?.alert.colour == .yellow && row?.usage?.costUsd == 0.5 && row?.live == true
                && row?.model == "Haiku 5.5" && row?.sessionId == ORIGINAL)
        #expect(r.liveCount() == 1)
        // A late line of the old conversation does not change the row.
        r.applyEvents([ev(.userPromptSubmit, ORIGINAL, 3100)], now: 3100)
        r.applyUsage(ORIGINAL, LiveUsage(costUsd: 9), at: 3100)
        #expect(r.rows().first?.alert.colour == .yellow)
        #expect(r.rows().first?.usage?.costUsd == 0.5)
    }

    @Test
    func eventBeforeLink() {
        var r = registry()
        r.applyAgents([f.before], sampledAt: 100)
        r.applyEvents([ev(.stop, CLEARED, 1500)], now: 1500)
        #expect(r.rows().first?.alert.colour == AlertColour.none)
        r.applyAgents([f.after], sampledAt: 2100)
        #expect(r.rows().first?.alert.colour == .yellow)
        #expect(r.rows().first?.sessionId == ORIGINAL)
    }

    @Test
    func rowIdOf() {
        var r = cleared()
        r.applyUsage(
            CLEARED, LiveUsage(rateLimits: RateLimits(fiveHour: win(10, 9_000_000))), at: 3000)
        #expect(r.usage()?.name == "Work")
        #expect(r.usage()?.sessionId == ORIGINAL)
        #expect(r.rowIdOf(CLEARED) == ORIGINAL)
        #expect(r.rowIdOf(ORIGINAL) == ORIGINAL)
        #expect(r.rowIdOf("other") == "other")
    }

    @Test("forget removes the current ID, the job and its lines")
    func forgetCurrent() {
        var r = cleared()
        r.applyUsage(CLEARED, LiveUsage(costUsd: 1), at: 3000)
        r.forget(ORIGINAL)
        #expect(r.rows() == [])
        let store = r.store()
        #expect(store.aliases == [:])
        #expect(store.current == [:])
        #expect(store.jobs == [:])
        #expect(r.liveCount() == 0)
        // A new entry with the cleared ID is a new row now.
        r.applyAgents([f.after], sampledAt: 5000)
        #expect(r.ids == [CLEARED])
    }

    @Test
    func otherFolderNoLink() {
        var r = registry()
        r.applyAgents([f.before], sampledAt: 100)
        giveValues(&r, ORIGINAL)
        r.applyAgents([f.after.with { $0.cwd = "/somewhere/else" }], sampledAt: 2100)
        #expect(r.row(CLEARED)?.name == "bifrost-test-cl1")
        #expect(r.row(CLEARED) != nil)
        #expect(r.row(CLEARED)?.priority == nil)
    }

    @Test
    func otherShortNoLink() {
        var r = registry()
        r.applyAgents([f.before], sampledAt: 100)
        giveValues(&r, ORIGINAL)
        r.applyAgents([f.after.with { $0.id = "dac563c2" }], sampledAt: 2100)
        let row = r.row(CLEARED)
        #expect(row?.name == "bifrost-test-cl1")
        #expect(row?.shortId == "dac563c2")
        #expect(row != nil)
        #expect(row?.priority == nil)
    }

    @Test
    func worktreeStopFolder() {
        let repo = "/r"
        let tree = "\(repo)/.claude/worktrees/cl1"
        var r = registry()
        r.applyAgents([f.before.with { $0.cwd = tree }], sampledAt: 100)
        giveValues(&r, ORIGINAL)
        r.applyAgents([f.after.with { $0.cwd = tree }], sampledAt: 2100)
        r.applyAgents([], sampledAt: 4100)
        // A stopped session reports its start folder.
        r.applyAllAgents([stopped.with { $0.cwd = repo }], complete: true)
        let rows = r.rows()
        #expect(
            rows.count == 1 && rows.first?.sessionId == ORIGINAL && rows.first?.name == "Work"
                && rows.first?.state == .parked)
    }
}

@Suite("one row across /clear in an interactive session")
struct ClearInteractiveTests {
    private let oldId = "a0a0a0a0-0000-4000-8000-000000000001"
    private let newId = "b1b1b1b1-0000-4000-8000-000000000002"
    private func term(cwd: String = "/t", pid: pid_t = 77, sessionId: String? = nil) -> AgentEntry {
        bg(
            cwd: cwd, id: nil, background: false, name: "term", pid: pid,
            sessionId: sessionId ?? oldId)
    }

    // An interactive session with values, then a /clear. The mod sends session.end for the old
    // ID, and a usage line for the new ID 1 s later.
    private func cleared() -> SessionRegistry {
        var r = registry()
        r.applyAgents([term()], sampledAt: 100)
        _ = r.setAlias(oldId, "Mine")
        _ = r.setPriority(oldId, .p1)
        r.applyEvents([ev(.sessionEnd, oldId, 1000)], now: 1000)
        r.applyUsage(newId, LiveUsage(model: "claude-haiku-5-5"), at: 2000)
        r.applyAgents([term(sessionId: newId)], sampledAt: 2100)
        return r
    }

    @Test("a /clear links by PID and folder to one row and the current ID changes")
    func links() {
        let rows = cleared().rows()
        #expect(rows.count == 1)
        let row = rows.first
        #expect(
            row?.currentId == newId && row?.kind == .external && row?.live == true
                && row?.model == "Haiku 5.5" && row?.name == "Mine"
                && row?.priority == .p1 && row?.sessionId == oldId && row?.state == .idle)
        #expect(row?.resumeId == nil)
    }

    @Test
    func clearEndNoPark() {
        var r = registry()
        r.applyAgents([term()], sampledAt: 100)
        r.applyEvents([HookEvent(.sessionEnd, oldId, at: 1000, reason: "clear")], now: 1000)
        #expect(r.rows().first?.sessionId == oldId)
        #expect(r.rows().first?.state == .idle)
        // Another reason ends the process, so the row parks as before.
        r.applyEvents([HookEvent(.sessionEnd, oldId, at: 1100, reason: "logout")], now: 1100)
        #expect(r.rows().first?.state == .parked)
    }

    @Test("after a restart the stored current ID points to the row")
    func restart() {
        var next = registry(cleared().store())
        next.applyAgents([term(sessionId: newId)], sampledAt: 100)
        let rows = next.rows()
        #expect(
            rows.count == 1 && rows.first?.sessionId == oldId && rows.first?.currentId == newId
                && rows.first?.name == "Mine")
    }

    @Test("taking control after a /clear maps the job of the current ID to the row")
    func takeControl() {
        var r = cleared()
        // Take control resumes the current ID. The new job gets the first 8 characters as its short
        // ID.
        let job = bg(cwd: "/t", id: "b1b1b1b1", name: "term", pid: 900, sessionId: newId)
        r.applyAgents([job], sampledAt: 4100)
        #expect(r.rows().count == 1)
        let row = r.rows().first
        #expect(
            row?.kind == .owned && row?.name == "Mine" && row?.pid == 900 && row?.resumeId == newId
                && row?.sessionId == oldId && row?.shortId == "b1b1b1b1")
    }

    @Test("a different folder gives no link")
    func folderDiffers() {
        var r = registry()
        r.applyAgents([term()], sampledAt: 100)
        _ = r.setAlias(oldId, "Mine")
        r.applyAgents([term(cwd: "/other", sessionId: newId)], sampledAt: 2100)
        #expect(r.rows().map { [$0.sessionId, $0.name] } == [[newId, "term"]])
    }

    @Test("a different or non-positive PID gives no link")
    func pidDiffers() {
        for pid: pid_t in [78, 0, -1] {
            var r = registry()
            r.applyAgents([term(pid: pid <= 0 ? pid : 77)], sampledAt: 100)
            _ = r.setAlias(oldId, "Mine")
            r.applyAgents([term(pid: pid, sessionId: newId)], sampledAt: 2100)
            #expect(r.rows().map { [$0.sessionId, $0.name] } == [[newId, "term"]])
        }
    }

    @Test
    func notOneToOne() {
        let newer = "c2c2c2c2-0000-4000-8000-000000000003"
        var r = registry()
        r.applyAgents([term()], sampledAt: 100)
        _ = r.setAlias(oldId, "Mine")
        r.applyAgents([term(sessionId: newId), term(sessionId: newer)], sampledAt: 2100)
        #expect(r.rows().map(\.name) == ["term", "term"])
    }

    @Test
    func oldStillThere() {
        var r = registry()
        r.applyAgents([term()], sampledAt: 100)
        _ = r.setAlias(oldId, "Mine")
        r.applyAgents([term(), term(sessionId: newId)], sampledAt: 2100)
        #expect(r.rows().map { [$0.sessionId, $0.name] } == [[oldId, "Mine"], [newId, "term"]])
    }

    @Test
    func waitsForActive() {
        var r = cleared()
        // claude --bg --resume <old ID> in a terminal: a new job runs the old conversation.
        let job = bg(cwd: "/t", id: "a0a0a0a0", name: "job", pid: 950, sessionId: oldId)
        let before = r.store()
        r.applyAllAgents([term(sessionId: newId), job], complete: false)
        #expect(r.store() == before)
        #expect(r.rows().count == 1)
        r.applyAgents([term(sessionId: newId), job], sampledAt: 4100)
        let added = r.rows().first { $0.sessionId != oldId }
        #expect(added?.currentId == oldId)
        #expect(added?.name == "job")
        #expect(added?.shortId == "a0a0a0a0")
        // The next --all list finds that row by its short ID.
        r.applyAllAgents([job], complete: true)
        #expect(r.rows().count == 2)
    }

    @Test("a started row with no short ID resumes its current ID after a restart")
    func resumesCurrent() {
        // A Take control failed after the signal, then Bifrost restarted.
        var r = registry(RegistryStore(current: [oldId: newId], started: [oldId]))
        r.applyAgents([], sampledAt: 100)
        #expect(
            r.rows().first?.currentId == newId && r.rows().first?.resumeId == newId
                && r.rows().first?.state == .parked)
    }

    @Test("the job of a take-control keeps its original ID after its own /clear")
    func keepsOriginal() {
        let newer = "d3d3d3d3-0000-4000-8000-000000000004"
        var r = cleared()
        let job = bg(cwd: "/t", id: "b1b1b1b1", name: "term", pid: 900, sessionId: newId)
        // Take control marks the row as started, so the stopped job stays as a parked row.
        r.markStarted(oldId)
        r.applyAgents([job], sampledAt: 4100)
        r.applyAgents([job.with { $0.sessionId = newer }], sampledAt: 6100)
        r.applyAgents([], sampledAt: 8100)
        #expect(
            r.rows().first?.currentId == newer && r.rows().first?.resumeId == newId
                && r.rows().first?.sessionId == oldId)
    }

    @Test
    func oldConversationRow() {
        var r = cleared()
        r.applyAgents([term(sessionId: newId), term(pid: 81)], sampledAt: 4100)
        let other = r.rows().first { $0.sessionId != oldId }
        // The job of oldId gets the first 8 characters of oldId as its short ID. The row ID oldId
        // starts with them, but its current ID is newId, so oldId is not the row of that job.
        let job = bg(cwd: "/t", id: "a0a0a0a0", name: "term", pid: 950, sessionId: oldId)
        r.applyAgents([term(sessionId: newId), job], sampledAt: 6100)
        let otherNow = r.rows().first { $0.sessionId == other?.sessionId }
        #expect(otherNow?.kind == .owned)
        #expect(otherNow?.shortId == "a0a0a0a0")
        #expect(r.row(oldId)?.name == "Mine")
        #expect(r.row(oldId)?.pid == 77)
    }

    @Test("the old conversation in a second process has its own row")
    func ownRow() {
        var r = cleared()
        // claude --resume <old ID> in another terminal.
        r.applyAgents([term(sessionId: newId), term(pid: 81)], sampledAt: 4100)
        let rows = r.rows()
        #expect(rows.count == 2)
        let mine = rows.first { $0.sessionId == oldId }
        let other = rows.first { $0.sessionId != oldId }
        #expect(mine?.currentId == newId)
        #expect(mine?.name == "Mine")
        #expect(mine?.pid == 77)
        #expect(other?.currentId == oldId)
        #expect(other?.name == "term")
        #expect(other?.pid == 81)
        #expect(other.map { SessionID($0.sessionId) != nil } == true)
        #expect(other != nil)
        #expect(other?.priority == nil)
    }
}

@Suite("PR sessions")
struct PrSessionTests {
    @Test("a PR session gets no yellow box and no escalation at the end of a turn")
    func noYellow() {
        var r = registry()
        r.markPrSession("s1")
        r.applyAgents([bg(status: .busy)], sampledAt: 100)
        r.applyAgents([bg(status: .idle)], sampledAt: 200)
        #expect(
            r.rows().first?.alert.colour == AlertColour.none && r.rows().first?.prSession == true
                && r.rows().first?.state == .idle)
        r.applyEvents([ev(.userPromptSubmit, "s1", 300), ev(.stop, "s1", 400)], now: 400)
        #expect(r.rows().first?.alert.colour == AlertColour.none)
        #expect(r.rows().first?.state == .idle)
        r.tick(now: 400 + 700_000)
        #expect(r.rows().first?.alert.colour == AlertColour.none)
        #expect(r.rows().first?.state == .idle)
        var plain = registry()
        plain.applyAgents([bg(status: .busy)], sampledAt: 100)
        plain.applyAgents([bg(status: .idle)], sampledAt: 200)
        #expect(plain.rows().first?.alert.colour == .yellow)
        #expect(plain.rows().first?.prSession == false)
    }

    @Test("a PR session keeps its red error box")
    func errorBox() {
        var r = registry()
        r.markPrSession("s1")
        r.applyAgents([bg(status: .busy)], sampledAt: 100)
        r.applyEvents([ev(.stopFailure, "s1", 150)], now: 150)
        #expect(r.rows().first?.alert.colour == .red)
        #expect(r.rows().first?.alert.reason == .error)
    }

    @Test("the store keeps PR sessions and forget removes one")
    func storeKeeps() {
        var r = registry()
        r.markPrSession("s1")
        r.markPrSession("s2")
        #expect(r.store().prSessions == ["s1", "s2"])
        var again = registry(r.store())
        again.applyAgents([bg()], sampledAt: 100)
        #expect(again.rows().first?.prSession == true)
        r.forget("s1")
        #expect(r.store().prSessions == ["s2"])
    }

    @Test
    func resumeAllSkips() {
        var r = registry(RegistryStore(lastActive: ["s1"], prSessions: ["s1"]))
        r.applyAgents([], sampledAt: 100)
        r.applyAllAgents([bg(pid: nil, status: .unknown), another], complete: true)
        let row = r.row("s1")
        #expect(row?.state == .parked)
        #expect(row?.resumable == false)
    }
}

@Suite("PR session names")
struct PrNameTests {
    @Test("a row with an expected PR name follows the PR rule when it shows")
    func expected() {
        var r = registry()
        r.expectPrSession("alpha")
        r.applyAgents([bg(status: .busy)], sampledAt: 100)
        r.applyAgents([bg(status: .idle)], sampledAt: 200)
        #expect(
            r.rows().first?.alert.colour == AlertColour.none
                && r.rows().first?.prSession == true)
        #expect(r.store().prNames == ["alpha"])
        var again = registry(r.store())
        again.applyAgents([bg()], sampledAt: 300)
        #expect(again.rows().first?.prSession == true)
    }

    @Test("forget keeps the name mark and releasing a PR session removes it")
    func release() {
        var r = registry()
        r.expectPrSession("alpha")
        r.applyAgents([bg()], sampledAt: 100)
        r.forget("s1")
        r.applyAgents([bg()], sampledAt: 200)
        #expect(r.rows().first?.prSession == true)
        r.releasePrSession("alpha")
        r.forget("s1")
        r.applyAgents([bg()], sampledAt: 300)
        #expect(r.rows().first?.prSession == false)
        #expect(r.store().prNames.isEmpty)
    }
}
