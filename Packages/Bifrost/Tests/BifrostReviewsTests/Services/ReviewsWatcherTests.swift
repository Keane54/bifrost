import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

// The Reviews watcher (docs/behaviour/reviews.md, "The watcher"): the polls on the manual clock,
// the marks of the first turn-on, the notifications, the pauses, the rows that an approval holds
// and the health events. Each test
// uses the FakeGitHub, a Reviews folder in a temporary folder and a notifier that shows nothing.
// No test reaches GitHub.

// The wall time of the tests. It moves with the manual clock.
@MainActor
private final class Wall {
    // 2026-11-10 12:00:00 UTC, after the request times of the poll fixture.
    var date = Date(timeIntervalSince1970: 1_794_312_000)
}

private let viewerKey = "owner-a/repo-b#101"
private let approvedKey = "owner-a/repo-b#102"

// A poll answer where the viewer asked for a review of #101 again, after the first sight. ci is
// the state of the checks of its head commit, and pending is the ID of a pending review of the
// viewer on it.
private func againAnswer(ci: String = "SUCCESS", pending: String? = nil) throws -> Data {
    try FixtureFiles.edited("poll-basic") { root in
        editPR(&root, list: "toReview", number: 101) { pr in
            var events = (pr["timelineItems"] as? [String: Any]) ?? [:]
            var nodes = (events["nodes"] as? [[String: Any]]) ?? []
            nodes.append([
                "createdAt": "2026-11-10T12:30:00Z",
                "requestedReviewer": ["__typename": "User", "login": "viewer-a"],
            ])
            events["nodes"] = nodes
            pr["timelineItems"] = events
            var commits = pr["commits"] as? [String: Any] ?? [:]
            var items = commits["nodes"] as? [[String: Any]] ?? []
            var commit = items.first?["commit"] as? [String: Any] ?? [:]
            var rollup = commit["statusCheckRollup"] as? [String: Any] ?? [:]
            rollup["state"] = ci
            commit["statusCheckRollup"] = rollup
            items = [["commit": commit]]
            commits["nodes"] = items
            pr["commits"] = commits
            if let pending { pr["pendingReviews"] = ["nodes": [["id": pending]]] }
        }
    }
}

// A poll answer with no request for the PR of the number, as after a review of the viewer.
private func droppedAnswer(_ number: Int = 102) throws -> Data {
    try FixtureFiles.edited("poll-basic") { root in
        edit(&root, list: "toReview") { search in
            var nodes = search["nodes"] as? [[String: Any]] ?? []
            nodes.removeAll { $0["number"] as? Int == number }
            search["nodes"] = nodes
        }
    }
}

// The PRs that the approvals of a test hold.
@MainActor
private final class Held {
    var keys: Set<PRKey> = []
}

// GitHub of the tests that holds each read at a gate until the test opens it.
@MainActor
private final class HeldGitHub: GitHubAccess {
    let inner: FakeGitHub
    let gate = TestGate()

    init(_ inner: FakeGitHub, holding: Bool) {
        self.inner = inner
        if !holding { gate.openAll() }
    }

    @MainActor func read(_ query: GitHubQuery) async throws(GitHubError) -> Data {
        await gate.pass()
        return try await inner.read(query)
    }

    @MainActor func write(_ write: GitHubWrite) async throws(GitHubError) -> Data {
        try await inner.write(write)
    }

    @MainActor func fetch(_ read: GitHubRead) async throws(GitHubError) -> Data {
        throw .refused("No fetch in this test.")
    }

    @MainActor func scopes() async throws(GitHubError) -> GitHubScopes? {
        try await inner.scopes()
    }
}

@MainActor
private struct Harness {
    let folder: TemporaryFolder
    let store: ReviewsStore
    let github: FakeGitHub
    let held: HeldGitHub
    let writeGate = WriteGate()
    let clock = ManualClock()
    let wall = Wall()
    let notifier = FakeNotifier()
    let log = Recorder<ReviewsLogEvent>()
    let events: AsyncStream<HealthEvent>
    let watcher: ReviewsWatcher
    let panelOpened = Recorder<Void>()

    init(
        poll: Result<Data, GitHubError>? = nil, holdRead: Bool = false, holdWrite: Bool = false
    ) async throws {
        folder = try TemporaryFolder()
        let layout = ReviewsLayout(
            folder: folder.url.appending(path: ".bifrost/reviews", directoryHint: .isDirectory))
        let steps = writeGate.steps
        let storeLog = Recorder<StoreEvent>()
        if holdWrite {
            // The take-over of the open saves first: let that write through.
            let opening = Task {
                try await ReviewsStore.open(layout: layout, log: storeLog, steps: steps)
            }
            try #require(await writeGate.waitUntilWriting())
            writeGate.open()
            store = try await ended(opening)
        } else {
            writeGate.openAll()
            store = try await ReviewsStore.open(layout: layout, log: storeLog, steps: steps)
        }
        let opened = store
        let basic = try FixtureFiles.data("poll-basic")
        github = FakeGitHub(answers: ["poll": poll ?? .success(basic)])
        held = HeldGitHub(github, holding: holdRead)
        let (reporter, stream) = HealthReporter.make()
        events = stream
        let wall = wall
        let panelOpened = panelOpened
        watcher = ReviewsWatcher(
            github: GitHubClient(access: held), store: .success(opened), notifier: notifier,
            health: reporter, log: log, clock: clock, now: { wall.date },
            openPanel: { panelOpened.record(()) })
    }

    // Close the store and remove the folder.
    func end() async {
        watcher.stop()
        held.gate.openAll()
        writeGate.openAll()
        await ended(store.close())
        folder.remove()
    }

    // Move the wall time and the manual clock together.
    func advance(_ span: Duration) {
        wall.date = wall.date.addingTimeInterval(
            Double(span.components.seconds))
        clock.advance(by: span)
    }

    // Turn Watch GitHub on and wait for the first poll and the start of the wait that follows.
    func start(_ config: ReviewsConfig = ReviewsConfig(watch: true)) async {
        watcher.apply(config)
        await settle()
    }

    // Wait for the poll that runs and the timer of the next poll.
    func settle() async {
        while let task = watcher.pollTask { await ended(task) }
        await clock.waitForSleepers(1)
    }

    // Poll now with the answer, and wait for the poll and the timer of the next poll.
    func poll(_ answer: Data) async {
        github.answers["poll"] = .success(answer)
        watcher.refresh()
        await settle()
    }

    // Move the clock to the end of the wait and wait for the poll that follows.
    func tick(_ span: Duration) async {
        let timer = watcher.pollTimerTask
        advance(span)
        await ended(timer)
        await settle()
    }

    func nextHealth() async -> HealthEvent? {
        var iterator = events.makeAsyncIterator()
        return await iterator.next()
    }
}

@MainActor
@Suite("the Reviews watcher", .testTimeLimit)
struct ReviewsWatcherTests {
    // The scopes of the gh login are read in their own task: once at the first start of Reviews
    // in the run of the app, and at each refresh of the user, never at a poll of the timer. A login
    // with no workflow scope makes lacksWorkflowScope true.
    @Test func theScopesAreReadAtTheFirstStartAndAtEachRefresh() async throws {
        let harness = try await Harness()
        harness.github.scopes = .success(GitHubScopes(names: ["repo", "gist"]))
        #expect(!harness.watcher.lacksWorkflowScope)
        await harness.start()
        await ended(harness.watcher.scopesReadTask)
        #expect(harness.github.scopeReads == 1 && harness.watcher.lacksWorkflowScope)
        // A turn-off and a new turn-on of Watch GitHub do not read again in this run.
        harness.watcher.apply(ReviewsConfig(watch: false))
        await harness.start()
        await ended(harness.watcher.scopesReadTask)
        #expect(harness.github.scopeReads == 1)
        // A poll of the timer reads no scopes.
        await harness.tick(.seconds(120))
        #expect(harness.github.scopeReads == 1)
        // A refresh reads them again, and the new answer replaces the old one.
        harness.github.scopes = .success(GitHubScopes(names: ["repo", "workflow"]))
        harness.watcher.refresh()
        await ended(harness.watcher.scopesReadTask)
        await harness.settle()
        #expect(harness.github.scopeReads == 2 && !harness.watcher.lacksWorkflowScope)
        await harness.end()
    }

    // A read that fails keeps the last answer that Bifrost knew, so the warning stays. A login
    // with no scope header gives an unknown answer, which replaces it.
    @Test func aFailedScopesReadKeepsTheLastAnswer() async throws {
        let harness = try await Harness()
        harness.github.scopes = .success(GitHubScopes(names: ["repo"]))
        await harness.start()
        await ended(harness.watcher.scopesReadTask)
        #expect(harness.watcher.lacksWorkflowScope)
        harness.github.scopes = .failure(.timedOut)
        harness.watcher.refresh()
        await ended(harness.watcher.scopesReadTask)
        await harness.settle()
        #expect(harness.github.scopeReads == 2 && harness.watcher.lacksWorkflowScope)
        harness.github.scopes = .success(nil)
        harness.watcher.refresh()
        await ended(harness.watcher.scopesReadTask)
        await harness.settle()
        #expect(harness.watcher.scopes == nil)
        await harness.end()
    }

    // A login with no scope header and a read that fails both leave the scopes unknown, so no
    // warning shows.
    @Test func unknownScopesGiveNoWarning() async throws {
        let harness = try await Harness()
        harness.github.scopes = .success(nil)
        await harness.start()
        await ended(harness.watcher.scopesReadTask)
        #expect(harness.watcher.scopes == nil && !harness.watcher.lacksWorkflowScope)
        harness.github.scopes = .failure(.timedOut)
        harness.watcher.refresh()
        await ended(harness.watcher.scopesReadTask)
        await harness.settle()
        #expect(harness.watcher.scopes == nil && !harness.watcher.lacksWorkflowScope)
        await harness.end()
    }

    @Test func thePollRunsAtTheIntervalAndOnRefresh() async throws {
        let harness = try await Harness()
        await harness.start()
        #expect(harness.github.calls == [.read("poll")])
        harness.advance(.seconds(119))
        #expect(harness.github.calls.count == 1 && harness.clock.sleeperCount == 1)
        await harness.tick(.seconds(1))
        #expect(harness.github.calls.count == 2)
        harness.watcher.refresh()
        await harness.settle()
        #expect(harness.github.calls.count == 3)
        await harness.end()
    }

    @Test func aRefreshDuringASleepPollsAtOnceAndOnce() async throws {
        let harness = try await Harness()
        await harness.start()
        harness.watcher.refresh()
        // The second click meets the poll that runs: one more poll follows it, and no more.
        harness.watcher.refresh()
        await harness.settle()
        await harness.clock.waitForSleepers(exactly: 1)
        #expect(harness.github.calls.count == 3)
        // The wait counts from the end of the last poll.
        harness.advance(.seconds(119))
        #expect(harness.github.calls.count == 3)
        await harness.tick(.seconds(1))
        #expect(harness.github.calls.count == 4)
        await harness.end()
    }

    @Test func aRefreshDuringARunningPollRunsOneMorePollAtItsEnd() async throws {
        let harness = try await Harness(holdRead: true)
        harness.watcher.apply(ReviewsConfig(watch: true))
        await harness.held.gate.waitUntilHolding()
        harness.watcher.refresh()
        harness.watcher.refresh()
        harness.watcher.refresh()
        harness.held.gate.open()
        // The second poll waits at the gate too: the first one has ended.
        await harness.held.gate.waitUntilHolding()
        #expect(harness.github.calls.count == 1)
        harness.held.gate.openAll()
        await harness.settle()
        #expect(harness.github.calls.count == 2)
        await harness.end()
    }

    // The watcher counts the polls that start, and gives the number of the poll of the last good
    // answer. A refresh during a poll gives one more poll, and a poll that fails answers nothing.
    @Test func thePollCountGivesThePollOfTheLastGoodAnswer() async throws {
        let harness = try await Harness(holdRead: true)
        #expect(harness.watcher.polls == PollCount())
        harness.watcher.apply(ReviewsConfig(watch: true))
        await harness.held.gate.waitUntilHolding()
        #expect(harness.watcher.polls == PollCount(started: 1, answered: 0))
        harness.watcher.refresh()
        harness.github.answers["poll"] = .failure(.notLoggedIn)
        harness.held.gate.open()
        await harness.held.gate.waitUntilHolding()
        #expect(harness.watcher.polls == PollCount(started: 2, answered: 0))
        harness.github.answers["poll"] = .success(try FixtureFiles.data("poll-basic"))
        harness.held.gate.open()
        await harness.settle()
        #expect(harness.watcher.polls == PollCount(started: 2, answered: 2))
        harness.github.answers["poll"] = .failure(.notLoggedIn)
        harness.held.gate.openAll()
        harness.watcher.refresh()
        await harness.settle()
        #expect(harness.watcher.polls == PollCount(started: 3, answered: 2))
        await harness.end()
    }

    // The flag of a refresh that the user asked for: true from the click until the poll that the
    // click asked for ends, also when it fails. The first poll and a poll of the timer leave it
    // false. A click during a poll of the timer keeps it true until the next poll ends.
    @Test func theRefreshFlagFollowsTheClickAndNotTheTimer() async throws {
        let harness = try await Harness(holdRead: true)
        let gate = harness.held.gate
        harness.watcher.apply(ReviewsConfig(watch: true))
        await gate.waitUntilHolding()
        #expect(!harness.watcher.refreshing)
        gate.open()
        await harness.settle()
        #expect(!harness.watcher.refreshing)
        // A click in the wait: true during its poll, false after it.
        harness.watcher.refresh()
        await gate.waitUntilHolding()
        #expect(harness.watcher.refreshing)
        gate.open()
        await harness.settle()
        #expect(!harness.watcher.refreshing)
        // A poll of the timer leaves it false.
        let timer = harness.watcher.pollTimerTask
        harness.advance(.seconds(120))
        await ended(timer)
        await gate.waitUntilHolding()
        #expect(!harness.watcher.refreshing)
        // A click during that poll asks for one more poll: true until that one ends.
        harness.watcher.refresh()
        #expect(harness.watcher.refreshing)
        gate.open()
        await gate.waitUntilHolding()
        #expect(harness.watcher.refreshing)
        gate.open()
        await harness.settle()
        #expect(!harness.watcher.refreshing)
        await harness.end()
    }

    // A poll that fails ends the refresh too, and a stop clears the flag.
    @Test func aFailedPollEndsTheRefreshAndAStopClearsIt() async throws {
        let harness = try await Harness(holdRead: true)
        let gate = harness.held.gate
        harness.watcher.apply(ReviewsConfig(watch: true))
        await gate.waitUntilHolding()
        gate.open()
        await harness.settle()
        harness.github.answers["poll"] = .failure(.timedOut)
        harness.watcher.refresh()
        await gate.waitUntilHolding()
        #expect(harness.watcher.refreshing)
        gate.open()
        await harness.settle()
        #expect(harness.watcher.problem == .timedOut && !harness.watcher.refreshing)
        harness.watcher.refresh()
        await gate.waitUntilHolding()
        #expect(harness.watcher.refreshing)
        harness.watcher.stop()
        #expect(!harness.watcher.refreshing)
        await harness.end()
    }

    @Test func aStopDuringTheGhReadChangesNothing() async throws {
        let harness = try await Harness(holdRead: true)
        harness.watcher.apply(ReviewsConfig(watch: true))
        await harness.held.gate.waitUntilHolding()
        let poll = harness.watcher.pollTask
        harness.watcher.stop()
        harness.held.gate.openAll()
        await ended(poll)
        #expect(harness.watcher.answer == nil && harness.watcher.toReview.isEmpty)
        #expect(harness.store.state.turnedOnAt == nil && harness.notifier.shown.isEmpty)
        #expect(harness.clock.sleeperCount == 0)
        var iterator = harness.events.makeAsyncIterator()
        #expect(await iterator.next() == .stopped(.reviews))
        await harness.end()
    }

    // A poll changes the state at once and does not wait for the write of its marks: the rows
    // show while the store writes. A stop then clears the rows, and the write still ends.
    @Test func thePollDoesNotWaitForTheWriteOfItsMarks() async throws {
        let harness = try await Harness(holdWrite: true)
        harness.watcher.apply(ReviewsConfig(watch: true))
        let poll = harness.watcher.pollTask
        try #require(await harness.writeGate.waitUntilWriting())
        await ended(poll)
        #expect(harness.watcher.lastPoll != nil && harness.store.state.turnedOnAt != nil)
        harness.watcher.stop()
        harness.writeGate.openAll()
        #expect(harness.watcher.answer == nil && harness.watcher.toReview.isEmpty)
        #expect(harness.clock.sleeperCount == 0)
        var iterator = harness.events.makeAsyncIterator()
        #expect(await iterator.next() == .poll(.reviews, .ok))
        #expect(await iterator.next() == .stopped(.reviews))
        #expect(await harness.store.saved(harness.store.change { _ in }))
        await harness.end()
    }

    // Up to three new requests of one poll give one notification each. More give one summary
    // with their count, as the alert rules do.
    @Test(arguments: [3, 4])
    func moreThanThreeNewRequestsGiveOneSummary(count: Int) async throws {
        let harness = try await Harness()
        await harness.start()
        let more = try FixtureFiles.edited("poll-basic") { root in
            edit(&root, list: "toReview") { search in
                var nodes = (search["nodes"] as? [[String: Any]]) ?? []
                let template = nodes[0]
                for number in 201..<(201 + count) {
                    var pr = template
                    pr["number"] = number
                    pr["title"] = "Change \(number)"
                    pr["url"] = "https://github.com/owner-a/repo-b/pull/\(number)"
                    pr["timelineItems"] = [
                        "nodes": [
                            [
                                "createdAt": "2026-11-10T12:30:00Z",
                                "requestedReviewer": ["__typename": "User", "login": "viewer-a"],
                            ]
                        ]
                    ]
                    nodes.append(pr)
                }
                search["nodes"] = nodes
            }
        }
        harness.github.answers["poll"] = .success(more)
        harness.watcher.refresh()
        await harness.settle()
        let shown = harness.notifier.shown
        #expect(shown.allSatisfy { $0.source == .reviews })
        if count <= 3 {
            #expect(shown.count == count)
            #expect(!shown.contains { $0.title == "New review requests" })
        } else {
            #expect(shown.count == 1)
            #expect(shown.first?.title == "New review requests")
            #expect(shown.first?.body == "\(count) pull requests wait for your review.")
        }
        await harness.end()
    }

    @Test func aNewIntervalAppliesToTheNextSleep() async throws {
        let harness = try await Harness()
        await harness.start()
        harness.advance(.seconds(30))
        // The wait that runs counts from its start: 30 seconds of 60 have passed.
        harness.watcher.apply(ReviewsConfig(watch: true, pollInterval: .seconds(60)))
        await harness.clock.waitForSleepers(exactly: 1)
        harness.advance(.seconds(29))
        #expect(harness.github.calls.count == 1)
        await harness.tick(.seconds(1))
        #expect(harness.github.calls.count == 2)
        // The next wait is 60 seconds.
        harness.advance(.seconds(59))
        #expect(harness.github.calls.count == 2)
        await harness.tick(.seconds(1))
        #expect(harness.github.calls.count == 3)
        // A shorter interval than the time that passed polls at once.
        harness.advance(.seconds(40))
        harness.watcher.apply(ReviewsConfig(watch: true, pollInterval: .seconds(30)))
        await harness.settle()
        #expect(harness.github.calls.count == 4)
        await harness.end()
    }

    @Test func theFirstTurnOnMarksTheOpenItems() async throws {
        let harness = try await Harness()
        await harness.start()
        let state = harness.store.state
        #expect(state.turnedOnAt == harness.wall.date)
        #expect(state.requests.count == 3 && state.requests.values.allSatisfy(\.baseline))
        // The start of new request work and the open items are set, and no automatic round has
        // the consent of the user.
        #expect(state.fixFrom != nil && !state.baseline.isEmpty)
        #expect(state.autoFixConsent == false)
        #expect(harness.watcher.toReview.count == 3)
        // Nothing flashes, nothing notifies and nothing waits for the user.
        #expect(harness.watcher.toReview.allSatisfy { !$0.flash })
        #expect(!harness.watcher.attention)
        #expect(harness.notifier.shown.isEmpty)
        // A later request flashes.
        harness.github.answers["poll"] = .success(try againAnswer())
        harness.watcher.refresh()
        await harness.settle()
        let key = try #require(PRKey(text: viewerKey))
        let row = try #require(harness.watcher.toReview.first { $0.id == key })
        #expect(row.state == .toReview(.newRequest) && row.flash && harness.watcher.attention)
        await harness.end()
    }

    @Test func aNewDirectRequestNotifiesOnce() async throws {
        let harness = try await Harness()
        await harness.start()
        harness.github.answers["poll"] = .success(try againAnswer())
        harness.watcher.refresh()
        await harness.settle()
        #expect(harness.notifier.shown.map(\.source) == [.reviews])
        #expect(harness.notifier.shown.first?.sound == false)
        harness.watcher.refresh()
        await harness.settle()
        #expect(harness.notifier.shown.count == 1)
        harness.notifier.click(0)
        #expect(harness.panelOpened.values.count == 1)
        let refused = Recorder<Void>()
        harness.watcher.refused = { refused.record(()) }
        harness.notifier.refuse(0)
        #expect(refused.values.count == 1)
        #expect(harness.log.values == [.started(interval: .seconds(120))])
        await harness.end()
    }

    // A new request whose CI fails does not need the user now (user decision, 2026-11-19): it
    // does not flash, sets no attention dot and does not notify, over more polls too. Its notice
    // waits in the state. The first poll where CI passes makes it flash and notify one time, and
    // a later fail and pass of CI never notifies again.
    @Test func aRequestWithFailingCINotifiesOnceWhenCIPasses() async throws {
        let harness = try await Harness()
        await harness.start()
        let key = try #require(PRKey(text: viewerKey))
        func row() -> ReviewRow? { harness.watcher.toReview.first { $0.id == key } }
        func waits() -> Bool? { harness.store.state.requests[key]?.noticeWaitsForCI }
        for _ in 0..<2 {
            await harness.poll(try againAnswer(ci: "FAILURE"))
            #expect(row()?.toReviewState == .newRequest && row()?.flash == false)
            #expect(row()?.status.text == "CI failing" && row()?.reviewable == false)
            #expect(!harness.watcher.attention && harness.notifier.shown.isEmpty)
            #expect(waits() == true)
        }
        await harness.poll(try againAnswer())
        #expect(row()?.toReviewState == .newRequest && row()?.flash == true)
        #expect(harness.watcher.attention && harness.notifier.shown.count == 1)
        #expect(waits() == false)
        for ci in ["SUCCESS", "FAILURE", "PENDING", "SUCCESS"] {
            await harness.poll(try againAnswer(ci: ci))
        }
        #expect(harness.notifier.shown.count == 1)
        await harness.end()
    }

    // A review of the user ends a notice that waits for CI: a pending review on GitHub, and then
    // its submit, which ends the request. No notification comes, also after CI passes.
    @Test func aReviewEndsANoticeThatWaitsForCI() async throws {
        let harness = try await Harness()
        await harness.start()
        let key = try #require(PRKey(text: viewerKey))
        func waits() -> Bool? { harness.store.state.requests[key]?.noticeWaitsForCI }
        await harness.poll(try againAnswer(ci: "FAILURE"))
        #expect(waits() == true)
        await harness.poll(try againAnswer(ci: "FAILURE", pending: "PRR_pending1"))
        #expect(waits() == false)
        await harness.poll(try againAnswer(pending: "PRR_pending1"))
        let row = harness.watcher.toReview.first { $0.id == key }
        #expect(row?.toReviewState == .draftReady)
        await harness.poll(try droppedAnswer(101))
        #expect(harness.store.state.requests[key] == nil)
        #expect(harness.notifier.shown.isEmpty)
        await harness.end()
    }

    // A pause is an act of the user on the request, so it ends a notice that waits for CI. After
    // the pause, the row flashes when CI passes, with no notification.
    @Test func aPauseEndsANoticeThatWaitsForCI() async throws {
        let harness = try await Harness()
        await harness.start()
        let key = try #require(PRKey(text: viewerKey))
        await harness.poll(try againAnswer(ci: "FAILURE"))
        #expect(harness.store.state.requests[key]?.noticeWaitsForCI == true)
        harness.watcher.pause(key)
        #expect(harness.store.state.requests[key]?.noticeWaitsForCI == false)
        harness.watcher.endPause(key)
        await harness.poll(try againAnswer())
        #expect(harness.watcher.toReview.first { $0.id == key }?.flash == true)
        #expect(harness.notifier.shown.isEmpty)
        await harness.end()
    }

    @Test func theNotificationRulesHold() async throws {
        let harness = try await Harness()
        await harness.start(ReviewsConfig(watch: true, notifications: false))
        harness.github.answers["poll"] = .success(try againAnswer())
        harness.watcher.refresh()
        await harness.settle()
        #expect(harness.notifier.shown.isEmpty)
        // A notice of the rounds follows the same rules.
        harness.watcher.apply(ReviewsConfig(watch: true))
        harness.watcher.focused = { true }
        harness.watcher.notify(.draftReady(try #require(PRKey(text: viewerKey))))
        #expect(harness.notifier.shown.isEmpty)
        harness.watcher.focused = { false }
        let key = try #require(PRKey(text: viewerKey))
        harness.watcher.notify(.draftReady(key))
        harness.watcher.notify(.needsYou(key, questions: 1))
        harness.watcher.notify(.trustNeeded(try #require(RepoName("owner-a/repo-b"))))
        #expect(harness.notifier.shown.count == 3)
        #expect(harness.notifier.shown.allSatisfy { $0.source == .reviews })
        await harness.end()
    }

    // The notification of a Looks good round says what Claude found: nothing, or the count of
    // each kind of finding as line 2 of the row gives it, so it never says "nothing to flag" for a
    // round with findings.
    @Test func theLooksGoodNotificationSaysWhatClaudeFound() async throws {
        let harness = try await Harness()
        await harness.start()
        harness.watcher.focused = { false }
        let key = try #require(PRKey(text: viewerKey))
        let head = try #require(CommitID(String(repeating: "a", count: 40)))
        let store = harness.store
        func found(_ kinds: [FindingKind]) async {
            let findings = kinds.map {
                Finding(kind: $0, place: nil, body: "A point.", onDiff: false)
            }
            await store.update { state in
                var prState = state.prs[key] ?? PRState()
                prState.recommendation = RecommendationMark(
                    value: .approve, why: "the change is small", headSHA: head, reviewID: nil,
                    at: Date(timeIntervalSince1970: 1_794_312_000), findings: findings)
                state.prs[key] = prState
            }
            harness.watcher.notify(.reviewed(key))
        }
        await found([])
        await found([.nit, .minor, .minor])
        await found([.nit, .nit])
        #expect(
            harness.notifier.shown.map(\.body) == [
                "Claude found nothing to flag in owner-a/repo-b#101, so nothing was posted.",
                "Claude suggests approving owner-a/repo-b#101, but found 2 minor points and 1 nit "
                    + "for you to check.",
                "Claude suggests approving owner-a/repo-b#101, but found 2 nits for you to check.",
            ])
        #expect(harness.notifier.shown.allSatisfy { $0.title == "Claude suggests you approve" })
        await harness.end()
    }

    @Test func aPauseEndsAtItsTimeWithNoTick() async throws {
        let harness = try await Harness()
        let config = ReviewsConfig(
            watch: true, pause: .seconds(600), pollInterval: .seconds(100_000))
        await harness.start(config)
        harness.github.answers["poll"] = .success(try againAnswer())
        harness.watcher.refresh()
        await harness.settle()
        let key = try #require(PRKey(text: viewerKey))
        harness.watcher.pause(key)
        #expect(harness.watcher.toReview.first { $0.id == key }?.flash == false)
        if case .paused? = harness.watcher.toReview.first(where: { $0.id == key })?.toReviewState {
        } else {
            Issue.record("The row is not paused.")
        }
        // The poll timer and the timer of the pause are the only sleepers: no tick.
        await harness.clock.waitForSleepers(exactly: 2)
        #expect(harness.watcher.pauseTimerTask != nil)
        harness.advance(.seconds(599))
        #expect(harness.watcher.toReview.first { $0.id == key }?.flash == false)
        let timer = harness.watcher.pauseTimerTask
        harness.advance(.seconds(1))
        await ended(timer)
        #expect(harness.watcher.toReview.first { $0.id == key }?.flash == true)
        #expect(harness.watcher.pauseTimerTask == nil && harness.clock.sleeperCount == 1)
        await harness.end()
    }

    // The display clock of the panel makes the time texts new between two polls: the minutes
    // left of a pause and the age of a request move, and GitHub gets no call.
    @Test func theTimeTextsFollowTheDisplayClockWithNoPoll() async throws {
        let harness = try await Harness()
        let config = ReviewsConfig(
            watch: true, pause: .seconds(2 * 86_400), pollInterval: .seconds(1_000_000))
        await harness.start(config)
        harness.github.answers["poll"] = .success(try againAnswer())
        harness.watcher.refresh()
        await harness.settle()
        let key = try #require(PRKey(text: viewerKey))
        harness.watcher.pause(key)
        let calls = harness.github.calls.count
        func status() -> String? { harness.watcher.toReview.first { $0.id == key }?.status.text }
        func notes() -> [[String]] { harness.watcher.toReview.map(\.notes) }
        #expect(status() == "Paused 2880m")
        let ages = notes()
        #expect(ages.contains(["user-b", "+10 \u{2212}2", "6d ago"]))
        // The wall time moves one day, and the manual clock does not: no timer ends.
        harness.wall.date += 86_400
        #expect(status() == "Paused 2880m")
        harness.watcher.refreshTimes()
        #expect(status() == "Paused 1440m")
        #expect(notes().contains(["user-b", "+10 \u{2212}2", "7d ago"]))
        #expect(harness.github.calls.count == calls)
        await harness.end()
    }

    @Test func endingAPauseWakesTheRowAtOnce() async throws {
        let harness = try await Harness()
        await harness.start()
        harness.github.answers["poll"] = .success(try againAnswer())
        harness.watcher.refresh()
        await harness.settle()
        let key = try #require(PRKey(text: viewerKey))
        harness.watcher.pause(key)
        #expect(harness.store.state.pauses[key] != nil)
        harness.watcher.endPause(key)
        #expect(harness.store.state.pauses[key] == nil)
        #expect(harness.watcher.toReview.first { $0.id == key }?.flash == true)
        #expect(harness.watcher.pauseTimerTask == nil)
        // Only a new request pauses.
        let approved = try #require(PRKey(text: approvedKey))
        harness.watcher.pause(approved)
        #expect(harness.store.state.pauses[approved] == nil)
        await harness.end()
    }

    // While an approval holds a PR, a poll that drops the PR keeps its row at its place, and a
    // build of the rows at the end of the hold removes it.
    @Test func aHeldRowStaysWhenAPollDropsItsPR() async throws {
        let harness = try await Harness()
        let held = Held()
        harness.watcher.held = { held.keys }
        await harness.start()
        let key = try #require(PRKey(text: approvedKey))
        let rows = harness.watcher.toReview
        #expect(rows.count == 3 && rows[1].id == key)
        held.keys = [key]
        harness.github.answers["poll"] = .success(try droppedAnswer())
        harness.watcher.refresh()
        await harness.settle()
        #expect(harness.watcher.answer?.toReview.contains { $0.key == key } == false)
        #expect(harness.watcher.toReview.map(\.id) == rows.map(\.id))
        #expect(harness.watcher.toReview[1] == rows[1])
        held.keys = []
        harness.watcher.refreshTimes()
        #expect(harness.watcher.toReview.map(\.id) == [rows[0].id, rows[2].id])
        await harness.end()
    }

    @Test func removeHidesOnlyARowThatOthersApproved() async throws {
        let harness = try await Harness()
        await harness.start()
        let waiting = try #require(PRKey(text: viewerKey))
        harness.watcher.remove(waiting)
        #expect(harness.watcher.toReview.count == 3)
        let approved = try #require(PRKey(text: approvedKey))
        harness.watcher.remove(approved)
        #expect(harness.watcher.toReview.count == 2)
        #expect(harness.store.state.hidden[approved] != nil)
        await harness.end()
    }

    @Test func aLoggedOutGhShowsTheGhLineAndRecordsNoData() async throws {
        let harness = try await Harness(poll: .failure(.notLoggedIn))
        await harness.start()
        #expect(harness.watcher.problem == .notLoggedIn)
        #expect(harness.watcher.answer == nil && harness.watcher.toReview.isEmpty)
        #expect(await harness.nextHealth() == .poll(.reviews, .noData))
        // The same failure logs one line only, and a good poll ends the problem.
        harness.watcher.refresh()
        await harness.settle()
        let failures = harness.log.values.filter { $0 == .pollFailed(.notLoggedIn) }
        #expect(failures.count == 1)
        harness.github.answers["poll"] = .success(try FixtureFiles.data("poll-basic"))
        harness.watcher.refresh()
        await harness.settle()
        #expect(harness.watcher.problem == nil && harness.watcher.toReview.count == 3)
        #expect(harness.watcher.lastPoll == harness.wall.date)
        await harness.end()
    }

    @Test func aFailedPollKeepsTheLastRows() async throws {
        let harness = try await Harness()
        await harness.start()
        harness.github.answers["poll"] = .failure(.timedOut)
        harness.watcher.refresh()
        await harness.settle()
        #expect(harness.watcher.problem == .timedOut)
        #expect(harness.watcher.toReview.count == 3 && harness.watcher.mine.count == 2)
        #expect(harness.watcher.answer != nil)
        await harness.end()
    }

    @Test func eachPollReachesTheHealthStream() async throws {
        let harness = try await Harness()
        await harness.start()
        harness.github.answers["poll"] = .failure(.notInstalled)
        harness.watcher.refresh()
        await harness.settle()
        harness.github.answers["poll"] = .failure(.timedOut)
        harness.watcher.refresh()
        await harness.settle()
        var iterator = harness.events.makeAsyncIterator()
        #expect(await iterator.next() == .poll(.reviews, .ok))
        #expect(await iterator.next() == .poll(.reviews, .noData))
        #expect(await iterator.next() == .poll(.reviews, .failed))
        await harness.end()
    }

    @Test func watchOffStopsThePollsAndKeepsTheState() async throws {
        let harness = try await Harness()
        await harness.start()
        let kept = harness.store.state
        harness.watcher.apply(ReviewsConfig(watch: false))
        #expect(harness.watcher.toReview.isEmpty && harness.watcher.mine.isEmpty)
        #expect(harness.watcher.answer == nil && harness.watcher.lastPoll == nil)
        #expect(harness.clock.sleeperCount == 0 && !harness.watcher.attention)
        #expect(harness.store.state == kept)
        #expect(harness.log.values.last == .stopped)
        harness.watcher.refresh()
        #expect(harness.github.calls.count == 1)
        var iterator = harness.events.makeAsyncIterator()
        #expect(await iterator.next() == .poll(.reviews, .ok))
        #expect(await iterator.next() == .stopped(.reviews))
        // A new turn-on polls again, and nothing flashes: the first turn-on stays.
        await harness.start()
        #expect(harness.github.calls.count == 2)
        #expect(harness.watcher.toReview.allSatisfy { !$0.flash })
        await harness.end()
    }

    @Test func aStoreThatDidNotOpenGivesAWatcherThatDoesNothing() async throws {
        let github = FakeGitHub()
        let log = Recorder<ReviewsLogEvent>()
        let notifier = FakeNotifier()
        let watcher = ReviewsWatcher(
            github: GitHubClient(access: github), store: .failure(.otherCopy), notifier: notifier,
            health: .none, log: log, clock: ManualClock(), now: { .now }, openPanel: {})
        watcher.apply(ReviewsConfig(watch: true))
        watcher.refresh()
        #expect(github.calls.isEmpty && watcher.pollTask == nil)
        #expect(watcher.refusal == .otherCopy && watcher.toReview.isEmpty)
        #expect(log.values == [.notStarted(.otherCopy)])
    }
}
