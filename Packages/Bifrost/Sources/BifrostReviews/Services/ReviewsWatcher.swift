// The Reviews watcher (docs/behaviour/reviews.md, "The watcher"): it polls GitHub while Watch
// GitHub is on, records what each poll says in the Reviews state, and gives the rows to the
// panel. It is the one owner of the poll, so a poll never overlaps another.
//
// - The poll follows the timer of the app: a poll, then one TimerSlot waits for the next one. A
//   refresh ends the wait at once. A refresh during a poll starts one more poll at the end of
//   that poll, because the poll that runs can hold an answer from before the change of the user.
//   Several refreshes during one poll give one more poll. A new interval counts from the start
//   of the wait that runs.
// - Each good poll first records its marks in the state (ReviewsState.recordPoll), then builds
//   the rows. So the first poll after the first turn-on never flashes an open request.
// - A poll that fails keeps the last good answer and its rows. problem holds the reason.
// - A second TimerSlot wakes the rows at the earliest end of a pause. No tick runs here: the
//   panel asks for new time texts on its own display clock (refreshTimes).
// - A store that did not open (refusal) means no poll: the panel shows the message.
// - Each good poll goes to the clones of Reviews after its rows (answered: RepoSetup.run), and
//   the rows read the clone states (clones), so a queued round shows why it waits.
// - A To review row whose PR has an approval progress (held: ApproveFlow.held) stays when a poll
//   drops the PR, so the row shows the progress to its end (ReviewRows.holding).
// - A To review row of an approval that GitHub confirmed says You approved until a poll shows the
//   approval (approvedHere: ApproveFlow.approvedHere), so a poll that is behind GitHub never
//   brings Approve back.
import BifrostFoundation
import BifrostSessions
import Foundation
import Observation

// A notification that other parts of Reviews ask for (the rounds of later tasks).
package enum ReviewsNotice: Sendable, Equatable {
    case newRequest(PRKey)
    // More than AlertRules.maxNotifications new requests in one poll.
    case newRequests(Int)
    case draftReady(PRKey)
    // A review round found nothing to flag: Claude suggests Approve, and nothing was posted.
    case reviewed(PRKey)
    case needsYou(PRKey, questions: Int)
    case trustNeeded(RepoName)
}

@MainActor
@Observable
package final class ReviewsWatcher {
    // The last good answer. It stays after a poll that fails.
    package private(set) var answer: PollAnswer?
    package private(set) var toReview: [ReviewRow] = []
    package private(set) var mine: [ReviewRow] = []
    // The reason of the last poll, when it failed. This is the gh line of the panel.
    package private(set) var problem: GitHubError?
    // The time of the last good poll.
    package private(set) var lastPoll: Date?
    // Why Reviews does not run: the store did not open.
    package private(set) var refusal: ReviewsStoreError?

    // True when the window has the focus. The shell reads it from the window. The default counts
    // the window as not focused.
    @ObservationIgnored package var focused: @MainActor () -> Bool = { false }

    // True when a row flashes or needs the user: a new request, a draft to check, or a question
    // of Claude on a PR of the user.
    package var attention: Bool {
        toReview.contains { $0.flash || $0.state == .toReview(.draftReady) }
            || mine.contains {
                if case .mine(_, .needsYou) = $0.state { true } else { false }
            }
    }

    private enum Phase {
        case stopped
        // On, and no poll runs. The timer waits for the next poll.
        case waiting
        // On, and this poll runs.
        // again is true when a refresh came during the poll: one more poll follows at once.
        case polling(Task<Void, Never>, again: Bool)
    }

    @ObservationIgnored private let github: GitHubClient
    @ObservationIgnored private let store: ReviewsStore?
    @ObservationIgnored private let notifier: any Notifier
    @ObservationIgnored private let health: HealthReporter
    @ObservationIgnored private let log: any ReviewsLog
    @ObservationIgnored private let timeline: Timeline
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let openPanel: @MainActor () -> Void
    @ObservationIgnored private let pollTimer: TimerSlot
    @ObservationIgnored private let pauseTimer: TimerSlot
    @ObservationIgnored private var config = ReviewsConfig()
    @ObservationIgnored private var phase = Phase.stopped
    // The start of the wait that runs, on the timeline.
    @ObservationIgnored private var waitStart: Duration = .zero
    // macOS refused a notification. The shell adds one line to the Event log, as for the alerts.
    @ObservationIgnored package var refused: @MainActor () -> Void = {}
    // The clone states of the rows (RepoSetup.clones). The default has no clone state.
    @ObservationIgnored package var clones: @MainActor () -> CloneStates = { CloneStates() }
    // A good poll, after its rows and its notifications: the clones of its repositories.
    @ObservationIgnored package var answered: @MainActor (PollAnswer) -> Void = { _ in }
    // The PRs whose To review row stays when a poll drops them (ApproveFlow.held). The default
    // holds no row.
    @ObservationIgnored package var held: @MainActor () -> Set<PRKey> = { [] }
    // The approvals of the user that GitHub confirmed and that the answer does not show yet
    // (ApproveFlow.approvedHere). Their rows say You approved. The default has none.
    @ObservationIgnored package var approvedHere: @MainActor (PollAnswer) -> [PRKey: String] = {
        _ in [:]
    }

    // store is the result of the open of the store. A store that did not open gives a watcher
    // that does nothing on GitHub.
    package init(
        github: GitHubClient, store: Result<ReviewsStore, ReviewsStoreError>,
        notifier: any Notifier, health: HealthReporter, log: any ReviewsLog,
        clock: any Clock<Duration>, now: @escaping () -> Date,
        openPanel: @escaping @MainActor () -> Void
    ) {
        self.github = github
        self.notifier = notifier
        self.health = health
        self.log = log
        self.now = now
        self.openPanel = openPanel
        timeline = Timeline(clock)
        pollTimer = TimerSlot(clock: clock)
        pauseTimer = TimerSlot(clock: clock)
        switch store {
        case .success(let opened):
            self.store = opened
        case .failure(let failure):
            self.store = nil
            refusal = failure
            log.record(.notStarted(failure))
        }
    }

    // The task of the poll that runs, or nil. A test waits for it.
    package var pollTask: Task<Void, Never>? {
        if case .polling(let task, _) = phase { task } else { nil }
    }

    // The task of the timer of the next poll, or nil. A test waits for it.
    package var pollTimerTask: Task<Void, Never>? { pollTimer.task }

    // The task of the timer of the end of a pause, or nil. A test waits for it.
    package var pauseTimerTask: Task<Void, Never>? { pauseTimer.task }

    // MARK: - The settings

    // Take the settings. Watch GitHub turns the polls on or off. A change of another setting
    // builds the rows again, and a new interval counts from the start of the wait that runs.
    package func apply(_ new: ReviewsConfig) {
        let old = config
        config = new
        guard store != nil else { return }
        switch (new.watch, phase) {
        case (true, .stopped):
            log.record(.started(interval: new.pollInterval))
            phase = .waiting
            poll()
        case (false, .stopped):
            break
        case (false, _):
            stop()
        case (true, _):
            rebuild()
            if old.pollInterval != new.pollInterval, case .waiting = phase {
                schedule(elapsed: timeline.now() - waitStart)
            }
        }
    }

    // End the polls and the timers, and clear the rows. The state stays as it is. The call of a
    // stop at the quit of the app ends each task of the watcher. A click before the stop changed
    // the state at once, and the close of the store waits for its save.
    package func stop() {
        if case .stopped = phase { return }
        if case .polling(let task, _) = phase { task.cancel() }
        phase = .stopped
        pollTimer.stop()
        pauseTimer.stop()
        answer = nil
        toReview = []
        mine = []
        problem = nil
        lastPoll = nil
        health.record(.stopped(.reviews))
        log.record(.stopped)
    }

    // MARK: - The poll

    // Poll now, also in the wait for the next poll. During a poll, one more poll follows at the
    // end of that poll.
    package func refresh() {
        switch phase {
        case .stopped: break
        case .waiting: poll()
        case .polling(let task, _): phase = .polling(task, again: true)
        }
    }

    private func poll() {
        guard case .waiting = phase else { return }
        pollTimer.stop()
        phase = .polling(Task { [weak self] in await self?.run() }, again: false)
    }

    private func run() async {
        let result = await fetch()
        // A stop cancelled this poll, so it changes nothing.
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let fresh): accept(fresh)
        case .failure(let failure): reject(failure)
        }
        guard !Task.isCancelled else { return }
        var again = false
        if case .polling(_, let more) = phase { again = more }
        phase = .waiting
        if again { poll() } else { schedule(elapsed: .zero) }
    }

    private func fetch() async -> Result<PollAnswer, GitHubError> {
        do throws(GitHubError) {
            return .success(try await github.poll())
        } catch {
            return .failure(error)
        }
    }

    // A good answer. The marks go into the state first, in one update, and the update runs only
    // when the state changes. Then the rows are built, so the first poll shows no flash and the
    // requests that arrived with this poll are known.
    private func accept(_ fresh: PollAnswer) {
        guard let store else { return }
        let time = now()
        // The check runs on a copy, so the store writes only when the poll changes the state.
        var probe = store.state
        probe.recordPoll(fresh, now: time)
        var arrived: Set<PRKey> = []
        if probe != store.state {
            store.change { arrived = $0.recordPoll(fresh, now: time) }
        }
        answer = fresh
        problem = nil
        lastPoll = time
        health.record(.poll(.reviews, .ok))
        rebuild()
        // At most maxNotifications requests show one notification each. More give one summary.
        let flashing = toReview.filter {
            arrived.contains($0.id) && $0.state == .toReview(.newRequest)
        }
        if flashing.count > AlertRules.maxNotifications {
            notify(.newRequests(flashing.count))
        } else {
            for row in flashing { notify(.newRequest(row.id)) }
        }
        answered(fresh)
    }

    // A poll that failed. The last good answer and its rows stay.
    private func reject(_ failure: GitHubError) {
        if problem != failure { log.record(.pollFailed(failure)) }
        problem = failure
        switch failure {
        case .notInstalled, .notLoggedIn:
            health.record(.poll(.reviews, .noData))
        case .notSent, .refused, .timedOut, .badAnswer, .unknownOutcome:
            health.record(.poll(.reviews, .failed))
        }
    }

    // Start the timer of the next poll. elapsed is the part of the wait that has passed.
    private func schedule(elapsed: Duration) {
        waitStart = timeline.now() - elapsed
        let remaining = config.pollInterval - elapsed
        if remaining <= .zero {
            poll()
        } else {
            pollTimer.start(after: remaining) { [weak self] in self?.poll() }
        }
    }

    // MARK: - The rows

    // Build the rows again at the time of now, with no poll, so the time texts ("5m ago",
    // "Paused 42m") are correct between two polls. The panel calls it on its display clock, and
    // the end of an approval progress calls it, so a held row goes. With no good answer, or while
    // stopped, it does nothing.
    package func refreshTimes() {
        rebuild()
    }

    // Build both tabs again from the last good answer, the state and the settings, and plan the
    // wake at the end of the first pause. A held row stays.
    private func rebuild() {
        guard let store, let answer else { return }
        let time = now()
        let clones = clones()
        let rows = ReviewRows.holding(
            held(), old: toReview,
            new: ReviewRows.toReview(
                answer, store.state, config, clones: clones, approvedHere: approvedHere(answer),
                now: time))
        if rows != toReview { toReview = rows }
        let own = ReviewRows.mine(answer, store.state, config, clones: clones, now: time)
        if own != mine { mine = own }
        planPauseEnd(store.state, now: time)
    }

    private func planPauseEnd(_ state: ReviewsState, now time: Date) {
        guard let end = state.pauses.values.filter({ $0 > time }).min() else {
            pauseTimer.stop()
            return
        }
        pauseTimer.start(after: .seconds(end.timeIntervalSince(time))) { [weak self] in
            self?.rebuild()
        }
    }

    // MARK: - The clicks on a row

    // Pause a new request: it stops to flash until the end of the pause setting.
    package func pause(_ pr: PRKey) {
        guard toReview.contains(where: { $0.id == pr && $0.state == .toReview(.newRequest) })
        else { return }
        let until = now().addingTimeInterval(config.pause.seconds)
        edit { $0.pauses[pr] = until }
    }

    // End the pause of a PR at once.
    package func endPause(_ pr: PRKey) {
        guard store?.state.pauses[pr] != nil else { return }
        edit { $0.pauses[pr] = nil }
    }

    // Remove the row of a PR that others approved. Nothing changes on GitHub.
    package func remove(_ pr: PRKey) {
        guard toReview.contains(where: { $0.id == pr && $0.isRemovable }),
            let request = answer?.toReview.first(where: { $0.key == pr })
        else { return }
        let time = now()
        edit { $0.hide(request, now: time) }
    }

    // Change the state at once, then build the rows again. The store saves the change.
    private func edit(_ change: (inout ReviewsState) -> Void) {
        guard let store else { return }
        store.change(change)
        rebuild()
    }

    // MARK: - The notifications

    // Show a notification of Reviews. It shows only with Notifications on in Settings and with
    // no focus in the window. A click opens the Reviews panel.
    package func notify(_ notice: ReviewsNotice) {
        guard config.notifications, !focused() else { return }
        let note = AlertNote(title: Self.title(notice), body: body(notice), source: .reviews)
        notifier.show(
            note, onClick: { [openPanel] _ in openPanel() },
            onFailed: { [weak self] in self?.refused() })
    }

    private static func title(_ notice: ReviewsNotice) -> String {
        switch notice {
        case .newRequest: "New review request"
        case .newRequests: "New review requests"
        case .draftReady: "Your review draft is ready"
        case .reviewed: "Claude suggests you approve"
        case .needsYou: "Claude has questions"
        case .trustNeeded: "Claude needs your trust"
        }
    }

    private func body(_ notice: ReviewsNotice) -> String {
        switch notice {
        case .newRequest(let pr):
            let title = answer?.toReview.first { $0.key == pr }?.title
            return [pr.text, title].compactMap { $0 }.joined(separator: ": ")
        case .newRequests(let count):
            return "\(count) pull requests wait for your review."
        case .draftReady(let pr):
            return "Claude finished its draft for \(pr.text). Check it before you send it."
        case .reviewed(let pr):
            return "Claude found nothing to flag in \(pr.text). Nothing was posted."
        case .needsYou(let pr, let questions):
            let count = questions == 1 ? "a question" : "\(questions) questions"
            return "Claude has \(count) for you on \(pr.text)."
        case .trustNeeded(let repo):
            return "Trust the folder of \(repo) so Claude can start on it."
        }
    }
}

extension Duration {
    // The span in seconds.
    fileprivate var seconds: Double {
        let (whole, atto) = components
        return Double(whole) + Double(atto) / 1e18
    }
}
