import BifrostFoundation
import BifrostTestSupport
import Foundation
import Observation
import Synchronization
import Testing

@testable import BifrostSessions

// The tests of the registry service. Each test runs the service on a manual clock with fake
// dependencies. The fake answers on the main actor, so a test sees each call at once. A held
// call waits until the test releases it. run(for:) moves the clock in steps, and after each step
// it waits until each task of the service waits again (RegistryHarness.idle).

private let epoch = 1_000_000

private func list(_ entries: AgentEntry...) -> AgentList { AgentList(entries: entries) }
private func failed(_ detail: String) -> AgentList { .failed(.commandFailed(detail: detail)) }

// The fake dependencies of the service. Each call runs on the main actor.
@MainActor
private final class FakeRegistryDeps: RegistryServiceDeps {
    enum Call: Hashable { case active, all, branch, table, clients, save }

    private let clock: ManualClock
    // The replies. The number is the count of the call, from 1. An error is a failed call.
    var active: (Int) throws -> AgentList = { _ in AgentList() }
    var all: (Int) throws -> AgentList = { _ in AgentList() }
    var branch: (Int) throws -> String? = { _ in "main" }
    var table: () -> ProcessTable = { [:] }
    var clients: () -> [AttachClient] = { [] }
    var save: (Int) throws -> Void = { _ in }
    // A call of these kinds waits until release(_:).
    var held: Set<Call> = []
    private var waiting: [Call: [CheckedContinuation<Void, Never>]] = [:]

    // The records. A time is the time of the call in milliseconds from the start.
    private(set) var activeCalls: [Int] = []
    private(set) var allCalls: [Int] = []
    private(set) var branchCalls: [String] = []
    private(set) var tableCalls = 0
    private(set) var clientCalls = 0
    private(set) var saves: [RegistryStore] = []
    // The highest number of "claude agents" runs at one time.
    private(set) var mostLists = 0
    private var lists = 0

    init(clock: ManualClock) {
        self.clock = clock
    }

    private var elapsed: Int { Int(clock.now.offset / .milliseconds(1)) }

    @MainActor func listActive() async throws -> AgentList {
        activeCalls.append(elapsed)
        let count = activeCalls.count
        return try await list(.active) { try self.active(count) }
    }

    @MainActor func listAll() async throws -> AgentList {
        allCalls.append(elapsed)
        let count = allCalls.count
        return try await list(.all) { try self.all(count) }
    }

    @MainActor func readBranch(_ cwd: String) async throws -> String? {
        branchCalls.append(cwd)
        let count = branchCalls.count
        await wait(.branch)
        return try branch(count)
    }

    @MainActor func readTerminalApps(_ pids: [pid_t]) async -> TerminalApps {
        tableCalls += 1
        await wait(.table)
        let processes = table()
        return TerminalApps(of: pids) { processes.terminalApp(of: $0) }
    }

    @MainActor func readAttachClients() async -> [AttachClient] {
        clientCalls += 1
        await wait(.clients)
        return clients()
    }

    @MainActor func saveStore(_ store: RegistryStore) async throws {
        saves.append(store)
        let count = saves.count
        await wait(.save)
        try save(count)
    }

    private func list(_ call: Call, _ reply: () throws -> AgentList) async throws -> AgentList {
        lists += 1
        mostLists = max(mostLists, lists)
        defer { lists -= 1 }
        await wait(call)
        return try reply()
    }

    private func wait(_ call: Call) async {
        guard held.contains(call) else { return }
        await withCheckedContinuation { waiting[call, default: []].append($0) }
    }

    // End the hold of a kind of call. The calls that wait continue.
    func release(_ call: Call) {
        held.remove(call)
        for waiter in waiting.removeValue(forKey: call) ?? [] { waiter.resume() }
    }

    func releaseAll() {
        for call in [Call.active, .all, .branch, .table, .clients, .save] { release(call) }
    }

    // The calls that wait for a release now.
    var waitingCalls: Int { waiting.values.reduce(0) { $0 + $1.count } }
}

// The log lines of a service.
@MainActor
private final class RegistryRecords {
    let log = Recorder<SessionsLogEvent>()
}

// The wall time of a time in milliseconds since 1970.
private func date(_ milliseconds: Int) -> Date {
    Date(timeIntervalSince1970: Double(milliseconds) / 1000)
}

// A count that the clock closure of the service can raise from any thread.
private final class CallCounter: Sendable {
    private let value = Mutex(0)
    func add() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

// A service with fake dependencies on a manual clock. The end of the test stops the service.
@MainActor
private final class RegistryHarness {
    let clock = ManualClock()
    let deps: FakeRegistryDeps
    let records = RegistryRecords()
    let service: RegistryService
    // The count of the calls of the clock of the service (now).
    let nowCalls = CallCounter()

    // The wall time goes with the clock. stepBack: from this time of the clock (ms from the
    // start), the wall time is this many ms behind the clock.
    init(
        _ registry: SessionRegistry = SessionRegistry(
            store: RegistryStore(), escalation: .seconds(600)),
        timing: RegistryTiming = .standard, stepBack: (at: Int, by: Int)? = nil,
        health: HealthReporter = .none, _ setUp: (FakeRegistryDeps) -> Void = { _ in }
    ) {
        deps = FakeRegistryDeps(clock: clock)
        setUp(deps)
        service = RegistryService(
            registry: registry, deps: deps, clock: clock,
            now: { [clock, nowCalls] in
                nowCalls.add()
                let elapsed = Int(clock.now.offset / .milliseconds(1))
                let back = stepBack.map { elapsed >= $0.at ? $0.by : 0 } ?? 0
                return date(epoch + elapsed - back)
            }, timing: timing, log: records.log, health: health)
    }

    isolated deinit {
        service.stop()
        deps.releaseAll()
    }

    // Start the service and wait until it sleeps.
    func start() async {
        service.start()
        await idle()
    }

    // Wait until each task of the service waits at a point that the test controls: a sleep that
    // is on the clock, a held call of the fake, or the turn to list. A move of the clock or a
    // release wakes a task, and the task counts in RegistryService.awake until its next wait.
    // So the condition is true only when no task of the service can run.
    func idle(sourceLocation: SourceLocation = #_sourceLocation) async {
        await waitUntil(
            every: .milliseconds(1), sourceLocation: sourceLocation
        ) {
            service.awake == deps.waitingCalls + service.queuedLists
                && service.sleeps == clock.sleeperCount
        }
    }

    // Wait until the waits for a row are there. Each wait has a timer that sleeps on the clock,
    // next to the four loops of a service that loaded its list.
    func waitForRowWaits(_ count: Int) async {
        await clock.waitForSleepers(exactly: 4 + count)
        await idle()
    }

    // Move the clock in steps. After each step, wait until the service sleeps again.
    func run(for duration: Duration, step: Duration = .seconds(1)) async {
        var left = duration
        repeat {
            let move = min(step, left)
            clock.advance(by: move)
            left -= move
            await idle()
        } while left > .zero
    }

    func release(_ call: FakeRegistryDeps.Call) async {
        deps.release(call)
        await idle()
    }
}

// A started service whose first poll gave the row s1.
@MainActor
private func ready(_ entries: AgentEntry...) async -> RegistryHarness {
    let rows = entries.isEmpty ? [bg()] : entries
    let h = RegistryHarness { $0.active = { _ in AgentList(entries: rows) } }
    await h.start()
    return h
}

@MainActor
@Suite("the registry service: polls", .testTimeLimit)
struct RegistryPollTests {
    @Test func theNextActivePollStartsOneIntervalAfterTheEndOfThePollBefore() async {
        let h = RegistryHarness()
        await h.start()
        #expect(h.deps.activeCalls == [0])
        await h.run(for: .seconds(2))
        #expect(h.deps.activeCalls == [0, 2000])
        // The third poll runs from 4000 ms to 5000 ms.
        h.deps.held = [.active]
        await h.run(for: .seconds(3))
        #expect(h.deps.activeCalls == [0, 2000, 4000])
        await h.release(.active)
        await h.run(for: .seconds(1))
        #expect(h.deps.activeCalls.count == 3)
        await h.run(for: .seconds(1))
        #expect(h.deps.activeCalls == [0, 2000, 4000, 7000])
    }

    // Each run of claude agents takes the next turn, and only an active list that the registry
    // applied gives its turn to appliedListTurn. So a wait can tell that a list started after a
    // time (PRSessions.waitForTurnEnd): a failed list took a turn but applied nothing.
    @Test func anAppliedActiveListGivesItsTurn() async {
        let h = RegistryHarness { $0.active = { n in n == 3 ? failed("boom") : list(bg()) } }
        await h.start()
        #expect(h.service.appliedListTurn >= 1)
        let started = h.service.startedLists
        await h.run(for: .seconds(2))
        let applied = h.service.appliedListTurn
        #expect(applied > started)
        await h.run(for: .seconds(2))
        #expect(h.service.startedLists > applied && h.service.appliedListTurn == applied)
    }

    @Test func theFullPollRunsEvery30Seconds() async {
        let h = RegistryHarness()
        await h.start()
        await h.run(for: .seconds(60))
        #expect(h.deps.allCalls == [0, 30_000, 60_000])
        #expect(h.deps.mostLists == 1)
    }

    // The sample time of an active poll is the time when its run starts, after the wait for the
    // full poll: a status change sets lastActivity to it.
    @Test func theActivePollWaitsForTheFullPollAndSamplesAtItsStart() async {
        let h = RegistryHarness {
            $0.active = { n in
                list(n == 1 ? bg(status: .waiting, waitingFor: "approval") : bg(status: .busy))
            }
            $0.held = [.all]
        }
        await h.start()
        #expect(h.service.rows.first?.alert.since == epoch)
        await h.run(for: .seconds(5))
        #expect(h.deps.activeCalls == [0])
        await h.release(.all)
        #expect(h.deps.activeCalls == [0, 5000])
        #expect(h.deps.mostLists == 1)
        #expect(h.service.rows.first?.lastActivity == epoch + 5000)
    }

    // The full poll, the branches and the tick start when the first active poll ends. The first
    // tick runs at once: the yellow box of a stop event at 0 ms turns red, because the escalation
    // time of 3 s is over.
    @Test func theOtherLoopsStartWhenTheFirstActivePollEnds() async {
        let h = RegistryHarness(SessionRegistry(store: RegistryStore(), escalation: .seconds(3))) {
            $0.active = { _ in list(bg()) }
            $0.held = [.active]
        }
        // The event waits for the row of s1.
        h.service.pushLive(.state(HookEvent(.stop, "s1", at: epoch)))
        await h.start()
        await h.run(for: .seconds(5))
        #expect(h.deps.allCalls.isEmpty)
        #expect(h.deps.branchCalls.isEmpty)
        #expect(!h.service.loaded)
        await h.release(.active)
        #expect(h.deps.allCalls == [5000] && h.deps.branchCalls == ["/p"])
        #expect(h.service.rows.first?.alert.colour == .red)
    }

    @Test func aFailedActivePollShowsItsErrorAndKeepsTheRows() async {
        let h = RegistryHarness {
            $0.active = { n in
                switch n {
                case 2: failed("boom")
                case 3: throw RegistryFailure("spawn failed")
                default: list(bg())
                }
            }
            $0.all = { _ in failed("boom") }
        }
        await h.start()
        #expect(h.service.loaded)
        #expect(h.service.error == nil)
        #expect(h.service.rows.map(\.sessionId) == ["s1"])
        await h.run(for: .seconds(2))
        #expect(h.service.error == .commandFailed(detail: "boom"))
        #expect(h.service.rows.map(\.sessionId) == ["s1"])
        await h.run(for: .seconds(2))
        #expect(h.service.error == .commandFailed(detail: "spawn failed"))
        #expect(h.service.rows.map(\.sessionId) == ["s1"])
        await h.run(for: .seconds(2))
        #expect(h.service.error == nil)
        await h.run(for: .seconds(30))
        #expect(h.deps.allCalls.count == 2)
    }

    // Each active poll tells the health log its result: ok for a list, failed for a failed list
    // and for a failed run of claude.
    @Test func eachActivePollTellsTheHealthLog() async {
        let (health, events) = HealthReporter.make()
        let seen = Recorder<HealthEvent>()
        let reader = Task { for await event in events { seen.record(event) } }
        defer { reader.cancel() }
        let h = RegistryHarness(health: health) {
            $0.active = { n in
                switch n {
                case 2: failed("boom")
                case 3: throw RegistryFailure("spawn failed")
                default: list(bg())
                }
            }
        }
        await h.start()
        await h.run(for: .seconds(6))
        #expect(h.deps.activeCalls.count == 4)
        await waitUntil { seen.values.count >= 4 }
        #expect(
            seen.values == [
                .poll(.sessions, .ok), .poll(.sessions, .failed), .poll(.sessions, .failed),
                .poll(.sessions, .ok),
            ])
    }

    // The detail of a failed list goes to the log one time, not to the screen.
    @Test func theDetailOfAFailedListIsLoggedOneTime() async {
        let h = RegistryHarness {
            $0.active = { n in n == 1 ? list(bg()) : .failed(.badJSON(detail: "line 1")) }
        }
        await h.start()
        await h.run(for: .seconds(6))
        #expect(h.deps.activeCalls.count == 4)
        #expect(h.service.error == .badJSON(detail: "line 1"))
        #expect(h.records.log.values == [.agentListFailed(.badJSON(detail: "line 1"))])
    }

    @Test func aFirstPollThatFailsLoadsTheListWithItsError() async {
        let h = RegistryHarness { $0.active = { _ in throw RegistryFailure("spawn failed") } }
        await h.start()
        #expect(h.service.loaded)
        #expect(h.service.error == .commandFailed(detail: "spawn failed"))
        #expect(h.service.rows.isEmpty)
        await h.run(for: .seconds(2))
        #expect(h.deps.activeCalls == [0, 2000])
    }

    @Test func theListLoadsWhenTheFirstActivePollEnds() async {
        let h = RegistryHarness {
            $0.active = { _ in list(bg()) }
            $0.held = [.active]
        }
        h.service.pushLive(.usage(sessionId: "s1", at: epoch, LiveUsage(model: "claude-opus-5-5")))
        await h.start()
        await h.run(for: .seconds(1))
        #expect(!h.service.loaded)
        await h.release(.active)
        #expect(h.service.loaded)
        #expect(h.service.rows.map { "\($0.model ?? "") \($0.sessionId)" } == ["Opus 5.5 s1"])
    }

    @Test func aFailedFullPollKeepsTheLastFullList() async {
        let parked = bg(id: "f7f7f7f7", pid: nil, sessionId: "s7", status: .unknown)
        let h = RegistryHarness { $0.all = { n in n == 1 ? list(parked) : failed("boom") } }
        await h.start()
        #expect(h.service.rows.map { "\($0.sessionId) \($0.state)" } == ["s7 parked"])
        await h.run(for: .seconds(30))
        #expect(h.deps.allCalls.count == 2)
        #expect(h.service.rows.map { "\($0.sessionId) \($0.state)" } == ["s7 parked"])
    }

    // A wait that runs keeps its time. The new interval applies to the next wait.
    @Test func aNewIntervalAppliesToTheWaitAfterThePollThatRuns() async {
        let h = RegistryHarness()
        await h.start()
        h.service.setActiveInterval(.seconds(5))
        await h.run(for: .seconds(2))
        #expect(h.deps.activeCalls == [0, 2000])
        await h.run(for: .seconds(4))
        #expect(h.deps.activeCalls.count == 2)
        await h.run(for: .seconds(1))
        #expect(h.deps.activeCalls == [0, 2000, 7000])
        h.service.setActiveInterval(.seconds(1))
        await h.run(for: .seconds(5))
        #expect(h.deps.activeCalls == [0, 2000, 7000, 12_000])
        await h.run(for: .seconds(1))
        #expect(h.deps.activeCalls == [0, 2000, 7000, 12_000, 13_000])
    }

    @Test func theTimingHasNoUpdateGap() {
        let keys = Mirror(reflecting: RegistryTiming()).children.compactMap(\.label).sorted()
        #expect(keys == ["active", "all", "branch", "tick"])
    }

    @Test func theServiceRunsOnTheRealClock() async {
        var timing = RegistryTiming()
        timing.active = .milliseconds(20)
        let deps = FakeRegistryDeps(clock: ManualClock())
        deps.active = { _ in list(bg()) }
        let service = RegistryService(
            registry: registry(), deps: deps, clock: ContinuousClock(), now: { date(epoch) },
            timing: timing, log: Recorder<SessionsLogEvent>())
        service.start()
        await waitUntil { deps.activeCalls.count >= 3 }
        #expect(service.rows.map(\.sessionId) == ["s1"])
        service.stop()
    }
}

@MainActor
@Suite("the registry service: a window that is not visible", .testTimeLimit)
struct HiddenWindowPollTests {
    @Test func aHiddenWindowPollsEvery15Seconds() async {
        let h = RegistryHarness()
        await h.start()
        h.service.setWindowVisible(false)
        // The wait that runs keeps its 2 s. The next waits are 15 s.
        await h.run(for: .seconds(2))
        #expect(h.deps.activeCalls == [0, 2000])
        await h.run(for: .seconds(14))
        #expect(h.deps.activeCalls.count == 2)
        await h.run(for: .seconds(1))
        #expect(h.deps.activeCalls == [0, 2000, 17_000])
    }

    @Test func aWindowThatShowsPollsAtOnceThenAtTheNormalInterval() async {
        let h = RegistryHarness()
        await h.start()
        h.service.setWindowVisible(false)
        await h.run(for: .seconds(2))
        await h.run(for: .seconds(5))
        #expect(h.deps.activeCalls == [0, 2000])
        h.service.setWindowVisible(true)
        await h.idle()
        #expect(h.deps.activeCalls == [0, 2000, 7000])
        await h.run(for: .seconds(1))
        #expect(h.deps.activeCalls.count == 3)
        await h.run(for: .seconds(1))
        #expect(h.deps.activeCalls == [0, 2000, 7000, 9000])
    }

    @Test func theSameVisibleValueTwiceGivesNoPoll() async {
        let h = RegistryHarness()
        await h.start()
        h.service.setWindowVisible(true)
        await h.idle()
        #expect(h.deps.activeCalls == [0])
    }

    @Test func aLongerIntervalAppliesWhileTheWindowIsHidden() async {
        let h = RegistryHarness()
        await h.start()
        h.service.setWindowVisible(false)
        h.service.setActiveInterval(.seconds(30))
        await h.run(for: .seconds(2))
        #expect(h.deps.activeCalls == [0, 2000])
        await h.run(for: .seconds(29))
        #expect(h.deps.activeCalls.count == 2)
        await h.run(for: .seconds(1))
        #expect(h.deps.activeCalls == [0, 2000, 32_000])
    }

    // The time of the wait comes, and the window shows before the loop runs again. The wait
    // ended already, so the loop polls one time, not two times.
    @Test func aWaitThatEndsJustBeforeTheWindowShowsGivesOnePoll() async {
        let h = RegistryHarness()
        h.service.setWindowVisible(false)
        await h.start()
        h.clock.advance(by: .seconds(15))
        h.service.setWindowVisible(true)
        await h.idle()
        #expect(h.deps.activeCalls == [0, 15_000])
        await h.run(for: .seconds(2))
        #expect(h.deps.activeCalls == [0, 15_000, 17_000])
    }
}

@MainActor
@Suite("the registry service: changes and the store", .testTimeLimit)
struct RegistryChangeTests {
    @Test func theRowsChangeOnlyWhenARowChanges() async {
        let h = await ready()
        let rows = Recorder(following: Observations { h.service.rows })
        await waitUntil { rows.values.count == 1 }
        await h.run(for: .seconds(20))
        // The change of the priority is the marker: the rows of the polls before it gave no value.
        #expect(h.service.setPriority("s1", .p2))
        await waitUntil { rows.values.count >= 2 }
        #expect(rows.values.count == 2)
        #expect(rows.values.last?.first?.priority == .p2)
    }

    @Test func aBoxKeepsFlashingUntilTheUserAnswers() async {
        let h = await ready()
        h.service.pushLive(.state(HookEvent(.stop, "s1", at: epoch)))
        #expect(
            h.service.rows.first?.alert.colour == .yellow
                && h.service.rows.first?.alert.flashes == true)
        await h.run(for: .seconds(5))
        #expect(
            h.service.rows.first?.alert.colour == .yellow
                && h.service.rows.first?.alert.flashes == true)
        h.service.pushLive(.state(HookEvent(.userPromptSubmit, "s1", at: epoch + 6000)))
        #expect(h.service.rows.first?.alert.colour == AlertColour.none)
        #expect(h.service.rows.first?.alert.flashes == false)
    }

    @Test func aPriorityShowsAtOnceAndIsSaved() async {
        let h = await ready()
        #expect(h.service.setPriority("s1", .p2))
        #expect(h.service.rows.first?.priority == .p2)
        await h.idle()
        #expect(h.deps.saves.last?.priorities == ["s1": .p2])
        #expect(!h.service.setPriority("nope", .p2))
    }

    @Test func aLocalNameShowsAtOnceIsSavedAndRenamesTheRateLimits() async {
        let h = await ready()
        let limits = RateLimits(sevenDay: RateWindow(usedPercent: 15, resetsAt: 9_000_000))
        h.service.pushLive(.usage(sessionId: "s1", at: epoch, LiveUsage(rateLimits: limits)))
        #expect(h.service.usage?.name == "alpha")
        #expect(h.service.setAlias("s1", "Work"))
        #expect(h.service.rows.first?.claudeName == "alpha")
        #expect(h.service.rows.first?.name == "Work")
        #expect(h.service.usage?.name == "Work")
        await h.idle()
        #expect(h.deps.saves.last?.aliases == ["s1": "Work"])
        #expect(!h.service.setAlias("nope", "x"))
    }

    @Test func aRememberedWorktreeShowsAtOnceAndIsSaved() async {
        let worktree = "/r/.claude/worktrees/fix-a"
        let h = await ready()
        #expect(h.service.rememberWorktree("s1", worktree))
        #expect(h.service.rows.first?.worktree == worktree)
        await h.idle()
        #expect(h.deps.saves.last?.worktrees == ["s1": worktree])
        #expect(!h.service.rememberWorktree("nope", worktree))
    }

    @Test func aCarryOverChangesTheRowsOnlyWhenValuesMove() async {
        let h = await ready(bg(), bg(id: "bbbbbbbb", name: "beta", pid: 6, sessionId: "s2"))
        #expect(h.service.setPriority("s1", .p2))
        let rows = Recorder(following: Observations { h.service.rows })
        await waitUntil { rows.values.count == 1 }
        #expect(h.service.carryOver(from: "s1", to: "s2"))
        await waitUntil { rows.values.count == 2 }
        #expect(h.service.rows.first { $0.sessionId == "s2" }?.priority == .p2)
        #expect(!h.service.carryOver(from: "s1", to: "nope"))
        // The next change is the marker: the carry-over to no row gave no value.
        #expect(h.service.setPriority("s1", .p3))
        await waitUntil { rows.values.count >= 3 }
        #expect(rows.values.count == 3)
    }

    @Test func deferredDeletesSaveOnlyWhenTheStoreChanges() async {
        let worktree = "/r/.claude/worktrees/w1"
        let entry = DeferredDelete(sessionId: "s1", shortId: "aaaaaaaa", worktree: worktree)
        // s1 is a parked row of the last run. s2 runs in the same worktree.
        let h = RegistryHarness(registry(RegistryStore(started: ["s1"]))) {
            $0.active = { _ in
                list(bg(cwd: worktree, id: "bbbbbbbb", name: "beta", pid: 6, sessionId: "s2"))
            }
        }
        await h.start()
        #expect(h.service.rows.map(\.sessionId) == ["s1", "s2"])
        let mark = h.deps.saves.count
        let saves = { h.deps.saves.count - mark }
        let lastDeferred = { h.deps.saves.last?.deferred ?? [] }

        // A defer removes the row and saves.
        h.service.defer(entry)
        #expect(h.service.rows.map(\.sessionId) == ["s2"])
        await h.idle()
        #expect(saves() == 1)
        #expect(lastDeferred() == [entry])

        // No change gives no save.
        h.service.defer(entry)
        h.service.undefer("nope")
        h.service.dropDeferred("nope")
        await h.idle()
        #expect(saves() == 1)
        #expect(h.service.deferredIn(worktree) == [entry])

        // undefer and dropDeferred change the store.
        h.service.undefer("s1")
        await h.idle()
        #expect(saves() == 2)
        #expect(lastDeferred().isEmpty)
        h.service.defer(entry)
        await h.idle()
        #expect(saves() == 3)
        h.service.dropDeferred("s1")
        await h.idle()
        #expect(saves() == 4)
        #expect(lastDeferred().isEmpty)
        #expect(h.service.deferredIn(worktree) == [])
        #expect(h.service.rows.map(\.sessionId) == ["s2"])
    }

    @Test func watchlistChangesShowAtOnceAndAreSaved() async {
        let h = await ready(bg(), bg(id: "bbbbbbbb", name: "beta", pid: 6, sessionId: "s2"))
        let watch = { (id: String) in h.service.rows.first { $0.sessionId == id }?.watch }

        #expect(h.service.watchAdd("s1", .darkBlue))
        #expect(h.service.watchAdd("s2", .green))
        #expect(watch("s1") == RowWatch(colour: .darkBlue, order: 0))
        #expect(watch("s2") == RowWatch(colour: .green, order: 1))
        await h.idle()
        #expect(h.deps.saves.last?.watch == [WatchEntry("s1", .darkBlue), WatchEntry("s2", .green)])

        #expect(h.service.watchColour("s1", .red))
        #expect(watch("s1")?.colour == .red)
        #expect(h.service.watchMove("s2", before: "s1"))
        #expect(watch("s2")?.order == 0)
        #expect(watch("s1")?.order == 1)
        await h.idle()
        #expect(h.deps.saves.last?.watch == [WatchEntry("s2", .green), WatchEntry("s1", .red)])

        #expect(h.service.watchRemove("s2"))
        #expect(watch("s2") == nil)
        await h.idle()
        #expect(h.deps.saves.last?.watch == [WatchEntry("s1", .red)])

        let mark = h.deps.saves.count
        #expect(!h.service.watchAdd("nope", .darkBlue))
        #expect(!h.service.watchRemove("nope"))
        #expect(!h.service.watchColour("nope", .darkBlue))
        #expect(!h.service.watchMove("nope", before: nil))
        await h.idle()
        #expect(h.deps.saves.count == mark)
    }

    @Test func theMarksAndAForgetAreSaved() async {
        let h = await ready()
        h.service.markStarted("s1")
        await h.idle()
        #expect(h.deps.saves.last?.started == ["s1"])
        h.service.markStopped("s1")
        await h.idle()
        #expect(h.deps.saves.last?.lastActive == [])
        h.service.forget("s1")
        #expect(h.service.rows == [])
        await h.idle()
        #expect(h.deps.saves.last?.started == [])
    }

    @Test func thePrSessionCommandsAreSaved() async {
        let h = await ready()
        h.service.markPrSession("s1")
        #expect(h.service.rows.first?.prSession == true)
        h.service.expectPrSession("alpha-1-review")
        await h.idle()
        #expect(h.deps.saves.last?.prSessions == ["s1"])
        #expect(h.deps.saves.last?.prNames == ["alpha-1-review"])
        h.service.releasePrSession("alpha-1-review")
        await h.idle()
        #expect(h.deps.saves.last?.prNames == [])
    }

    @Test func theFirstPollSavesTheStoreOneTime() async {
        let h = await ready()
        #expect(
            h.deps.saves == [
                RegistryStore(jobs: ["s1": "aaaaaaaa"], lastActive: ["s1"], names: ["s1": "alpha"])
            ])
        await h.run(for: .seconds(10))
        #expect(h.deps.saves.count == 1)
    }

    @Test func aFailedSaveIsLoggedOneTimeAndALaterChangeSavesAgain() async {
        let h = RegistryHarness {
            $0.active = { _ in list(bg()) }
            $0.save = { n in if n == 1 { throw RegistryFailure("disk full") } }
        }
        await h.start()
        await h.run(for: .seconds(1))
        #expect(h.deps.saves.count == 2)
        #expect(
            h.deps.saves.last
                == RegistryStore(
                    jobs: ["s1": "aaaaaaaa"], lastActive: ["s1"], names: ["s1": "alpha"]))
        await h.run(for: .seconds(10))
        #expect(h.deps.saves.count == 2)
        #expect(h.records.log.values == [.registryStoreSaveFailed(message: "disk full")])
    }

    @Test func eachFailedSaveTriesAgainAndTheLogShowsTheFirstFailure() async {
        let h = RegistryHarness {
            $0.active = { _ in list(bg()) }
            $0.save = { n in if n <= 2 { throw RegistryFailure("disk full") } }
        }
        await h.start()
        await h.run(for: .seconds(10))
        #expect(h.deps.saves.count == 3)
        #expect(h.records.log.values.count == 1)
    }

    // The health log gets the first failed save of each series, with the name of the data of
    // the file, so the Performance panel shows it. The tries of the same series add nothing, and
    // a series after a good save tells it again.
    @Test func theFirstFailedSaveOfASeriesTellsTheHealthLog() async {
        let (health, events) = HealthReporter.make()
        let saves = Recorder<HealthEvent>()
        let reader = Task {
            for await event in events where event != .poll(.sessions, .ok) { saves.record(event) }
        }
        defer { reader.cancel() }
        let h = RegistryHarness(health: health) {
            $0.active = { n in list(n <= 2 ? bg() : bg(name: "beta")) }
            $0.save = { n in if n <= 3 || n == 5 { throw RegistryFailure("disk full") } }
        }
        await h.start()
        await h.run(for: .seconds(8))
        #expect(h.deps.saves.count >= 6)
        await waitUntil { saves.values.count >= 2 }
        let failed = HealthEvent.saveFailed(what: "the registry store")
        #expect(saves.values == [failed, failed])
    }

    @Test func aChangeDuringASaveSavesTheNewestStoreWhenThatSaveEnds() async {
        let h = RegistryHarness {
            $0.active = { n in list(n == 1 ? bg() : bg(name: "beta")) }
            $0.held = [.save]
        }
        await h.start()
        // The second poll changes the name while the first save runs.
        await h.run(for: .seconds(2))
        #expect(h.service.rows.first?.name == "beta")
        #expect(h.deps.saves.count == 1)
        #expect(h.service.isSaving)
        await h.release(.save)
        #expect(h.deps.saves.count == 2)
        #expect(
            h.deps.saves.last
                == RegistryStore(
                    jobs: ["s1": "aaaaaaaa"], lastActive: ["s1"], names: ["s1": "beta"]))
        #expect(!h.service.isSaving)
    }

    @Test func aLoopErrorIsLoggedOneTimeAndTheLoopGoesOn() async {
        let h = RegistryHarness {
            $0.active = { _ in list(bg()) }
            $0.branch = { _ in throw RegistryFailure("boom") }
        }
        await h.start()
        await h.run(for: .seconds(30))
        #expect(h.deps.branchCalls.count == 4)
        #expect(
            h.records.log.values == [.registryLoopFailed(message: "boom")])
    }

    @Test func atMost20LoopErrorsAreLogged() async {
        var timing = RegistryTiming()
        timing.branch = .seconds(1)
        let h = RegistryHarness(timing: timing) {
            $0.active = { _ in list(bg()) }
            $0.branch = { n in throw RegistryFailure("boom \(n)") }
        }
        await h.start()
        await h.run(for: .seconds(25))
        #expect(h.deps.branchCalls.count == 26)
        #expect(h.records.log.values.count == 20)
        #expect(h.records.log.values.last == .registryLoopFailed(message: "boom 20"))
    }

    // A failed list counts in the log by its reason, not by its detail. So a stderr of claude
    // that changes at each poll goes to the log one time, and a later loop error still goes to
    // the log.
    @Test func aFailedListWithANewDetailAtEachPollLeavesRoomForALoopError() async {
        let h = RegistryHarness {
            $0.active = { n in n == 1 ? list(bg()) : failed("stderr \(n)") }
            $0.all = { _ in list(bg()) }
            $0.branch = { n in
                guard n < 6 else { throw RegistryFailure("boom") }
                return "main"
            }
        }
        await h.start()
        await h.run(for: .seconds(55))
        #expect(h.deps.activeCalls.count > 21)
        #expect(h.deps.branchCalls.count == 6)
        #expect(
            h.records.log.values == [
                .agentListFailed(.commandFailed(detail: "stderr 2")),
                .registryLoopFailed(message: "boom"),
            ])
    }

    @Test func theBranchIsReadOneTimeForEachFolder() async {
        let h = await ready(bg(), bg(id: "bbbbbbbb", sessionId: "s2"))
        #expect(h.deps.branchCalls == ["/p"])
        #expect(h.service.rows.map(\.branch) == ["main", "main"])
        await h.run(for: .seconds(10))
        #expect(h.deps.branchCalls == ["/p", "/p"])
    }

    @Test func theTerminalAppIsReadOneTimeForANewExternalPID() async {
        let external = bg(id: nil, background: false, name: "", pid: 931, sessionId: "e1")
        let h = RegistryHarness {
            $0.active = { _ in list(external) }
            $0.table = {
                [
                    931: ProcessEntry(ppid: 866, comm: "-zsh"),
                    866: ProcessEntry(
                        ppid: 1, comm: "/Applications/Warp.app/Contents/MacOS/stable"),
                ]
            }
        }
        await h.start()
        await h.run(for: .seconds(5))
        #expect(h.deps.tableCalls == 1)
        #expect(h.service.rows.first?.terminalApp == "Warp")
        #expect(h.service.terminalOf("e1")?.bundle == "/Applications/Warp.app")
    }

    // Only one read of the terminal apps runs at a time. A PID with no app is not read again.
    @Test func oneTerminalAppReadRunsAtATime() async {
        let external = bg(id: nil, background: false, name: "", pid: 931, sessionId: "e1")
        let h = RegistryHarness {
            $0.active = { _ in list(external) }
            $0.held = [.table]
        }
        await h.start()
        await h.run(for: .seconds(4))
        #expect(h.deps.tableCalls == 1)
        await h.release(.table)
        #expect(h.service.rows.first?.terminalApp == nil)
        await h.run(for: .seconds(4))
        #expect(h.deps.tableCalls == 1)
    }

    // A "claude attach" client can start or end at any time, so the scan of the clients runs
    // after each active poll while the registry has an owned session.
    @Test func theAttachClientsAreReadAfterEachActivePoll() async {
        let warp = TerminalApp(name: "Warp", bundle: "/Applications/Warp.app")
        let inWarp = AttachClient(
            pid: 40, started: ProcessStart(seconds: 9, microseconds: 0),
            argument: .idStart("aaaaaaaa"), app: warp)
        let h = RegistryHarness {
            $0.active = { _ in list(bg()) }
            $0.clients = { [inWarp] }
        }
        await h.start()
        #expect(h.deps.clientCalls == 1)
        #expect(h.deps.tableCalls == 0)
        #expect(h.service.rows.first?.terminalApp == "Warp")
        #expect(h.service.terminalOf("s1") == warp)
        h.deps.clients = { [] }
        await h.run(for: .seconds(2))
        #expect(h.deps.clientCalls == 2)
        #expect(h.service.rows.first?.terminalApp == nil)
        #expect(h.service.terminalOf("s1") == nil)
    }

    @Test func noScanOfTheAttachClientsRunsWithNoOwnedSession() async {
        let external = bg(id: nil, background: false, name: "", pid: 931, sessionId: "e1")
        let h = RegistryHarness { $0.active = { _ in list(external) } }
        await h.start()
        await h.run(for: .seconds(4))
        #expect(h.deps.tableCalls == 1)
        #expect(h.deps.clientCalls == 0)
    }

    // A scan that waits holds the next polls: they start no second read.
    @Test func oneScanOfTheAttachClientsRunsAtATime() async {
        let h = RegistryHarness {
            $0.active = { _ in list(bg()) }
            $0.held = [.clients]
        }
        await h.start()
        await h.run(for: .seconds(4))
        #expect(h.deps.activeCalls.count == 3)
        #expect(h.deps.clientCalls == 1)
        await h.release(.clients)
        await h.run(for: .seconds(2))
        #expect(h.deps.clientCalls == 2)
    }
}

@MainActor
@Suite("the registry service: a stop", .testTimeLimit)
struct RegistryStopTests {
    // The stop comes after the first poll made the other loops and before they run for the
    // first time. The stop task is queued before the loop tasks, so it runs first.
    @Test func aStopBeforeTheFirstRunOfTheLoopsDoesNoWork() async {
        let h = RegistryHarness()
        h.deps.active = { _ in
            Task { @MainActor in h.service.stop() }
            return list(bg())
        }
        h.service.start()
        await h.idle()
        #expect(h.deps.allCalls.isEmpty)
        #expect(h.deps.branchCalls.isEmpty)
        // The first poll reads the clock one time. A tick would read it again.
        #expect(h.nowCalls.count == 1)
        #expect(h.clock.sleeperCount == 0)
    }

    @Test func aFailedSaveThatEndsAfterTheStopLogsNothing() async {
        let h = RegistryHarness {
            $0.active = { _ in list(bg()) }
            $0.save = { _ in throw RegistryFailure("disk full") }
            $0.held = [.save]
        }
        await h.start()
        #expect(h.deps.saves.count == 1)
        h.service.stop()
        await h.release(.save)
        await waitUntil { !h.service.isSaving }
        #expect(h.records.log.values.isEmpty)
    }

    @Test func aStopEndsEachSleepAndALateResultChangesNothing() async {
        let h = RegistryHarness {
            $0.active = { _ in list(bg()) }
            $0.held = [.active]
        }
        await h.start()
        h.service.stop()
        await h.release(.active)
        #expect(h.clock.sleeperCount == 0)
        #expect(!h.service.loaded)
        #expect(h.service.rows.isEmpty)
        await h.run(for: .seconds(60))
        #expect(h.deps.activeCalls.count == 1)
    }

    @Test func afterAStopNoCommandChangesTheRegistry() async {
        let h = await ready()
        h.service.stop()
        await h.idle()
        #expect(h.clock.sleeperCount == 0)
        let rows = h.service.rows
        let saves = h.deps.saves.count
        h.service.pushLive(.usage(sessionId: "s1", at: epoch, LiveUsage(costUsd: 0.42)))
        h.service.pushLive(.state(HookEvent(.stop, "s1", at: epoch)))
        h.service.forget("s1")
        h.service.markStarted("s1")
        #expect(!h.service.setAlias("s1", "Work"))
        await h.idle()
        #expect(h.service.rows == rows)
        #expect(h.service.usage == nil)
        #expect(h.service.forgotten.isEmpty)
        #expect(h.deps.saves.count == saves)
        // A start after the stop starts nothing.
        h.service.start()
        await h.run(for: .seconds(5))
        #expect(h.deps.activeCalls.count == 1)
    }

    @Test func aBranchThatComesAfterTheStopChangesNothing() async {
        let h = RegistryHarness {
            $0.active = { _ in list(bg()) }
            $0.held = [.branch]
        }
        await h.start()
        h.service.stop()
        await h.release(.branch)
        #expect(h.service.rows.first?.branch == nil)
        #expect(h.clock.sleeperCount == 0)
    }
}

@MainActor
@Suite("the registry service: a wait for a row", .testTimeLimit)
struct RowWaitTests {
    @Test func aWaitEndsWithTheFirstRowThatMatchesAfterAChange() async throws {
        let h = RegistryHarness { $0.active = { n in n == 1 ? AgentList() : list(bg()) } }
        await h.start()
        let found = Task {
            try await h.service.waitForRow(timeout: .seconds(10)) { $0.sessionId == "s1" }
        }
        await h.waitForRowWaits(1)
        await h.run(for: .seconds(2))
        #expect(try await found.value.sessionId == "s1")
    }

    @Test func aWaitThrowsTimeoutAtItsTimeAndStoppedAtTheStop() async {
        let h = await ready()
        let late = Task {
            try await h.service.waitForRow(timeout: .milliseconds(500)) { _ in false }
        }
        let open = Task { try await h.service.waitForRow(timeout: .seconds(10)) { _ in false } }
        await h.waitForRowWaits(2)
        await h.run(for: .milliseconds(500))
        await #expect(throws: RowWaitError.timeout) { try await late.value }
        h.service.stop()
        await #expect(throws: RowWaitError.stopped) { try await open.value }
        await h.idle()
        #expect(h.clock.sleeperCount == 0)
    }

    @Test func aCancelledCallerEndsItsWaitAtOnceAndALaterRowResumesNothing() async {
        let h = await ready()
        let caller = Task {
            try await h.service.waitForRow(timeout: .seconds(10)) { $0.sessionId == "s2" }
        }
        await h.waitForRowWaits(1)
        caller.cancel()
        // The clock does not move: the cancel alone ends the wait.
        await #expect(throws: RowWaitError.cancelled) { try await caller.value }
        await h.idle()
        #expect(h.clock.sleeperCount == h.service.sleeps)
        // A row that matches later finds no wait, and the timeout of the wait does not come.
        h.deps.active = { _ in list(bg(), bg(id: "b2b2b2b2", sessionId: "s2")) }
        await h.run(for: .seconds(30))
        #expect(h.service.rows.contains { $0.sessionId == "s2" })
    }

    @Test func aCallerThatWasCancelledBeforeTheCallEndsAtOnce() async {
        let h = await ready()
        let caller = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await h.service.waitForRow(timeout: .seconds(10)) { _ in false }
        }
        caller.cancel()
        await #expect(throws: RowWaitError.cancelled) { try await caller.value }
    }

    @Test func aRowThatExistsEndsTheWaitAtOnce() async throws {
        let h = await ready()
        let sleeps = h.service.sleeps
        let row = try await h.service.waitForRow(timeout: .seconds(5)) { $0.sessionId == "s1" }
        #expect(row.sessionId == "s1")
        #expect(h.service.sleeps == sleeps)
    }

    // The session list reads the rows from the registry, so a change of the registry is in the
    // list in the same turn (user decision, 2026-11-16: the rows exist in one place). The match
    // of a wait runs in the turn of a poll, right after the registry sets its rows. A command
    // changes the list before the next statement.
    @Test func aRegistryChangeIsInTheSessionListInTheSameTurn() async throws {
        let h = RegistryHarness { $0.active = { n in n == 1 ? AgentList() : list(bg()) } }
        let sessions = SessionListModel()
        sessions.read(from: h.service)
        await h.start()
        #expect(sessions.rows.isEmpty)
        let inList = Recorder<Bool>()
        let found = Task { @MainActor in
            try await h.service.waitForRow(timeout: .seconds(10)) { row in
                guard row.sessionId == "s1" else { return false }
                inList.record(sessions.rows.contains(row))
                return true
            }
        }
        await h.waitForRowWaits(1)
        await h.run(for: .seconds(2))
        _ = try await found.value
        #expect(inList.values == [true])
        #expect(h.service.setAlias("s1", "renamed"))
        #expect(sessions.rows.map(\.name) == ["renamed"])
    }

    @Test func aWaitAfterTheStopThrowsStopped() async {
        let h = RegistryHarness()
        h.service.stop()
        await #expect(throws: RowWaitError.stopped) {
            try await h.service.waitForRow(timeout: .seconds(5)) { _ in true }
        }
    }

    // A wait for the rows gets all the rows, so a change that leaves no row also ends it. A wait
    // for a row cannot see that change, because it has no row to match.
    @Test func aWaitForTheRowsEndsAtAChangeThatLeavesNoRow() async throws {
        let h = RegistryHarness { $0.active = { n in n == 1 ? list(bg()) : AgentList() } }
        await h.start()
        #expect(h.service.rows.map(\.sessionId) == ["s1"])
        let empty = Task { try await h.service.waitForRows(timeout: .seconds(10)) { $0.isEmpty } }
        await h.waitForRowWaits(1)
        await h.run(for: .seconds(2))
        try await empty.value
        #expect(h.service.rows.isEmpty)
    }

    @Test func rowsThatMatchNowEndTheWaitForTheRowsAtOnce() async throws {
        let h = await ready()
        let sleeps = h.service.sleeps
        try await h.service.waitForRows(timeout: .seconds(5)) { $0.count == 1 }
        #expect(h.service.sleeps == sleeps)
    }
}

// Another parked session, so that the --all list is not empty.
private let otherParked = bg(id: "bbbbbbbb", pid: nil, sessionId: "o1", status: .unknown)

// s9 is a started session that claude rm in a terminal removed.
private func withGone() -> SessionRegistry {
    registry(RegistryStore(names: ["s9": "nine"], started: ["s9"]))
}

// The replies of listAll in their order. After the last one, a call fails.
private func lists(_ replies: AgentList...) -> (Int) throws -> AgentList {
    { n in
        guard n <= replies.count else { throw RegistryFailure("no reply") }
        return replies[n - 1]
    }
}

// Discuss with Claude keeps the IDs of its sessions, and drops an ID only when Bifrost forgets
// that session for good. A failed or partial list never counts, and a deferred delete does not
// count, because the session can come back.
@MainActor
@Suite("the registry service: a session that is gone", .testTimeLimit)
struct GoneSessionTests {
    @Test func aFailedFullListBetweenTwoGoodListsDoesNotCount() async {
        let h = RegistryHarness(withGone()) {
            $0.all = lists(
                list(otherParked), failed("/x/claude stopped with signal 9."), list(otherParked))
        }
        await h.start()
        #expect(h.service.rows.map(\.sessionId).contains("s9"))
        await h.run(for: .seconds(30))
        #expect(h.service.rows.map(\.sessionId).contains("s9"))
        await h.run(for: .seconds(30))
        #expect(h.deps.allCalls.count == 3)
        #expect(h.service.rows.map(\.sessionId) == ["o1"])
        #expect(h.service.forgotten == ["s9"])
        #expect(h.deps.saves.last?.started == [])
        #expect(h.deps.saves.last?.names["s9"] == nil)
    }

    @Test func failedAndRejectedFullListsNeverForget() async {
        let h = RegistryHarness(withGone()) {
            $0.all = { n in
                switch n {
                case 1: list(otherParked)
                case 2, 4: failed("boom")
                default: throw RegistryFailure("spawn failed")
                }
            }
        }
        await h.start()
        await h.run(for: .seconds(120), step: .seconds(2))
        #expect(h.deps.allCalls.count == 5)
        #expect(h.service.rows.map(\.sessionId).contains("s9"))
        #expect(h.service.forgotten.isEmpty)
    }

    @Test func aPartialFullListNeverForgets() async {
        let partial = AgentList(entries: [otherParked], partial: true)
        let h = RegistryHarness(withGone()) {
            $0.all = lists(list(otherParked), partial, partial, partial)
        }
        await h.start()
        await h.run(for: .seconds(90), step: .seconds(2))
        #expect(h.deps.allCalls.count == 4)
        #expect(h.service.rows.map(\.sessionId).contains("s9"))
    }

    @Test func aFullListThatComesAfterTheStopDoesNotForget() async {
        let h = RegistryHarness(withGone()) { $0.all = lists(list(otherParked), list(otherParked)) }
        await h.start()
        h.deps.held = [.all]
        await h.run(for: .seconds(30))
        #expect(h.deps.allCalls.count == 2)
        h.service.stop()
        await h.release(.all)
        #expect(h.service.rows.map(\.sessionId).contains("s9"))
        #expect(h.service.forgotten.isEmpty)
    }

    @Test func aSessionThatIsGoneFromTheListsIsForgotten() async {
        let h = RegistryHarness(registry(RegistryStore(started: ["s9"]))) {
            $0.all = { _ in list(otherParked) }
        }
        await h.start()
        await h.run(for: .seconds(90), step: .seconds(2))
        #expect(h.service.forgotten == ["s9"])
    }

    @Test func aDeleteIsForgotten() async {
        let h = RegistryHarness(registry(RegistryStore(started: ["s9"])))
        await h.start()
        h.service.forget("s9")
        #expect(h.service.forgotten == ["s9"])
    }

    @Test func failedActiveListsForgetNothing() async {
        let h = RegistryHarness(registry(RegistryStore(started: ["d1"]))) {
            $0.active = { n in
                switch n {
                case 1: failed("/x/claude stopped with signal 9.")
                case 2: throw RegistryFailure("spawn failed")
                default: list(bg(sessionId: "d1"))
                }
            }
            $0.all = { _ in list(bg(sessionId: "d1")) }
        }
        await h.start()
        #expect(h.service.error != nil)
        await h.run(for: .seconds(120), step: .seconds(2))
        #expect(h.service.rows.map(\.sessionId).contains("d1"))
        #expect(h.service.forgotten.isEmpty)
    }

    @Test func aDeferredDeleteIsNotForgotten() async {
        let h = RegistryHarness(registry(RegistryStore(started: ["s9"])))
        await h.start()
        h.service.defer(
            DeferredDelete(
                sessionId: "s9", shortId: "aaaaaaaa", worktree: "/p/.claude/worktrees/w"))
        // The defer removed the row, but the session can come back.
        #expect(!h.service.rows.map(\.sessionId).contains("s9"))
        #expect(h.service.forgotten.isEmpty)
    }
}

@MainActor
@Suite("the registry service: rows that only an --all read lists", .testTimeLimit)
struct UnconfirmedRowTests {
    // The marks of the rows that an --all read added follow the turns of the lists in their lock,
    // not the wall clock. The wall clock steps back 3 s at 4.5 s. The active list of 4 s then
    // has a later wall time than the --all read of 5 s, which adds a new row with no pid. The row
    // stays listed until the active list of 6 s, whose turn is later, also lacks it.
    @Test func aStepBackOfTheWallClockKeepsANewRowOfTheAllListListed() async {
        var timing = RegistryTiming()
        timing.active = .seconds(2)
        timing.all = .seconds(5)
        let h = RegistryHarness(timing: timing, stepBack: (at: 4_500, by: 3_000)) {
            $0.all = { count in count >= 2 ? list(bg(pid: nil, status: .unknown)) : list() }
        }
        await h.start()
        await h.run(for: .seconds(5))
        #expect(h.deps.allCalls == [0, 5_000])
        #expect(h.deps.activeCalls == [0, 2_000, 4_000])
        let row = h.service.rows.first { $0.sessionId == "s1" }
        #expect(row?.state == .parked)
        #expect(row?.listedActive == true)
        await h.run(for: .seconds(1))
        #expect(h.deps.activeCalls == [0, 2_000, 4_000, 6_000])
        #expect(h.service.rows.first { $0.sessionId == "s1" }?.listedActive == false)
    }

    // The start reads the active list one time: the new row of the first --all list stays
    // unconfirmed. A check is one more poll of the active list, in the task of the caller. It
    // applies the list as a poll of the loop does, so the row is confirmed as not listed, and
    // the active loop keeps its times.
    @Test func aCheckPollsTheActiveListOneTimeAndTheLoopKeepsItsTimes() async {
        let h = RegistryHarness { $0.all = { _ in list(bg(pid: nil, status: .unknown)) } }
        await h.start()
        #expect(h.deps.activeCalls == [0])
        #expect(h.deps.allCalls == [0])
        #expect(h.service.rows.first?.listing == .unconfirmed)
        #expect(await h.service.checkActive() == .applied)
        #expect(h.deps.activeCalls == [0, 0])
        #expect(h.service.rows.first?.listing == .notListed)
        await h.run(for: .seconds(2))
        #expect(h.deps.activeCalls == [0, 0, 2_000])
    }

    // A check whose poll fails keeps the rows and the mark, and gives the reason. The error of
    // the registry shows it, as for a failed poll of the loop.
    @Test func aFailedCheckKeepsTheMarkAndGivesTheReason() async {
        let h = RegistryHarness {
            $0.all = { _ in list(bg(pid: nil, status: .unknown)) }
            $0.active = { count in count == 2 ? failed("boom") : list() }
        }
        await h.start()
        #expect(await h.service.checkActive() == .failed(.commandFailed(detail: "boom")))
        #expect(h.service.rows.first?.listing == .unconfirmed)
        #expect(h.service.error == .commandFailed(detail: "boom"))
    }

    // A check during a poll of the loop waits for its turn in the lock of the lists, so only one
    // claude agents runs at a time, and its turn comes after that poll.
    @Test func aCheckDuringAPollWaitsForItsTurn() async {
        let h = RegistryHarness { $0.all = { _ in list(bg(pid: nil, status: .unknown)) } }
        await h.start()
        h.deps.held = [.active]
        h.clock.advance(by: .seconds(2))
        await waitUntil { h.deps.waitingCalls == 1 }
        let check = Task { await h.service.checkActive() }
        await waitUntil { h.service.queuedLists == 1 }
        #expect(h.deps.activeCalls == [0, 2_000])
        await h.release(.active)
        #expect(await check.value == .applied)
        #expect(h.deps.activeCalls == [0, 2_000, 2_000])
        #expect(h.deps.mostLists == 1)
        #expect(h.service.rows.first?.listing == .notListed)
    }

    // A stop also ends a check that waits for its turn in the lock of the lists. The check runs
    // in the task of its caller, and nothing cancels that task. The check ends at the stop with
    // no run of claude agents, and the poll of the loop that held the lock changes nothing.
    @Test func aStopEndsACheckThatWaitsForItsTurn() async {
        let h = RegistryHarness { $0.all = { _ in list(bg(pid: nil, status: .unknown)) } }
        await h.start()
        h.deps.held = [.active]
        h.clock.advance(by: .seconds(2))
        await waitUntil { h.deps.waitingCalls == 1 }
        let check = Task { await h.service.checkActive() }
        await waitUntil { h.service.queuedLists == 1 }
        let rows = h.service.rows
        h.service.stop()
        h.deps.release(.active)
        #expect(await check.value == .ended)
        await waitUntil { h.service.awake == 0 }
        #expect(h.deps.activeCalls == [0, 2_000])
        #expect(h.service.rows == rows)
        #expect(h.service.rows.first?.listing == .unconfirmed)
        #expect(h.service.error == nil)
    }

    // A stop during the list of a check: the list comes after the stop, and the registry does
    // not apply it. The row stays unconfirmed, and the check ends.
    @Test func aListThatComesAfterTheStopChangesNothing() async {
        let h = RegistryHarness {
            $0.all = { _ in list(bg(pid: nil, status: .unknown)) }
            $0.active = { count in count == 2 ? failed("boom") : list() }
        }
        await h.start()
        h.deps.held = [.active]
        let check = Task { await h.service.checkActive() }
        await waitUntil { h.deps.waitingCalls == 1 }
        let rows = h.service.rows
        h.service.stop()
        h.deps.release(.active)
        #expect(await check.value == .ended)
        #expect(h.deps.activeCalls == [0, 0])
        #expect(h.service.rows == rows)
        #expect(h.service.error == nil)
    }

    // No check runs before the start or after the stop of the registry.
    @Test func noCheckRunsBeforeTheStartOrAfterTheStop() async {
        let h = RegistryHarness()
        #expect(await h.service.checkActive() == .ended)
        #expect(h.deps.activeCalls.isEmpty)
        await h.start()
        h.service.stop()
        #expect(await h.service.checkActive() == .ended)
        #expect(h.deps.activeCalls == [0])
    }
}

@MainActor
@Suite("the registry service: live lines", .testTimeLimit)
struct RegistryLiveTests {
    @Test func aStateEventShowsAtOnce() async {
        let h = await ready()
        #expect(h.service.rows.first?.alert.colour == AlertColour.none)
        #expect(h.service.liveCount == 0)
        h.service.pushLive(.state(HookEvent(.stop, "s1", at: epoch)))
        let row = h.service.rows.first
        #expect(row?.alert.colour == .yellow)
        #expect(row?.alert.flashes == true)
        #expect(row?.live == true)
        #expect(h.service.liveCount == 1)
    }

    @Test func aUsageLineShowsAtOnceAndIsNoActivity() async {
        let h = await ready()
        h.service.pushLive(.usage(sessionId: "s1", at: epoch, LiveUsage(costUsd: 0.42)))
        let row = h.service.rows.first
        #expect(row?.usage?.costUsd == 0.42)
        #expect(row?.live == true)
        #expect(row?.lastActivity == 1)
    }

    // Each state event goes to the stream after the registry applied it, with the row ID of its
    // session. A usage line gives no event. The stream ends at the stop.
    @Test func theEventStreamGetsEachStateEventWithTheRowID() async {
        // A /clear in a job: the session ID changes, the short ID stays.
        let h = RegistryHarness { $0.active = { n in list(n == 1 ? bg() : bg(sessionId: "s2")) } }
        await h.start()
        await h.run(for: .seconds(2))
        #expect(h.service.rows.map { "\($0.sessionId) \($0.currentId ?? "")" } == ["s1 s2"])
        var events = h.service.events.makeAsyncIterator()
        h.service.pushLive(.state(HookEvent(.stop, "s2", at: epoch)))
        h.service.pushLive(.usage(sessionId: "s2", at: epoch, LiveUsage(costUsd: 0.42)))
        // A session that is not a row yet also gives its event.
        h.service.pushLive(.state(HookEvent(.userPromptSubmit, "new", at: epoch)))
        h.service.stop()
        var told = HookEvent(.stop, "s2", at: epoch)
        told.sessionId = "s1"
        #expect(await events.next(isolation: #isolation) == told)
        #expect(h.service.rows.first?.alert.colour == .yellow)
        #expect(
            await events.next(isolation: #isolation)
                == HookEvent(.userPromptSubmit, "new", at: epoch))
        #expect(await events.next(isolation: #isolation) == nil)
    }

    @Test func clearLiveEndsTheLiveFlagsAndKeepsTheUsage() async {
        let h = await ready()
        h.service.pushLive(.usage(sessionId: "s1", at: epoch, LiveUsage(costUsd: 0.42)))
        #expect(h.service.liveCount == 1)
        h.service.clearLive()
        #expect(h.service.liveCount == 0)
        #expect(h.service.rows.first?.live == false)
        #expect(h.service.rows.first?.usage?.costUsd == 0.42)
    }

    @Test func theLiveCountFollowsTheTick() async {
        let h = await ready()
        h.service.pushLive(.usage(sessionId: "s1", at: epoch, LiveUsage(costUsd: 0.42)))
        #expect(h.service.liveCount == 1)
        await h.run(for: .seconds(91), step: .seconds(7))
        #expect(h.service.liveCount == 0)
        #expect(h.service.rows.first?.live == false)
    }
}

@MainActor
@Suite("the registry service: the newest rate limits", .testTimeLimit)
struct RegistryRateLimitTests {
    private let limits = RateLimits(sevenDay: RateWindow(usedPercent: 15, resetsAt: 9_000_000))

    @Test func theRateLimitsChangeAtOnceAndOnlyWithANewValue() async {
        let h = await ready()
        #expect(h.service.usage == nil)
        let usage = Recorder(following: Observations { h.service.usage })
        await waitUntil { usage.values.count == 1 }
        h.service.pushLive(.usage(sessionId: "s1", at: epoch, LiveUsage(rateLimits: limits)))
        #expect(
            h.service.usage
                == UsageSnapshot(sessionId: "s1", name: "alpha", updatedAt: epoch, limits: limits))
        await waitUntil { usage.values.count == 2 }
        // The same line again changes nothing. A line with no rate limits changes nothing.
        h.service.pushLive(.usage(sessionId: "s1", at: epoch, LiveUsage(rateLimits: limits)))
        h.service.pushLive(.usage(sessionId: "s2", at: epoch + 10, LiveUsage(costUsd: 0.1)))
        await h.run(for: .seconds(1))
        // A newer line with the same limits changes the time. It is the marker: the lines
        // before it gave no value.
        h.service.pushLive(
            .usage(sessionId: "s1", at: epoch + 30_000, LiveUsage(rateLimits: limits)))
        #expect(h.service.usage?.updatedAt == epoch + 30_000)
        await waitUntil { usage.values.count >= 3 }
        #expect(usage.values.count == 3)
    }

    // Only a session of the session list gives rate limits, so a line of another program cannot
    // set the windows of the plan. Its line changes no row.
    @Test func theRateLimitsOfASessionWithNoRowDoNotCount() async {
        let h = await ready()
        let rows = Recorder(following: Observations { h.service.rows })
        await waitUntil { rows.values.count == 1 }
        h.service.pushLive(.usage(sessionId: "s2", at: epoch, LiveUsage(rateLimits: limits)))
        #expect(h.service.usage == nil)
        // The change of the priority is the marker: the rate limits gave no value of the rows.
        #expect(h.service.setPriority("s1", .p2))
        await waitUntil { rows.values.count >= 2 }
        #expect(rows.values.count == 2)
    }

    // A flood of lines in one batch makes one rebuild of the values. The lines of session IDs
    // with no row keep at most 256 IDs and 1,000 waiting events. The flood has more state events
    // and more new session IDs than these limits. The service runs on the main actor, and in a
    // debug build each line of a flood takes about 0.1 ms. So this flood stays small: a flood of
    // 10,000 lines holds the main actor for more than a second. The model tests send 20,000
    // lines to the registry off the main actor.
    @Test func aFloodOfLinesIsOneChangeAndKeepsALimitedNumberOfUnknownSessions() async {
        let h = await ready()
        let before = h.service.changes
        let count = 2 * (SessionRegistry.maxPendingEvents + 100)
        let lines = (0..<count).map { n -> LiveEvent in
            n.isMultiple(of: 2)
                ? .state(HookEvent(.userPromptSubmit, "x\(n)", at: epoch + n))
                : .usage(sessionId: "x\(n)", at: epoch + n, LiveUsage(costUsd: 1))
        }
        h.service.pushLive(lines)
        #expect(h.service.changes == before + 1)
        #expect(h.service.rows.map(\.sessionId) == ["s1"])
        #expect(h.service.liveCount == 0)
        // A row that shows gets no line of a session that went out.
        h.service.pushLive(.state(HookEvent(.stop, "s1", at: epoch + 10_001)))
        #expect(h.service.rows.first?.state == .needsYou)
    }

    @Test func aForgetRemovesTheRateLimitsAtOnce() async {
        let h = await ready()
        h.service.pushLive(.usage(sessionId: "s1", at: epoch, LiveUsage(rateLimits: limits)))
        #expect(h.service.usage != nil)
        h.service.forget("s1")
        #expect(h.service.usage == nil)
    }

    @Test func aNewRowNameRenamesTheRateLimits() async {
        let h = RegistryHarness { $0.active = { n in list(bg(name: n == 1 ? "alpha" : "beta")) } }
        await h.start()
        h.service.pushLive(.usage(sessionId: "s1", at: epoch, LiveUsage(rateLimits: limits)))
        #expect(h.service.usage?.name == "alpha")
        await h.run(for: .seconds(2))
        #expect(h.service.usage?.name == "beta")
    }
}
