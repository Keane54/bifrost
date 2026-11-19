import BifrostTestSupport
import Darwin
import Testing

@testable import BifrostSessions

// The watchlist, worktrees and priorities.

@Suite("watchlist")
struct WatchlistTests {
    private func two() -> SessionRegistry {
        var r = registry()
        r.applyAgents(
            [bg(), bg(id: "bbbbbbbb", name: "beta", pid: 6, sessionId: "s2")], sampledAt: 100)
        return r
    }

    @Test("adding to the watchlist appends the session")
    func appends() {
        var r = two()
        #expect(r.watchAdd("s2", .darkBlue) == true)
        #expect(r.watchAdd("s1", .red) == true)
        #expect(r.store().watch == [WatchEntry("s2", .darkBlue), WatchEntry("s1", .red)])
    }

    @Test("adding a watched session changes only the colour")
    func onlyColour() {
        var r = two()
        _ = r.watchAdd("s1", .darkBlue)
        _ = r.watchAdd("s2", .green)
        #expect(r.watchAdd("s1", .lightBlue) == true)
        #expect(r.store().watch == [WatchEntry("s1", .lightBlue), WatchEntry("s2", .green)])
        let before = r.store()
        _ = r.watchAdd("s1", .lightBlue)
        #expect(r.store() == before)
    }

    @Test("adding an unknown session to the watchlist is refused")
    func addUnknown() {
        var r = two()
        let before = r.store()
        #expect(r.watchAdd("nope", .darkBlue) == false)
        #expect(r.store() == before)
    }

    @Test("removing from the watchlist removes the session")
    func removes() {
        var r = two()
        _ = r.watchAdd("s1", .darkBlue)
        #expect(r.watchRemove("s1") == true)
        #expect(r.store().watch == [])
        let before = r.store()
        #expect(r.watchRemove("s1") == true)
        #expect(r.watchRemove("nope") == false)
        #expect(r.store() == before)
    }

    @Test("the colour changes for a watched session only")
    func colour() {
        var r = two()
        _ = r.watchAdd("s1", .darkBlue)
        #expect(r.watchColour("s1", .green) == true)
        #expect(r.store().watch == [WatchEntry("s1", .green)])
        let before = r.store()
        #expect(r.watchColour("s2", .green) == true)
        #expect(r.watchColour("nope", .green) == false)
        #expect(r.store() == before)
    }

    @Test("a watchlist move puts the session before another one")
    func moveBefore() {
        var r = two()
        _ = r.watchAdd("s1", .darkBlue)
        _ = r.watchAdd("s2", .green)
        #expect(r.watchMove("s2", before: "s1") == true)
        #expect(r.store().watch.map(\.sessionId) == ["s2", "s1"])
    }

    @Test("a watchlist move to null puts the session at the end")
    func moveEnd() {
        var r = two()
        _ = r.watchAdd("s1", .darkBlue)
        _ = r.watchAdd("s2", .green)
        #expect(r.watchMove("s1", before: nil) == true)
        #expect(r.store().watch.map(\.sessionId) == ["s2", "s1"])
    }

    @Test("a watchlist move of an unknown ID does nothing")
    func moveUnknown() {
        var r = two()
        _ = r.watchAdd("s1", .darkBlue)
        _ = r.watchAdd("s2", .green)
        let before = r.store()
        #expect(r.watchMove("nope", before: "s1") == false)
        #expect(r.watchMove("s2", before: "nope") == false)
        #expect(r.watchMove("s1", before: "s1") == true)
        #expect(r.store() == before)
    }

    @Test("each row has its colour and its place")
    func rowsCarry() {
        var r = two()
        _ = r.watchAdd("s2", .darkBlue)
        _ = r.watchAdd("s1", .red)
        #expect(r.row("s2")?.watch == RowWatch(colour: .darkBlue, order: 0))
        #expect(r.row("s1")?.watch == RowWatch(colour: .red, order: 1))
        _ = r.watchRemove("s2")
        #expect(r.row("s2") != nil)
        #expect(r.row("s2")?.watch == nil)
        #expect(r.row("s1")?.watch == RowWatch(colour: .red, order: 0))
    }

    @Test("a store without a watchlist is valid")
    func noWatch() {
        let r = SessionRegistry(store: RegistryStore(), escalation: .seconds(600))
        #expect(r.store().watch == [])
    }

    @Test
    func removedWhenGone() {
        var r = registry()
        r.applyAgents([bg(id: nil, background: false)], sampledAt: 100)
        _ = r.watchAdd("s1", .darkBlue)
        r.applyAgents([], sampledAt: 200)
        r.applyAllAgents([another], complete: true)
        #expect(r.store().watch == [WatchEntry("s1", .darkBlue)])
        r.applyAllAgents([another], complete: true)
        #expect(r.store().watch == [])
    }

    @Test("forgetting a session takes it off the watchlist")
    func forgetRemoves() {
        var r = two()
        _ = r.watchAdd("s1", .darkBlue)
        r.forget("s1")
        #expect(r.store().watch == [])
    }
}

@Suite("worktrees")
struct WorktreeTests {
    private let wt = "/r/.claude/worktrees/fix-a"
    // A worktree session that runs. Its cwd is a subfolder of the worktree.
    private func inWorktree(
        id: ShortID? = "aaaaaaaa", background: Bool = true, pid: pid_t? = 5,
        sessionId: String = "s1",
        status: AgentStatus = .idle
    ) -> AgentEntry {
        bg(
            cwd: "\(wt)/src", id: id, background: background, pid: pid, sessionId: sessionId,
            status: status)
    }
    // The --all entry of the same session after a stop. Its cwd is the start folder.
    private func stopped() -> AgentEntry { bg(cwd: "/r", pid: nil, status: .unknown) }

    @Test("the registry remembers the worktree of a running session")
    func remembers() {
        var r = registry()
        r.applyAgents([inWorktree()], sampledAt: 100)
        #expect(r.rows().first?.worktree == wt)
        #expect(r.store().worktrees == ["s1": wt])
        // The same worktree again does not change the store.
        let before = r.store()
        r.applyAgents([inWorktree()], sampledAt: 200)
        #expect(r.store() == before)
    }

    @Test
    func outsideAndParked() {
        var r = registry()
        r.applyAgents([bg(cwd: "/r")], sampledAt: 100)
        #expect(r.rows().first?.worktree == nil)
        // An entry with a worktree cwd and no pid is parked.
        r.applyAllAgents([inWorktree(pid: nil, sessionId: "s2", status: .unknown)], complete: true)
        #expect(r.row("s2")?.state == .parked)
        #expect(r.store().worktrees == [:])
    }

    @Test
    func parkedInActive() {
        // A started session that is not active is parked. Its next active entry has no pid.
        var r = registry()
        r.markStarted("s1")
        r.applyAgents([], sampledAt: 100)
        r.applyAgents([inWorktree(pid: nil, status: .unknown)], sampledAt: 200)
        #expect(r.rows().first?.cwd == "\(wt)/src")
        #expect(r.rows().first?.state == .parked)
        #expect(r.rows().first?.worktree == nil)
        #expect(r.store().worktrees == [:])
    }

    @Test("a worktree root is stored for a known session only")
    func rememberWorktree() {
        var r = registry()
        r.markStarted("s1")
        r.applyAllAgents([stopped()], complete: true)
        let before = r.store()
        // A path that is not a worktree root, and an unknown session, change nothing.
        for path in ["\(wt)/src", "/r", "r/.claude/worktrees/a", "\(wt)/"] {
            #expect(r.rememberWorktree("s1", path) == false)
        }
        #expect(r.rememberWorktree("s9", wt) == false)
        #expect(r.store() == before)
        #expect(r.rememberWorktree("s1", wt) == true)
        #expect(r.rows().first?.cwd == "/r")
        #expect(r.rows().first?.worktree == wt)
        #expect(r.store().worktrees == ["s1": wt])
        let remembered = r.store()
        #expect(r.rememberWorktree("s1", wt) == true)
        #expect(r.store() == remembered)
    }

    @Test
    func staysAfterPark() {
        var r = registry()
        r.markStarted("s1")
        r.applyAgents([inWorktree()], sampledAt: 100)
        r.applyAgents([], sampledAt: 200)
        r.applyAllAgents([stopped()], complete: true)
        let row = r.rows().first
        #expect(row?.cwd == "/r")
        #expect(row?.state == .parked)
        #expect(row?.worktree == wt)
        #expect(r.store().worktrees == ["s1": wt])
    }

    @Test
    func branchUsesStored() {
        var r = registry()
        r.applyAgents([inWorktree(), bg(cwd: "/q", sessionId: "s2", startedAt: 2)], sampledAt: 100)
        #expect(r.cwds() == ["\(wt)/src", "/q"])
        r.applyAgents([bg(cwd: "/q", sessionId: "s2", startedAt: 2)], sampledAt: 200)
        r.applyAllAgents([stopped(), bg(cwd: "/q", sessionId: "s2", startedAt: 2)], complete: true)
        #expect(r.cwds() == [wt, "/q"])
        r.applyBranch(wt, "worktree-fix-a")
        r.applyBranch("/r", "main")
        #expect(r.rows().first?.branch == "worktree-fix-a")
        #expect(r.rows().first?.cwd == "/r")
    }

    @Test("the full list prunes the worktree of a session that left all lists")
    func prunes() {
        var r = registry()
        r.applyAgents([inWorktree(id: nil, background: false)], sampledAt: 100)
        #expect(r.store().worktrees.count == 1)
        r.applyAgents([], sampledAt: 200)
        r.applyAllAgents([another], complete: true)
        #expect(r.store().worktrees.count == 1)
        r.applyAllAgents([another], complete: true)
        #expect(r.store().worktrees == [:])
    }

    @Test("forget removes the stored worktree")
    func forgetRemoves() {
        var r = registry()
        r.applyAgents([inWorktree()], sampledAt: 100)
        r.forget("s1")
        #expect(r.store().worktrees == [:])
    }

    @Test("a loaded worktree goes on the row and a store without worktrees is valid")
    func loaded() {
        var r = registry(RegistryStore(started: ["s1"], worktrees: ["s1": wt]))
        r.applyAllAgents([stopped()], complete: true)
        #expect(r.rows().first?.cwd == "/r")
        #expect(r.rows().first?.worktree == wt)
        let old = SessionRegistry(store: RegistryStore(), escalation: .seconds(600))
        #expect(old.store().worktrees == [:])
    }
}

@Suite("priority")
struct PriorityTests {
    @Test("setting a priority puts it in the row and the store")
    func sets() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        #expect(r.setPriority("s1", .p2) == true)
        #expect(r.rows().first?.priority == .p2)
        #expect(r.store().priorities == ["s1": .p2])
    }

    @Test("a null priority removes it from the row and the store")
    func removes() {
        var r = registry(RegistryStore(priorities: ["s1": .p3]))
        r.applyAgents([bg()], sampledAt: 100)
        #expect(r.rows().first?.priority == .p3)
        #expect(r.setPriority("s1", nil) == true)
        #expect(r.rows().first != nil)
        #expect(r.rows().first?.priority == nil)
        #expect(r.store().priorities == [:])
    }

    @Test("the same priority does not change the store")
    func same() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        _ = r.setPriority("s1", .p2)
        let withPriority = r.store()
        #expect(r.setPriority("s1", .p2) == true)
        #expect(r.store() == withPriority)
        _ = r.setPriority("s1", nil)
        let withoutPriority = r.store()
        #expect(r.setPriority("s1", nil) == true)
        #expect(r.store() == withoutPriority)
    }

    @Test("a priority for an unknown session is refused")
    func unknown() {
        var r = registry()
        #expect(r.setPriority("nope", .p1) == false)
        #expect(r.store() == RegistryStore())
    }

    @Test("the priority stays when the session parks")
    func staysParked() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        _ = r.setPriority("s1", .p4)
        r.applyAllAgents([bg()], complete: true)
        r.applyAgents([], sampledAt: 200)
        #expect(r.rows().first?.priority == .p4)
        #expect(r.rows().first?.state == .parked)
    }

    @Test
    func removedWhenGone() {
        var r = registry()
        r.applyAgents([bg(id: nil, background: false)], sampledAt: 100)
        _ = r.setPriority("s1", .p1)
        r.applyAgents([], sampledAt: 200)
        r.applyAllAgents([another], complete: true)
        #expect(r.store().priorities == ["s1": .p1])
        r.applyAllAgents([another], complete: true)
        #expect(r.store().priorities == [:])
    }
}
