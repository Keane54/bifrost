import BifrostTestSupport
import Darwin
import Testing

@testable import BifrostSessions

// The edges of the registry rules that the other tests do not reach: rows that share one
// current ID, the order of the rows, empty short IDs, commands on the same or a bad value, the
// forget of a waiting event, and the stored values that hold a row.

private let u1 = "2f493bf0-1598-4b3b-b419-8acb9cb11bcb"
private let worktree = "/r/.claude/worktrees/w1"

@Suite("rows that share one current ID")
struct SharedCurrentEdgeTests {
    @Test(
        "after loading, the row with the lowest row ID gets the live lines",
        arguments: [
            (["rb", "ra"], "ra"), (["rc", "ra", "rb"], "ra"), (["rb"], "rb"),
            (["r2", "r10"], "r10"),
        ])
    func loadOwner(rows: [String], owner: String) {
        let current = Dictionary(uniqueKeysWithValues: rows.map { ($0, u1) })
        let r = registry(
            RegistryStore(
                current: current, names: Dictionary(uniqueKeysWithValues: rows.map { ($0, $0) })))
        #expect(r.rowIdOf(u1) == owner)
    }

    @Test("only the owner row of a current ID is live")
    func liveOwner() {
        var r = registry(
            RegistryStore(
                current: ["rb": u1, "ra": u1], jobs: ["ra": "11111111", "rb": "22222222"]))
        r.applyAgents(
            [
                bg(id: "11111111", pid: 5, sessionId: u1),
                bg(id: "22222222", pid: 6, sessionId: u1),
            ], sampledAt: 100)
        r.applyUsage(u1, LiveUsage(model: "claude-opus-5-5"), at: 150)
        r.applyEvents([ev(.userPromptSubmit, u1, 160)], now: 160)
        #expect(r.rows().map(\.sessionId).sorted() == ["ra", "rb"])
        #expect(r.row("ra")?.live == true)
        #expect(r.row("rb")?.live == false)
        #expect(r.row("ra")?.state == .working)
        #expect(r.row("rb")?.state != .working)
    }

    @Test
    func currentBackToRowId() {
        var r = registry()
        r.applyAgents([bg(id: nil, background: false, pid: 5, sessionId: "s1")], sampledAt: 100)
        // A /clear: the same process shows a new session ID.
        r.applyAgents([bg(id: nil, background: false, pid: 5, sessionId: u1)], sampledAt: 200)
        r.applyAgents([bg(id: nil, background: false, pid: 5, sessionId: u1)], sampledAt: 300)
        #expect(r.rows().count == 1)
        #expect(r.store().current == ["s1": u1])
        // The old conversation shows again with the same process.
        r.applyAgents([bg(id: nil, background: false, pid: 5, sessionId: "s1")], sampledAt: 400)
        #expect(r.rows().count == 1)
        #expect(r.store().current == [:])
    }
}

@Suite("short IDs")
struct ShortIdEdgeTests {
    @Test("an entry with an empty ID stores no job and its row has no short ID")
    func emptyId() {
        var r = registry()
        let list = AgentList(output: #"[{"sessionId":"s1","kind":"background","id":"","pid":5}]"#)
        r.applyAgents(list.entries, sampledAt: 100)
        #expect(r.rows().count == 1)
        #expect(r.store().jobs == [:])
        #expect(r.row("s1")?.shortId == nil)
    }

    @Test
    func parkedWithoutShortId() {
        var r = registry()
        r.applyAllAgents(
            [bg(id: nil, name: "x", pid: nil, sessionId: "s7", status: .unknown)], complete: true)
        let row = r.row("s7")
        #expect(row?.state == .parked)
        #expect(row?.shortId == nil)
        #expect(row?.resumeId == "s7")
    }

    @Test
    func parkedJobResume() {
        var r = registry()
        r.applyAgents([bg(id: "2f493bf0", sessionId: u1)], sampledAt: 100)
        r.applyAgents([], sampledAt: 200)
        r.applyAllAgents(
            [bg(id: "2f493bf0", pid: nil, sessionId: u1, status: .unknown)], complete: true)
        #expect(r.row(u1)?.resumeId == u1)
        #expect(r.row(u1)?.shortId == "2f493bf0")
    }
}

@Suite("commands on edge values")
struct CommandEdgeTests {
    @Test
    func carryToSelf() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        _ = r.setPriority("s1", .p2)
        _ = r.watchAdd("s1", .red)
        let before = r.store()
        let carried = r.carryOver(from: "s1", to: "s1")
        #expect(carried)
        #expect(r.store() == before)
    }

    @Test(
        "carrying over an unknown row gives false",
        arguments: [("s1", "nope"), ("nope", "s1"), ("nope", "nope")])
    func carryUnknown(from: String, to: String) {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        _ = r.setPriority("s1", .p2)
        let carried = r.carryOver(from: from, to: to)
        #expect(!carried)
        #expect(r.store().priorities == ["s1": .p2])
    }

    @Test(arguments: [
            worktree + "/src", "/r", "", "r/.claude/worktrees/w1", "/r/../.claude/worktrees/w1",
        ])
    func deferBadPath(path: String) {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        r.defer(DeferredDelete(sessionId: "s1", shortId: "aaaaaaaa", worktree: path), at: 150)
        #expect(r.store().deferred == [])
        #expect(r.row("s1") != nil)
    }

    @Test
    func deferGoodPath() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        r.defer(DeferredDelete(sessionId: "s1", shortId: "aaaaaaaa", worktree: worktree), at: 150)
        #expect(r.store().deferred.map(\.sessionId) == ["s1"])
        #expect(r.row("s1") == nil)
    }

    @Test
    func rememberWorktreeEdges() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        let results = [
            r.rememberWorktree("s1", worktree + "/src"), r.rememberWorktree("s1", "/r"),
            r.rememberWorktree("nope", worktree), r.rememberWorktree("s1", worktree),
            r.rememberWorktree("s1", worktree),
        ]
        #expect(results == [false, false, false, true, true])
        #expect(r.store().worktrees == ["s1": worktree])
    }

    @Test
    func forgetDropsPending() {
        var r = registry()
        r.applyEvents([ev(.stop, "s1", 10)], now: 10)
        r.forget("s1")
        r.applyAgents([bg()], sampledAt: 20)
        #expect(r.row("s1")?.alert.colour == AlertColour.none)
    }
}

@Suite("the terminal app of a row")
struct TerminalRowEdgeTests {
    private let warp = TerminalApp(name: "Warp", bundle: "/Applications/Warp.app")

    @Test("an external row with a PID gets the terminal app from the table")
    func external() {
        var r = registry()
        r.applyAgents([bg(id: nil, background: false, pid: 5)], sampledAt: 100)
        #expect(r.pidsWithoutTerminal() == [5])
        r.applyTerminals(TerminalApps(apps: [5: warp]))
        #expect(r.terminalOf("s1") == warp)
        #expect(r.pidsWithoutTerminal() == [])
        #expect(r.row("s1")?.terminalApp == "Warp")
    }

    @Test(
        "no app for a PID, an owned row, an external row without PID or an unknown row")
    func none() {
        var r = registry()
        r.applyAgents(
            [
                bg(id: nil, background: false, pid: 5, sessionId: "e1"),
                bg(id: "aaaaaaaa", pid: 6, sessionId: "o1"),
                bg(id: nil, background: false, pid: nil, sessionId: "e2"),
            ], sampledAt: 100)
        r.applyTerminals(TerminalApps(apps: [6: warp, 77: warp], noApp: [5]))
        #expect(r.terminalOf("e1") == nil)
        #expect(r.terminalOf("o1") == nil)
        #expect(r.terminalOf("e2") == nil)
        #expect(r.terminalOf("nope") == nil)
        // A PID with no external row is dropped.
        #expect(r.pidsWithoutTerminal() == [])
        // A PID that the table does not name gives nil too, and the registry asks for it.
        r.applyAgents([bg(id: nil, background: false, pid: 8, sessionId: "e3")], sampledAt: 200)
        #expect(r.terminalOf("e3") == nil)
        #expect(r.pidsWithoutTerminal() == [8])
    }
}

private func external(_ id: String, pid: pid_t? = 5, cwd: String = "/p") -> AgentEntry {
    bg(cwd: cwd, id: nil, background: false, name: "term", pid: pid, sessionId: id)
}

@Suite("one entry and the rows of a /clear")
struct ClearLinkEdgeTests {
    @Test
    func twoRowsOneEntry() {
        var r = registry()
        r.applyAgents([external("s1"), external("s2")], sampledAt: 100)
        r.applyAgents([external("s3")], sampledAt: 2100)
        #expect(r.ids == ["s3"])
        #expect(r.store().current == [:])
    }

    @Test
    func twoEntriesShareRow() {
        var r = registry()
        r.applyAgents([external("s1", pid: 5)], sampledAt: 100)
        r.applyAgents([external("s1", pid: 5), external("s1", pid: 6)], sampledAt: 2100)
        #expect(r.ids == ["s1"])
    }

    @Test
    func shortIdDoesNotShare() {
        var r = registry()
        r.applyAgents([external("s1", pid: 5)], sampledAt: 100)
        r.applyAgents(
            [external("s1", pid: 5), bg(id: "cccccccc", pid: 6, sessionId: "s1")], sampledAt: 2100)
        #expect(r.rows().count == 2)
        #expect(r.row("s1")?.kind == .external)
    }
}

@Suite("the reason of a refused local name")
struct AliasReasonEdgeTests {
    @Test("each refusal has a text for the user")
    func reasons() {
        #expect(AliasRefusal.control.reason == "A name can't hold control or hidden characters.")
        #expect(
            AliasRefusal.tooLong.reason == "The name is too long. The maximum is 64 characters.")
    }

    @Test
    func setAliasRefuses() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        let ok = r.setAlias("s1", "Work")
        let hidden = r.setAlias("s1", "a\u{200B}b")
        let long = r.setAlias("s1", String(repeating: "x", count: 65))
        #expect(ok)
        #expect(!hidden)
        #expect(!long)
        #expect(r.store().aliases == ["s1": "Work"])
    }
}

// The row IDs of a job before and after a /clear. The short ID is the start of the first ID.
private let jobRowId = "aaaaaaaa-1111-4111-8111-111111111111"
private let jobNextId = "aaaaaaaa-2222-4222-8222-222222222222"

@Suite("the stored values that hold a row")
struct StoredValueEdgeTests {
    // A background entry goes to the one stored row whose row ID starts with its short ID
    // That row needs a stored value other than the PR flag, no short ID and no
    // current ID. Else the entry gets a new row.
    @Test(
        "a job finds a stored row by the start of its row ID",
        arguments: [
            (RegistryStore(names: [jobRowId: "fix"]), jobRowId),
            (RegistryStore(lastActive: [jobRowId]), jobRowId),
            (RegistryStore(started: [jobRowId]), jobRowId),
            (RegistryStore(prSessions: [jobRowId]), jobNextId),
            (RegistryStore(jobs: [jobRowId: "bbbbbbbb"], names: [jobRowId: "fix"]), jobNextId),
            (RegistryStore(current: [jobRowId: u1], names: [jobRowId: "fix"]), jobNextId),
        ])
    func jobFindsStoredRow(store: RegistryStore, rowId: String) {
        var r = registry(store)
        r.applyAgents([bg(id: "aaaaaaaa", sessionId: jobNextId)], sampledAt: 100)
        #expect(r.ids == [rowId])
    }

    // A lastActive value goes after its grace time. The PR flag goes with the other values of
    // its row.
    @Test("the counted lists do not forget a session that has only lastActive or the PR flag")
    func notCounted() {
        var r = registry(RegistryStore(lastActive: ["s1"], prSessions: ["s3"]))
        let job = bg(id: "bbbbbbbb", pid: nil, sessionId: "s2", status: .unknown)
        r.applyAgents([], sampledAt: 1000)
        for _ in 0...SessionRegistry.goneLists {
            #expect(r.applyAllAgents([job], complete: true).isEmpty)
        }
        #expect(r.store().lastActive == ["s1"])
        #expect(r.store().prSessions == ["s3"])
        r.tick(now: 1000 + 60_000)
        #expect(r.store().lastActive == [])
        #expect(r.store().prSessions == ["s3"])
    }

    @Test("a stored current ID equal to its row ID is no current ID")
    func ownCurrent() {
        var r = registry(RegistryStore(current: ["s1": "s1"], names: ["s1": "alpha"]))
        #expect(r.store() == RegistryStore(names: ["s1": "alpha"]))
        r.applyAgents([bg()], sampledAt: 100)
        r.applyEvents([ev(.stop, "s1", 200)], now: 200)
        #expect(r.row("s1")?.state == .needsYou)
    }
}
