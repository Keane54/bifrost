import BifrostFoundation
import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostReviews

// The store of state.json and the take-over of the Electron state (docs/behaviour/reviews.md,
// "The state"). Each test uses a Reviews folder in its own temporary folder and copies of the
// fixtures, never the real ~/.bifrost.

private let nowMs = 1_794_100_000_000
private let now = time(nowMs)

private func time(_ milliseconds: Int) -> Date {
    Date(timeIntervalSince1970: Double(milliseconds) / 1000)
}

private func key(_ text: String) throws -> PRKey {
    try #require(PRKey(text: text))
}

private func node(_ text: String) throws -> NodeID {
    try #require(NodeID(text))
}

// A test home with the Reviews folder <home>/.bifrost/reviews. The folder is not made.
private func home() throws -> (folder: TemporaryFolder, layout: ReviewsLayout) {
    let folder = try TemporaryFolder()
    let reviews = folder.url.appending(path: ".bifrost/reviews", directoryHint: .isDirectory)
    return (folder, ReviewsLayout(folder: reviews))
}

// Put the bytes at the URL, with its folder.
private func put(_ data: Data, at url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

private func mode(_ url: URL) -> mode_t {
    var info = stat()
    guard lstat(path(url), &info) == 0 else { return 0 }
    return info.st_mode & 0o777
}

// The state that a new read of the saved file gives.
private func reread(_ layout: ReviewsLayout) throws -> ReviewsState {
    try JSONDecoder().decode(StoredReviewsState.self, from: Data(contentsOf: layout.stateFile))
        .state
}

// The steps of a safe write that fail at the rename while fail is on. A gate can hold each write
// before its sync.
private final class FailingSteps: Sendable {
    private let failing = Mutex(false)
    private let gate: WriteGate?

    init(gate: WriteGate? = nil) {
        self.gate = gate
    }

    func fail(_ on: Bool) {
        failing.withLock { $0 = on }
    }

    var steps: WriteSteps {
        let base = gate?.steps ?? .system
        return WriteSteps(
            sync: base.sync,
            rename: { [self] from, to in
                if failing.withLock({ $0 }) { throw POSIXError(.EIO) }
                try base.rename(from, to)
            })
    }
}

@MainActor
private func openStore(
    _ layout: ReviewsLayout, log: Recorder<StoreEvent> = .init(), steps: WriteSteps = .system
) async throws(ReviewsStoreError) -> ReviewsStore {
    try await ReviewsStore.open(layout: layout, log: log, now: now, steps: steps)
}

// Open a store whose writes wait at the gate, and let the take-over save through. The task of
// the open ends here, so it does not keep the store.
@MainActor
private func openThroughGate(
    _ layout: ReviewsLayout, _ gate: WriteGate
) async throws -> ReviewsStore {
    let opening = Task { try await openStore(layout, steps: gate.steps) }
    try #require(await gate.waitUntilWriting())
    gate.open()
    return try await opening.value
}

@MainActor
@Suite("the Reviews store", .testTimeLimit)
struct ReviewsStoreTests {
    // The first open copies state.json byte for byte to state.json.before-native, with the mode
    // 0600, before it saves. With no state.json, the copy is empty.
    @Test func theFirstOpenKeepsACopyOfTheElectronFile() async throws {
        let (folder, layout) = try home()
        defer { folder.remove() }
        let electron = try FixtureFiles.data("state-request-round")
        try put(electron, at: layout.stateFile)
        let store = try await openStore(layout)
        #expect(store.tookOver)
        #expect(try Data(contentsOf: layout.stateCopy) == electron)
        #expect(mode(layout.stateCopy) == 0o600)
        #expect(try Data(contentsOf: layout.stateFile) != electron)
        await store.close().value

        let (empty, fresh) = try home()
        defer { empty.remove() }
        let first = try await openStore(fresh)
        #expect(first.tookOver)
        #expect(try Data(contentsOf: fresh.stateCopy) == Data())
        #expect(try reread(fresh).autoFixConsent == false)
        await first.close().value
    }

    // A later open makes no copy and takes nothing over: the copy keeps the Electron bytes.
    @Test func theCopyIsMadeOnlyOnce() async throws {
        let (folder, layout) = try home()
        defer { folder.remove() }
        let electron = try FixtureFiles.data("state-first-release")
        try put(electron, at: layout.stateFile)
        let first = try await openStore(layout)
        await first.update { $0.setUpAt = now }
        await first.close().value

        let second = try await openStore(layout)
        #expect(!second.tookOver)
        #expect(second.state.setUpAt == now)
        #expect(try Data(contentsOf: layout.stateCopy) == electron)
        await second.update { $0.setUpAt = nil }
        await second.close().value
        #expect(try Data(contentsOf: layout.stateCopy) == electron)
    }

    // The fields that the read of state.json dropped go to the log one time in a run of the app:
    // a second open of the same file in the run logs nothing more, and a new run logs them again.
    // A damaged CI mark reads with no fix and no re-run left.
    @Test func aDroppedFieldIsLoggedOneTimeInARun() async throws {
        let (folder, layout) = try home()
        defer { folder.remove() }
        let head = String(repeating: "a", count: 40)
        let text = """
            {"version": 1, "prs": {"owner-a/repo-a#1": {
            "ci": {"chain": ["\(head)"], "fixes": "two"},
            "conflict": {"head": "\(head)", "base": "\(head)", "at": 1, "outcome": "later"}}}}
            """
        try put(Data(text.utf8), at: layout.stateFile)
        // A safety copy that differs from the file: no take-over, so the open does not save.
        try put(Data("{}".utf8), at: layout.stateCopy)
        let events = Recorder<StoreEvent>()
        let run = ReviewsStoreLog(base: events)
        let first = try await ReviewsStore.open(layout: layout, log: run, now: now)
        let pr = try key("owner-a/repo-a#1")
        #expect(first.state.prs[pr]?.ci?.fixes == CIRule.maxFixes)
        #expect(first.state.prs[pr]?.conflict?.outcome == .failed(""))
        await first.close().value
        #expect(try Data(contentsOf: layout.stateFile) == Data(text.utf8))
        let second = try await ReviewsStore.open(layout: layout, log: run, now: now)
        await second.close().value
        let path = layout.stateFile.path(percentEncoded: false)
        let names = ["prs.ci.fixes", "prs.conflict.outcome"]
        #expect(events.values == [.defaulted(file: path, keys: names)])
        let next = try await ReviewsStore.open(
            layout: layout, log: ReviewsStoreLog(base: events), now: now)
        await next.close().value
        #expect(events.values == Array(repeating: .defaulted(file: path, keys: names), count: 2))
    }

    // A quit after the copy and before the first save leaves state.json equal to the copy. The
    // next open takes the state over again, and the copy stays as it is.
    @Test func aTakeOverThatDidNotSaveRunsAgain() async throws {
        let (folder, layout) = try home()
        defer { folder.remove() }
        let electron = try FixtureFiles.data("state-request-round")
        try put(electron, at: layout.stateFile)
        try put(electron, at: layout.stateCopy)
        let store = try await openStore(layout)
        #expect(store.tookOver)
        #expect(try store.state.prs[key("owner-a/repo-b#7")]?.outbox == nil)
        #expect(try Data(contentsOf: layout.stateCopy) == electron)
        await store.close().value
    }

    // Each outbox of the Electron state goes: the items whose writes all went are handled, and
    // the other items are held with the reason. Each request round stops and holds its items,
    // and the request entries of the queue go with their clicks. Nothing is left for a resume
    // to send, in the state or in the file.
    @Test func anAdoptedOutboxIsHeldAndNeverSent() async throws {
        let (folder, layout) = try home()
        defer { folder.remove() }
        try put(FixtureFiles.data("state-request-round"), at: layout.stateFile)
        let store = try await openStore(layout)
        let state = store.state
        let reason = "Bifrost stopped this round before it finished. Choose Try again."

        let fixing = try #require(state.prs[key("owner-a/repo-b#7")])
        #expect(fixing.outbox == nil && fixing.round == nil)
        #expect(
            try fixing.handled[node("PRRT_kwDOexample12")]
                == Handled(at: now, lastReplyAt: time(1_794_002_500_000)))
        #expect(
            try fixing.held == [
                node("PRRT_kwDOexample17"), node("IC_kwDOexample13"), node("PRRT_kwDOexample14"),
            ])
        #expect(fixing.lastError == reason)
        #expect(!fixing.handleOlder)
        #expect(fixing.questions.count == 1 && fixing.handled.count == 2)

        let signed = try #require(state.prs[key("owner-a/repo-a#11")])
        #expect(signed.outbox == nil)
        #expect(try signed.held == [node("PRRT_kwDOexample19")] && signed.lastError == reason)

        let running = try #require(state.prs[key("owner-a/repo-b#10")])
        #expect(running.round == nil)
        #expect(try running.held == [node("PRRT_kwDOexample18")] && running.lastError == reason)
        #expect(running.requestSession?.name == "repo-b-10-request")

        let queued = try #require(state.prs[key("owner-a/repo-b#8")])
        #expect(!queued.handleOlder && !queued.handleCopilot && queued.lastError == nil)
        #expect(try state.queue.map(\.pr) == [key("owner-a/repo-a#9")])
        #expect(state.queue.first?.kind == .review)
        #expect(state.posted.count == 1 && state.repos.count == 2)

        #expect(state.prs.values.allSatisfy { $0.outbox == nil && $0.round?.kind != .request })
        #expect(try reread(layout) == state)
        await store.close().value
    }

    // The poll gives the key in lower case. It finds the PR of the Electron key in another case,
    // with its handled items, its pause and its hidden mark, and the save keeps the spelling of
    // the file.
    @Test func aMixedCaseElectronKeyIsFoundAfterTheTakeOver() async throws {
        let (folder, layout) = try home()
        defer { folder.remove() }
        try put(FixtureFiles.data("state-mixed-case"), at: layout.stateFile)
        let store = try await openStore(layout)
        let repo = try #require(RepoName(owner: "owner-a", name: "repo-b"))
        let polled = try #require(PRKey(repo: repo, number: 12))
        #expect(
            try store.state.prs[polled]?.handled[node("PRRT_kwDOexample20")]
                == Handled(at: time(1_794_001_000_000), lastReplyAt: time(1_794_000_900_000)))
        #expect(store.state.pauses[polled] == time(1_794_009_000_000))
        #expect(store.state.hidden[polled] == time(1_794_005_000_000))
        #expect(store.state.requests[polled] != nil)
        let saved = try readSaved(layout.stateFile).fields
        #expect(saved?["prs"]?.object?.keys.sorted() == ["Owner-A/Repo-B#12"])
        #expect(saved?["hidden"] == ["Owner-A/Repo-B#12": 1_794_005_000_000])
        await store.close().value
    }

    // The take-over turns the consent of the automatic rounds off and starts the new work now,
    // whatever the Electron state says. A later open keeps both.
    @Test func theTakeOverSetsNoConsentAndFixFromNow() async throws {
        let (folder, layout) = try home()
        defer { folder.remove() }
        try put(FixtureFiles.data("state-request-round"), at: layout.stateFile)
        let store = try await openStore(layout)
        #expect(store.state.autoFixConsent == false)
        #expect(store.state.fixFrom == now)
        let saved = try readSaved(layout.stateFile).fields
        #expect(saved?["autoFixConsent"] == false)
        #expect(saved?["fixFrom"] == .int(nowMs))
        await store.close().value

        let later = try await openStore(layout)
        #expect(!later.tookOver)
        #expect(later.state.autoFixConsent == false && later.state.fixFrom == now)
        await later.close().value
    }

    // A file that does not parse gives the empty state. The store copies it to
    // state.json.unreadable before its first save, then saves.
    @Test func anUnreadableFileIsKeptBeforeTheFirstSave() async throws {
        let (folder, layout) = try home()
        defer { folder.remove() }
        try await openStore(layout).close().value
        let broken = Data("{ \"version\": 1, ".utf8)
        try put(broken, at: layout.stateFile)
        let unreadable = layout.folder.appending(path: "state.json.unreadable")

        let log = Recorder<StoreEvent>()
        let store = try await openStore(layout, log: log)
        #expect(!store.tookOver)
        #expect(store.state == ReviewsState())
        #expect(!FileManager.default.fileExists(atPath: path(unreadable)))
        await store.update { $0.turnedOnAt = now }
        #expect(try Data(contentsOf: unreadable) == broken)
        #expect(try reread(layout).turnedOnAt == now)
        let kept = StoreEvent.keptUnreadableCopy(
            file: path(layout.stateFile), copy: path(unreadable))
        #expect(log.values == [kept])
        await store.close().value
    }

    // Each update changes the state at once. The saves run one at a time, and the file gets the
    // newest state last: an update that waits gives its place to a newer one.
    @Test func updatesSaveInOrderWithTheNewestLast() async throws {
        let (folder, layout) = try home()
        defer { folder.remove() }
        let gate = WriteGate()
        defer { gate.openAll() }
        let opening = Task { try await openStore(layout, steps: gate.steps) }
        try #require(await gate.waitUntilWriting())
        gate.open()
        let store = try await opening.value
        #expect(gate.writes == 1)

        let first = Task.immediate { await store.update { $0.turnedOnAt = time(1) } }
        try #require(await gate.waitUntilWriting())
        let second = Task.immediate { await store.update { $0.turnedOnAt = time(2) } }
        let third = Task.immediate { await store.update { $0.turnedOnAt = time(3) } }
        #expect(store.state.turnedOnAt == time(3))
        gate.openAll()
        let results = [await first.value, await second.value, await third.value]
        #expect(results == [true, true, true])
        #expect(gate.writes == 3)
        #expect(try reread(layout).turnedOnAt == time(3))
        await store.close().value
    }

    // A failed write gives false and keeps the change in the state. The next update writes again,
    // also when it changes nothing, and gives true when the file holds the change.
    @Test func aFailedWriteGivesFalseAndTheNextUpdateTriesAgain() async throws {
        let (folder, layout) = try home()
        defer { folder.remove() }
        let failing = FailingSteps()
        let log = Recorder<StoreEvent>()
        let store = try await openStore(layout, log: log, steps: failing.steps)
        failing.fail(true)
        #expect(await store.update { $0.setUpAt = now } == false)
        #expect(store.state.setUpAt == now)
        #expect(try reread(layout).setUpAt == nil)
        guard case .saveFailed(let what, _)? = log.values.last else {
            Issue.record("No saveFailed line in the log.")
            return
        }
        #expect(what == "the Reviews state")
        failing.fail(false)
        #expect(await store.update { _ in })
        #expect(try reread(layout).setUpAt == now)
        await store.close().value
    }

    // A save that the saver skips (the save is off, because the copy of a file that does not
    // parse failed) gives false, and the file stays as it is.
    @Test func aSkippedWriteGivesFalse() async throws {
        let (folder, layout) = try home()
        defer { folder.remove() }
        try await openStore(layout).close().value
        let broken = Data("{ broken".utf8)
        try put(broken, at: layout.stateFile)
        // A folder with a file in it at the path of the copy makes the copy fail.
        try put(Data(), at: layout.folder.appending(path: "state.json.unreadable/keep"))
        let store = try await openStore(layout)
        #expect(await store.update { $0.setUpAt = now } == false)
        #expect(try Data(contentsOf: layout.stateFile) == broken)
        await store.close().value
    }

    // Saves that wait while a write runs merge into one write. Each update gets the result of
    // the write that carried its change: the first write saved, and the merged write failed.
    @Test func aMergedSaveGivesEachUpdateTheResultOfItsWrite() async throws {
        let (folder, layout) = try home()
        defer { folder.remove() }
        let gate = WriteGate()
        defer { gate.openAll() }
        let failing = FailingSteps(gate: gate)
        let opening = Task { try await openStore(layout, steps: failing.steps) }
        try #require(await gate.waitUntilWriting())
        gate.open()
        let store = try await opening.value

        let first = Task.immediate { await store.update { $0.setUpAt = time(1) } }
        try #require(await gate.waitUntilWriting())
        let second = Task.immediate { await store.update { $0.setUpAt = time(2) } }
        let third = Task.immediate { await store.update { $0.setUpAt = time(3) } }
        gate.open()
        #expect(await first.value)
        try #require(await gate.waitUntilWriting())
        failing.fail(true)
        gate.open()
        #expect(await second.value == false)
        #expect(await third.value == false)
        #expect(gate.writes == 2)
        #expect(try reread(layout).setUpAt == time(1))
        await store.close().value
    }

    // An update after the close changes nothing and gives false.
    @Test func anUpdateAfterTheCloseIsNotSaved() async throws {
        let (folder, layout) = try home()
        defer { folder.remove() }
        let store = try await openStore(layout)
        await store.close().value
        #expect(await store.update { $0.setUpAt = now } == false)
        #expect(store.state.setUpAt == nil)
        #expect(try reread(layout).setUpAt == nil)
    }

    // A file of a newer or an unknown version stops the open, and nothing writes a file: no copy,
    // no save and no unreadable copy. The lock is free after each refusal.
    @Test func aFileOfAnotherVersionIsNeverWritten() async throws {
        let (folder, layout) = try home()
        defer { folder.remove() }
        let later = try FixtureFiles.edited("state-request-round") { $0["version"] = 2 }
        try put(later, at: layout.stateFile)
        await #expect(throws: ReviewsStoreError.laterVersion) { try await openStore(layout) }
        await #expect(throws: ReviewsStoreError.laterVersion) { try await openStore(layout) }
        #expect(try Data(contentsOf: layout.stateFile) == later)
        #expect(try names(layout.folder) == [".lock", "state.json"])

        let unknown = try FixtureFiles.edited("state-request-round") {
            $0.removeValue(forKey: "version")
        }
        try put(unknown, at: layout.stateFile)
        await #expect(throws: ReviewsStoreError.unknownVersion) { try await openStore(layout) }
        #expect(try Data(contentsOf: layout.stateFile) == unknown)
        #expect(try names(layout.folder) == [".lock", "state.json"])
        #expect(ReviewsStoreError.laterVersion.message.contains("newer version of Bifrost"))
        #expect(ReviewsStoreError.unknownVersion.message.contains("leaves that data as it is"))
    }

    // A store that its owner drops while a save runs keeps its lock until the save ends, so a new
    // open never reads the file under a late write.
    @Test func aDroppedStoreKeepsTheLockUntilItsSavesEnd() async throws {
        let (folder, layout) = try home()
        defer { folder.remove() }
        let gate = WriteGate()
        defer { gate.openAll() }
        var store: ReviewsStore? = try await openThroughGate(layout, gate)
        weak let watched = store
        let pending = Task.immediate { [store] in
            await store?.update { $0.setUpAt = now } ?? false
        }
        store = nil
        try #require(await gate.waitUntilWriting())
        await #expect(throws: ReviewsStoreError.otherCopy) { try await openStore(layout) }
        gate.open()
        #expect(await pending.value)
        await waitUntil { watched == nil }
        let next = try await openStore(layout)
        #expect(next.state.setUpAt == now)
        await next.close().value
    }

    // A root that is not an object is a file that does not parse: the store keeps it in
    // state.json.unreadable before its first save, and the log says where the copy is.
    @Test func aRootThatIsNotAnObjectIsKeptAside() async throws {
        let (folder, layout) = try home()
        defer { folder.remove() }
        try await openStore(layout).close().value
        let list = Data("[1, 2]".utf8)
        try put(list, at: layout.stateFile)
        let unreadable = layout.folder.appending(path: "state.json.unreadable")
        let log = Recorder<StoreEvent>()
        let store = try await openStore(layout, log: log)
        #expect(store.state == ReviewsState())
        #expect(await store.update { $0.setUpAt = now })
        #expect(try Data(contentsOf: unreadable) == list)
        let kept = StoreEvent.keptUnreadableCopy(
            file: path(layout.stateFile), copy: path(unreadable))
        #expect(log.values == [kept])
        await store.close().value
    }

    // The take-over of an Electron file that does not parse keeps two copies of its bytes: the
    // safety copy, and the unreadable copy of the first save. Then it saves the taken-over state.
    @Test func theTakeOverOfAFileThatDoesNotParseKeepsBothCopies() async throws {
        let (folder, layout) = try home()
        defer { folder.remove() }
        let broken = Data("{ \"version\": 1, \"prs\": ".utf8)
        try put(broken, at: layout.stateFile)
        let log = Recorder<StoreEvent>()
        let store = try await openStore(layout, log: log)
        #expect(store.tookOver)
        let unreadable = layout.folder.appending(path: "state.json.unreadable")
        #expect(try Data(contentsOf: layout.stateCopy) == broken)
        #expect(try Data(contentsOf: unreadable) == broken)
        #expect(try reread(layout).autoFixConsent == false)
        #expect(try reread(layout).fixFrom == now)
        let kept = StoreEvent.keptUnreadableCopy(
            file: path(layout.stateFile), copy: path(unreadable))
        #expect(log.values == [kept])
        await store.close().value
    }

    // The write of the safety copy never replaces a file that is at its path, and it leaves no
    // temporary file.
    @Test func theSafetyCopyNeverReplacesAFile() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let copy = folder.url.appending(path: "state.json.before-native")
        try put(Data("first".utf8), at: copy)
        #expect(try JSONFile.keepFirstCopy(Data("second".utf8), at: copy) == false)
        #expect(try Data(contentsOf: copy) == Data("first".utf8))
        #expect(try names(folder.url) == ["state.json.before-native"])
    }

    // A file of the state that has unknown fields keeps them through the take-over save.
    @Test func theTakeOverKeepsTheUnknownFields() async throws {
        let (folder, layout) = try home()
        defer { folder.remove() }
        let data = try FixtureFiles.edited("state-hidden-rows") { $0["laterField"] = "kept" }
        try put(data, at: layout.stateFile)
        let store = try await openStore(layout)
        #expect(try readSaved(layout.stateFile).fields?["laterField"] == "kept")
        #expect(store.state.hidden.count == 2)
        await store.close().value
    }
}
