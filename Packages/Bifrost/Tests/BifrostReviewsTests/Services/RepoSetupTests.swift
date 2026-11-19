// The set-up of the review clones and the list of the repositories that need trust
// (docs/behaviour/reviews.md, "Clones and trust"), with the real git, local bare sources and a
// Reviews store in a temporary folder. The trust check reads .claude.json of the temporary folder.
// No test reaches GitHub or reads the real ~/.claude.json.
import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostReviews

private typealias R = Rows

// A runner of the real git that counts the clones that run at one time.
private final class CloneCounter: CommandRunner {
    private struct Counts {
        var now = 0
        var most = 0
        var clones = 0
    }

    private let counts = Mutex(Counts())
    private let inner = ProcessRunner()

    var most: Int { counts.withLock { $0.most } }
    var clones: Int { counts.withLock { $0.clones } }

    func run(_ command: Command) async -> ExecResult {
        let clone = command.arguments.contains("clone")
        if clone {
            counts.withLock {
                $0.now += 1
                $0.clones += 1
                $0.most = max($0.most, $0.now)
            }
        }
        let result = await inner.run(command)
        if clone { counts.withLock { $0.now -= 1 } }
        return result
    }
}

// The repo store fixture with the Reviews store and the set-up.
@MainActor
private struct SetupFixture {
    let repos: RepoFixture
    let counter: CloneCounter
    let store: ReviewsStore
    let notices = Recorder<ReviewsNotice>()
    let setup: RepoSetup
    static let time = Date(timeIntervalSince1970: 1_794_312_000)

    init() async throws {
        let counter = CloneCounter()
        self.counter = counter
        repos = try RepoFixture(runner: counter)
        store = try await ReviewsStore.open(layout: repos.layout, log: Recorder<StoreEvent>())
        let notices = notices
        setup = RepoSetup(
            repos: repos.store, store: store, ptys: nil,
            home: URL(filePath: repos.root, directoryHint: .isDirectory),
            notify: { notices.record($0) }, now: { Self.time })
    }

    func end() async {
        await store.close().value
        repos.folder.remove()
    }

    // Mark the clone of the repository as trusted in .claude.json of the home.
    func trust(_ repos: [RepoName]) throws {
        let entries = repos.map { repo in
            let path = String(self.repos.clone(repo).dropLast())
            return "\"\(path)\": {\"hasTrustDialogAccepted\": true}"
        }
        try "{\"projects\": {\(entries.joined(separator: ", "))}}".write(
            toFile: self.repos.root + "/.claude.json", atomically: false, encoding: .utf8)
    }
}

private func repo(_ text: String) throws -> RepoName { try #require(RepoName(text)) }

@MainActor
@Suite("the set-up of the review clones", .serialized, .timeLimit(.minutes(2)), .tags(.realProcess))
struct RepoSetupTests {
    // The first turn-on clones each repository of the open PRs and requests that is not
    // ignored, one at a time, then lists the ones that need trust with the count of their PRs.
    // It sends no notification, and it records the end of the set-up.
    @Test func theFirstTurnOnClonesOneAtATimeAndSendsNoNotification() async throws {
        let f = try await SetupFixture()
        let (a, b) = (try repo("owner-a/repo-a"), try repo("owner-b/repo-b"))
        let c = try repo("owner-c/repo-c")
        for name in [a, b, c] { try await f.repos.source(name) }
        let answer = R.answer(
            toReview: [try R.pull("owner-a/repo-a#1"), try R.pull("owner-c/repo-c#3")],
            mine: [try R.pull("owner-b/repo-b#2"), try R.pull("owner-a/repo-a#4")])
        let ignored = try #require(IgnoreEntry("owner-c/*"))
        #expect(f.store.state.setUpAt == nil)
        await f.setup.run(for: answer, ignoring: [ignored])
        #expect(await f.repos.store.hasClone(a))
        #expect(await f.repos.store.hasClone(b))
        #expect(!(await f.repos.store.hasClone(c)))
        #expect(f.counter.clones == 2)
        #expect(f.counter.most == 1)
        #expect(f.setup.needsTrust == [a: 2, b: 1])
        #expect(f.setup.cloning.isEmpty)
        #expect(f.setup.clones == CloneStates(needsTrust: [a, b]))
        #expect(f.notices.values.isEmpty)
        #expect(f.store.state.setUpAt == SetupFixture.time)
        #expect(f.store.state.repos.isEmpty)
        // A second poll clones nothing more and sends no notification.
        await f.setup.run(for: answer, ignoring: [ignored])
        #expect(f.counter.clones == 2)
        #expect(f.notices.values.isEmpty)
        await f.end()
    }

    // After the set-up, a repository that shows later gets its clone, and one notification when
    // it needs trust. The notice is kept in the state, so a later poll sends no second one. A
    // trust step takes the repository off the list.
    @Test func aLaterRepoThatNeedsTrustNotifiesOnce() async throws {
        let f = try await SetupFixture()
        let (a, b) = (try repo("owner-a/repo-a"), try repo("owner-b/repo-b"))
        for name in [a, b] { try await f.repos.source(name) }
        let first = R.answer(toReview: [try R.pull("owner-a/repo-a#1")])
        await f.setup.run(for: first, ignoring: [])
        #expect(f.notices.values.isEmpty)
        let later = R.answer(
            toReview: [try R.pull("owner-a/repo-a#1")], mine: [try R.pull("owner-b/repo-b#2")])
        await f.setup.run(for: later, ignoring: [])
        #expect(f.notices.values == [.trustNeeded(b)])
        #expect(f.store.state.repos[b]?.trustNotifiedAt == SetupFixture.time)
        #expect(f.store.state.repos[a] == nil)
        await f.setup.run(for: later, ignoring: [])
        #expect(f.notices.values == [.trustNeeded(b)])
        #expect(f.setup.needsTrust == [a: 1, b: 1])
        // The user trusts the clone: the list drops it, and the waiting work may start.
        let started = Recorder<RepoName>()
        f.setup.onTrusted = { started.record($0) }
        try f.trust([b])
        #expect(await f.setup.isTrusted(b))
        f.setup.trusted(b)
        #expect(f.setup.needsTrust == [a: 1])
        #expect(started.values == [b])
        await f.setup.run(for: later, ignoring: [])
        #expect(f.setup.needsTrust == [a: 1])
        #expect(f.notices.values == [.trustNeeded(b)])
        #expect(started.values == [b])
        // A trust that the next poll finds (no trust step of the panel) starts the work too.
        try f.trust([a, b])
        await f.setup.run(for: later, ignoring: [])
        #expect(f.setup.needsTrust.isEmpty)
        #expect(started.values == [b, a])
        await f.end()
    }

    // A notice comes only after the state saved it: with a closed store (a turn-off), the run
    // sends none. After a stop, a run does nothing.
    @Test func aClosedStoreOrAStopSendsNoNotice() async throws {
        let f = try await SetupFixture()
        await f.store.update { $0.setUpAt = SetupFixture.time }
        let b = try repo("owner-b/repo-b")
        try await f.repos.source(b)
        await f.store.close().value
        let answer = R.answer(mine: [try R.pull("owner-b/repo-b#2")])
        await f.setup.run(for: answer, ignoring: [])
        #expect(f.setup.needsTrust == [b: 1])
        #expect(f.notices.values.isEmpty)
        f.setup.stop()
        let clones = f.counter.clones
        await f.setup.run(for: R.answer(mine: [try R.pull("owner-c/repo-c#3")]), ignoring: [])
        #expect(f.counter.clones == clones)
        #expect(f.notices.values.isEmpty)
        f.repos.folder.remove()
    }

    // A repository whose clone fails, and a repository that needs trust, do not stop the clone
    // and the trust read of the others. The failed clone waits one hour for its next try.
    @Test func anUntrustedRepoDoesNotBlockTheOthers() async throws {
        let f = try await SetupFixture()
        await f.store.update { $0.setUpAt = SetupFixture.time }
        let (a, b) = (try repo("owner-a/repo-a"), try repo("owner-b/repo-b"))
        let c = try repo("owner-c/repo-c")
        for name in [b, c] { try await f.repos.source(name) }
        try f.trust([c])
        let answer = R.answer(mine: [
            try R.pull("owner-a/repo-a#1"), try R.pull("owner-b/repo-b#2"),
            try R.pull("owner-c/repo-c#3"),
        ])
        await f.setup.run(for: answer, ignoring: [])
        #expect(f.repos.store.failedRecently(a))
        #expect(!(await f.repos.store.hasClone(a)))
        #expect(await f.repos.store.hasClone(b))
        #expect(await f.repos.store.hasClone(c))
        #expect(f.setup.needsTrust == [b: 1])
        #expect(f.setup.clones == CloneStates(needsTrust: [b]))
        #expect(f.notices.values == [.trustNeeded(b)])
        // A queued request round of the trusted repository is only queued; the others wait.
        var state = f.store.state
        state.queue = try [1, 2, 3].map { number in
            let key = try R.key(["owner-a/repo-a", "owner-b/repo-b", "owner-c/repo-c"][number - 1]
                + "#\(number)")
            return QueueEntry(pr: key, kind: .request, at: R.at(-1))
        }
        let rows = R.mine(answer, state, clones: f.setup.clones)
        let claude = Dictionary(
            uniqueKeysWithValues: rows.map { ($0.id.repo, $0.mineState?.claude) })
        #expect(claude[c] == .queued)
        #expect(claude[b] == .trustNeeded)
        #expect(claude[a] == .queued)
        // The next poll in the hour does not try the failed clone again.
        let clones = f.counter.clones
        await f.setup.run(for: answer, ignoring: [])
        #expect(f.counter.clones == clones)
        await f.end()
    }

    // What Reviews knows of the trust of a clone apart from the read is one value: a click gives
    // one start only to a clone in the list, a round takes it once, a refusal of claude keeps a
    // start that a click gave, the end of a trust step lifts the refusal and gives one start, a
    // seen trust ends both, and a started session counts as trusted.
    @Test func aCloneHasOneValueOfTrust() async throws {
        let f = try await SetupFixture()
        let a = try repo("owner-a/repo-a")
        f.setup.allowOneStart(a)
        #expect(!f.setup.hasOneStart(a))
        f.setup.waitsForTrust(a, refusedByClaude: false)
        f.setup.allowOneStart(a)
        #expect(f.setup.takeOneStart(a) && !f.setup.takeOneStart(a))
        f.setup.allowOneStart(a)
        f.setup.waitsForTrust(a, refusedByClaude: true)
        #expect(!(await f.setup.trustsForStart(a)))
        #expect(f.setup.hasOneStart(a))
        f.setup.dropOneStarts()
        let refused = await f.setup.trustsForStart(a)
        #expect(!f.setup.hasOneStart(a) && !refused)
        f.setup.stepEnded(a)
        #expect(f.setup.hasOneStart(a))
        f.setup.trusted(a)
        #expect(!f.setup.hasOneStart(a) && f.setup.needsTrust.isEmpty)
        f.setup.startedSession(a)
        #expect(await f.setup.trustsForStart(a))
        f.setup.stepEnded(a)
        let started = await f.setup.trustsForStart(a)
        #expect(!f.setup.hasOneStart(a) && started)
        await f.end()
    }
}
