import Foundation


// The time from start to end of two times in milliseconds since 1970.
private func elapsed(from start: Int, to end: Int) -> Duration { .milliseconds(end - start) }

// The data that the registry keeps for one session. sessionId is the row ID: the first session ID
// that Bifrost saw for the session. It never changes.
struct Session {
    var sessionId: String
    var shortId: ShortID?
    // The original session ID of the job: the ID that a resume needs to wake the same job.
    var jobId: String?
    var kind: SessionKind = .owned
    var pid: pid_t?
    var cwd = ""
    var status = AgentStatus.unknown
    var waitingFor: String?
    var startedAt = 0
    // The time and the seq of the last applied state event, nil when no event came.
    var lastEventAt: Int?
    var lastEventSeq: Int?
    // The sample time of the last status change, nil when none came.
    var statusChangedAt: Int?
    // The sample time of the last busy sample of the session list, nil when none came.
    var lastBusyAt: Int?
    // The time of the last park. nil when the session never parked.
    var parkedAt: Int?
    var machine = MachineState.initial

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    // Copy the values of an entry.
    mutating func copy(_ entry: AgentEntry) {
        shortId = entry.id
        kind = entry.isBackground ? .owned : .external
        pid = entry.pid
        cwd = entry.cwd
        status = entry.status
        waitingFor = entry.waitingFor
        startedAt = entry.startedAt
    }
}

// The last usage line of a session. A line without rate limits keeps the rate limits of the
// session. limitsAt is the time of the line that had them.
struct UsageLine {
    var usage: LiveUsage
    var updatedAt: Int
    var limitsAt: Int?
}

// The run state of one row ID in this run of the app: the values of the list rules and the time
// rules that the store does not keep. A row ID can have run state and no session: a session of
// lastActive that does not run yet, a stored row that a counted --all list misses, or a deferred
// delete.
struct RowRun: Equatable {
    // The sample time when a session of lastActive was first not active.
    var inactiveSince: Int?
    // The count of the counted --all lists in a row without the row.
    var missing = 0
    // The time of the defer of a deferred delete in this run, and the count of the counted
    // --all lists in a row without its row ID.
    var deferredAt: Int?
    var deferredMissing = 0

    // Forget the values of the row. The values of a deferred delete stay: a defer forgets the
    // row first.
    mutating func forgetRow() {
        inactiveSince = nil
        missing = 0
    }
}

// The row of an entry of a list. isNew is true for a row that the entry starts.
struct Match {
    var entry: AgentEntry
    var rowId: String
    var isNew: Bool
}

// The indexes of one match, so the match does not scan all stored records for each entry. A
// match changes neither the store nor the sessions while it runs.
private struct MatchIndex {
    // The stored rows by their current ID, in the order of their row IDs.
    var byCurrent: [String: [String]] = [:]
    // The rows by the short ID of their job, and the row IDs of the deferred deletes by their
    // short ID.
    var byJob: [ShortID: [String]] = [:]
    // The known rows with no job and no current ID, by the first 9 characters of the row ID
    // when they are a short ID and "-", in the order of the row IDs.
    var freeByPrefix: [String: [String]] = [:]
    // The sessions in the order of their row IDs.
    var sessions: [Session] = []

    init(_ registry: SessionRegistry) {
        let stored = registry.stored
        for (rowId, record) in stored.rows.sorted(by: { $0.key < $1.key }) {
            if let current = record.current { byCurrent[current, default: []].append(rowId) }
            if let job = record.job { byJob[job, default: []].append(rowId) }
        }
        for deferred in stored.deferred {
            byJob[deferred.shortId, default: []].append(deferred.sessionId)
        }
        let known = Set(registry.sessions.keys).union(stored.rows.keys)
        for rowId in known.sorted() {
            let record = stored[row: rowId]
            let prefix = rowId.prefix(9)
            guard prefix.count == 9, prefix.last == "-", record.job == nil, record.current == nil,
                registry.sessions[rowId] != nil || record.makesRowKnown
            else { continue }
            freeByPrefix[String(prefix), default: []].append(rowId)
        }
        sessions = registry.sessions.values.sorted { $0.sessionId < $1.sessionId }
    }
}

// The same place in the main checkout for a folder in a worktree. Other folders stay the same.
private func checkoutPlace(_ cwd: String) -> String {
    guard let root = WorktreeRoot(cwd: cwd) else { return cwd }
    return root.repo + cwd.dropFirst(root.worktree.count)
}

// True when two folders can be the folder of one job. An empty folder is not known.
private func sameFolder(_ a: String, _ b: String) -> Bool {
    a.isEmpty || b.isEmpty || checkoutPlace(a) == checkoutPlace(b)
}

// True when the use value a is higher than b. A value that is not finite never wins.
private func beats(_ a: Double, _ b: Double) -> Bool {
    a.isFinite && (!b.isFinite || a > b)
}

// Merge the session list, the state events and the usage lines of the mod, and the git branches
// into rows. Each session has its own state machine. The registry is a value: a copy is a
// separate registry. store() gives the values to save. The service compares it with the last
// saved store, so the registry keeps no flag for a change.
package struct SessionRegistry: Sendable {
    // A state event for an unknown session waits this long for the session to show.
    package static let pendingEventTime = Duration.seconds(60)
    // The limits of the lines of the mod for sessions that no row has: at most this many events
    // wait, and at most this many session IDs keep a line time, a usage line or a waiting event.
    // The oldest goes first. So a flood of lines with new session IDs cannot fill the memory.
    package static let maxPendingEvents = 1000
    package static let maxUnknownSessions = 256
    // A rate limit window counts only when it resets within this time from now.
    package static let rateWindowHorizon = Duration.seconds(8 * 24 * 60 * 60)
    // A session is live for this long after its last line of the mod. The mod sends a usage line
    // each 30 s, so a live idle session stays live.
    package static let liveTime = Duration.seconds(90)
    // A session that is not active stays in lastActive this long.
    package static let lastActiveGrace = Duration.seconds(60)
    // The registry forgets a session after this many counted --all lists without it.
    package static let goneLists = 2
    // Two rate window readings with resetsAt values within this time are the same window.
    static let sameWindowTime = Duration.seconds(10 * 60)

    // The time from a yellow box to the escalation to red. 0 stops the escalation.
    package private(set) var escalation: Duration
    // The source of new row IDs. A test gives a fixed source.
    let makeID: @Sendable () -> String
    // The values that the store file keeps: a record for each row, the watchlist, the deferred
    // deletes and the PR names. A deferred row ID never becomes a row.
    var stored: RegistryStore
    // The row that gets the live lines of each current ID that is not its row ID.
    var byCurrent: [String: String] = [:]
    // The sessions of lastActive at the start. Resume all can resume them. Not saved.
    var resumable: Set<String>
    // The run state of each row ID (RowRun). No entry is empty.
    var runs: [String: RowRun] = [:]
    // The terminal app of each PID of an external row, and the PIDs of external rows that have
    // no terminal app.
    var terminals: [pid_t: TerminalApp] = [:]
    var noTerminal: Set<pid_t> = []
    // The terminal app of each owned row that a "claude attach" client in a terminal shows, by
    // row ID, from the last scan of the attach clients (applyAttachClients).
    var attachApps: [String: TerminalApp] = [:]
    var sessions: [String: Session] = [:]
    // The row IDs of the last active list.
    var active: Set<String> = []
    // The rows that an --all read added, with the turn of that read, until an active list of a
    // later turn also lacks them. The --all list can have a new background entry
    // with no pid before an active list has it, for example a session that starts. Such a row
    // counts as listed (ActiveListing.unconfirmed) until then.
    var unconfirmed: [String: Int] = [:]
    // The turn of the newest list, and the turn of the newest active list (nil before the first
    // one). The service gives each list the number of its turn in the lock of the lists, so the
    // turns give the order of the samples, also when the wall clock steps back. A list with no
    // turn comes after each list before it.
    var lastTurn = 0
    var activeTurn: Int?
    // The session IDs of the entries of the last active list.
    var lastSample: Set<String> = []
    // The background row IDs of the last counted --all list, and of each later list that did
    // not count.
    var all: Set<String> = []
    // The row IDs of the background entries of the last active list.
    var activeBackground: Set<String> = []
    // State events for sessions that did not show yet.
    var pending: [HookEvent] = []
    // The session IDs with lines of the mod and no row, in the order of their first line. An ID
    // that has a row now leaves at the next trim.
    var unknownIds: [String] = []
    // The time of the newest line of the mod for each session ID.
    var liveAt: [String: Int] = [:]
    var usageLines: [String: UsageLine] = [:]
    // The newest prompt of a person for each session ID that sent a prompt line: the order number
    // of that prompt, or 0 when no prompt of the session came from a person (applyPrompt).
    var personPrompts: [String: Int] = [:]
    // The order number of the newest prompt of a person in this run, of any session.
    var promptOrder = 0
    // The newest time that applyAgents, applyEvents, applyUsage or tick got.
    var clock = 0
    var branches: [String: String] = [:]

    package init(
        store: RegistryStore, escalation: Duration,
        makeID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.escalation = escalation
        self.makeID = makeID
        stored = store
        resumable = store.lastActive
        // A current ID equal to its row ID is no current ID. When two rows have one current ID,
        // the row with the lowest row ID gets its live lines until the next active list (D9).
        for (rowId, id) in store.current.sorted(by: { $0.key < $1.key }) {
            if id == rowId {
                stored[row: rowId].current = nil
            } else if byCurrent[id] == nil {
                byCurrent[id] = rowId
            }
        }
    }

    // MARK: - The active list

    // Apply the output of "claude agents --json". sampledAt is the time when the poll started,
    // and turn its turn in the lock of the lists (nil: after each list before it).
    package mutating func applyAgents(_ entries: [AgentEntry], sampledAt: Int, turn: Int? = nil) {
        let turn = nextTurn(turn)
        advance(sampledAt)
        var matches: [Match] = []
        for m in match(entries, link: true) where !hiddenInActive(m, sampledAt: sampledAt) {
            matches.append(m)
        }
        let ids = Set(matches.map(\.rowId))
        for m in matches {
            let entry = m.entry
            let rowId = m.rowId
            let known = sessions[rowId]
            if known == nil { add(rowId) }
            // Only an entry with a pid, or a new row, sets the current ID.
            if m.isNew || entry.pid != nil { setCurrent(rowId, entry.sessionId, listed: ids) }
            keepName(rowId, entry)
            keepJob(rowId, entry)
            guard var s = sessions[rowId] else { continue }
            // The status before this sample. A new session has none.
            let prevStatus = known?.status
            if let known, known.status != entry.status { s.statusChangedAt = sampledAt }
            if entry.status == .busy { s.lastBusyAt = sampledAt }
            // Without the mod, only the session list can clear the parked state. A sample that
            // started before the park is too old to clear it.
            let restarted = entry.pid != nil && s.parkedAt.map { sampledAt > $0 } ?? true
            if s.machine.state == .parked && restarted {
                s.machine = s.machine.onHookEvent(
                    HookEvent(.sessionStart, s.sessionId, at: sampledAt))
            }
            s.copy(entry)
            // The ID of a job that starts with its short ID is its original ID.
            if entry.isBackground, let short = entry.id, entry.sessionId.hasPrefix(short.text) {
                s.jobId = entry.sessionId
            }
            sessions[rowId] = s
            let sample = StatusSample(
                entry.status, at: sampledAt, waitingFor: entry.waitingFor, prevStatus: prevStatus,
                live: liveOf(rowId))
            setMachine(rowId, s.machine.onStatus(sample))
            keepWorktree(rowId)
        }
        for id in active where !ids.contains(id) {
            leave(id, sampledAt: sampledAt)
        }
        active = ids
        unconfirmed = unconfirmed.filter { !ids.contains($0.key) && $0.value > turn }
        activeTurn = max(activeTurn ?? turn, turn)
        lastSample = Set(entries.map(\.sessionId))
        activeBackground = Set(matches.filter { $0.entry.isBackground }.map(\.rowId))
        for id in ids { self[run: id].missing = 0 }
        parkStarted(sampledAt: sampledAt)
        trackLastActive(matches, sampledAt: sampledAt)
    }

    // The turn of a list: the turn that the service gave, or the turn after the newest one.
    private mutating func nextTurn(_ turn: Int?) -> Int {
        let turn = turn ?? lastTurn + 1
        lastTurn = max(lastTurn, turn)
        return turn
    }

    // Find the row of each entry of a list (docs/behaviour/registry.md, "Rows and identity"), in
    // this order:
    // 1. A background entry goes to the one row with its short ID, when the folder agrees. Only one
    //    entry of the list can have that short ID.
    // 2. An entry goes to a known row whose current ID is the session ID of the entry. A row with a
    //    short ID belongs to its job: only an entry with that short ID goes there.
    // 3. Only for the active list: a /clear of a session with no short ID (links).
    // 4. A new row. Its row ID is the session ID of the entry, or a new UUID when a row or a stored
    //    value has that ID already.
    mutating func match(_ entries: [AgentEntry], link: Bool) -> [Match] {
        let indexes = MatchIndex(self)
        var found: [Int: Match] = [:]
        // The entry index that took each row in this list.
        var taken: [String: Int] = [:]
        func take(_ index: Int, _ rowId: String, isNew: Bool) {
            found[index] = Match(entry: entries[index], rowId: rowId, isNew: isNew)
            taken[rowId] = index
        }
        var shortIds: [ShortID: Int] = [:]
        for short in entries.compactMap(\.id) { shortIds[short, default: 0] += 1 }
        for (index, entry) in entries.enumerated() {
            guard entry.isBackground, let short = entry.id, shortIds[short] == 1,
                let rowId = jobRow(short, indexes), taken[rowId] == nil,
                sameFolder(sessions[rowId]?.cwd ?? "", entry.cwd)
            else { continue }
            take(index, rowId, isNew: false)
        }
        for (index, entry) in entries.enumerated() where found[index] == nil {
            for rowId in rowsOfCurrent(entry.sessionId, indexes) {
                // Two entries with no short ID and one session ID share a row.
                if let by = taken[rowId] {
                    let other = entries[by]
                    if other.sessionId != entry.sessionId || other.id != nil || entry.id != nil
                    {
                        continue
                    }
                }
                if let job = stored[row: rowId].job, job != entry.id { continue }
                take(index, rowId, isNew: false)
                break
            }
        }
        if link {
            for (entry, rowId) in links(entries, indexes, found: found, taken: taken) {
                take(entry, rowId, isNew: false)
            }
        }
        // The new rows of this list, by session ID. Two entries with one session ID share a row.
        var added: [String: String] = [:]
        for (index, entry) in entries.enumerated() where found[index] == nil {
            let id = entry.sessionId
            let free = taken[id] == nil && !isKnown(id)
            let rowId = added[id] ?? (free ? id : makeID())
            added[id] = rowId
            take(index, rowId, isNew: true)
        }
        return entries.indices.compactMap { found[$0] }
    }

    // Rule 3 of match: a /clear of a session with no short ID gives the same process a new
    // session ID. Link the entry to a row when all of these are true:
    // - The entry has no short ID, a positive pid and a folder, and its session ID is not the
    //   current ID of a known row.
    // - The row has no short ID, the same pid and the same folder.
    // - The current ID of the row was in the last active list and is not in this list.
    // - One entry matches one row, and one row matches one entry.
    private func links(
        _ entries: [AgentEntry], _ index: MatchIndex, found: [Int: Match], taken: [String: Int]
    ) -> [(Int, String)] {
        let sample = Set(entries.map(\.sessionId))
        var pairs: [(entry: Int, rowId: String)] = []
        for (entryIndex, entry) in entries.enumerated() {
            guard found[entryIndex] == nil, entry.id == nil, let pid = entry.pid, pid > 0,
                !entry.cwd.isEmpty, rowsOfCurrent(entry.sessionId, index).isEmpty
            else { continue }
            for s in index.sessions {
                let current = currentOf(s.sessionId)
                guard taken[s.sessionId] == nil, s.shortId == nil, lastSample.contains(current),
                    !sample.contains(current), s.pid == pid, s.cwd == entry.cwd
                else { continue }
                pairs.append((entryIndex, s.sessionId))
            }
        }
        var entryCounts: [Int: Int] = [:]
        var rowCounts: [String: Int] = [:]
        for pair in pairs {
            entryCounts[pair.entry, default: 0] += 1
            rowCounts[pair.rowId, default: 0] += 1
        }
        return pairs.filter { entryCounts[$0.entry] == 1 && rowCounts[$0.rowId] == 1 }
            .map { ($0.entry, $0.rowId) }
    }

    // The one row of the job with this short ID: the row with that short ID in jobs or in a
    // deferred delete. When no row has it, the one known row whose row ID starts with the short ID,
    // has no short ID and has its row ID as its current ID. nil when no row or more than one row
    // matches.
    private func jobRow(_ shortId: ShortID, _ index: MatchIndex) -> String? {
        let owners = index.byJob[shortId] ?? []
        if !owners.isEmpty { return owners.count == 1 ? owners[0] : nil }
        let free = index.freeByPrefix["\(shortId.text)-"] ?? []
        return free.count == 1 ? free[0] : nil
    }

    // True when the registry has a row or a stored value with this row ID.
    private func isKnown(_ rowId: String) -> Bool {
        sessions[rowId] != nil || stored[row: rowId].makesRowKnown
    }

    private func currentOf(_ rowId: String) -> String { stored[row: rowId].current ?? rowId }

    // The row whose current ID is sessionId. nil when sessionId is the row ID of a row with another
    // current ID: then sessionId is the old conversation of that row.
    private func rowOf(_ sessionId: String) -> String? {
        if let rowId = byCurrent[sessionId] { return rowId }
        return stored[row: sessionId].current == nil ? sessionId : nil
    }

    // The row ID that the Event log and the Usage HUD use for a session ID of the mod.
    package func rowIdOf(_ sessionId: String) -> String { byCurrent[sessionId] ?? sessionId }

    // The known rows whose current ID is id. The row that gets the live lines comes first. The
    // other rows follow in the order of their row IDs (D9). A match gives its index.
    private func rowsOfCurrent(_ id: String, _ index: MatchIndex? = nil) -> [String] {
        var rows: [String] = []
        if let owner = rowOf(id), isKnown(owner) { rows.append(owner) }
        let others =
            index.map { $0.byCurrent[id] ?? [] }
            ?? stored.rows.filter { $0.value.current == id }.map(\.key).sorted()
        rows += others.filter { !rows.contains($0) }
        if stored[row: id].current == nil, isKnown(id), !rows.contains(id) { rows.append(id) }
        return rows
    }

    // True when the row gets the live lines of its current ID.
    private func ownsCurrent(_ rowId: String) -> Bool { rowOf(currentOf(rowId)) == rowId }

    private func liveOf(_ rowId: String) -> Bool {
        ownsCurrent(rowId) && isLive(currentOf(rowId))
    }

    // Make id the current ID of a row. listed holds the rows of this active list. The live lines of
    // id go to one row only. A row that has them keeps them while the list has it. The newest line
    // time of the old ID carries over, and the events that wait for id apply.
    private mutating func setCurrent(_ rowId: String, _ id: String, listed: Set<String>) {
        let old = currentOf(rowId)
        if old != id {
            stored[row: rowId].current = id == rowId ? nil : id
            if byCurrent[old] == rowId { byCurrent[old] = nil }
            if let at = liveAt[old] { touch(id, at: at) }
        }
        let owner = rowOf(id)
        if owner == rowId { return }
        if let owner, isKnown(owner), listed.contains(owner) { return }
        byCurrent[id] = id == rowId ? nil : rowId
        if sessions[rowId] != nil { applyPending(rowId, id) }
    }

    // Keep the --all ID of a stopped job. An ID that starts with the short ID is the original ID.
    // Another ID only fills an empty value.
    private mutating func keepJobId(_ rowId: String, _ entry: AgentEntry) {
        guard var s = sessions[rowId] else { return }
        let original = entry.id.map { entry.sessionId.hasPrefix($0.text) } ?? false
        if s.jobId == nil || original { s.jobId = entry.sessionId }
        sessions[rowId] = s
    }

    private mutating func keepJob(_ rowId: String, _ entry: AgentEntry) {
        guard entry.isBackground, let short = entry.id else { return }
        stored[row: rowId].job = short
    }

    // A background entry with a pid is active. The other sessions of lastActive start a grace.
    private mutating func trackLastActive(_ matches: [Match], sampledAt: Int) {
        var running: Set<String> = []
        for m in matches where m.entry.isBackground && m.entry.pid != nil {
            running.insert(m.rowId)
            stored[row: m.rowId].lastActive = true
            resumable.remove(m.rowId)
            self[run: m.rowId].inactiveSince = nil
        }
        for id in stored.lastActive where !running.contains(id) {
            if self[run: id].inactiveSince == nil { self[run: id].inactiveSince = sampledAt }
        }
    }

    // MARK: - The --all list

    // Apply the output of "claude agents --json --all" after a poll that did not fail. complete
    // is false when the parser skipped an entry. Only a list that counts can remove a row or a
    // stored value, through forgetGone. A list counts when it is complete, not empty, has each
    // background session of the last active list, and has a background entry or the registry
    // knows no parked owned session. Return the row IDs that the registry forgot for good.
    // turn is the turn of the read in the lock of the lists (nil: after each list before it).
    @discardableResult
    package mutating func applyAllAgents(
        _ entries: [AgentEntry], complete: Bool, turn: Int? = nil
    ) -> [String] {
        let turn = nextTurn(turn)
        // An interactive session that ended must not come back as a parked row.
        let owned = entries.filter(\.isBackground)
        let found = match(owned, link: false)
        // A running entry that needs a new row ID waits for the active list.
        let matches = found.filter {
            !($0.isNew && $0.rowId != $0.entry.sessionId && $0.entry.pid != nil)
        }
        let ownedIds = matches.map(\.rowId)
        var listed = Set(ownedIds)
        for entry in entries where !entry.isBackground { listed.insert(rowIdOf(entry.sessionId)) }
        let counts =
            complete && !entries.isEmpty && activeBackground.isSubset(of: listed)
            && (!owned.isEmpty || !knowsParkedOwned())
        all = counts ? Set(ownedIds) : all.union(ownedIds)
        for m in matches where !isDeferred(m.rowId) {
            keepName(m.rowId, m.entry)
            keepJob(m.rowId, m.entry)
            // An entry with a pid has a process. The active list gives its data.
            if m.entry.pid != nil || active.contains(m.rowId) { continue }
            if sessions[m.rowId] == nil {
                add(m.rowId)
                // An active list of a later turn already lacks the row.
                if turn > activeTurn ?? .min { unconfirmed[m.rowId] = turn }
            }
            if m.isNew { setCurrent(m.rowId, m.entry.sessionId, listed: active) }
            sessions[m.rowId]?.copy(m.entry)
            keepJobId(m.rowId, m.entry)
            park(m.rowId)
        }
        guard counts else { return [] }
        let gone = forgetGone(listed: listed)
        checkDeferred(found, entries)
        return gone
    }

    // True when the active list skips the entry of a deferred row. An entry with a pid, from a
    // sample that started after the defer, means that the session runs again: the deferred delete
    // goes, and the row shows as normal.
    private mutating func hiddenInActive(_ m: Match, sampledAt: Int) -> Bool {
        guard isDeferred(m.rowId) else { return false }
        if let at = self[run: m.rowId].deferredAt, sampledAt <= at { return true }
        if m.entry.pid == nil { return true }
        showAgain(m.rowId)
        return false
    }

    // The rules of the deferred deletes after a counted --all list.
    // Gone rule: after goneLists counted lists in a row without its row ID, a deferred delete goes.
    // Orphan rule: a worktree is in use when a row, an entry of any kind with a pid, or a
    // background entry without a pid (not of a deferred session) has it as its root. A deferred
    // delete of a worktree that is not in use goes, and its session gets its worktree and its job
    // back.
    private mutating func checkDeferred(_ found: [Match], _ entries: [AgentEntry]) {
        let given = Set(found.map(\.rowId))
        for id in stored.deferred.map(\.sessionId) {
            if given.contains(id) {
                self[run: id].deferredMissing = 0
                continue
            }
            let count = self[run: id].deferredMissing + 1
            if count >= Self.goneLists {
                removeDeferred(id)
            } else {
                self[run: id].deferredMissing = count
            }
        }
        var used: Set<String> = []
        for s in sessions.values {
            let root = WorktreeRoot(cwd: s.cwd, stored: stored[row: s.sessionId].worktree)
            if let root { used.insert(root.worktree) }
        }
        for entry in entries where entry.pid != nil {
            if let root = WorktreeRoot(cwd: entry.cwd) { used.insert(root.worktree) }
        }
        for m in found where m.entry.pid == nil && !isDeferred(m.rowId) {
            if let root = WorktreeRoot(cwd: m.entry.cwd) { used.insert(root.worktree) }
        }
        for d in stored.deferred where !used.contains(d.worktree) { showAgain(d.sessionId) }
    }

    // MARK: - Live lines

    // Apply state events. An event goes to the row whose current ID is its session ID. An event
    // for an unknown session waits until the session shows, and goes after pendingEventTime.
    // At most maxPendingEvents events wait, and the oldest goes first.
    package mutating func applyEvents(_ events: [HookEvent], now: Int) {
        advance(now)
        for ev in events {
            touch(ev.sessionId, at: ev.at)
            if let rowId = rowOf(ev.sessionId), sessions[rowId] != nil {
                applyEvent(rowId, ev)
            } else {
                pending.append(ev)
                if pending.count > Self.maxPendingEvents {
                    pending.removeFirst(pending.count - Self.maxPendingEvents)
                }
                noteUnknown(ev.sessionId)
            }
        }
        dropOldEvents(now: now)
    }

    // Keep the newest usage line of a session. The session can be unknown. A usage line is not
    // activity (D8). A line without rate limits keeps the last rate limits and their time. The
    // rate limits count only for a session of a row, and each window only when it resets within
    // rateWindowHorizon from now (the newest time of the registry), so a line of another program
    // cannot set the windows of the plan.
    package mutating func applyUsage(_ sessionId: String, _ usage: LiveUsage, at: Int) {
        advance(at)
        touch(sessionId, at: at)
        let known = hasRow(sessionId)
        if !known { noteUnknown(sessionId) }
        let old = usageLines[sessionId]
        if let old, at < old.updatedAt { return }
        var usage = usage
        usage.rateLimits = known ? trusted(usage.rateLimits) : nil
        var line = UsageLine(usage: usage, updatedAt: at)
        if usage.rateLimits != nil {
            line.limitsAt = at
        } else if let old, old.usage.rateLimits != nil {
            line.usage.rateLimits = old.usage.rateLimits
            line.limitsAt = old.limitsAt
        }
        usageLines[sessionId] = line
    }

    // Keep the newest prompt of a person of a session (docs/behaviour/alerts.md). The session can
    // be unknown. A prompt of a person gets the next order number of the run. A prompt of another
    // source only makes the prompts of the session known. A prompt line is not activity: the
    // turn.start line of the prompt gives the activity.
    package mutating func applyPrompt(_ sessionId: String, person: Bool, at: Int) {
        advance(at)
        touch(sessionId, at: at)
        if !hasRow(sessionId) { noteUnknown(sessionId) }
        if person {
            promptOrder += 1
            personPrompts[sessionId] = promptOrder
        } else if personPrompts[sessionId] == nil {
            personPrompts[sessionId] = 0
        }
    }

    // The windows that reset from now to now + rateWindowHorizon, or nil when none does.
    private func trusted(_ limits: RateLimits?) -> RateLimits? {
        let last = clock + Int(Self.rateWindowHorizon / .milliseconds(1))
        let inRange = { (window: RateWindow?) in
            window.flatMap { (clock...last).contains($0.resetsAt) ? $0 : nil }
        }
        let kept = RateLimits(
            fiveHour: inRange(limits?.fiveHour), sevenDay: inRange(limits?.sevenDay))
        return kept == RateLimits() ? nil : kept
    }

    // True when a row gets the lines of the mod of this session ID.
    private func hasRow(_ sessionId: String) -> Bool {
        guard let rowId = rowOf(sessionId) else { return false }
        return sessions[rowId] != nil
    }

    // Keep the session ID of a line with no row, and forget the lines of the oldest such IDs
    // over maxUnknownSessions.
    private mutating func noteUnknown(_ sessionId: String) {
        if !unknownIds.contains(sessionId) { unknownIds.append(sessionId) }
        guard unknownIds.count > Self.maxUnknownSessions else { return }
        let ids = unknownIds
        unknownIds = ids.filter { !hasRow($0) }
        while unknownIds.count > Self.maxUnknownSessions {
            let id = unknownIds.removeFirst()
            liveAt[id] = nil
            usageLines[id] = nil
            personPrompts[id] = nil
            pending.removeAll { $0.sessionId == id }
        }
    }

    // The newest value of each window, chosen on its own from the usage lines of all sessions:
    // the latest resetsAt wins; readings within sameWindowTime are one window; in one window the
    // highest use wins. name, sessionId and updatedAt come from the line of the 7-day value,
    // else of the 5-hour value. nil when no session has a window.
    package func usage() -> UsageSnapshot? {
        let fiveHour = pickWindow(\.fiveHour)
        let sevenDay = pickWindow(\.sevenDay)
        guard let source = sevenDay ?? fiveHour else { return nil }
        let limits = RateLimits(fiveHour: fiveHour?.window, sevenDay: sevenDay?.window)
        let s = sessions[rowIdOf(source.sessionId)]
        return UsageSnapshot(
            sessionId: s?.sessionId ?? source.sessionId,
            name: s.map(shownName) ?? String(source.sessionId.prefix(8)),
            updatedAt: source.at, limits: limits)
    }

    private struct Reading {
        var window: RateWindow
        var sessionId: String
        var at: Int
    }

    // The readings go in the order of their session IDs, so a tie has one result (D8).
    private func pickWindow(_ key: KeyPath<RateLimits, RateWindow?>) -> Reading? {
        var readings: [Reading] = []
        for (sessionId, line) in usageLines.sorted(by: { $0.key < $1.key }) {
            guard let window = line.usage.rateLimits?[keyPath: key], let at = line.limitsAt else {
                continue
            }
            readings.append(Reading(window: window, sessionId: sessionId, at: at))
        }
        guard let latestReset = readings.map(\.window.resetsAt).max() else { return nil }
        var best: Reading?
        for r in readings
        where elapsed(from: r.window.resetsAt, to: latestReset) <= Self.sameWindowTime {
            guard let b = best else {
                best = r
                continue
            }
            if beats(r.window.usedPercent, b.window.usedPercent)
                || (r.window.usedPercent == b.window.usedPercent && r.at > b.at)
            {
                best = r
            }
        }
        return best
    }

    // The number of rows that are live and not parked.
    package func liveCount() -> Int {
        sessions.values.filter {
            $0.machine.state != .parked && liveOf($0.sessionId)
        }.count
    }

    // Forget the newest line time of each session. Then no row is live. The usage stays.
    package mutating func clearLive() { liveAt.removeAll() }

    // Set the branch of all rows with this cwd. nil removes the branch. True when the branch
    // changed.
    @discardableResult
    package mutating func applyBranch(_ cwd: String, _ branch: String?) -> Bool {
        guard branches[cwd] != branch else { return false }
        branches[cwd] = branch
        return true
    }

    // MARK: - Commands

    // Remove a session and all values that the registry keeps for it. sessionId is a row ID. The
    // lines of the mod of its row ID and its current ID go too, when no other row has that ID as
    // its current ID.
    package mutating func forget(_ sessionId: String) {
        let current = currentOf(sessionId)
        for id in Set([sessionId, current])
        where !rowsOfCurrent(id).contains(where: { $0 != sessionId }) {
            pending.removeAll { $0.sessionId == id }
            usageLines[id] = nil
            personPrompts[id] = nil
            liveAt[id] = nil
        }
        if byCurrent[current] == sessionId { byCurrent[current] = nil }
        sessions[sessionId] = nil
        active.remove(sessionId)
        unconfirmed[sessionId] = nil
        all.remove(sessionId)
        resumable.remove(sessionId)
        self[run: sessionId].forgetRow()
        activeBackground.remove(sessionId)
        // An empty record removes the stored values of the row.
        stored[row: sessionId] = RowRecord()
    }

    // Record a review session for a PR. It gets no yellow box and no Resume all.
    package mutating func markPrSession(_ sessionId: String) {
        guard !stored[row: sessionId].prSession else { return }
        stored[row: sessionId].prSession = true
        if let machine = sessions[sessionId]?.machine { setMachine(sessionId, machine) }
        resumable.remove(sessionId)
    }

    // Call this before the start of a PR session. A row with this name gets the PR rule.
    package mutating func expectPrSession(_ name: String) { stored.prNames.insert(name) }

    // Remove the name after a remove that worked.
    package mutating func releasePrSession(_ name: String) { stored.prNames.remove(name) }

    // A stopped session is no candidate for Resume all.
    package mutating func markStopped(_ sessionId: String) {
        stored[row: sessionId].lastActive = false
        resumable.remove(sessionId)
        self[run: sessionId].inactiveSince = nil
    }

    // Merge the terminal apps of a read by PID. Remove the PIDs that no external row has.
    package mutating func applyTerminals(_ read: TerminalApps) {
        terminals.merge(read.apps) { _, new in new }
        noTerminal.subtract(read.apps.keys)
        for pid in read.noApp { terminals[pid] = nil }
        noTerminal.formUnion(read.noApp)
        let pids = Set(
            sessions.values.filter { $0.kind == .external }.compactMap(\.pid))
        terminals = terminals.filter { pids.contains($0.key) }
        noTerminal.formIntersection(pids)
    }

    // The PIDs of the running external rows that have no terminal entry, in the row order.
    package func pidsWithoutTerminal() -> [pid_t] {
        sorted().compactMap { s in
            guard s.kind == .external, s.machine.state != .parked, let pid = s.pid,
                terminals[pid] == nil, !noTerminal.contains(pid)
            else { return nil }
            return pid
        }
    }

    // True when the registry has an owned session, also a parked one. Only then can a scan of
    // the attach clients change a row, and each scan replaces the apps of the last scan, so a
    // session that parks and runs again never shows an old app.
    package var hasOwnedSession: Bool { sessions.values.contains { $0.kind == .owned } }

    // Apply a scan of the "claude attach" clients. Each owned row gets the app of its newest
    // client that has an app: the client with the latest start time, and with the higher PID
    // when two start at the same time. The newest client is the window that the user opened
    // last. A client with no app (tmux, ssh) does not count, so an older client in a terminal
    // app still shows. A client whose argument matches no owned row, or more than one, does not
    // count (attachRow). True when the app of a row changed.
    @discardableResult
    package mutating func applyAttachClients(_ clients: [AttachClient]) -> Bool {
        let owned = sorted().filter { $0.kind == .owned }
        var newest: [String: AttachClient] = [:]
        for client in clients where client.app != nil {
            guard let rowId = attachRow(client.argument, owned) else { continue }
            if let best = newest[rowId], (best.started, best.pid) >= (client.started, client.pid) {
                continue
            }
            newest[rowId] = client
        }
        let apps = newest.compactMapValues(\.app)
        guard apps != attachApps else { return false }
        attachApps = apps
        return true
    }

    // The owned row that the argument of claude attach names, as Claude Code reads it: the start
    // of an ID matches the short ID and each session ID of a row (the row ID, the current ID and
    // the original ID of the job), and a name matches the Claude Code name of a row. Claude Code
    // refuses an argument that matches more than one session, so such an argument gives no row.
    private func attachRow(_ argument: AttachArgument, _ owned: [Session]) -> String? {
        let matches = owned.filter { s in
            switch argument {
            case .idStart(let start):
                [s.shortId?.text, s.sessionId, currentOf(s.sessionId), s.jobId]
                    .contains { $0?.hasPrefix(start) == true }
            case .name(let name):
                stored[row: s.sessionId].name == name
            }
        }
        return matches.count == 1 ? matches.first?.sessionId : nil
    }

    // The terminal app of a session: for an external session, the app of its process; for an
    // owned session that is not parked, the app of its newest attach client in a terminal.
    package func terminalOf(_ sessionId: String) -> TerminalApp? {
        guard let s = sessions[sessionId] else { return nil }
        switch s.kind {
        case .external:
            return s.pid.flatMap { terminals[$0] }
        case .owned:
            return s.machine.state == .parked ? nil : attachApps[sessionId]
        }
    }

    // Record a session that Bifrost started.
    package mutating func markStarted(_ sessionId: String) { stored[row: sessionId].started = true }

    // The next tick uses this time, also for a box that is already yellow. 0 stops the escalation.
    package mutating func setEscalation(_ escalation: Duration) { self.escalation = escalation }

    // The time rules: the escalation of a box, the end of the live time, the end of old events
    // and the end of the grace time of lastActive. True when a row, the live count or the store
    // can have changed, so the service rebuilds its values only then.
    @discardableResult
    package mutating func tick(now: Int) -> Bool {
        let machines = sessions.mapValues(\.machine)
        let live = liveRows()
        let store = stored
        advance(now)
        for id in sessions.keys {
            if let machine = sessions[id]?.machine {
                setMachine(id, machine.onTick(now: now, escalation: escalation))
            }
        }
        dropOldEvents(now: now)
        for id in stored.lastActive {
            guard let since = self[run: id].inactiveSince,
                elapsed(from: since, to: now) >= Self.lastActiveGrace
            else { continue }
            stored[row: id].lastActive = false
            self[run: id].inactiveSince = nil
        }
        return sessions.mapValues(\.machine) != machines || liveRows() != live || stored != store
    }

    // The row IDs of the rows that are live now.
    private func liveRows() -> Set<String> {
        Set(sessions.keys.filter(liveOf))
    }

    // Set the local name of a session. nil, an empty name and a name equal to the Claude Code
    // name remove it. Return false for an unknown session and for a bad name.
    package mutating func setAlias(_ sessionId: String, _ name: String?) -> Bool {
        guard let s = sessions[sessionId] else { return false }
        var clean = ""
        if let name {
            guard let checked = try? cleanAlias(name) else { return false }
            clean = checked
        }
        stored[row: sessionId].alias = clean.isEmpty || clean == nameOf(s) ? nil : clean
        return true
    }

    // Set the priority of a session. nil removes it. Return false for an unknown session.
    package mutating func setPriority(_ sessionId: String, _ priority: SessionPriority?) -> Bool {
        guard sessions[sessionId] != nil else { return false }
        stored[row: sessionId].priority = priority
        return true
    }

    private func watchIndex(_ sessionId: String) -> Int? {
        stored.watchlist.firstIndex(of: sessionId)
    }

    // Add a session to the end of the watchlist. A watched session only gets the new colour.
    package mutating func watchAdd(_ sessionId: String, _ colour: WatchColour) -> Bool {
        guard sessions[sessionId] != nil else { return false }
        stored[row: sessionId].watch = colour
        return true
    }

    package mutating func watchRemove(_ sessionId: String) -> Bool {
        guard sessions[sessionId] != nil else { return false }
        stored[row: sessionId].watch = nil
        return true
    }

    // Change the colour of a watched session. A session that is not watched stays as it is.
    package mutating func watchColour(_ sessionId: String, _ colour: WatchColour) -> Bool {
        guard sessions[sessionId] != nil else { return false }
        if stored[row: sessionId].watch != nil { stored[row: sessionId].watch = colour }
        return true
    }

    // Move a watched session before another watched session. nil moves it to the end. Return
    // false if one of the two is not watched. Then nothing changes.
    package mutating func watchMove(_ sessionId: String, before beforeId: String?) -> Bool {
        guard watchIndex(sessionId) != nil else { return false }
        if let beforeId, watchIndex(beforeId) == nil { return false }
        stored.moveWatch(sessionId, before: beforeId)
        return true
    }

    // Move the priority and the watchlist entry of one session to another (Hand over). The new
    // session takes the place and the colour of the old one in the watchlist. With no value on
    // the old session, the new session keeps its own. Return false if one ID is unknown.
    package mutating func carryOver(from fromId: String, to toId: String) -> Bool {
        guard sessions[fromId] != nil, sessions[toId] != nil else { return false }
        if fromId == toId { return true }
        if let priority = stored[row: fromId].priority {
            stored[row: fromId].priority = nil
            stored[row: toId].priority = priority
        }
        if let colour = stored[row: fromId].watch {
            // The new session goes just before the old session, then the old session leaves.
            stored[row: toId].watch = colour
            stored.moveWatch(toId, before: fromId)
            stored[row: fromId].watch = nil
        }
        return true
    }

    // Store the worktree root that claude rm names for a session. Return false for an unknown
    // session or a path that is not a worktree root.
    package mutating func rememberWorktree(_ sessionId: String, _ path: String) -> Bool {
        guard sessions[sessionId] != nil, WorktreeRoot.isRoot(path) else { return false }
        stored[row: sessionId].worktree = path
        return true
    }

    // Delete of a session whose worktree another session uses. Forget the row and keep the
    // deferred delete. at is the time of the defer (default: the newest time of the registry).
    // An active sample that started before it does not show the row again. The entry keeps the
    // job value of the row, not the job value of the caller.
    package mutating func `defer`(_ entry: DeferredDelete, at: Int? = nil) {
        guard WorktreeRoot.isRoot(entry.worktree) else { return }
        let old = stored.deferred.first { $0.sessionId == entry.sessionId }
        let job = stored[row: entry.sessionId].job ?? old?.job
        forget(entry.sessionId)
        self[run: entry.sessionId].deferredAt = at ?? clock
        let kept = DeferredDelete(
            sessionId: entry.sessionId, shortId: entry.shortId, worktree: entry.worktree, job: job)
        if old == kept { return }
        // A changed entry goes to the end, as a new defer.
        stored.deferred.removeAll { $0.sessionId == entry.sessionId }
        stored.deferred.append(kept)
        self[run: entry.sessionId].deferredMissing = 0
    }

    // The deferred deletes of a worktree root, in the order of the defers.
    package func deferredIn(_ worktree: String) -> [DeferredDelete] {
        stored.deferred.filter { $0.worktree == worktree }
    }

    // Remove a deferred delete. The next --all list shows the session again as a parked row.
    package mutating func undefer(_ sessionId: String) { showAgain(sessionId) }

    // Remove a deferred delete after a good claude rm.
    package mutating func dropDeferred(_ sessionId: String) { removeDeferred(sessionId) }

    // MARK: - Output

    // The rows, sorted by startedAt, then by sessionId.
    package func rows() -> [SessionRow] {
        var order: [String: Int] = [:]
        for (place, rowId) in stored.watchlist.enumerated() where order[rowId] == nil {
            order[rowId] = place
        }
        return sorted().map { row($0, watchOrder: order) }
    }

    // The folder of the branch read of each row, one time each, in the row order. An empty cwd
    // is not in the list.
    package func cwds() -> [String] {
        var seen: Set<String> = []
        return sorted().map(branchDir).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // The values that the store file keeps.
    package func store() -> RegistryStore { stored }

    // MARK: - Helpers

    // The run state of a row ID. A row ID with no run state gives an empty value, and an empty
    // value removes the entry.
    subscript(run rowId: String) -> RowRun {
        get { runs[rowId] ?? RowRun() }
        set { runs[rowId] = newValue == RowRun() ? nil : newValue }
    }

    // Remove a deferred delete, and give the session its stored worktree and job value back, so
    // the next entry of the job finds the same row.
    private mutating func showAgain(_ sessionId: String) {
        guard let d = stored.deferred.first(where: { $0.sessionId == sessionId }) else { return }
        removeDeferred(sessionId)
        stored[row: sessionId].worktree = d.worktree
        if let job = d.job { stored[row: sessionId].job = job }
    }

    private func isDeferred(_ rowId: String) -> Bool {
        stored.deferred.contains { $0.sessionId == rowId }
    }

    private mutating func removeDeferred(_ sessionId: String) {
        self[run: sessionId].deferredAt = nil
        self[run: sessionId].deferredMissing = 0
        stored.deferred.removeAll { $0.sessionId == sessionId }
    }

    // Add a session with the initial state. Apply the events that wait for its current ID.
    private mutating func add(_ sessionId: String) {
        sessions[sessionId] = Session(sessionId: sessionId)
        applyPending(sessionId, currentOf(sessionId))
    }

    private mutating func applyPending(_ rowId: String, _ id: String) {
        let waiting = pending.filter { $0.sessionId == id }
        if waiting.isEmpty { return }
        pending.removeAll { $0.sessionId == id }
        for ev in waiting { applyEvent(rowId, ev) }
    }

    // Apply one state event. Skip an event that is older than the last applied event (D4): for two
    // events with the same time, the seq gives the order when both have one. A /clear keeps the
    // process, so its SessionEnd does not park the row.
    private mutating func applyEvent(_ rowId: String, _ ev: HookEvent) {
        guard var s = sessions[rowId] else { return }
        if let lastAt = s.lastEventAt {
            if ev.at < lastAt { return }
            if ev.at == lastAt, let seq = ev.seq, let last = s.lastEventSeq, seq <= last { return }
        }
        if ev.name == .sessionEnd && ev.reason == "clear" { return }
        s.lastEventAt = ev.at
        s.lastEventSeq = ev.seq
        if ev.name == .sessionEnd { s.parkedAt = max(s.parkedAt ?? ev.at, ev.at) }
        sessions[rowId] = s
        setMachine(rowId, s.machine.onHookEvent(ev))
    }

    // A PR session gets no yellow box (docs/behaviour/registry.md, "States and alert boxes").
    private mutating func setMachine(_ rowId: String, _ machine: MachineState) {
        sessions[rowId]?.machine = stored[row: rowId].prSession ? machine.withoutYellow() : machine
    }

    // The clock never goes back.
    private mutating func advance(_ at: Int) { clock = max(clock, at) }

    private mutating func touch(_ sessionId: String, at: Int) {
        liveAt[sessionId] = max(liveAt[sessionId] ?? at, at)
    }

    private func isLive(_ sessionId: String) -> Bool {
        guard let at = liveAt[sessionId] else { return false }
        return elapsed(from: at, to: clock) <= Self.liveTime
    }

    private mutating func dropOldEvents(now: Int) {
        pending.removeAll { elapsed(from: $0.at, to: now) > Self.pendingEventTime }
    }

    // Store the worktree root of a session that is not parked and has a cwd in a worktree.
    private mutating func keepWorktree(_ rowId: String) {
        guard let s = sessions[rowId], s.machine.state != .parked,
            let root = WorktreeRoot(cwd: s.cwd)
        else { return }
        stored[row: rowId].worktree = root.worktree
    }

    // A stopped worktree session reports its start folder, so the stored worktree gives its branch.
    private func branchDir(_ s: Session) -> String {
        if WorktreeRoot(cwd: s.cwd) != nil { return s.cwd }
        return stored[row: s.sessionId].worktree ?? s.cwd
    }

    // A new background entry first shows its short ID as the name. That value is not a name.
    private mutating func keepName(_ rowId: String, _ entry: AgentEntry) {
        let name = entry.name.isEmpty || entry.name == entry.id?.text ? nil : entry.name
        if let name, stored.prNames.contains(name) { markPrSession(rowId) }
        guard let name, stored[row: rowId].name != name else { return }
        stored[row: rowId].name = name
        // A local name equal to the new Claude Code name has no use.
        if stored[row: rowId].alias == name { stored[row: rowId].alias = nil }
    }

    // A session that left the active list: a session that Bifrost started, and an owned session
    // in --all, stay as parked rows. All other sessions go away.
    private mutating func leave(_ sessionId: String, sampledAt: Int) {
        guard let s = sessions[sessionId] else { return }
        if (s.kind == .owned && all.contains(sessionId)) || stored[row: sessionId].started {
            park(sessionId, at: sampledAt)
        } else {
            sessions[sessionId] = nil
        }
    }

    // Count each session that a counted --all list does not have, and forget the session after
    // goneLists counted lists in a row without it. The sessions are the owned rows, each record
    // that counts (RowRecord.countsForGone), and each session with a usage line or a line time
    // of the mod. The count goes back to 0 when the last active list has the session, when
    // this list has its background entry, or when this list has any entry of a started session.
    private mutating func forgetGone(listed: Set<String>) -> [String] {
        var ids = Set(stored.rows.filter { $0.value.countsForGone }.keys)
        ids.formUnion(usageLines.keys.map(rowIdOf))
        ids.formUnion(liveAt.keys.map(rowIdOf))
        ids.formUnion(
            sessions.values.filter { $0.kind == .owned }.map(\.sessionId))
        for id in runs.keys.sorted() where !ids.contains(id) {
            self[run: id].missing = 0
        }
        var gone: [String] = []
        for id in ids.sorted() {
            if active.contains(id) || all.contains(id)
                || (stored[row: id].started && listed.contains(id))
            {
                self[run: id].missing = 0
                continue
            }
            let count = self[run: id].missing + 1
            if count >= Self.goneLists {
                forget(id)
                gone.append(id)
            } else {
                self[run: id].missing = count
            }
        }
        return gone
    }

    // True when the registry knows an owned session without a process: a parked owned row, or
    // a session of the last run that did not run again yet.
    private func knowsParkedOwned() -> Bool {
        !resumable.isEmpty
            || sessions.values.contains {
                $0.kind == .owned && $0.machine.state == .parked
            }
    }

    // A session that Bifrost started and that is not active is parked.
    private mutating func parkStarted(sampledAt: Int) {
        for id in stored.started where !active.contains(id) && sessions[id] == nil {
            add(id)
            park(id, at: sampledAt)
        }
    }

    // Park a session and remove the values that came from the active list. A park from the --all
    // list keeps the old park time.
    private mutating func park(_ rowId: String, at: Int? = nil) {
        guard var s = sessions[rowId] else { return }
        if let at { s.parkedAt = max(s.parkedAt ?? at, at) }
        s.machine = s.machine.parked()
        s.pid = nil
        s.status = .unknown
        s.waitingFor = nil
        sessions[rowId] = s
    }

    private func sorted() -> [Session] {
        sessions.values.sorted { ($0.startedAt, $0.sessionId) < ($1.startedAt, $1.sessionId) }
    }

    // The session ID that resumes an owned row. A stopped job wakes only by its original session
    // ID: the --all ID, the row ID or the current ID, the first that starts with the short ID, else
    // the --all ID. A row with no short ID uses its current ID.
    private func resumeIdOf(_ s: Session) -> String? {
        guard let short = s.shortId ?? stored[row: s.sessionId].job else {
            return currentOf(s.sessionId)
        }
        let ids = [s.jobId, s.sessionId, currentOf(s.sessionId)].compactMap { $0 }
        return ids.first { $0.hasPrefix(short.text) } ?? s.jobId
    }

    // The name that Bifrost shows: the local name, else the Claude Code name.
    private func shownName(_ s: Session) -> String { stored[row: s.sessionId].alias ?? nameOf(s) }

    // The stored name (the last real entry name), the short ID, or the first 8 characters of the
    // row ID.
    private func nameOf(_ s: Session) -> String {
        for name in [stored[row: s.sessionId].name, s.shortId?.text] {
            if let name, !name.isEmpty { return name }
        }
        return String(s.sessionId.prefix(8))
    }

    // The usage, the live flag and the prompt of a person come from the current ID, when the row
    // gets its live lines. The prompt of a person counts only while the row is live.
    private func row(_ s: Session, watchOrder: [String: Int]) -> SessionRow {
        let m = s.machine
        let current = currentOf(s.sessionId)
        let usage = ownsCurrent(s.sessionId) ? usageLines[current]?.usage : nil
        let live = liveOf(s.sessionId)
        let record = stored[row: s.sessionId]
        let watch = record.watch.flatMap { colour in
            watchOrder[s.sessionId].map { RowWatch(colour: colour, order: $0) }
        }
        var row = SessionRow(
            sessionId: s.sessionId, currentId: current == s.sessionId ? nil : current,
            resumeId: s.kind == .owned ? resumeIdOf(s) : nil, shortId: s.shortId,
            name: shownName(s), claudeName: nameOf(s), kind: s.kind, pid: s.pid, cwd: s.cwd,
            status: s.status,
            listing: active.contains(s.sessionId)
                ? .listed : unconfirmed[s.sessionId] == nil ? .notListed : .unconfirmed,
            waitingFor: s.waitingFor, state: m.state, alert: m.box.alert,
            lastMessage: m.lastMessage,
            // A usage line is not activity (D8).
            lastActivity: [s.startedAt, s.lastEventAt, s.statusChangedAt].compactMap(\.self).max()
                ?? s.startedAt,
            lastBusyAt: s.lastBusyAt, startedAt: s.startedAt, usage: usage,
            live: live, personPrompt: live ? personPrompts[current] : nil,
            branch: branches[branchDir(s)],
            worktree: record.worktree, priority: record.priority, watch: watch,
            prSession: record.prSession)
        row.resumable = m.state == .parked && resumable.contains(s.sessionId) && !row.prSession
        row.terminalApp = terminalOf(s.sessionId)?.name
        return row
    }
}
