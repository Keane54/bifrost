import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostSessions

// The row IDs of the fixture registry.json.
private let job = "2f493bf0-1598-4b3b-b419-8acb9cb11bcb"
private let notes = "5c0e7a3e-6b8d-4f0f-9a51-3d2f4e8b7c11"
private let review = "8a1d4c55-0e2b-4c3e-8f6a-7b9d0e1f2a34"
private let nightly = "c3b2a190-7e6d-4f5c-8b4a-392817160514"
private let worktrees = "/Users/user/Developer/app/.claude/worktrees"

// The values of the fixture registry.json, as the file names them, and its two unknown fields.
private let fixtureStore = withUnknownFields(RegistryStore(
    aliases: [job: "Login fix"], current: [job: "1db82d17-d5fd-4e53-a042-7dd67ea654d8"],
    deferred: [
        DeferredDelete(
            sessionId: "d4e5f6a7-1111-4222-8333-444455556666", shortId: "d4e5f6a7",
            worktree: "\(worktrees)/old-spike", job: "d4e5f6a7"),
        DeferredDelete(
            sessionId: "0b1c2d3e-7777-4888-8999-aaaabbbbcccc", shortId: "0b1c2d3e",
            worktree: "\(worktrees)/old-spike"),
    ],
    jobs: [job: "2f493bf0", review: "8a1d4c55", nightly: "c3b2a190"],
    lastActive: [job, nightly],
    names: [
        job: "fix-login-flow", notes: "notes", review: "app-42-review", nightly: "nightly-tests",
    ],
    prSessions: [review], prNames: ["app-42-review", "app-43-review"], started: [job, review],
    priorities: [job: .p2, notes: .p4], watch: [WatchEntry(notes, .red), WatchEntry(job, .amber)],
    worktrees: [job: "\(worktrees)/fix-login", notes: "\(worktrees)/docs-pass"]))

private func withUnknownFields(_ store: RegistryStore) -> RegistryStore {
    var store = store
    store.unknown = UnknownFields([
        "futureField": ["level": 3, "tags": ["a", true, .null]], "schema": 2,
    ])
    return store
}

@Suite("the row records of the store", .testTimeLimit)
struct StoreRecordTests {
    // The fixture is a file that the app wrote: sorted keys, the watchlist and the deferred
    // deletes in their order, and two top-level fields that this app does not know.
    @Test("a registry.json that the app wrote loads to its values and saves to the same bytes")
    func fileRoundTrip() throws {
        let fixture = try Fixture.data("registry.json")
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let dir = temp.url
        let file = dir.appendingPathComponent("registry.json")
        try fixture.write(to: file)
        let log = Recorder<StoreEvent>()
        let opened = StoreFile.open(path: file.path, log: log)
        #expect(opened.store == fixtureStore)
        // The store goes through the registry, as in the app.
        let store = registry(opened.store).store()
        #expect(store == fixtureStore)
        try opened.saver.save(store)
        let saved = try Data(contentsOf: file)
        #expect(String(decoding: saved, as: UTF8.self) == String(decoding: fixture, as: UTF8.self))
        #expect(log.values.isEmpty)
    }

    @Test("each row keeps its stored values in one record")
    func oneRecordForEachRow() {
        #expect(
            fixtureStore.rows == [
                job: RowRecord(
                    name: "fix-login-flow", alias: "Login fix", priority: .p2, watch: .amber,
                    worktree: "\(worktrees)/fix-login", job: "2f493bf0",
                    current: "1db82d17-d5fd-4e53-a042-7dd67ea654d8", started: true,
                    lastActive: true),
                notes: RowRecord(
                    name: "notes", priority: .p4, watch: .red, worktree: "\(worktrees)/docs-pass"),
                review: RowRecord(
                    name: "app-42-review", job: "8a1d4c55", started: true, prSession: true),
                nightly: RowRecord(name: "nightly-tests", job: "c3b2a190", lastActive: true),
            ])
        // A deferred row ID and a PR name are not rows.
        #expect(fixtureStore.deferred.count == 2)
        #expect(fixtureStore.prNames.count == 2)
    }

    @Test("a record with no value goes")
    func emptyRecordGoes() {
        var store = RegistryStore(
            names: ["a": "alpha"], prSessions: ["b"], watch: [.init("c", .red)])
        store[row: "a"].name = nil
        store[row: "b"].prSession = false
        store[row: "c"].watch = nil
        #expect(store.rows.isEmpty)
        #expect(store.watch.isEmpty)
        #expect(store == RegistryStore())
        #expect(store[row: "a"] == RowRecord())
    }

    @Test("a watch colour puts the row at the end of the watchlist, and a new colour keeps it")
    func watchlistOrder() {
        // A repeated row keeps its first colour.
        var store = RegistryStore(watch: [.init("b", .red), .init("a", .amber), .init("b", .green)])
        #expect(store.watch == [.init("b", .red), .init("a", .amber)])
        store[row: "c"].watch = .white
        store[row: "b"].watch = .green
        #expect(store.watch == [.init("b", .green), .init("a", .amber), .init("c", .white)])
        store[row: "a"].watch = nil
        #expect(store.watch == [.init("b", .green), .init("c", .white)])
        store[row: "a"].watch = .yellow
        #expect(store.watch.map(\.sessionId) == ["b", "c", "a"])
    }
}
