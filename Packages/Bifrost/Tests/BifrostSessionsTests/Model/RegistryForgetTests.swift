import BifrostTestSupport
import Testing

@testable import BifrostSessions

// Forgetting a session.

@Suite("a session that is gone")
struct GoneTests {
    private let wt = "/r/.claude/worktrees/gone"
    // Another parked session, so that the --all list is not empty.
    private let other = bg(
        id: "bbbbbbbb", name: "beta", pid: nil, sessionId: "o1", status: .unknown)
    // A started session that claude rm in a terminal removed. The store has all its values.
    private func withGone() -> SessionRegistry {
        var r = registry(
            RegistryStore(
                lastActive: ["s9"], names: ["s9": "nine"], started: ["s9"], priorities: ["s9": .p2],
                watch: [WatchEntry("s9", .amber)], worktrees: ["s9": wt]))
        r.applyAgents([], sampledAt: 100)
        return r
    }

    @Test("a started session missing from two full lists in a row is forgotten")
    func forgotten() {
        var r = withGone()
        #expect(r.ids == ["s9"])
        r.applyAllAgents([other], complete: true)
        #expect(r.ids == ["s9", "o1"])
        #expect(r.store().started == ["s9"])
        r.applyAllAgents([other], complete: true)
        #expect(r.ids == ["o1"])
        #expect(r.store() == RegistryStore(jobs: ["o1": "bbbbbbbb"], names: ["o1": "beta"]))
        // The next active list does not park it again.
        r.applyAgents([], sampledAt: 200)
        #expect(r.ids == ["o1"])
    }

    @Test("a session that comes back resets its count")
    func comesBack() {
        var r = withGone()
        let back = bg(id: "a9a9a9a9", pid: nil, sessionId: "s9", status: .unknown)
        r.applyAllAgents([other], complete: true)
        r.applyAllAgents([other, back], complete: true)
        r.applyAllAgents([other], complete: true)
        #expect(r.ids.contains("s9"))
        #expect(r.store().started == ["s9"])
        r.applyAllAgents([other], complete: true)
        #expect(!r.ids.contains("s9"))
    }

    @Test("a session in the active list is never gone")
    func inActive() {
        // A --all list that started before the session can miss it. The active list has it.
        var r = withGone()
        for at in [200, 300, 400] {
            r.applyAgents([bg(sessionId: "s9")], sampledAt: at)
            r.applyAllAgents([other], complete: true)
        }
        #expect(r.ids.contains("s9"))
        #expect(r.store().started == ["s9"])
    }

    @Test("an entry of any kind in the full list keeps the session")
    func anyKind() {
        // A failed Take control leaves a started session with an interactive entry.
        var r = withGone()
        let ended = bg(id: nil, background: false, pid: nil, sessionId: "s9", status: .unknown)
        for _ in 0..<3 { r.applyAllAgents([other, ended], complete: true) }
        #expect(r.ids.contains("s9"))
        #expect(r.store().watch == [WatchEntry("s9", .amber)])
    }

    @Test
    func emptyAndPartial() {
        var r = withGone()
        r.applyAllAgents([other], complete: true)
        r.applyAllAgents([], complete: true)
        r.applyAllAgents([other], complete: false)
        r.applyAllAgents([], complete: false)
        #expect(r.ids.contains("s9"))
        #expect(r.store().started == ["s9"])
        #expect(r.store().worktrees == ["s9": wt])
        // These lists do not stop the count either. The next good list is the second one in a row.
        r.applyAllAgents([other], complete: true)
        #expect(!r.ids.contains("s9"))
    }

    @Test("one full list without the session does not forget it")
    func oneList() {
        var r = withGone()
        r.applyAllAgents([other], complete: true)
        r.applyAgents([], sampledAt: 200)
        r.tick(now: 300)
        let row = r.row("s9")
        #expect(
            row?.name == "nine" && row?.priority == .p2 && row?.state == .parked
                && row?.watch == RowWatch(colour: .amber, order: 0) && row?.worktree == wt)
    }

    @Test("a full list that misses a running background session does not count")
    func missesRunning() {
        // A list that misses a session that runs is not complete, or Claude Code filtered it.
        var r = withGone()
        let running = bg(id: "e1e1e1e1", name: "run", sessionId: "r1")
        r.applyAgents([running], sampledAt: 200)
        for _ in 0..<3 { r.applyAllAgents([other], complete: true) }
        #expect(r.ids.contains("s9"))
        #expect(r.store().started == ["s9"])
        // An entry of any kind for the running session makes the list complete.
        r.applyAllAgents([other, running], complete: true)
        #expect(r.ids.contains("s9"))
        r.applyAllAgents([other, running.with { $0.isBackground = false }], complete: true)
        #expect(!r.ids.contains("s9"))
    }

    @Test("a list that does not count does not reset any count")
    func noReset() {
        var r = withGone()
        let listed = bg(id: "a9a9a9a9", pid: nil, sessionId: "s9", status: .unknown)
        r.applyAllAgents([other], complete: true)
        // A partial list, and a list that misses a running session, have s9. They do not reset it.
        r.applyAllAgents([other, listed], complete: false)
        r.applyAgents([bg(id: "e1e1e1e1", sessionId: "r1")], sampledAt: 200)
        r.applyAllAgents([other, listed], complete: true)
        r.applyAgents([], sampledAt: 300)
        #expect(r.ids.contains("s9"))
        r.applyAllAgents([other], complete: true)
        #expect(!r.ids.contains("s9"))
    }

    @Test("an active list that holds the session resets its count")
    func activeResets() {
        var r = withGone()
        r.applyAllAgents([other], complete: true)
        // s9 runs for a short time between two --all lists.
        r.applyAgents([bg(sessionId: "s9")], sampledAt: 200)
        r.applyAgents([], sampledAt: 300)
        r.applyAllAgents([other], complete: true)
        #expect(r.ids.contains("s9"))
        r.applyAllAgents([other], complete: true)
        #expect(!r.ids.contains("s9"))
    }

    @Test("a Delete forget also clears the count")
    func deleteClears() {
        var r = withGone()
        r.applyAllAgents([other], complete: true)
        r.forget("s9")
        // The same ID again starts with no count.
        r.markStarted("s9")
        r.applyAgents([], sampledAt: 200)
        r.applyAllAgents([other], complete: true)
        #expect(r.ids.contains("s9"))
    }
}

@Suite("one rule for all forgets")
struct OneRuleTests {
    private let wt = "/r/.claude/worktrees/kept"
    // An owned session that Bifrost did not start. It is parked, and it has all stored values.
    private func withParked() -> SessionRegistry {
        var r = registry()
        r.applyAllAgents([bg(pid: nil, status: .unknown)], complete: true)
        _ = r.setPriority("s1", .p3)
        _ = r.watchAdd("s1", .green)
        _ = r.rememberWorktree("s1", wt)
        return r
    }

    private func kept(_ r: SessionRegistry) {
        let row = r.row("s1")
        #expect(
            row?.name == "alpha" && row?.priority == .p3 && row?.state == .parked
                && row?.watch == RowWatch(colour: .green, order: 0) && row?.worktree == wt)
        let store = r.store()
        #expect(store.names["s1"] == "alpha")
        #expect(store.priorities["s1"] == .p3)
        #expect(store.watch == [WatchEntry("s1", .green)])
        #expect(store.worktrees == ["s1": wt])
    }

    @Test("an empty full list removes nothing")
    func empty() {
        var r = withParked()
        for _ in 0..<3 { r.applyAllAgents([], complete: true) }
        kept(r)
    }

    @Test("a partial full list removes nothing")
    func partial() {
        var r = withParked()
        for _ in 0..<3 { r.applyAllAgents([another], complete: false) }
        kept(r)
        for _ in 0..<3 { r.applyAllAgents([], complete: false) }
        kept(r)
    }

    @Test("a full list that misses a running session removes nothing")
    func missesRunning() {
        var r = withParked()
        r.applyAgents([bg(id: "e1e1e1e1", sessionId: "r1")], sampledAt: 100)
        for _ in 0..<3 { r.applyAllAgents([another], complete: true) }
        kept(r)
    }

    @Test("one counted full list without the session removes nothing")
    func oneCounted() {
        var r = withParked()
        r.applyAllAgents([another], complete: true)
        kept(r)
        r.applyAllAgents([another], complete: true)
        #expect(r.ids == ["o2"])
        let store = r.store()
        #expect(store.priorities == [:])
        #expect(store.watch == [])
        #expect(store.worktrees == [:])
        #expect(store.names == ["o2": "gamma"])
    }

    @Test("a list that does not count does not remove a stopped session")
    func stoppedStays() {
        // The session ran and was in the last counted list. Then a list that does not count came.
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        r.applyAllAgents([bg()], complete: true)
        r.applyAllAgents([], complete: true)
        r.applyAllAgents([another], complete: false)
        r.applyAgents([], sampledAt: 200)
        #expect(r.row("s1")?.state == .parked)
    }
}

@Suite("a list with no background entry")
struct NoBackgroundTests {
    // An interactive session in a terminal, for example in Warp. Its entry is in both lists.
    private let warp = bg(id: nil, background: false, name: "warp", pid: 77, sessionId: "w1")

    @Test("a list without a background entry does not count while a parked owned row exists")
    func parkedOwned() {
        // For example after a restart of the computer: the background service starts slowly, and
        // the lists have only the interactive sessions.
        var r = registry()
        r.applyAllAgents([bg(pid: nil, status: .unknown)], complete: true)
        _ = r.setPriority("s1", .p3)
        _ = r.watchAdd("s1", .green)
        r.applyAgents([warp], sampledAt: 100)
        for _ in 0..<3 { r.applyAllAgents([warp], complete: true) }
        let row = r.row("s1")
        #expect(
            row?.name == "alpha" && row?.priority == .p3 && row?.state == .parked
                && row?.watch == RowWatch(colour: .green, order: 0))
        // A list with a background entry counts again.
        r.applyAllAgents([warp, another], complete: true)
        r.applyAllAgents([warp, another], complete: true)
        #expect(r.ids == ["o2", "w1"])
    }

    @Test
    func lastRunWaits() {
        // Bifrost did not start s5, and no list showed it yet. lastActive of the store has it.
        var r = registry(
            RegistryStore(
                lastActive: ["s5"], names: ["s5": "five"], priorities: ["s5": .p1],
                watch: [WatchEntry("s5", .amber)]))
        r.applyAgents([warp], sampledAt: 100)
        for _ in 0..<3 { r.applyAllAgents([warp], complete: true) }
        let store = r.store()
        #expect(
            store.lastActive == ["s5"] && store.names == ["s5": "five", "w1": "warp"]
                && store.priorities == ["s5": .p1]
                && store.watch == [WatchEntry("s5", .amber)])
    }

    @Test("a list without a background entry counts when no owned session waits")
    func counts() {
        // Only the stored values of an interactive session that ended. Nothing owned is parked.
        var r = registry(RegistryStore(names: ["e1": "old"], priorities: ["e1": .p2]))
        r.applyAgents([warp], sampledAt: 100)
        r.applyAllAgents([warp], complete: true)
        #expect(r.store().priorities == ["e1": .p2])
        r.applyAllAgents([warp], complete: true)
        #expect(r.store().priorities == [:])
        #expect(r.store().names == ["w1": "warp"])
    }
}

@Suite("the active list keeps a session from a forget")
struct ActiveKeepsTests {
    @Test("two counted full lists do not forget a session of the active list")
    func activeKeeps() {
        // An interactive session in the active list. The --all set has only background IDs, and
        // the session is not started. So only the active list keeps it.
        let term = bg(id: nil, background: false, name: "term", pid: 77, sessionId: "e1")
        var r = registry()
        r.applyAgents([term], sampledAt: 100)
        #expect(r.setPriority("e1", .p2) == true)
        _ = r.watchAdd("e1", .lightBlue)
        r.applyAllAgents([term, another], complete: true)
        r.applyAllAgents([term, another], complete: true)
        r.applyAllAgents([term, another], complete: true)
        let row = r.row("e1")
        #expect(
            row?.kind == .external && row?.priority == .p2
                && row?.watch == RowWatch(colour: .lightBlue, order: 0))
    }
}

@Suite("deferred deletes")
struct DeferredTests {
    private let wt = "/r/.claude/worktrees/w1"
    // Session a started with a worktree from /r. Session b came from a hand-over and runs in the
    // same worktree.
    private var aRuns: AgentEntry {
        bg(cwd: "\(wt)/src", id: "aaaaaaaa", name: "alpha", pid: 5, sessionId: "s1")
    }
    private var bRuns: AgentEntry {
        bg(cwd: wt, id: "bbbbbbbb", name: "beta", pid: 6, sessionId: "s2")
    }
    // The --all entry of a after a stop. Its cwd is its start folder.
    private var aStopped: AgentEntry {
        aRuns.with { $0.cwd = "/r"; $0.pid = nil; $0.status = .unknown }
    }
    // The --all entry of b after a stop. b started in the worktree.
    private var bStopped: AgentEntry { bRuns.with { $0.pid = nil; $0.status = .unknown } }
    private var A: DeferredDelete {
        DeferredDelete(sessionId: "s1", shortId: "aaaaaaaa", worktree: wt)
    }
    // The stored entry also keeps the job value of the row.
    private var AJ: DeferredDelete {
        DeferredDelete(sessionId: "s1", shortId: "aaaaaaaa", worktree: wt, job: "aaaaaaaa")
    }

    // a is parked and b runs. Then the Delete of a defers it.
    private func withDeferred() -> SessionRegistry {
        var r = registry()
        r.applyAgents([aRuns, bRuns], sampledAt: 100)
        r.applyAllAgents([aRuns, bRuns], complete: true)
        r.applyAgents([bRuns], sampledAt: 200)
        r.applyAllAgents([aStopped, bRuns], complete: true)
        let rows = r.rows()
        #expect(
            rows.count == 2 && rows.first?.sessionId == "s1" && rows.first?.state == .parked
                && rows.first?.worktree == wt
                && rows.last?.sessionId == "s2" && rows.last?.state == .idle)
        r.defer(A)
        return r
    }

    @Test("a deferred delete forgets the row and keeps the entry in the store")
    func forgetsRow() {
        var r = withDeferred()
        #expect(r.ids == ["s2"])
        let store = r.store()
        #expect(store.deferred == [AJ])
        #expect(store.names == ["s2": "beta"])
        #expect(store.jobs == ["s2": "bbbbbbbb"])
        #expect(store.worktrees == ["s2": wt])
        // deferredIn gives the entries of one worktree in the order of the defers.
        let C = DeferredDelete(sessionId: "s3", shortId: "cccccccc", worktree: wt)
        let D = DeferredDelete(
            sessionId: "s4", shortId: "dddddddd", worktree: "/r/.claude/worktrees/w2")
        r.defer(C)
        r.defer(D)
        #expect(r.deferredIn(wt) == [AJ, C])
        #expect(r.deferredIn("/r/.claude/worktrees/w2") == [D])
        // The caller cannot change the registry through the result.
        var copy = r.deferredIn(wt)
        copy[0].shortId = "eeeeeeee"
        #expect(r.deferredIn(wt).first?.shortId == "aaaaaaaa")
        let before = r.store()
        // A second defer of the same entry changes nothing.
        r.defer(A)
        #expect(r.store() == before)
    }

    @Test
    func undeferAndDrop() {
        var r = withDeferred()
        let before = r.store()
        r.undefer("nope")
        r.dropDeferred("nope")
        #expect(r.store() == before)
        r.undefer("s1")
        #expect(r.deferredIn(wt) == [])
        #expect(r.store().deferred.isEmpty)
        r.defer(A)
        #expect(r.store().deferred == [AJ])
        r.dropDeferred("s1")
        #expect(r.deferredIn(wt) == [])
        #expect(r.store().deferred.isEmpty)
    }

    @Test("after a store reload a deferred delete is still there and hidden")
    func survivesReload() {
        let r = withDeferred()
        var again = registry(r.store())
        #expect(again.deferredIn(wt) == [AJ])
        again.applyAgents([bRuns], sampledAt: 300)
        // The --all list still has the deferred session.
        for _ in 0..<3 {
            again.applyAllAgents([aStopped, bRuns], complete: true)
            #expect(again.ids == ["s2"])
        }
        again.applyAgents([bRuns], sampledAt: 400)
        #expect(again.ids == ["s2"])
        #expect(again.store().deferred == [AJ])
        // An old store without the field loads with no deferred delete.
        let old = registry()
        #expect(old.deferredIn(wt) == [])
        #expect(old.store().deferred.isEmpty)
    }

    @Test("a deferred row that is in the active list is shown again")
    func showsAgain() {
        var r = withDeferred()
        // Someone resumed a outside Bifrost.
        r.applyAgents([aRuns, bRuns], sampledAt: 300)
        #expect(r.ids == ["s1", "s2"])
        #expect(
            r.rows().first?.name == "alpha" && r.rows().first?.shortId == "aaaaaaaa"
                && r.rows().first?.state == .idle)
        #expect(r.deferredIn(wt) == [])
        #expect(r.store().deferred.isEmpty)
    }

    @Test("an active entry without a PID or from before the defer keeps the row hidden")
    func staysHidden() {
        var r = withDeferred()
        // After a stop, the active list can show the entry without a pid for a short time.
        r.applyAgents([aStopped, bRuns], sampledAt: 300)
        #expect(r.ids == ["s2"])
        #expect(r.deferredIn(wt) == [AJ])
        // A sample that started before the defer still saw the process.
        r.undefer("s1")
        r.defer(A, at: 500)
        r.applyAgents([aRuns, bRuns], sampledAt: 400)
        #expect(r.ids == ["s2"])
        #expect(r.deferredIn(wt) == [AJ])
        r.applyAgents([aRuns, bRuns], sampledAt: 600)
        #expect(r.ids == ["s1", "s2"])
        #expect(r.deferredIn(wt) == [])
    }

    @Test("the gone rule ends a deferred delete")
    func goneRule() {
        var r = withDeferred()
        r.applyAllAgents([bRuns], complete: true)
        #expect(r.deferredIn(wt) == [AJ])
        // A list that has the session again sets the count back to 0.
        r.applyAllAgents([aStopped, bRuns], complete: true)
        r.applyAllAgents([bRuns], complete: true)
        #expect(r.deferredIn(wt) == [AJ])
        r.applyAllAgents([bRuns], complete: true)
        #expect(r.deferredIn(wt) == [])
        #expect(r.store().deferred.isEmpty)
        #expect(r.ids == ["s2"])
    }

    @Test("the orphan rule brings a deferred session back")
    func orphanRule() {
        var r = withDeferred()
        // claude rm in a terminal removed b. Its parked row stays until the gone rule forgets it.
        r.applyAgents([], sampledAt: 300)
        r.applyAllAgents([aStopped], complete: true)
        #expect(
            r.rows().count == 1 && r.rows().first?.sessionId == "s2"
                && r.rows().first?.state == .parked)
        #expect(r.deferredIn(wt) == [AJ])
        r.applyAllAgents([aStopped], complete: true)
        #expect(r.ids == [])
        #expect(r.deferredIn(wt) == [])
        // The next list adds the row again as a parked row.
        r.applyAllAgents([aStopped], complete: true)
        #expect(
            r.rows().count == 1 && r.rows().first?.name == "alpha"
                && r.rows().first?.sessionId == "s1" && r.rows().first?.state == .parked)
    }

    @Test
    func ownEntryNotInUse() {
        var r = registry()
        r.applyAgents([aRuns, bRuns], sampledAt: 100)
        r.applyAllAgents([aRuns, bRuns], complete: true)
        r.applyAgents([aRuns], sampledAt: 200)
        r.defer(DeferredDelete(sessionId: "s2", shortId: "bbbbbbbb", worktree: wt))
        // claude rm in a terminal removed a and the worktree. b still reports the worktree.
        r.applyAgents([], sampledAt: 300)
        r.applyAllAgents([bStopped], complete: true)
        #expect(r.deferredIn(wt).count == 1)
        r.applyAllAgents([bStopped], complete: true)
        #expect(r.ids == [])
        #expect(r.deferredIn(wt) == [])
        r.applyAllAgents([bStopped], complete: true)
        #expect(
            r.rows().count == 1 && r.rows().first?.sessionId == "s2"
                && r.rows().first?.state == .parked)
    }

    @Test
    func pidInUse() {
        let r = withDeferred()
        var again = registry(r.store())
        // The first active list after a start can miss a session that runs.
        again.applyAgents([], sampledAt: 300)
        again.applyAllAgents([aStopped, bRuns], complete: true)
        #expect(again.ids == [])
        again.applyAllAgents([aStopped, bRuns], complete: true)
        #expect(again.deferredIn(wt) == [AJ])
        // A background entry without a pid also keeps the folder in use.
        again.applyAllAgents([aStopped, bStopped], complete: true)
        again.applyAllAgents([aStopped, bStopped], complete: true)
        #expect(again.deferredIn(wt) == [AJ])
        again.applyAgents([bRuns], sampledAt: 400)
        #expect(again.ids == ["s2"])
    }

    @Test("a list that does not count leaves deferred deletes alone")
    func notCounted() {
        var r = withDeferred()
        // A partial list and an empty list do not count, so the count stays at 0.
        for _ in 0..<3 {
            r.applyAllAgents([bRuns], complete: false)
            r.applyAllAgents([], complete: true)
        }
        #expect(r.deferredIn(wt) == [AJ])
        r.applyAllAgents([bRuns], complete: true)
        #expect(r.deferredIn(wt) == [AJ])
        // No row uses the folder now. A list that does not count does not show the session again.
        r.forget("s2")
        r.applyAgents([], sampledAt: 300)
        for _ in 0..<3 {
            r.applyAllAgents([aStopped], complete: false)
            r.applyAllAgents([], complete: true)
        }
        #expect(r.deferredIn(wt) == [AJ])
        #expect(r.ids == [])
    }

    @Test
    func keepsWorktreeAndJob() {
        var r = withDeferred()
        r.undefer("s1")
        #expect(r.store().jobs == ["s1": "aaaaaaaa", "s2": "bbbbbbbb"])
        #expect(r.store().worktrees["s1"] == wt)
        r.applyAllAgents([aStopped, bRuns], complete: true)
        let rows = r.rows()
        #expect(
            rows.first?.cwd == "/r" && rows.first?.sessionId == "s1" && rows.first?.state == .parked
                && rows.first?.worktree == wt)
        // So a second Delete of a also keeps the folder: the row s2 still uses the worktree.
        let users = rows.filter { WorktreeRoot(cwd: $0.cwd, stored: $0.worktree)?.worktree == wt }
        #expect(users.map(\.sessionId).sorted() == ["s1", "s2"])
    }

    @Test("the orphan rule and the active list return the worktree and the job")
    func giveBack() {
        var r = withDeferred()
        r.applyAgents([], sampledAt: 300)
        r.applyAllAgents([aStopped], complete: true)
        r.applyAllAgents([aStopped], complete: true)
        #expect(r.deferredIn(wt) == [])
        #expect(r.store().jobs == ["s1": "aaaaaaaa"])
        #expect(r.store().worktrees == ["s1": wt])
        r.applyAllAgents([aStopped], complete: true)
        #expect(
            r.rows().count == 1 && r.rows().first?.sessionId == "s1"
                && r.rows().first?.state == .parked && r.rows().first?.worktree == wt)
        // The session runs again from its start folder.
        var q = withDeferred()
        q.applyAgents([aRuns.with { $0.cwd = "/r" }, bRuns], sampledAt: 300)
        #expect(q.rows().first?.sessionId == "s1")
        #expect(q.rows().first?.worktree == wt)
        // dropDeferred and the gone rule give nothing back.
        var d = withDeferred()
        d.dropDeferred("s1")
        #expect(d.store().jobs == ["s2": "bbbbbbbb"])
        #expect(d.store().worktrees == ["s2": wt])
        var g = withDeferred()
        g.applyAllAgents([bRuns], complete: true)
        g.applyAllAgents([bRuns], complete: true)
        #expect(g.deferredIn(wt) == [])
        #expect(g.store().jobs == ["s2": "bbbbbbbb"])
        #expect(g.store().worktrees == ["s2": wt])
    }

    @Test
    func clearedRowHidden() {
        // Bifrost first saw the job after a /clear. So its row ID is not the --all session ID.
        let cleared = aRuns.with { $0.cwd = wt; $0.sessionId = "r1" }
        let original = aStopped.with { $0.sessionId = "aaaaaaaa-0001" }
        var r = registry()
        r.applyAgents([cleared, bRuns], sampledAt: 100)
        r.applyAllAgents([cleared, bRuns], complete: true)
        r.applyAgents([bRuns], sampledAt: 200)
        r.applyAllAgents([original, bRuns], complete: true)
        let before = r.rows()
        #expect(
            before.count == 2 && before.first?.sessionId == "r1" && before.first?.state == .parked
                && before.first?.worktree == wt && before.last?.sessionId == "s2")
        r.defer(DeferredDelete(sessionId: "r1", shortId: "aaaaaaaa", worktree: wt))
        var again = registry(r.store())
        again.applyAgents([bRuns], sampledAt: 300)
        for _ in 0..<3 {
            again.applyAllAgents([original, bRuns], complete: true)
            #expect(again.ids == ["s2"])
        }
        again.undefer("r1")
        again.applyAllAgents([original, bRuns], complete: true)
        let after = again.rows()
        #expect(
            after.count == 2 && after.first?.sessionId == "r1" && after.first?.state == .parked
                && after.first?.worktree == wt && after.last?.sessionId == "s2")
    }

    @Test
    func anyKindInUse() {
        // A claude in a terminal runs in the worktree. Bifrost has no row for it yet.
        let terminal = bg(
            cwd: "\(wt)/src", id: nil, background: false, name: "", pid: 77, sessionId: "t1")
        var r = withDeferred()
        r.forget("s2")
        r.applyAgents([], sampledAt: 300)
        r.applyAllAgents([aStopped, terminal], complete: true)
        #expect(r.deferredIn(wt) == [AJ])
        // A terminal session that ended does not use the folder.
        r.applyAllAgents([aStopped, terminal.with { $0.pid = nil }], complete: true)
        #expect(r.deferredIn(wt) == [])
    }

    @Test
    func ownEntryWithPid() {
        var r = registry()
        r.applyAgents([aRuns, bRuns], sampledAt: 100)
        r.applyAllAgents([aRuns, bRuns], complete: true)
        r.applyAgents([aRuns], sampledAt: 200)
        r.defer(DeferredDelete(sessionId: "s2", shortId: "bbbbbbbb", worktree: wt))
        // claude rm in a terminal removed a. Then b runs again, and the active list does not have
        // it.
        r.applyAgents([], sampledAt: 300)
        r.applyAllAgents([bRuns], complete: true)
        r.applyAllAgents([bRuns], complete: true)
        #expect(r.ids == [])
        #expect(r.deferredIn(wt).count == 1)
        r.applyAgents([bRuns], sampledAt: 400)
        #expect(r.ids == ["s2"])
    }
}

@Suite("forget, lastActive and terminals")
struct ForgetLastActiveTests {
    private func ext(cwd: String = "/p") -> AgentEntry {
        bg(cwd: cwd, id: nil, background: false, name: "", pid: 931, sessionId: "e1")
    }
    private let warp = TerminalApp(name: "Warp", bundle: "/Applications/Warp.app")

    @Test("forget removes the row and every stored value of the session")
    func forgetAll() {
        var r = registry()
        r.markStarted("s1")
        r.applyAgents([bg()], sampledAt: 100)
        _ = r.setPriority("s1", .p2)
        r.forget("s1")
        #expect(r.ids == [])
        let store = r.store()
        #expect(store.started == [])
        #expect(store.lastActive == [])
        #expect(store.names == [:])
        #expect(store.priorities == [:])
    }

    @Test("forget drops the local name")
    func forgetAlias() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        _ = r.setAlias("s1", "Work")
        r.forget("s1")
        #expect(r.store().aliases == [:])
    }

    @Test
    func lastActiveOwned() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        #expect(r.store().lastActive == ["s1"])
    }

    @Test
    func lastActiveNotExternal() {
        var r = registry()
        r.applyAgents([ext(), bg(pid: nil, sessionId: "s2", status: .unknown)], sampledAt: 100)
        #expect(r.store().lastActive == [])
    }

    @Test
    func lastActiveGrace() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        r.applyAgents([], sampledAt: 1000)
        r.tick(now: 1000 + 60_000 - 1)
        #expect(r.store().lastActive == ["s1"])
        r.tick(now: 1000 + 60_000)
        #expect(r.store().lastActive == [])
    }

    @Test("marking a session stopped removes it from the last active list at once")
    func markStopped() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        r.markStopped("s1")
        #expect(r.store().lastActive == [])
    }

    @Test("the loaded last active list gives the resumable rows")
    func resumable() {
        var r = registry(RegistryStore(lastActive: ["s1"]))
        r.applyAgents([], sampledAt: 1000)
        r.applyAllAgents([bg(pid: nil, status: .unknown)], complete: true)
        #expect(r.rows().first?.resumable == true)
        #expect(r.rows().first?.state == .parked)
        r.tick(now: 1000 + 60_000)
        #expect(r.store().lastActive == [])
        #expect(r.rows().first?.resumable == true)
    }

    @Test("a resumable session that runs again stops being resumable")
    func notResumable() {
        var r = registry(RegistryStore(lastActive: ["s1"]))
        r.applyAgents([bg()], sampledAt: 1000)
        r.applyAgents([], sampledAt: 2000)
        r.applyAllAgents([bg(pid: nil, status: .unknown)], complete: true)
        #expect(r.rows().first?.state == .parked)
        #expect(r.rows().first?.resumable == false)
    }

    @Test("when its process ends, a started external session parks")
    func startedExternal() {
        var r = registry()
        r.markStarted("e1")
        r.applyAgents([ext(cwd: "/p")], sampledAt: 100)
        r.applyAgents([], sampledAt: 200)
        let row = r.rows().first
        #expect(row?.cwd == "/p")
        #expect(row?.kind == .external)
        #expect(row?.state == .parked)
    }

    @Test("an external session that Bifrost did not start is removed")
    func externalGoes() {
        var r = registry()
        r.applyAgents([ext()], sampledAt: 100)
        r.applyAgents([], sampledAt: 200)
        r.applyAllAgents([], complete: true)
        #expect(r.rows() == [])
    }

    @Test("an external row shows the name of its terminal app")
    func terminalName() {
        var r = registry()
        r.applyAgents([ext()], sampledAt: 100)
        r.applyTerminals(TerminalApps(apps: [931: warp]))
        #expect(r.rows().first?.terminalApp == "Warp")
        #expect(r.terminalOf("e1") == warp)
    }

    @Test("external PIDs without a cache entry are listed")
    func pidsWithout() {
        var r = registry()
        r.applyAgents([ext(), bg()], sampledAt: 100)
        #expect(r.pidsWithoutTerminal() == [931])
        r.applyTerminals(TerminalApps(noApp: [931]))
        #expect(r.pidsWithoutTerminal() == [])
        #expect(r.row("e1")?.terminalApp == nil)
    }
}
