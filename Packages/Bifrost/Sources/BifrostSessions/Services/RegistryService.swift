import BifrostFoundation
import Foundation
import Observation

// The times of the loops of the registry service.
package struct RegistryTiming: Sendable, Equatable {
    // The wait between two active polls while the window is visible. The settings set it.
    package var active = Duration.seconds(2)
    package var all = Duration.seconds(30)
    package var branch = Duration.seconds(10)
    package var tick = Duration.seconds(1)

    package init() {}

    package static let standard = RegistryTiming()

    // The wait between two active polls while the window is not visible.
    package static let hiddenPoll = Duration.seconds(15)

    // A visible window uses the normal wait. A window that is not visible uses at least 15
    // seconds.
    package static func pollInterval(_ normal: Duration, visible: Bool) -> Duration {
        visible ? normal : max(normal, hiddenPoll)
    }
}

package enum RowWaitError: Error, Equatable, Sendable {
    case timeout, stopped, cancelled
}

// The end of a check of the active list (RegistryService.checkActive).
package enum ActiveCheck: Sendable, Equatable {
    // The poll gave a list, and the registry applied it.
    case applied
    // The poll gave no list. The rows stay as they were.
    case failed(AgentListError)
    // The registry did not run, it stopped, or the caller was cancelled. The poll changed nothing.
    case ended
}

// A failed call of a dependency, with its message.
package struct RegistryFailure: MessageError, Equatable, Sendable {
    package var message: String

    package init(_ message: String) {
        self.message = message
    }
}

// The service reads all data and does all writes through these calls.
package protocol RegistryServiceDeps: Sendable {
    func listActive() async throws -> AgentList
    func listAll() async throws -> AgentList
    func readBranch(_ cwd: String) async throws -> String?
    func readTerminalApps(_ pids: [pid_t]) async -> TerminalApps
    // The "claude attach" clients in terminals (ProcessInspector.attachClients), with no attach
    // of this app.
    func readAttachClients() async -> [AttachClient]
    func saveStore(_ store: RegistryStore) async throws
}

// The registry service of the app. It keeps the session registry on the main actor and runs four
// loops as tasks on the injected clock:
// - The active loop runs "claude agents --json", then it waits the poll interval. While the
//   window is not visible, the wait is 15 s or more. A window that shows ends the wait, and the
//   next poll runs at once.
// - The --all loop runs "claude agents --json --all" every 30 s.
// - The branch loop reads the branch of each folder, one folder at a time, every 10 s.
// - The tick applies the time rules of the registry every second.
// The other three loops start when the first active poll ends, so they use real rows. Only one
// "claude agents" process runs at a time.
//
// After each change, the service saves the store (one save at a time) and sets its observable
// values at once: the rows, the error, the rate limits and the live count. A value that does not
// change notifies no observer. stop() cancels every task. After a stop, nothing changes.
//
// The health log of the app (HealthReporter) gets the result of each active poll, and the first
// failed save of each series of failed saves.
@MainActor
@Observable
package final class RegistryService {
    // The rows after the last change.
    package private(set) var rows: [SessionRow] = []
    // The error of the last active poll. A failed poll keeps the rows. A good poll clears it.
    package private(set) var error: AgentListError?
    // True when the first active poll ended. Until then, the session list waits.
    package private(set) var loaded = false
    // The newest rate limits of all sessions.
    package private(set) var usage: UsageSnapshot?
    // The number of rows that are live and not parked.
    package private(set) var liveCount = 0
    // The turn of the last active list that the registry applied, or 0 before the first one. Each
    // run of claude agents takes the next turn in the lock of the lists (startedLists). A wait
    // that must know that a list came after a time reads it.
    package private(set) var appliedListTurn = 0
    // The row IDs that Bifrost forgot for good in this run: a Delete, or a session that two
    // counted --all lists did not have. A deferred delete is not in the set, because the session
    // can come back.
    package private(set) var forgotten: Set<String> = []
    // Each state event of the Live details mod, after the registry applied it, with the row ID as
    // its session ID. A usage line and a prompt line give no event. The stream has one reader.
    // With no reader, it keeps the newest 1000 events. It ends at stop().
    package let events: AsyncStream<HookEvent>

    private enum Phase {
        case waiting, running, stopped
    }

    // A call of waitForRow or waitForRows that waits for a change. ended gives the rows to the
    // wait: when they end it, it resumes the caller and gives true. fail resumes the caller with
    // the error.
    private struct RowWait {
        let id: UUID
        let ended: ([SessionRow]) -> Bool
        let fail: (RowWaitError) -> Void
        let timer: Task<Void, Never>
    }

    private let deps: any RegistryServiceDeps
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    private let timing: RegistryTiming
    private let log: any SessionsLog
    private let health: HealthReporter
    private let sendEvent: AsyncStream<HookEvent>.Continuation
    // Only one "claude agents" process runs at a time.
    private let lists = OneAtATime()
    @ObservationIgnored private var registry: SessionRegistry
    @ObservationIgnored private var phase = Phase.waiting
    @ObservationIgnored private var loops: [Task<Void, Never>] = []
    // The wait of the active loop while it waits. A window that shows cancels it.
    @ObservationIgnored private var activeWait: Task<Void, Never>?
    @ObservationIgnored private var windowVisible = true
    @ObservationIgnored private var tableRead: Task<Void, Never>?
    @ObservationIgnored private var save: Task<Void, Never>?
    // The store of the last good save, or the store at the start. A store that differs needs a
    // save.
    @ObservationIgnored private var saved: RegistryStore
    @ObservationIgnored private var saveFailed = false
    // The errors of the loops and the failed lists that the log has. At most 20. A failed list
    // counts by its reason, with no detail (logOnce).
    @ObservationIgnored private var loggedErrors: Set<SessionsLogEvent> = []
    @ObservationIgnored private var rowWaits: [RowWait] = []
    // The wait between two active polls of a visible window. The next wait uses a new value.
    @ObservationIgnored private(set) var activeInterval: Duration
    // The sleeps on the clock that run now. A test waits until the clock has each of them.
    @ObservationIgnored private(set) var sleeps = 0
    // The tasks of the service that are not in a sleep on the clock: a task counts from its start
    // to its end, except during a sleep. A task that waits for a call of a dependency or for its
    // turn to list also counts. The wait of the active poll is a part of the active loop. A test
    // waits until each of these tasks waits at a point that the test controls.
    @ObservationIgnored private(set) var awake = 0
    // The list calls that wait for their turn.
    var queuedLists: Int { lists.waiting }
    // The count of the runs of claude agents that started (active and --all lists). A list that
    // starts later has a higher turn.
    package var startedLists: Int { lists.started }
    // The number of rebuilds of the values (changed()). A test counts the rebuilds of a batch.
    @ObservationIgnored private(set) var changes = 0

    // now gives the wall time. The registry keeps a wall time as milliseconds since 1970 (row D1
    // of docs/ports/registry), so the service makes the milliseconds at each call of the
    // registry. Only AppServices makes the service. health gets the results of the active polls
    // and the failed saves.
    package init(
        registry: SessionRegistry, deps: any RegistryServiceDeps, clock: any Clock<Duration>,
        now: @escaping @Sendable () -> Date = Date.init, timing: RegistryTiming = .standard,
        log: any SessionsLog = SystemSessionsLog(), health: HealthReporter = .none
    ) {
        self.registry = registry
        saved = registry.store()
        self.deps = deps
        self.clock = clock
        self.now = now
        self.timing = timing
        self.log = log
        self.health = health
        activeInterval = timing.active
        (events, sendEvent) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1000))
    }

    // MARK: - Start and stop

    // Start the active loop. A second call, and a call after stop(), do nothing.
    package func start() {
        guard phase == .waiting else { return }
        phase = .running
        loops = [task { await self.activeLoop() }]
    }

    // Stop each loop, each check and each wait for a row. A result that comes later changes
    // nothing. A save that runs ends normally, and no new save starts.
    package func stop() {
        phase = .stopped
        for loop in loops { loop.cancel() }
        loops = []
        // A check of a command (checkActive) runs in the task of its caller, so no cancel
        // reaches it. The close ends it when it waits for its turn.
        lists.close()
        for wait in rowWaits { endWait(wait.id, with: .stopped) }
        sendEvent.finish()
    }

    // True while a save of the store runs. A test waits for the end of the last save before it
    // removes the folder of the store.
    var isSaving: Bool { save != nil }

    // MARK: - The settings and the window

    // The wait between two active polls. The next wait uses it.
    package func setActiveInterval(_ interval: Duration) { activeInterval = interval }

    // The time from a yellow box to red (SessionRegistry.setEscalation). The next tick uses it.
    // 0 stops the escalation.
    package func setEscalation(_ escalation: Duration) { registry.setEscalation(escalation) }

    var escalation: Duration { registry.escalation }

    // A window that is not visible makes the active poll wait 15 s or more. When the window
    // shows, a wait in progress ends and the poll runs at once.
    package func setWindowVisible(_ visible: Bool) {
        guard visible != windowVisible else { return }
        windowVisible = visible
        if visible { activeWait?.cancel() }
    }

    // MARK: - The loops

    private func activeLoop() async {
        while !Task.isCancelled {
            guard await pollActive() else { return }
            await waitForActivePoll()
        }
    }

    // One active poll. A failed poll keeps the rows, sets the error and logs its detail. A failed
    // call of the dependency is a failed run of claude. The health log gets the result. The first
    // poll that ends loads the list and starts the other loops. False when a stop, or a cancel of
    // the task, came during the poll: then the poll changes nothing.
    private func pollActive() async -> Bool {
        guard let run = await runList({ try await deps.listActive() }), !Task.isCancelled,
            phase == .running
        else { return false }
        let list: AgentList
        switch run.result {
        case .success(let value): list = value
        case .failure(let failure): list = .failed(.commandFailed(detail: failure.message))
        }
        switch list {
        case .parsed(let entries, _):
            registry.applyAgents(entries, sampledAt: run.startedAt, turn: run.turn)
            appliedListTurn = run.turn
            error = nil
            readTerminals()
            health.record(.poll(.sessions, .ok))
        case .failed(let reason):
            error = reason
            logOnce(.agentListFailed(reason))
            health.record(.poll(.sessions, .failed))
        }
        let first = !loaded
        loaded = true
        changed()
        if first {
            loops += [
                task { await self.allLoop() },
                task { await self.branchLoop() },
                task { await self.tickLoop() },
            ]
        }
        return true
    }

    // Wait the poll interval: 15 s or more while the window is not visible. A window that shows
    // ends the wait at once. A stop also ends it.
    private func waitForActivePoll() async {
        let interval = RegistryTiming.pollInterval(activeInterval, visible: windowVisible)
        let wait = Task { _ = await self.sleep(for: interval) }
        activeWait = wait
        await withTaskCancellationHandler {
            await wait.value
        } onCancel: {
            wait.cancel()
        }
        activeWait = nil
    }

    // A failed run and a failed list change nothing, so a failed read never counts for the forget
    // of a gone session. A failed run is a loop error. The log gets the detail of a failed list.
    private func allLoop() async {
        repeat {
            if Task.isCancelled { return }
            guard let run = await runList({ try await deps.listAll() }), !Task.isCancelled else {
                return
            }
            switch run.result {
            case .failure(let failure):
                logOnce(.registryLoopFailed(message: failure.message))
            case .success(.parsed(let entries, let partial)):
                let gone = registry.applyAllAgents(entries, complete: !partial, turn: run.turn)
                if !gone.isEmpty { forgotten.formUnion(gone) }
                changed()
            case .success(.failed(let reason)):
                logOnce(.agentListFailed(reason))
            }
        } while await sleep(for: timing.all)
    }

    // The branch of each folder, one read at a time. A failed read ends the round. The next
    // round tries again. A round that changed no branch rebuilds nothing.
    private func branchLoop() async {
        repeat {
            if Task.isCancelled { return }
            var branchChanged = false
            do {
                for cwd in registry.cwds() {
                    let branch = try await deps.readBranch(cwd)
                    if Task.isCancelled { return }
                    if registry.applyBranch(cwd, branch) { branchChanged = true }
                }
            } catch {
                if Task.isCancelled { return }
                logOnce(.registryLoopFailed(message: ErrorText.of(error)))
            }
            if branchChanged { changed() }
        } while await sleep(for: timing.branch)
    }

    // The time rules of the registry: the escalation of a box, the end of the live time, and the
    // end of old events and of the grace time of lastActive. A tick that changed nothing
    // rebuilds nothing, unless a failed save waits for its next try.
    private func tickLoop() async {
        repeat {
            if Task.isCancelled { return }
            if registry.tick(now: nowMs()) || saveFailed { changed() }
        } while await sleep(for: timing.tick)
    }

    // A run of "claude agents": its result, the wall time at its start, and its turn in the lock
    // of the lists. The turns go up in the order of the runs, also when the wall clock steps
    // back, so the registry orders the lists by their turns (SessionRegistry.unconfirmed).
    private struct ListRun {
        let result: Result<AgentList, RegistryFailure>
        let startedAt: Int
        let turn: Int
    }

    // Run one list call in the lock of the lists. The start time and the turn come from inside
    // the lock, after the wait. nil when a stop cancelled the task during its wait.
    private func runList(_ call: () async throws -> AgentList) async -> ListRun? {
        try? await lists.run { turn in
            let startedAt = nowMs()
            return ListRun(result: await outcome(call), startedAt: startedAt, turn: turn)
        }
    }

    // Start a task of the service. It counts in awake until it ends.
    private func task(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        awake += 1
        return Task {
            defer { awake -= 1 }
            await work()
        }
    }

    // Sleep on the clock. False when the task was cancelled.
    private func sleep(for duration: Duration) async -> Bool {
        sleeps += 1
        awake -= 1
        defer {
            sleeps -= 1
            awake += 1
        }
        do {
            try await clock.sleep(for: duration)
        } catch {
            return false
        }
        // A sleep can end after the cancel of its task.
        return !Task.isCancelled
    }

    // After each good active poll, read the terminal apps, one read at a time: the apps of the
    // PIDs of new external rows, and the "claude attach" clients of the owned rows. The read of
    // a PID walks only its parents, and a PID that the read cannot see gets no app. The scan of
    // the attach clients runs at each poll while the registry has an owned session, because a
    // client can start or end at any time. It reads few processes (attachClients), and it uses
    // the time of the poll, so it adds no timer. The rows change only when an app changed.
    private func readTerminals() {
        let pids = registry.pidsWithoutTerminal()
        let scan = registry.hasOwnedSession
        guard tableRead == nil, !pids.isEmpty || scan else { return }
        tableRead = task { [self] in
            let apps = pids.isEmpty ? nil : await deps.readTerminalApps(pids)
            let clients = scan ? await deps.readAttachClients() : nil
            tableRead = nil
            guard phase != .stopped else { return }
            var rowsChanged = false
            if let apps {
                registry.applyTerminals(apps)
                rowsChanged = true
            }
            if let clients, registry.applyAttachClients(clients) { rowsChanged = true }
            if rowsChanged { changed() }
        }
    }

    // Log an error of a loop or a failed list one time. Log at most 20 errors. A failed list
    // counts by its reason, with no detail. The stderr of claude can change at each run, and then
    // the failed lists would fill the 20 and stop the log of a later loop error. So the failed
    // lists take at most six of the 20, and the log gets the detail of the first failure of each
    // reason.
    private func logOnce(_ event: SessionsLogEvent) {
        var key = event
        if case .agentListFailed(let error) = event { key = .agentListFailed(error.withoutDetail) }
        guard !loggedErrors.contains(key), loggedErrors.count < 20 else { return }
        loggedErrors.insert(key)
        log.record(event)
    }

    // MARK: - Changes and saves

    // Call this after each change of the registry. It saves the store when the store changed,
    // sets the observable values, and ends each wait that the rows end, also with no row.
    private func changed() {
        changes += 1
        saveStore()
        rows = registry.rows()
        usage = registry.usage()
        liveCount = registry.liveCount()
        for wait in rowWaits where wait.ended(rows) { removeWait(wait.id) }
    }

    // Save the newest store when it differs from the last saved store. Only one save runs at a
    // time: a change during a save saves again when that save ends. A failed save does not stop
    // the service: the next call of changed() tries again (the tick makes one each second while
    // a save failed). The log and the health log get only the first failure of a series.
    private func saveStore() {
        guard phase != .stopped, save == nil else { return }
        let store = registry.store()
        guard store != saved else { return }
        save = task { [self] in
            let result = await outcome { try await deps.saveStore(store) }
            save = nil
            // A save that ends after the stop changes nothing more.
            guard phase != .stopped else { return }
            switch result {
            case .success:
                saved = store
                saveFailed = false
                saveStore()
            case .failure(let failure):
                if !saveFailed {
                    log.record(.registryStoreSaveFailed(message: failure.message))
                    health.record(.saveFailed(what: StoreFile.what))
                }
                saveFailed = true
            }
        }
    }

    // The wall time of now in milliseconds since 1970, the form of the registry (row D1).
    private func nowMs() -> Int { now().millisecondsSince1970 }

    // MARK: - Commands

    // Poll the active list now, for a command that needs a row that only an --all read lists
    // (ActiveListing.unconfirmed). The check is a poll of the active loop (pollActive) in the
    // caller's task: it waits for its turn in the lock of the lists, so its turn comes after the
    // --all read that listed the row, and the registry applies its list as it applies each poll.
    // The active loop keeps its times. Only one claude agents runs at a time, so a check during
    // a poll waits for the end of that poll.
    package func checkActive() async -> ActiveCheck {
        guard phase == .running, await pollActive(), phase == .running else { return .ended }
        return error.map(ActiveCheck.failed) ?? .applied
    }

    // The first row that matches, now or after a change. Throws RowWaitError.timeout after the
    // timeout, RowWaitError.stopped at the stop, and RowWaitError.cancelled when the caller is
    // cancelled.
    package func waitForRow(
        timeout: Duration, where match: @escaping (SessionRow) -> Bool
    ) async throws(RowWaitError) -> SessionRow {
        try await wait(timeout: timeout) { $0.first(where: match) }
    }

    // Wait until the rows match, now or after a change. The match gets all the rows, so it can
    // also match a change that leaves no row. The errors are those of waitForRow.
    package func waitForRows(
        timeout: Duration, until match: @escaping ([SessionRow]) -> Bool
    ) async throws(RowWaitError) {
        try await wait(timeout: timeout) { match($0) ? () : nil }
    }

    // The value that the rows give, now or after a change. A value of nil waits for the next
    // change.
    private func wait<Value: Sendable>(
        timeout: Duration, for value: @escaping ([SessionRow]) -> Value?
    ) async throws(RowWaitError) -> Value {
        if phase == .stopped { throw .stopped }
        if Task.isCancelled { throw .cancelled }
        if let now = value(rows) { return now }
        let id = UUID()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation {
                (resume: CheckedContinuation<Result<Value, RowWaitError>, Never>) in
                let timer = task {
                    if await self.sleep(for: timeout) { self.endWait(id, with: .timeout) }
                }
                let ended = { (rows: [SessionRow]) -> Bool in
                    guard let found = value(rows) else { return false }
                    resume.resume(returning: .success(found))
                    return true
                }
                rowWaits.append(
                    RowWait(
                        id: id, ended: ended, fail: { resume.resume(returning: .failure($0)) },
                        timer: timer))
            }
        } onCancel: {
            // This can run before the wait exists. The hop to the main actor runs after the
            // wait is there, and endWait ignores an ID that is gone.
            Task { @MainActor in self.endWait(id, with: .cancelled) }
        }
        return try result.get()
    }

    // End the wait with the error. An ID that is gone changes nothing.
    private func endWait(_ id: UUID, with error: RowWaitError) {
        removeWait(id)?.fail(error)
    }

    // Remove the wait and stop its timer. The result is the wait, or nil for an ID that is gone.
    @discardableResult
    private func removeWait(_ id: UUID) -> RowWait? {
        guard let index = rowWaits.firstIndex(where: { $0.id == id }) else { return nil }
        let wait = rowWaits.remove(at: index)
        wait.timer.cancel()
        return wait
    }

    // Apply one line of the mod.
    package func pushLive(_ line: LiveEvent) { pushLive([line]) }

    // Apply a batch of lines of the mod in their order, then rebuild the values one time. So a
    // flood of lines makes one change for each batch. Each state event goes to events after the
    // registry applied it, with the row ID of its session.
    package func pushLive(_ lines: [LiveEvent]) {
        guard phase != .stopped, !lines.isEmpty else { return }
        var told: [HookEvent] = []
        for line in lines {
            switch line {
            case .state(let event):
                registry.applyEvents([event], now: nowMs())
                var event = event
                event.sessionId = registry.rowIdOf(event.sessionId)
                told.append(event)
            case .usage(let sessionId, let at, let usage):
                registry.applyUsage(sessionId, usage, at: at)
            case .prompt(let sessionId, let at, let person):
                registry.applyPrompt(sessionId, person: person, at: at)
            }
        }
        changed()
        for event in told { sendEvent.yield(event) }
    }

    // End the live flag of each row. The usage stays.
    package func clearLive() { apply { $0.clearLive() } }

    package func forget(_ sessionId: String) {
        if apply({ $0.forget(sessionId) }) { forgotten.insert(sessionId) }
    }

    package func markStarted(_ sessionId: String) { apply { $0.markStarted(sessionId) } }
    package func markPrSession(_ sessionId: String) { apply { $0.markPrSession(sessionId) } }
    package func expectPrSession(_ name: String) { apply { $0.expectPrSession(name) } }
    package func releasePrSession(_ name: String) { apply { $0.releasePrSession(name) } }
    package func markStopped(_ sessionId: String) { apply { $0.markStopped(sessionId) } }

    // A defer removes a row until the delete goes or the session runs again.
    package func `defer`(_ entry: DeferredDelete) {
        let at = nowMs()
        apply { $0.defer(entry, at: at) }
    }

    package func undefer(_ sessionId: String) { apply { $0.undefer(sessionId) } }
    package func dropDeferred(_ sessionId: String) { apply { $0.dropDeferred(sessionId) } }

    // These commands give false for an unknown session or a bad value, and change nothing.
    package func setAlias(_ sessionId: String, _ name: String?) -> Bool {
        command { $0.setAlias(sessionId, name) }
    }

    package func setPriority(_ sessionId: String, _ priority: SessionPriority?) -> Bool {
        command { $0.setPriority(sessionId, priority) }
    }

    package func watchAdd(_ sessionId: String, _ colour: WatchColour) -> Bool {
        command { $0.watchAdd(sessionId, colour) }
    }

    package func watchRemove(_ sessionId: String) -> Bool {
        command { $0.watchRemove(sessionId) }
    }

    package func watchColour(_ sessionId: String, _ colour: WatchColour) -> Bool {
        command { $0.watchColour(sessionId, colour) }
    }

    package func watchMove(_ sessionId: String, before: String?) -> Bool {
        command { $0.watchMove(sessionId, before: before) }
    }

    package func carryOver(from: String, to: String) -> Bool {
        command { $0.carryOver(from: from, to: to) }
    }

    package func rememberWorktree(_ sessionId: String, _ path: String) -> Bool {
        command { $0.rememberWorktree(sessionId, path) }
    }

    // Apply a change to the registry. False after a stop: then nothing changes.
    @discardableResult
    private func apply(_ change: (inout SessionRegistry) -> Void) -> Bool {
        command { registry in
            change(&registry)
            return true
        }
    }

    // Apply a change to the registry that can fail. False for a failed change and after a stop.
    private func command(_ change: (inout SessionRegistry) -> Bool) -> Bool {
        guard phase != .stopped, change(&registry) else { return false }
        changed()
        return true
    }

    // MARK: - Queries

    package func deferredIn(_ worktree: String) -> [DeferredDelete] {
        registry.deferredIn(worktree)
    }

    package func terminalOf(_ sessionId: String) -> TerminalApp? {
        registry.terminalOf(sessionId)
    }
}

extension AgentListError {
    // The same reason with no detail. The log counts a failed list by its reason.
    fileprivate var withoutDetail: AgentListError {
        switch self {
        case .badJSON: .badJSON(detail: "")
        case .commandFailed: .commandFailed(detail: "")
        case .emptyOutput, .noArray, .notAnArray, .claudeNotFound: self
        }
    }
}

// The result of a call of a dependency. An error gives a failure with the text of the error.
private func outcome<T>(_ call: () async throws -> T) async -> Result<T, RegistryFailure> {
    do {
        return .success(try await call())
    } catch {
        return .failure(RegistryFailure(ErrorText.of(error)))
    }
}

// Runs one job at a time, in the order of the calls. Each job gets the number of its turn: 1 for
// the first job, then 1 more for each next job.
@MainActor
private final class OneAtATime {
    private var busy = false
    private var closed = false
    private var queue: [CheckedContinuation<Void, Never>] = []
    private var turns = 0

    // The jobs that wait for their turn.
    var waiting: Int { queue.count }
    // The count of the jobs that got their turn.
    var started: Int { turns }

    // Run the job when the jobs before it ended. A job runs only when its task is not cancelled
    // and the lock is not closed at its turn. Else run throws, also for a call after close().
    func run<T>(_ job: (_ turn: Int) async -> T) async throws(CancellationError) -> T {
        if closed { throw CancellationError() }
        if busy {
            await withCheckedContinuation { queue.append($0) }
        } else {
            busy = true
        }
        // The turn goes to the next job of the queue. With no next job, the lock is free.
        defer {
            if queue.isEmpty { busy = false } else { queue.removeFirst().resume() }
        }
        if closed || Task.isCancelled { throw CancellationError() }
        turns += 1
        return await job(turns)
    }

    // Close the lock at the stop of the service. Each job that waits for its turn ends with no
    // run, also a job of a task that nothing cancelled. A job that runs now goes on to its end.
    func close() {
        closed = true
        let waiting = queue
        queue = []
        for job in waiting { job.resume() }
    }
}

// The dependencies of the app: the claude CLI, git, the process table and the store file. With no
// claude, the lists fail with claudeNotFound. The branch reader reads no HEAD file and
// runs no git in the folders of skipRoots. The process inspector reads the process table natively,
// with no program.
package struct RegistrySystemDeps: RegistryServiceDeps {
    let claude: ClaudeRunner?
    let runner: any CommandRunner
    let processes: any ProcessInspector
    let branches: BranchReader
    let saver: StoreSaver

    package init(
        claude: ClaudeRunner?, runner: any CommandRunner = ProcessRunner(), skipRoots: [String],
        saver: StoreSaver, processes: any ProcessInspector = SystemProcessInspector()
    ) {
        self.claude = claude
        self.runner = runner
        self.processes = processes
        self.saver = saver
        // git gets the env of the claude runs, so it is the git of the login PATH.
        branches = BranchReader(
            runner: runner, skipRoots: skipRoots, environment: claude?.environment)
    }

    private func list(all: Bool) async -> AgentList {
        guard let claude else { return .failed(.claudeNotFound) }
        return await listAgents(claude, all: all)
    }

    package func listActive() async throws -> AgentList { await list(all: false) }
    package func listAll() async throws -> AgentList { await list(all: true) }
    package func readBranch(_ cwd: String) async throws -> String? { await branches.read(cwd) }
    package func readTerminalApps(_ pids: [pid_t]) async -> TerminalApps {
        await processes.terminalApps(of: pids)
    }
    package func readAttachClients() async -> [AttachClient] {
        await processes.attachClients(own: getpid())
    }
    // The save writes the file and waits for a full sync, so it runs on the blocking executor.
    package func saveStore(_ store: RegistryStore) async throws {
        try await BlockingExecutor.run { [saver] () throws(RegistryFailure) in
            try saver.save(store)
        }
    }
}
