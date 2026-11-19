import BifrostTestSupport
import Testing

@testable import BifrostSessions

// Parking, leaving, and the stored file.

// Another parked session. A --all list with it is not empty, so the list counts for a forget.
let another = bg(id: "cccccccc", name: "gamma", pid: nil, sessionId: "o2", status: .unknown)

@Suite("kind and leave rules")
struct KindAndLeaveTests {
    @Test("an interactive session is external and a background job is owned")
    func kinds() {
        var r = registry()
        r.applyAgents([bg(background: false), bg(sessionId: "s2")], sampledAt: 100)
        #expect(r.rows().map(\.kind) == [.external, .owned])
    }

    @Test
    func leavesInAll() {
        var r = registry()
        r.applyAllAgents([bg()], complete: true)
        r.applyAgents([bg(status: .busy)], sampledAt: 100)
        r.applyAgents([], sampledAt: 200)
        #expect(r.rows().first?.state == .parked)
        #expect(r.rows().first?.status == .unknown)
        #expect(r.rows().first?.pid == nil)
    }

    @Test("an owned session that left both lists and was not started goes away")
    func leavesGone() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        #expect(r.rows().count == 1)
        r.applyAgents([], sampledAt: 200)
        #expect(r.rows() == [])
    }

    @Test("a parked session that Bifrost did not start goes away after two full lists without it")
    func parkedGoes() {
        var r = registry()
        r.applyAllAgents([bg(pid: nil, status: .unknown)], complete: true)
        #expect(r.rows().count == 1)
        r.applyAllAgents([another], complete: true)
        #expect(r.ids == ["o2", "s1"])
        r.applyAllAgents([another], complete: true)
        #expect(r.ids == ["o2"])
    }

    @Test
    func parkedComesBack() {
        // No hooks (Skip mode): only the session list can clear the parked state.
        var r = registry()
        r.markStarted("s1")
        r.applyAgents([], sampledAt: 100)
        #expect(r.rows().first?.state == .parked)
        r.applyAgents([bg(status: .busy)], sampledAt: 200)
        #expect(r.rows().first?.pid == 5)
        #expect(r.rows().first?.state == .working)
    }

    @Test
    func sessionEndParked() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        r.applyEvents([ev(.sessionEnd, "s1", 150)], now: 150)
        #expect(r.rows().first?.state == .parked)
        r.applyAgents([bg(status: .busy)], sampledAt: 200)
        #expect(r.rows().first?.state == .working)
    }

    @Test
    func staysParkedNoPid() {
        var r = registry()
        r.markStarted("s1")
        r.applyAgents([bg()], sampledAt: 100)
        r.applyEvents([ev(.sessionEnd, "s1", 150)], now: 150)
        r.applyAgents([bg(pid: nil, status: .unknown)], sampledAt: 200)
        #expect(r.rows().first?.state == .parked)
        r.applyAgents([], sampledAt: 300)
        #expect(r.rows().first?.state == .parked)
        r.applyAgents([bg(pid: nil, status: .unknown)], sampledAt: 400)
        #expect(r.rows().first?.state == .parked)
        r.applyAgents([bg()], sampledAt: 500)
        #expect(r.rows().first?.pid == 5)
        #expect(r.rows().first?.state == .idle)
        r.applyAgents([bg(status: .busy)], sampledAt: 600)
        #expect(r.rows().first?.state == .working)
    }

    @Test
    func sampleBeforeEnd() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 1000)
        r.applyEvents([ev(.sessionEnd, "s1", 2500)], now: 2500)
        r.applyAgents([bg()], sampledAt: 2000)
        #expect(r.rows().first?.state == .parked)
        r.applyAgents([bg()], sampledAt: 3000)
        #expect(r.rows().first?.state == .idle)
    }

    @Test
    func sampleBeforePark() {
        var r = registry()
        r.markStarted("s1")
        r.applyAgents([], sampledAt: 2500)
        r.applyAgents([bg()], sampledAt: 2000)
        #expect(r.rows().first?.state == .parked)
        r.applyAgents([bg()], sampledAt: 3000)
        #expect(r.rows().first?.state == .idle)
    }

    @Test
    func interactiveNotParked() {
        let ended = bg(id: nil, background: false, name: "warp", pid: nil, status: .unknown)
        var r = registry()
        r.applyAgents([ended.with { $0.pid = 7; $0.status = .idle }], sampledAt: 100)
        r.applyAgents([], sampledAt: 200)
        r.applyAllAgents([ended], complete: true)
        #expect(r.rows() == [])
    }
}

@Suite("store")
struct StoreTests {
    @Test("a poll and a mark change the store only when a stored value changes")
    func storeChanges() {
        var r = registry()
        #expect(r.store() == RegistryStore())
        r.applyAgents([bg()], sampledAt: 100)
        let polled = r.store()
        #expect(
            polled
                == RegistryStore(
                    jobs: ["s1": "aaaaaaaa"], lastActive: ["s1"], names: ["s1": "alpha"]))
        r.applyAgents([bg()], sampledAt: 200)
        #expect(r.store() == polled)
        r.markStarted("s1")
        r.markStarted("s1")
        #expect(
            r.store()
                == RegistryStore(
                    jobs: ["s1": "aaaaaaaa"], lastActive: ["s1"], names: ["s1": "alpha"],
                    started: ["s1"])
        )
    }

    @Test
    func nameFromAll() {
        var r = registry()
        r.applyAllAgents([bg(name: "beta", pid: nil, status: .unknown)], complete: true)
        #expect(r.store().names == ["s1": "beta"])
    }

    @Test
    func removesEndedName() {
        var r = registry()
        r.applyAgents([bg(id: nil, background: false, name: "warp")], sampledAt: 100)
        #expect(r.store().names == ["s1": "warp"])
        let before = r.store()
        r.applyAgents([], sampledAt: 200)
        #expect(r.store() == before)
        r.applyAllAgents([another], complete: true)
        #expect(r.store().names == ["o2": "gamma", "s1": "warp"])
        r.applyAllAgents([another], complete: true)
        #expect(r.store().names == ["o2": "gamma"])
    }

    @Test("the full list keeps the names of active, listed and started sessions")
    func keepsNames() {
        let stored = RegistryStore(
            jobs: ["s1": "aaaaaaaa", "s2": "bbbbbbbb"], lastActive: ["s1"],
            names: ["s1": "one", "s2": "two", "s3": "three"], started: ["s3"])
        var r = registry(stored)
        r.applyAgents([bg(name: "one")], sampledAt: 100)
        // The list has the active session s1, so it counts.
        r.applyAllAgents(
            [
                bg(name: "one"),
                bg(id: "bbbbbbbb", name: "", pid: nil, sessionId: "s2", status: .unknown),
            ],
            complete: true)
        #expect(r.store() == stored)
    }

    @Test("the full list does not keep the name of an interactive entry")
    func interactiveName() {
        var r = registry(RegistryStore(names: ["s1": "warp"]))
        let ended = bg(background: false, name: "warp", pid: nil, status: .unknown)
        r.applyAllAgents([ended], complete: true)
        #expect(r.store().names == ["s1": "warp"])
        r.applyAllAgents([ended], complete: true)
        #expect(r.store().names == [:])
    }

    // A SessionRow is a value, so two calls always give two values. The test changes the copies
    // and checks the registry.
    @Test("a store or row from the registry cannot change the registry")
    func noSharedState() {
        var input = RegistryStore(names: ["s1": "alpha"])
        var r = registry(input)
        input[row: "s1"].name = "changed"
        input[row: "s7"].started = true
        var copy = r.store()
        copy[row: "s1"].name = "changed"
        copy[row: "s8"].started = true
        #expect(r.store() == RegistryStore(names: ["s1": "alpha"]))
        r.applyAgents([bg(name: "")], sampledAt: 100)
        var row = r.rows().first
        row?.name = "changed"
        row?.state = .error
        #expect(r.rows().first?.name == "alpha")
        #expect(r.rows().first?.state == .idle)
    }
}
