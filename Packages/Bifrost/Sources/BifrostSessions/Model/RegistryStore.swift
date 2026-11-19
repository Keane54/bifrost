import BifrostFoundation
import Foundation

// The stored values of one row. RegistryStore keeps them by row ID. A row with no stored value has
// no record.
struct RowRecord: Sendable, Equatable {
    // The name of the last real entry of the session.
    var name: String?
    // The local name. Bifrost shows it and never sends it to Claude Code.
    var alias: String?
    var priority: SessionPriority?
    // The colour of a watched row. RegistryStore.watchlist keeps the order of the watchlist.
    var watch: WatchColour?
    // The worktree root, from a sample while the session ran.
    var worktree: String?
    // The short ID of a background row.
    var job: ShortID?
    // The current ID, when it is not the row ID (after a /clear).
    var current: String?
    // True for a session that Bifrost started.
    var started = false
    // True for a review session of a PR. It gets no yellow box and no Resume all.
    var prSession = false
    // True for a session that ran in the last run. Resume all uses it.
    var lastActive = false

    var isEmpty: Bool { self == RowRecord() }

    // True when the record makes its row ID known, so a new row cannot get that ID: the record
    // has a value other than the PR flag. The PR flag alone does not.
    var makesRowKnown: Bool {
        var values = self
        values.prSession = false
        return !values.isEmpty
    }

    // True when the gone count of the counted --all lists watches the row: the record has a
    // value other than the PR flag and lastActive. A lastActive value goes after its grace time.
    var countsForGone: Bool {
        var values = self
        values.prSession = false
        values.lastActive = false
        return !values.isEmpty
    }
}

// The data that the registry saves between runs of Bifrost: a record for each row, the order of
// the watchlist, the deferred deletes and the PR names. The file has the form of the file of the
// Electron app, so each app reads the file of the other. An empty prSessions, prNames or
// deferred value is not in the file.
package struct RegistryStore: Sendable, Equatable {
    // The record of each row, by row ID. No record is empty.
    private(set) var rows: [String: RowRecord] = [:]
    // The row IDs of the watchlist in its order: each row whose record has a watch colour, one
    // time.
    private(set) var watchlist: [String] = []
    // The deferred deletes, in the order of the defers. A deferred row ID is not a row.
    package var deferred: [DeferredDelete] = []
    // The names of the PR sessions that Bifrost starts.
    package var prNames: Set<String> = []
    // The top-level fields of registry.json that this app does not know. A save writes them
    // again, so a file of a later app loses nothing.
    package var unknown = UnknownFields()

    package init() {}

    // A store from the values of the store file. A repeated watch entry keeps its first colour.
    package init(
        aliases: [String: String] = [:], current: [String: String] = [:],
        deferred: [DeferredDelete] = [], jobs: [String: ShortID] = [:],
        lastActive: Set<String> = [], names: [String: String] = [:],
        prSessions: Set<String> = [], prNames: Set<String> = [], started: Set<String> = [],
        priorities: [String: SessionPriority] = [:], watch: [WatchEntry] = [],
        worktrees: [String: String] = [:]
    ) {
        self.deferred = deferred
        self.prNames = prNames
        fill(\.name, names)
        fill(\.alias, aliases)
        fill(\.priority, priorities)
        fill(\.worktree, worktrees)
        fill(\.job, jobs)
        fill(\.current, current)
        mark(\.started, started)
        mark(\.prSession, prSessions)
        mark(\.lastActive, lastActive)
        for entry in watch where self[row: entry.sessionId].watch == nil {
            self[row: entry.sessionId].watch = entry.colour
        }
    }

    // The record of a row. A row with no record gives an empty record, and an empty record
    // removes the row. A row that gets a watch colour goes to the end of the watchlist. A row
    // that loses its colour leaves the watchlist.
    subscript(row rowId: String) -> RowRecord {
        get { rows[rowId] ?? RowRecord() }
        set {
            let watched = rows[rowId]?.watch != nil
            rows[rowId] = newValue.isEmpty ? nil : newValue
            if !watched && newValue.watch != nil { watchlist.append(rowId) }
            if watched && newValue.watch == nil { watchlist.removeAll { $0 == rowId } }
        }
    }

    // Move a watched row before another watched row. nil, or a row that is not watched, moves
    // it to the end.
    mutating func moveWatch(_ rowId: String, before beforeId: String?) {
        guard beforeId != rowId, let from = watchlist.firstIndex(of: rowId) else { return }
        watchlist.remove(at: from)
        let to = beforeId.flatMap { watchlist.firstIndex(of: $0) } ?? watchlist.count
        watchlist.insert(rowId, at: to)
    }

    private mutating func fill<Value>(
        _ key: WritableKeyPath<RowRecord, Value?>, _ values: [String: Value]
    ) {
        for (rowId, value) in values {
            self[row: rowId][keyPath: key] = value
        }
    }

    private mutating func mark(_ key: WritableKeyPath<RowRecord, Bool>, _ rowIds: Set<String>) {
        for rowId in rowIds { self[row: rowId][keyPath: key] = true }
    }
}

extension RegistryStore {
    // The values of the store file, one map or one set of row IDs for each value of a record.
    package var names: [String: String] { rows.compactMapValues(\.name) }
    package var aliases: [String: String] { rows.compactMapValues(\.alias) }
    package var priorities: [String: SessionPriority] { rows.compactMapValues(\.priority) }
    package var worktrees: [String: String] { rows.compactMapValues(\.worktree) }
    package var jobs: [String: ShortID] { rows.compactMapValues(\.job) }
    package var current: [String: String] { rows.compactMapValues(\.current) }
    package var started: Set<String> { rowIds(\.started) }
    package var prSessions: Set<String> { rowIds(\.prSession) }
    package var lastActive: Set<String> { rowIds(\.lastActive) }

    // The watched rows in the order of the watchlist.
    package var watch: [WatchEntry] {
        watchlist.compactMap { rowId in rows[rowId]?.watch.map { WatchEntry(rowId, $0) } }
    }

    private func rowIds(_ flag: KeyPath<RowRecord, Bool>) -> Set<String> {
        Set(rows.filter { $0.value[keyPath: flag] }.keys)
    }
}

extension RegistryStore: Codable {
    enum Key: String, CodingKey {
        case aliases, current, deferred, jobs, lastActive, names, prSessions, prNames, started
        case priorities, watch, worktrees
    }

    private struct WorktreeLine: Codable {
        var path: String
        var sessionId: String
    }

    private struct WatchLine: Decodable {
        var sessionId: String
        var colour: String
    }

    private struct DeferredLine: Decodable {
        var sessionId: String
        var shortId: String
        var worktree: String
        var job: String?

        enum CodingKeys: String, CodingKey { case sessionId, shortId, worktree, job }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessionId = try c.decode(String.self, forKey: .sessionId)
            shortId = try c.decode(String.self, forKey: .shortId)
            worktree = try c.decode(String.self, forKey: .worktree)
            // The job value is optional. A job value of the wrong type is dropped.
            job = try? c.decode(String.self, forKey: .job)
        }
    }

    // The load rules of the store file. Each value with the wrong type goes, and the other values
    // stay. A field that is missing (from an older version) gives its empty value.
    // Each row ID in the UUID form is lower case (rowId, row D25 of docs/ports/registry), in each
    // map key and in each list. When two keys of a map give one row ID, the key that is already
    // lower case wins, then the first key in sort order. In a list, the first entry of a row ID
    // wins.
    // The load trims a local name, and drops a bad or empty one. A current ID must be a session
    // ID (SessionID, kept in lower case) that is not its row ID. A short ID must be a ShortID.
    // The load drops a watch entry with a bad colour or a repeated ID, and maps an old colour
    // name to its new colour. A worktree entry needs a path that WorktreeRoot(cwd:) accepts, and
    // the load drops a repeated ID. A deferred delete needs a non-empty ID, a short ID and a
    // worktree root, and the load drops a repeated ID.
    // The store keeps the unknown fields of the object. An unknown value with no JSON form
    // throws, so the store keeps a copy of the file.
    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        func record<V: Decodable>(_ key: Key, _: V.Type) -> [String: V] {
            Self.byRowId(
                ((try? c.decode([String: Lenient<V>].self, forKey: key)) ?? [:])
                    .compactMapValues(\.decoded))
        }
        func list<V: Decodable>(_ key: Key, _: V.Type) -> [V] {
            ((try? c.decode([Lenient<V>].self, forKey: key)) ?? []).compactMap(\.decoded)
        }
        func rowIds(_ key: Key) -> Set<String> { Set(list(key, String.self).map(Self.rowId)) }
        let watch = list(.watch, WatchLine.self).compactMap { line in
            WatchColour(storedName: line.colour).map { WatchEntry(Self.rowId(line.sessionId), $0) }
        }
        var worktrees: [String: String] = [:]
        for line in list(.worktrees, WorktreeLine.self) {
            let rowId = Self.rowId(line.sessionId)
            guard worktrees[rowId] == nil, WorktreeRoot(cwd: line.path) != nil else { continue }
            worktrees[rowId] = line.path
        }
        var deferred: [DeferredDelete] = []
        for line in list(.deferred, DeferredLine.self) {
            let rowId = Self.rowId(line.sessionId)
            guard !rowId.isEmpty, let shortId = ShortID(line.shortId),
                WorktreeRoot.isRoot(line.worktree),
                !deferred.contains(where: { $0.sessionId == rowId })
            else { continue }
            deferred.append(
                DeferredDelete(
                    sessionId: rowId, shortId: shortId, worktree: line.worktree,
                    job: line.job.flatMap { ShortID($0) }))
        }
        self.init(
            aliases: record(.aliases, String.self).compactMapValues { value in
                guard let name = try? cleanAlias(value), !name.isEmpty else { return nil }
                return name
            },
            current: record(.current, String.self).compactMapValues { SessionID($0)?.text }
                .filter { $0.value != $0.key },
            deferred: deferred,
            jobs: record(.jobs, String.self).compactMapValues { ShortID($0) },
            lastActive: rowIds(.lastActive),
            names: record(.names, String.self),
            prSessions: rowIds(.prSessions),
            prNames: Set(list(.prNames, String.self)),
            started: rowIds(.started),
            priorities: record(.priorities, Int.self)
                .compactMapValues(SessionPriority.init(rawValue:)),
            watch: watch, worktrees: worktrees)
        unknown = try UnknownFields(from: decoder, known: Key.self)
    }

    // The row ID of an ID of the store file: a session ID in the UUID form in lower case, else
    // the ID as it is.
    private static func rowId(_ id: String) -> String { SessionID(id)?.text ?? id }

    // The values by row ID. When two keys give one row ID, the key that is already lower case
    // wins, then the first key in sort order: a JSON object gives the decoder no order.
    private static func byRowId<V>(_ values: [String: V]) -> [String: V] {
        let keys = values.keys.sorted { a, b in
            (rowId(a) == a ? 0 : 1, a) < (rowId(b) == b ? 0 : 1, b)
        }
        var result: [String: V] = [:]
        for key in keys where result[rowId(key)] == nil { result[rowId(key)] = values[key] }
        return result
    }

    // The sets and the worktrees go out sorted, so the same store gives the same file. The
    // watchlist and the deferred deletes keep their order.
    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(aliases, forKey: .aliases)
        try c.encode(current, forKey: .current)
        try c.encode(jobs, forKey: .jobs)
        try c.encode(lastActive.sorted(), forKey: .lastActive)
        try c.encode(names, forKey: .names)
        try c.encode(priorities, forKey: .priorities)
        try c.encode(started.sorted(), forKey: .started)
        try c.encode(watch, forKey: .watch)
        let lines = worktrees.sorted { $0.key < $1.key }
            .map { WorktreeLine(path: $0.value, sessionId: $0.key) }
        try c.encode(lines, forKey: .worktrees)
        if !prSessions.isEmpty { try c.encode(prSessions.sorted(), forKey: .prSessions) }
        if !prNames.isEmpty { try c.encode(prNames.sorted(), forKey: .prNames) }
        if !deferred.isEmpty { try c.encode(deferred, forKey: .deferred) }
        try unknown.encode(to: encoder)
    }
}
