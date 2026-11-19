import BifrostFoundation
import BifrostLayout
import BifrostReviews
import BifrostSessions
import BifrostSettings
import BifrostTestSupport
import BifrostWindows
import Foundation
import Synchronization
import Testing

@testable import BifrostApp

// The Reviews part of the app (docs/behaviour/reviews.md, "The panel" and "Settings > Reviews"):
// the open and the close of the store with Watch GitHub, the settings that reach the watcher, the
// consent of the automatic request rounds and the state of the test port. Each test uses a
// settings store and a Reviews folder in a temporary folder, and the FakeGitHub, so no test
// reaches GitHub or reads the real Reviews folder.

// The wall time of the tests. 2026-11-10 12:00:00 UTC.
@MainActor
private final class Wall {
    var date = Date(timeIntervalSince1970: 1_794_312_000)
}

// The poll answers of the tests: PRs with only the fields that the rows read.
private enum Poll {
    static let viewer = "viewer-a"

    // A PR of a list. requested is the time of the request for the viewer, or for a team with
    // team true.
    static func pr(
        _ number: Int, owner: String = "owner-a", repo: String = "repo-a",
        requested: String = "2026-11-02T10:00:00Z", team: Bool = false, head: String = "aaaa"
    ) -> [String: Any] {
        let reviewer: [String: Any] =
            team
            ? ["__typename": "Team", "slug": "team-a"] : ["__typename": "User", "login": viewer]
        return [
            "number": number, "title": "Change \(number)", "isDraft": false, "additions": 3,
            "deletions": 1, "createdAt": "2026-11-01T09:00:00Z",
            "updatedAt": "2026-11-01T09:00:00Z",
            "repository": ["name": repo, "owner": ["login": owner]], "author": ["login": "user-b"],
            "headRefOid": head, "headRefName": "change-\(number)", "baseRefName": "main",
            "reviewRequests": ["nodes": [["requestedReviewer": reviewer]]],
            "timelineItems": ["nodes": [["createdAt": requested, "requestedReviewer": reviewer]]],
        ]
    }

    static func answer(_ toReview: [[String: Any]]) throws -> Data {
        let data: [String: Any] = [
            "viewer": ["login": viewer], "toReview": ["nodes": toReview], "mine": ["nodes": []],
        ]
        return try JSONSerialization.data(withJSONObject: ["data": data])
    }
}

// The steps of a safe write that pass until the test arms them. Then each write waits at the gate
// before its sync, until the test opens the gate.
private final class ArmedGate: Sendable {
    let gate = TestGate()
    private let armed = Mutex(false)

    func arm() { armed.withLock { $0 = true } }

    var steps: WriteSteps {
        let system = WriteSteps.system
        return WriteSteps(
            sync: { [self] handle in
                if armed.withLock({ $0 }) { gate.passBlocking() }
                try system.sync(handle)
            }, rename: system.rename)
    }
}

@MainActor
private final class Harness {
    let folder: TemporaryFolder
    let settings: SettingsStore
    let layout: ReviewsLayout
    let github: FakeGitHub
    let clock = ManualClock()
    let wall = Wall()
    let notifier = FakeNotifier()
    let health: HealthReporter
    let events: AsyncStream<HealthEvent>
    let log = Recorder<ReviewsLogEvent>()
    let parts: ReviewsParts
    // Each close of Reviews, which closes the trust panel in the app.
    let closes = Recorder<Void>()
    // The registry, the session commands and the fake claude of the PR sessions.
    let deps = FakeActionDeps()
    // The git that holds each clone, when the part has clones. Its runner runs the grace of a
    // stop on gitClock.
    let holding: HoldingGit?
    let gitClock = ManualClock()

    // state is the text of a state.json that is in the Reviews folder before the first open.
    // holding gives the part a repo store whose git holds each clone (HoldingGit), and the
    // folder of the test as the home of the trust read. sessions gives the part a repo store
    // with the real git (its sources are missing, so each clone fails) and the parts of the PR
    // sessions, so the review rounds run.
    init(
        _ toReview: [[String: Any]] = [Poll.pr(101)], state: String? = nil,
        steps: WriteSteps = .system, holding: Bool = false, sessions: Bool = false
    ) async throws {
        folder = try TemporaryFolder()
        let holding = holding ? try HoldingGit(in: folder) : nil
        self.holding = holding
        settings = await SettingsStore.open(
            file: folder.url.appending(path: "settings.json"), log: Recorder<StoreEvent>())
        layout = ReviewsLayout(
            folder: folder.url.appending(path: ".bifrost/reviews", directoryHint: .isDirectory))
        if let state {
            try FileManager.default.createDirectory(
                at: layout.folder, withIntermediateDirectories: true)
            try Data(state.utf8).write(to: layout.stateFile)
        }
        github = FakeGitHub(answers: ["poll": .success(try Poll.answer(toReview))])
        (health, events) = HealthReporter.make()
        let wall = wall
        var repos: RepoStore?
        if let holding {
            let env = [
                "PATH": "/usr/bin:/bin", "HOME": folder.path, "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": "/dev/null",
            ]
            let git = RepoGit(
                path: holding.path, environment: env, layout: layout,
                localRemotesForTestHome: true, runner: ProcessRunner(clock: gitClock))
            let sources = folder.path
            repos = RepoStore(
                layout: layout, git: git,
                cloneAddress: { URL(filePath: "\(sources)/\($0.key).git") }, clock: clock,
                log: log)
        }
        var sessionParts: SessionParts?
        if sessions {
            let env = [
                "PATH": "/usr/bin:/bin", "HOME": folder.path, "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": "/dev/null",
            ]
            let git = RepoGit(
                path: "/usr/bin/git", environment: env, layout: layout,
                localRemotesForTestHome: true, runner: ProcessRunner())
            let sources = folder.path
            repos =
                repos
                ?? RepoStore(
                    layout: layout, git: git,
                    cloneAddress: { URL(filePath: "\(sources)/\($0.key).git") }, clock: clock,
                    log: log)
            sessionParts = SessionParts(
                claude: deps.claudeRunner(), registry: deps.registry,
                actions: deps.makeActions(), skills: folder.url,
                userHome: folder.url,
                testPrefix: true)
        }
        parts = ReviewsParts(
            settings: settings, layout: layout, access: github, notifier: notifier,
            health: health, storeLog: Recorder<StoreEvent>(), log: log, clock: clock,
            now: { wall.date }, focused: { false }, refused: {}, openPanel: {}, steps: steps,
            repos: repos, trustHome: holding == nil && !sessions ? nil : folder.url,
            sessions: sessionParts, closed: { [closes] in closes.record(()) })
        parts.start()
    }

    // Change the settings with no confirm: a settings file, an import or the Debug test port.
    func set(_ change: @escaping (inout BifrostSettings.Settings) -> Void) async throws {
        _ = try await settings.edit(change)
    }

    // Settings > Reviews, with a confirm dialog that always confirms and the link of the consent
    // to the part, as the shell gives them (Shell.settingsLinks).
    lazy var section: ReviewsSection = {
        let parts = parts
        let model = SettingsModel(
            store: settings,
            layout: WindowLayoutModel(layout: WindowLayout(bounds: LayoutSize(w: 1200, h: 800))),
            links: SettingsLinks(
                confirm: { _ in true },
                reviews: ReviewsLinks(confirmAutoFix: { parts.autoFixConfirmed() })))
        return ReviewsSection(model: model)
    }()

    // Turn on "Handle comments on my PRs automatically" as Settings does: the confirm, the save,
    // then the consent. Wait for the edit of the part.
    func confirmAutoFix() async {
        #expect(await section.change(.autoFix, to: true))
        await parts.settled()
    }

    // Turn Watch GitHub on and wait for the open, the edits of the open and the first poll.
    func watch() async throws {
        try await set { $0.reviewsWatch = true }
        #expect(await waitUntil { self.parts.watcher != nil })
        await parts.settled()
        await settle()
    }

    // Wait for the poll that runs and the timer of the next poll.
    func settle() async {
        while let task = parts.watcher?.pollTask { await task.value }
        await clock.waitForSleepers(1)
    }

    // True when the clock of git sleeps to the end of the grace of a stop: the SIGTERM went, and
    // the held git, which ignores it, still runs.
    func graceSleeps() -> Bool {
        gitClock.nextDeadline == gitClock.now.advanced(by: RepoGit.stopGrace)
    }

    // Turn Watch GitHub off and wait for the close of the store.
    func unwatch() async throws {
        try await set { $0.reviewsWatch = false }
        #expect(await waitUntil { self.parts.watcher == nil })
        await parts.settled()
    }

    // What the panel shows, with claude found.
    func snapshot() -> ReviewsSnapshot {
        ReviewsParts.snapshot(settings: settings.settings, parts: parts, claudeMissing: false)
    }

    func toReview() -> [String] {
        parts.watcher?.toReview.map(\.id.text) ?? []
    }

    func end() async {
        parts.stop()
        await parts.settled()
        folder.remove()
    }
}

@MainActor
@Suite("the Reviews part", .serialized, .timeLimit(.minutes(1)))
struct ShellReviewsTests {
    @Test func watchGitHubOnOpensTheStoreAndStartsTheWatcher() async throws {
        let h = try await Harness()
        #expect(h.parts.watcher == nil && h.parts.store == nil)
        let off = h.snapshot()
        #expect(off.phase == .off)
        try await h.watch()
        #expect(h.parts.store != nil && h.parts.storeProblem == nil)
        #expect(h.github.calls == [.read("poll")])
        #expect(FileManager.default.fileExists(atPath: h.layout.lockFile.path))
        let on = h.snapshot()
        #expect(on.phase == .on && on.lastPoll == h.wall.date)
        #expect(on.toReview.map(\.id.text) == ["owner-a/repo-a#101"])
        #expect(h.log.values.first == .started(interval: .seconds(120)))
        await h.end()
    }

    // A turn-off stops the watcher and the polls, closes the store and frees its lock, so a new
    // open takes it. A second turn-on opens the store again.
    @Test func watchGitHubOffStopsAndFreesTheLock() async throws {
        let h = try await Harness()
        try await h.watch()
        try await h.unwatch()
        #expect(h.parts.store == nil && h.parts.autoFixConsent == nil)
        await h.clock.waitUntilNoSleepers()
        let again = try await ReviewsStore.open(layout: h.layout, log: Recorder<StoreEvent>())
        await again.close().value
        try await h.watch()
        #expect(h.parts.store != nil && h.github.calls.count == 2)
        await h.end()
    }

    // The health log gets the poll, then the stop of Reviews at the turn-off.
    // A turn-off closes the trust panel (its claude ends), once.
    @Test func aTurnOffClosesTheTrustPanel() async throws {
        let h = try await Harness()
        try await h.watch()
        #expect(h.closes.values.isEmpty)
        try await h.unwatch()
        #expect(h.closes.values.count == 1)
        await h.end()
        #expect(h.closes.values.count == 1)
    }

    // A turn-off during a clone of the set-up ends its git, and the close of the store waits for
    // it. The git ignores SIGTERM, so it ends at the SIGKILL of the end of the grace: when the
    // close ends, no git runs and its temporary folder went.
    @Test(.tags(.realProcess)) func aTurnOffDuringACloneEndsItsGit() async throws {
        let h = try await Harness(holding: true)
        let holding = try #require(h.holding)
        try await h.watch()
        try #require(await waitUntil { holding.clones.count == 1 })
        let clone = try #require(holding.clones.first)
        #expect(kill(clone.pid, 0) == 0)
        try await h.set { $0.reviewsWatch = false }
        try #require(await waitUntil { h.graceSleeps() })
        #expect(kill(clone.pid, 0) == 0)
        h.gitClock.advance(by: RepoGit.stopGrace)
        #expect(await waitUntil { h.parts.watcher == nil })
        await h.parts.settled()
        #expect(kill(clone.pid, 0) != 0)
        #expect(!FileManager.default.fileExists(atPath: clone.folder))
        await h.end()
    }

    // The quit stops the clones at once, and the store closes while they stop. A git that
    // ignores SIGTERM gets SIGKILL at the end of the grace, which is shorter than the wait of the
    // quit, and the quit waits for its end, so no git outlives the app.
    @Test(.tags(.realProcess)) func theQuitDuringACloneEndsItsGit() async throws {
        #expect(RepoGit.stopGrace < QuitWait.limit)
        let h = try await Harness(holding: true)
        let holding = try #require(h.holding)
        try await h.watch()
        try #require(await waitUntil { holding.clones.count == 1 })
        let clone = try #require(holding.clones.first)
        let quit = h.parts.closeForQuit()
        let ended = Recorder<Void>()
        let watching = Task {
            await quit.value
            ended.record(())
        }
        try #require(await waitUntil { h.graceSleeps() })
        // The store closed while git still runs: its lock is free.
        let freed = await waitUntil {
            guard let lock = try? ReviewsStore.takeLock(h.layout) else { return false }
            lock.release()
            return true
        }
        #expect(freed)
        #expect(ended.values.isEmpty)
        #expect(kill(clone.pid, 0) == 0)
        h.gitClock.advance(by: RepoGit.stopGrace)
        await watching.value
        #expect(kill(clone.pid, 0) != 0)
        #expect(!FileManager.default.fileExists(atPath: clone.folder))
        await h.end()
    }

    @Test func watchGitHubOffRecordsStopped() async throws {
        let h = try await Harness()
        try await h.watch()
        try await h.unwatch()
        var seen: [HealthEvent] = []
        for await event in h.events {
            seen.append(event)
            if event == .stopped(.reviews) { break }
        }
        #expect(seen == [.poll(.reviews, .ok), .stopped(.reviews)])
        #expect(h.log.values.last == .stopped)
        await h.end()
    }

    // Show team requests, the ignore list and the poll interval reach the watcher.
    @Test func theSettingsReachTheWatcher() async throws {
        let h = try await Harness([
            Poll.pr(101), Poll.pr(7, owner: "owner-b", repo: "repo-c", team: true),
        ])
        try await h.watch()
        #expect(h.toReview() == ["owner-a/repo-a#101", "owner-b/repo-c#7"])
        try await h.set { $0.reviewsTeamRequests = false }
        #expect(await waitUntil { h.toReview() == ["owner-a/repo-a#101"] })
        try await h.set {
            $0.reviewsTeamRequests = true
            $0.reviewsIgnore = ["owner-a/*"]
        }
        #expect(await waitUntil { h.toReview() == ["owner-b/repo-c#7"] })
        // A new interval counts from the start of the wait that runs.
        try await h.set { $0.reviewsPollMinutes = 5 }
        #expect(await waitUntil { h.clock.sleeperCount == 1 })
        h.clock.advance(by: .seconds(299))
        #expect(h.github.calls.count == 1)
        let timer = h.parts.watcher?.pollTimerTask
        h.clock.advance(by: .seconds(1))
        await timer?.value
        await h.settle()
        #expect(h.github.calls.count == 2)
        await h.end()
    }

    // The take-over of an Electron state with "Handle comments on my PRs automatically" on turns
    // the setting off with one edit, so no automatic round can start. Only the turn-on that
    // Settings makes after its confirm gives the consent and moves the start of new work.
    @Test func anImportedAutoFixWaitsForTheConfirm() async throws {
        let h = try await Harness()
        #expect(h.settings.settings.reviewsAutoFix)
        try await h.watch()
        let store = try #require(h.parts.store)
        #expect(store.tookOver)
        #expect(!h.settings.settings.reviewsAutoFix)
        #expect(h.parts.autoFixConsent == false && store.state.autoFixConsent == false)
        #expect(!store.state.allowsAutoFix(true))
        let takeOver = store.state.fixFrom
        // The confirmed turn-on.
        h.wall.date += 600
        await h.confirmAutoFix()
        #expect(h.parts.autoFixConsent == true && h.settings.settings.reviewsAutoFix)
        #expect(store.state.autoFixConsent == true && store.state.fixFrom == h.wall.date)
        #expect(store.state.fixFrom != takeOver)
        #expect(store.state.allowsAutoFix(h.settings.settings.reviewsAutoFix))
        // The consent changed the state at once. Wait for the write of the current state.
        #expect(await store.saved(store.change { _ in }))
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: h.layout.stateFile))
        #expect((saved as? [String: Any])?["autoFixConsent"] as? Bool == true)
        // A turn-off keeps the consent and stops the automatic rounds.
        try await h.set { $0.reviewsAutoFix = false }
        #expect(!store.state.allowsAutoFix(h.settings.settings.reviewsAutoFix))
        #expect(store.state.autoFixConsent == true)
        await h.end()
    }

    // A confirmed turn-on while Watch GitHub is off gives the consent at the next open of this
    // run, and the setting stays on. The next run finds the consent in the store, so the setting
    // stays on there too.
    @Test func aTurnOnWhileTheStoreIsClosedWaitsForTheNextOpen() async throws {
        let h = try await Harness()
        try await h.watch()
        try await h.unwatch()
        await h.confirmAutoFix()
        #expect(h.parts.autoFixConsent == nil && h.settings.settings.reviewsAutoFix)
        try await h.watch()
        #expect(h.parts.autoFixConsent == true && h.settings.settings.reviewsAutoFix)
        // The next run: the store keeps the consent, so the setting stays on.
        h.parts.stop()
        await h.parts.settled()
        let next = ReviewsParts(
            settings: h.settings, layout: h.layout, access: h.github, notifier: h.notifier,
            health: h.health, storeLog: Recorder<StoreEvent>(), log: h.log, clock: h.clock,
            now: { Date(timeIntervalSince1970: 1_794_312_000) }, focused: { false },
            refused: {}, openPanel: {})
        next.start()
        #expect(await waitUntil { next.store != nil })
        await next.settled()
                #expect(next.autoFixConsent == true && h.settings.settings.reviewsAutoFix)
        next.stop()
        await next.settled()
        h.folder.remove()
    }

    // The hint of My PRs shows while the store has no consent, and goes at the consent.
    @Test func theHintShowsUntilTheConsent() async throws {
        let h = try await Harness()
        #expect(h.snapshot().phase == .off && !h.snapshot().needsConsent)
        try await h.watch()
        #expect(h.snapshot().needsConsent)
        await h.confirmAutoFix()
        #expect(!h.snapshot().needsConsent)
        try await h.set { $0.reviewsAutoFix = false }
        #expect(!h.snapshot().needsConsent)
        await h.end()
    }

    // A write of true with no confirm (the Debug test port, an import, a settings file) records
    // no consent, so no automatic round can start, and the next open turns the setting off.
    @Test func aWriteOfTrueWithNoConfirmRecordsNoConsent() async throws {
        let h = try await Harness()
        try await h.watch()
        let store = try #require(h.parts.store)
        try await h.set { $0.reviewsAutoFix = true }
        #expect(await waitUntil { h.parts.config?.autoFix == true })
        await h.parts.settled()
        #expect(h.parts.autoFixConsent == false && store.state.autoFixConsent == false)
        #expect(!store.state.allowsAutoFix(h.settings.settings.reviewsAutoFix))
        try await h.unwatch()
        try await h.watch()
        #expect(!h.settings.settings.reviewsAutoFix && h.parts.autoFixConsent == false)
        await h.end()
    }

    // A turn-off and a confirmed turn-on in quick succession, with no wait for the part to see
    // the settings, keep the consent and move the start of new work to the confirm.
    @Test func twoQuickChangesKeepAConfirmedConsent() async throws {
        let h = try await Harness()
        try await h.watch()
        let store = try #require(h.parts.store)
        await h.confirmAutoFix()
        #expect(await waitUntil { h.parts.config?.autoFix == true })
        h.wall.date += 600
        try await h.set { $0.reviewsAutoFix = false }
        await h.confirmAutoFix()
        #expect(store.state.autoFixConsent == true && store.state.fixFrom == h.wall.date)
        #expect(await waitUntil { h.parts.config?.autoFix == true })
        #expect(h.parts.autoFixConsent == true && h.settings.settings.reviewsAutoFix)
        await h.end()
    }

    // The close of the quit ends only when the last save of the store is on the disk and the lock
    // is free: a consent that saves just before the quit is not lost. A stop after it does
    // nothing more.
    @Test func theCloseOfTheQuitEndsAfterTheLastSave() async throws {
        let writes = ArmedGate()
        let h = try await Harness(steps: writes.steps)
        try await h.watch()
        writes.arm()
        #expect(await h.section.change(.autoFix, to: true))
        #expect(await writes.gate.waitUntilHolding())
        let quit = h.parts.closeForQuit()
        // The save waits at the gate, so the store keeps its lock.
        await #expect(throws: ReviewsStoreError.otherCopy) {
            try await ReviewsStore.open(layout: h.layout, log: Recorder<StoreEvent>())
        }
        writes.gate.openAll()
        await quit.value
        #expect(h.parts.store == nil && h.parts.watcher == nil)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: h.layout.stateFile))
        #expect((saved as? [String: Any])?["autoFixConsent"] as? Bool == true)
        let again = try await ReviewsStore.open(layout: h.layout, log: Recorder<StoreEvent>())
        #expect(again.state.autoFixConsent == true)
        await again.close().value
        h.parts.stop()
        await h.end()
    }

    // With no claude there is no part: Watch GitHub on says that Claude Code is missing, while
    // the services still look for claude it says that Reviews starts, and Watch GitHub off says
    // that Reviews is off.
    @Test func withNoClaudeThePanelSaysWhy() {
        var settings = BifrostSettings.Settings()
        #expect(
            ReviewsParts.snapshot(settings: settings, parts: nil, claudeMissing: true).phase
                == .off)
        settings.reviewsWatch = true
        let missing = ReviewsParts.snapshot(settings: settings, parts: nil, claudeMissing: true)
        #expect(missing.phase == .noClaude && missing.toReview.isEmpty)
        let looking = ReviewsParts.snapshot(settings: settings, parts: nil, claudeMissing: false)
        #expect(looking.phase == .starting)
        #expect(ReviewsParts.snapshot(settings: nil, parts: nil, claudeMissing: true).phase == .off)
    }

    // A store of another copy of Bifrost: the panel shows why, and nothing polls.
    @Test func aRefusedStoreShowsWhyAndNeverPolls() async throws {
        let h = try await Harness()
        let other = try await ReviewsStore.open(layout: h.layout, log: Recorder<StoreEvent>())
        try await h.set { $0.reviewsWatch = true }
        #expect(await waitUntil { h.parts.watcher != nil })
        await h.parts.settled()
        #expect(h.parts.storeProblem == .otherCopy && h.parts.store == nil)
        #expect(h.parts.watcher?.refusal == .otherCopy)
        let snapshot = h.snapshot()
        #expect(snapshot.phase == .refused(.otherCopy))
        #expect(h.github.calls.isEmpty && h.clock.sleeperCount == 0)
        // The settings do not start a poll.
        try await h.set { $0.reviewsPollMinutes = 1 }
        await h.parts.settled()
        #expect(h.github.calls.isEmpty)
        await other.close().value
        await h.end()
    }

    // The state of the test port: each row with its tab, its flash, its pause, the text at the
    // right and the step of its round, the consent and the problem line.
    // While the store is open, the review rounds run: at the open, a round of an earlier run that
    // was posting fails with its reason and posts nothing again. A turn-off stops the rounds.
    @Test func theRoundsRunWhileTheStoreIsOpen() async throws {
        let started = 1_794_300_000_000
        let file = """
            {"version": 1, "prs": {"owner-a/repo-a#101": {"round": {"phase": "posting",
            "startedAt": \(started), "at": \(started), "kind": "review"}}}}
            """
        let h = try await Harness(state: file, sessions: true)
        try await h.watch()
        let rounds = try #require(h.parts.rounds)
        let pr = try #require(PRKey(text: "owner-a/repo-a#101"))
        #expect(h.parts.store?.state.prs[pr]?.round == nil)
        #expect(
            h.parts.store?.state.prs[pr]?.lastError == RoundFailure.closedWhilePosting.message)
        #expect(h.github.calls.allSatisfy { if case .write = $0 { false } else { true } })
        #expect(h.toReview() == ["owner-a/repo-a#101"])
        #expect(h.parts.watcher?.toReview.first?.state == .toReview(.failed(
            RoundFailure.closedWhilePosting.message)))
        try await h.unwatch()
        #expect(h.parts.rounds == nil)
        #expect(rounds.queue.running.isEmpty)
        await h.parts.setupTask?.value
        await h.end()
    }

    // While the store is open, the Approve button has its flow, each open of the Review panel
    // gets a new flow, and the Answer panel gets one while the rounds run. A turn-off drops them.
    @Test func thePanelsThatWriteFollowTheStore() async throws {
        let h = try await Harness(sessions: true)
        let pr = try #require(PRKey(text: "owner-a/repo-a#101"))
        #expect(h.parts.approver == nil && h.parts.draftFlow() == nil)
        try await h.watch()
        #expect(h.parts.approver != nil)
        let first = try #require(h.parts.draftFlow())
        #expect(h.parts.draftFlow() !== first)
        #expect(h.parts.answerFlow(for: pr)?.pr == pr)
        try await h.unwatch()
        #expect(h.parts.approver == nil && h.parts.draftFlow() == nil)
        #expect(h.parts.answerFlow(for: pr) == nil)
        await h.parts.setupTask?.value
        await h.end()
    }

    // The watcher keeps the row of a PR whose approval GitHub confirmed until the end of the
    // hold, also when the poll that follows the approval drops the PR. Then the row goes, with
    // no other poll.
    @Test func anApprovedRowStaysUntilTheEndOfTheHold() async throws {
        let h = try await Harness()
        try await h.watch()
        let pr = try #require(PRKey(text: "owner-a/repo-a#101"))
        let head = try #require(CommitID(String(repeating: "a", count: 40)))
        let store = try #require(h.parts.store)
        let at = h.wall.date
        await store.update { state in
            var prState = state.prs[pr] ?? PRState()
            prState.recommendation = RecommendationMark(
                value: .approve, why: "Nothing to change.", headSHA: head, reviewID: nil, at: at)
            state.prs[pr] = prState
        }
        h.github.answers[DraftQueries.freshName] = .success(DraftAnswers.fresh(pr, head: head))
        let write = GitHubWrite.approveCommit(
            pr: try #require(NodeID("PR_node7")), commit: head, click: UserClick())
        h.github.answers[FakeGitHub.key(write)] = .success(
            DraftAnswers.written(write, state: "APPROVED"))
        // The poll after the approval has no request for the viewer any more.
        h.github.answers["poll"] = .success(try Poll.answer([]))
        let approver = try #require(h.parts.approver)
        try await approver.approve(pr, click: UserClick())
        await h.settle()
        #expect(h.github.calls.filter { $0 == .read("poll") }.count == 2)
        #expect(approver.progress(pr) == .approved)
        #expect(h.toReview() == ["owner-a/repo-a#101"])
        let hold = try #require(approver.holdTask(pr))
        h.clock.advance(by: ApproveFlow.hold)
        await hold.value
        #expect(approver.progress(pr) == nil && h.toReview().isEmpty)
        #expect(h.github.calls.filter { $0 == .read("poll") }.count == 2)
        await h.end()
    }

    // GitHub can still list the request for a moment after it confirmed the approval. After the
    // hold, the row then says You approved and offers no Approve: it never goes back to the
    // state before the click.
    @Test func aConfirmedApprovalShowsYouApprovedWhileThePollIsBehind() async throws {
        let h = try await Harness()
        try await h.watch()
        let pr = try #require(PRKey(text: "owner-a/repo-a#101"))
        let head = try #require(CommitID(String(repeating: "a", count: 40)))
        let store = try #require(h.parts.store)
        let at = h.wall.date
        await store.update { state in
            var prState = state.prs[pr] ?? PRState()
            prState.recommendation = RecommendationMark(
                value: .approve, why: "Nothing to change.", headSHA: head, reviewID: nil, at: at)
            state.prs[pr] = prState
        }
        h.github.answers[DraftQueries.freshName] = .success(DraftAnswers.fresh(pr, head: head))
        let write = GitHubWrite.approveCommit(
            pr: try #require(NodeID("PR_node7")), commit: head, click: UserClick())
        h.github.answers[FakeGitHub.key(write)] = .success(
            DraftAnswers.written(write, state: "APPROVED"))
        // The poll after the approval still lists the request, with no review of the viewer.
        h.github.answers["poll"] = .success(try Poll.answer([Poll.pr(101, head: head.hex)]))
        let approver = try #require(h.parts.approver)
        try await approver.approve(pr, click: UserClick())
        await h.settle()
        #expect(approver.progress(pr) == .approved)
        let hold = try #require(approver.holdTask(pr))
        h.clock.advance(by: ApproveFlow.hold)
        await hold.value
        #expect(approver.progress(pr) == nil)
        let row = try #require(h.parts.watcher?.toReview.first)
        #expect(row.id == pr && row.status.text == "You approved" && row.approve == nil)
        await h.end()
    }

    @Test func theStateShowsTheFlashThePauseAndTheRoundOfEachRow() async throws {
        let started = 1_794_300_000_000
        let file = """
            {"version": 1, "prs": {"owner-a/repo-a#101": {"round": {"phase": "running",
            "startedAt": \(started), "at": \(started), "kind": "review"}}}}
            """
        let h = try await Harness(state: file)
        try await h.watch()
        // A new direct request after the first turn-on flashes.
        h.github.answers["poll"] = .success(
            try Poll.answer([Poll.pr(101), Poll.pr(102, requested: "2026-11-10T12:05:00Z")]))
        h.wall.date += 600
        h.parts.run(.refresh)
        await h.settle()
        func state() -> JSONValue {
            let parts = h.parts
            return TestPortMessage.reviews(
                ReviewsParts.snapshot(
                    settings: h.settings.settings, parts: parts, claudeMissing: false),
                consent: parts.autoFixConsent, round: { parts.round(of: $0) })
        }
        let flashing: JSONValue = [
            "pr": "owner-a/repo-a#102", "tab": "toReview", "flash": true, "paused": false,
            "state": "",
        ]
        let reviewing: JSONValue = [
            "pr": "owner-a/repo-a#101", "tab": "toReview", "flash": false, "paused": false,
            "state": "Reviewing", "round": "running",
        ]
        #expect(
            state()
                == [
                    "rows": [flashing, reviewing], "autoFixConsent": false, "problem": .null,
                ])
        let new = try #require(PRKey(text: "owner-a/repo-a#102"))
        h.parts.run(.pause(new))
        let paused: JSONValue = [
            "pr": "owner-a/repo-a#102", "tab": "toReview", "flash": false, "paused": true,
            "state": "Paused 60m",
        ]
        #expect(state().object?["rows"] == [reviewing, paused])
        // A failed poll gives the gh line.
        h.github.answers["poll"] = .failure(.notLoggedIn)
        h.parts.run(.refresh)
        await h.settle()
        #expect(state().object?["problem"] == .string(GitHubError.notLoggedIn.message))
        await h.end()
    }
}
