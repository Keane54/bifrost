// The harness of the tests of the session commands: the session commands on fake deps
// (FakeActionDeps), after the first lists of the registry, and the entries of the session lists.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostSessions

@MainActor
final class CommandHarness {
    let deps: FakeActionDeps
    let actions: SessionActions

    // projects: the projects folder of the transcript check, or nil for a path with no folder.
    // claude: a claude runner on the clock of the deps, or nil for the fake claude that runs no
    // program. processes and signals: the process reads and the signals of a test of a process
    // that the test started, or nil for the fakes. confirmAll: false keeps the new rows of the
    // first --all list unconfirmed (FakeActionDeps.start).
    init(
        store: RegistryStore = RegistryStore(), active: [AgentEntry] = [],
        all: [AgentEntry] = [], projects: URL? = nil,
        claude: ((ManualClock) -> ClaudeRunner)? = nil, processes: (any ProcessInspector)? = nil,
        signals: SystemSignals? = nil, confirmAll: Bool = true
    ) async {
        deps = FakeActionDeps(store: store, active: active, all: all)
        actions = deps.makeActions(
            claude: claude?(deps.clock), projects: projects, processes: processes,
            signals: signals)
        await deps.start(confirmAll: confirmAll)
    }

    var calls: FakeActionCalls { deps.calls }
    var clock: ManualClock { deps.clock }

    // Run the command as a job of its own, and give its result (see result(of:)).
    func run(
        _ command: SessionCommand, sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Result<ActionDone, ActionRefusal> {
        await result(of: start(command), sourceLocation: sourceLocation)
    }

    // Run Stop to its end. After claude stop, Stop waits for the park of its row. The lists of the
    // test do not change, so the clock moves past the limit of that wait (SessionActions.parkWait).
    func runStop(
        _ sessionId: String, sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Result<ActionDone, ActionRefusal> {
        let job = start(.stop(sessionId))
        await waitForSleepers(1, sourceLocation: sourceLocation)
        clock.advance(by: SessionActions.parkWait)
        return await result(of: job, sourceLocation: sourceLocation)
    }

    // Start the command as a job of its own. The test awaits its result later with result(of:).
    func start(_ command: SessionCommand) -> Task<Result<ActionDone, ActionRefusal>, Never> {
        Task {
            do throws(ActionRefusal) {
                return .success(try await actions.run(command))
            } catch {
                return .failure(error)
            }
        }
    }

    // The result of a job, within the limit on the real clock. The value of a task ignores a
    // cancel of the waiter, so a job that a defect holds would hold the whole run. At the limit
    // the wait records an issue and cancels the job, which then ends at once with cancelled.
    func result(
        of job: Task<Result<ActionDone, ActionRefusal>, Never>,
        within limit: Duration = testWaitLimit, sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Result<ActionDone, ActionRefusal> {
        let ended = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = await job.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return false
            }
            let first = await group.next() ?? false
            if !first { job.cancel() }
            group.cancelAll()
            return first
        }
        if !ended {
            Issue.record("The job did not end within \(limit).", sourceLocation: sourceLocation)
        }
        return await job.value
    }

    // True when a command logged its end.
    var anyEnded: Bool { !deps.log.values.isEmpty }

    // Wait until exactly this number of waits of the commands sleep on the clock, next to the
    // four loops of the registry. After a poll, the active loop sleeps again only in a new task,
    // so a test waits for the count and never reads it at once. The limit is the wide limit of
    // the test waits (testWaitLimit), because a test host under load can start a program late.
    func waitForSleepers(
        _ count: Int, within limit: Duration = testWaitLimit,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await clock.waitForSleepers(
            exactly: 4 + count, within: limit, sourceLocation: sourceLocation)
    }

    // Move the clock by step, count times, each time after a wait of the command sleeps.
    func advance(by step: Duration, times count: Int) async {
        for _ in 0..<count {
            await waitForSleepers(1)
            clock.advance(by: step)
        }
    }

    // The stored values of the registry after its last save.
    func store() async -> RegistryStore? {
        await waitUntil { !deps.registry.isSaving }
        return deps.lists.saves.last
    }

    func started() async -> Set<String> { await store()?.started ?? [] }

    // The row IDs of the registry now.
    var rowIds: [String] { deps.registry.rows.map(\.sessionId) }

    // The condition of a row that runs: the row ID is there and is not parked.
    nonisolated static func runs(_ id: String) -> ([SessionRow]) -> Bool {
        { rows in rows.contains { $0.sessionId == id && $0.state != .parked } }
    }
}

// The entries of the session lists.
enum Entry {
    // The short ID of the job of a session: the first 8 characters of its session ID.
    static func short(_ id: String) -> ShortID? { ShortID(id.prefix(8)) }

    // A background session of the active list: an owned row that runs.
    static func running(
        _ id: String, cwd: String = "/p", pid: pid_t? = 4242, status: AgentStatus = .idle,
        job: String? = nil, noShortId: Bool = false
    ) -> AgentEntry {
        AgentEntry(
            sessionId: id, cwd: cwd, isBackground: true, startedAt: 1, name: "bifrost-test-s",
            status: status, pid: pid, id: noShortId ? nil : short(job ?? id))
    }

    // A stopped background session of the --all list: a parked row.
    static func stopped(_ id: String, cwd: String = "/p", noShortId: Bool = false) -> AgentEntry {
        AgentEntry(
            sessionId: id, cwd: cwd, isBackground: true, startedAt: 1, name: "bifrost-test-s",
            id: noShortId ? nil : short(id))
    }

    // An interactive session in another terminal: an external row.
    static func interactive(
        _ id: String, cwd: String = "/p", pid: pid_t? = 4242, status: AgentStatus = .idle,
        waitingFor: String? = nil
    ) -> AgentEntry {
        AgentEntry(
            sessionId: id, cwd: cwd, startedAt: 1, name: "bifrost-test-x", status: status,
            pid: pid, waitingFor: waitingFor)
    }
}

@Suite("the job wait of the command harness", .timeLimit(.minutes(1)))
@MainActor
struct CommandHarnessTests {
    // A resume waits for a row that never shows. The wait records an issue at its limit, and the
    // job gives its cancelled end.
    @Test func aJobThatDoesNotEndIsCancelledAtTheLimitOfTheWait() async {
        let id = "f3a9c2d1-4b5e-4c6d-8e7f-0a1b2c3d4e5f"
        let c = await CommandHarness(all: [Entry.stopped(id)])
        let job = c.start(.resume(id))
        await c.waitForSleepers(1)
        var result: Result<ActionDone, ActionRefusal>?
        await withKnownIssue {
            result = await c.result(of: job, within: .milliseconds(100))
        }
        #expect(result == .failure(.cancelled))
        #expect(!c.actions.isRunning(id))
    }
}
