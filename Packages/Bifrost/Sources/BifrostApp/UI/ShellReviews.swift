// The Reviews part of the app (docs/behaviour/reviews.md, "The panel" and "Settings > Reviews"):
// the store of the Reviews state, the GitHub client, the watcher and the consents of the automatic
// work on the PRs of the user, and the links of the Reviews panel to them.
//
// - The part follows the Reviews settings (ReviewsConfig of the settings), from start() to
//   stop(). While Watch GitHub is on, it opens the store and makes the watcher with the result
//   of the open. A store that did not open gives a watcher that never polls, and storeProblem
//   holds the reason for the panel. A turn-off stops the watcher, which tells the health log
//   that Reviews stopped, and closes the store, so its lock is free. Each open waits for the end
//   of the open and the close before it, so two stores of one run never hold the lock together.
// - The settings effects of Reviews stay no-ops: the part follows the settings itself, and gives
//   each new value to the watcher.
// - The consents of the automatic work on the PRs of the user: one for each of the settings
//   "Handle comments on my PRs automatically" (the request rounds), "Resolve merge conflicts
//   automatically" (the conflict rounds) and "Fix failing CI automatically" (the CI rounds). At
//   each open, the part turns off each of these settings that is on with no consent in the store,
//   all in one settings edit, so each switch shows the real state. For the comments that is the
//   case after the take-over of the Electron state. Only the confirmed turn-on of Settings >
//   Reviews gives a consent: after its save, Settings calls the link of that setting
//   (ReviewsLinks), which calls autoFixConfirmed(), resolveConflictsConfirmed() or
//   fixCIConfirmed(). Then the store records the consent (ReviewsState.consentToAutoFix,
//   consentToConflictFix or consentToCIFix). The consent of the comments also moves the start
//   of new work. A change of the setting itself gives no consent, so another write of true (the
//   Debug test port, an import, a settings file) does not, and no order of the observed values
//   can lose a confirm. A confirm while no store is open gives the consent at the next open of
//   this run, while the setting stays on.
// - The clones (docs/behaviour/reviews.md, "Clones and trust"): while the store is open, a
//   RepoSetup clones the repositories of each good poll and lists the ones that need trust. The
//   rows read its clone states, and each change of them builds the rows again. The trust panel
//   reads the trust and opens the trust runs through it. Remove all clones runs in the repo
//   store while the store is open. With no open store, it takes the lock of the Reviews folder
//   for the removal, so it never deletes the clones of another copy of Bifrost that runs
//   Reviews.
// - The PR rounds (docs/behaviour/reviews.md, "Review rounds" and "Request rounds"): while the
//   store is open and the part has claude, the registry and the session commands, ReviewRounds
//   runs the rounds of the queue in PR sessions. The rounds read the last good poll of the
//   watcher (the viewer and the PRs), drop the work of a request that went or of a PR of the user
//   that closed, and queue the request rounds of new work while the automatic rounds are on; a
//   change of the state builds the rows again, and the end of a round polls at once. A request
//   session runs in the sandbox of RequestSandbox, which refuses the secret paths of the home of
//   the user (SessionParts.userHome). The request rounds of a PR share one session: a later turn
//   types its prompt through the session input of the shell (input), which the rounds read at
//   the time of each turn.
//   At the start of the rounds, a request round that was posting when Bifrost quit sends the rest
//   of its writes (RoundWrites.resume). The reason of git or of GitHub for a write that stopped
//   goes to the Event log (eventLine). A repository whose trust step ended wakes the queue
//   (RepoSetup.onTrusted). Remove all clones first stops the rounds, the queued rounds and the PR
//   sessions.
// - The panels that write on a click (docs/behaviour/reviews.md, "Approve", "The Review panel"
//   and "The Answer panel"): while the store is open, the Approve button approves through one
//   ApproveFlow, each open of the Review panel gets a new DraftFlow, and each open of the Answer
//   panel a new AnswerFlow, whose answers go to the request rounds. They read the viewer of the
//   last good poll, ask for a poll after a write, and send the reason of GitHub to the Event log.
//   One ReviewWrites keeps the progress and the result of the approvals and of the sends of the
//   Review panel. The watcher keeps the row of a PR with a progress (ReviewWrites.held) and reads
//   the reviews that GitHub confirmed (ReviewWrites.reviewedHere), and the end of a progress
//   builds the rows again. The start of a new review round of a PR ends its confirmed review
//   (ReviewWrites.forget).
import BifrostFoundation
import BifrostReviews
import BifrostSessions
import BifrostSettings
import BifrostWindows
import Foundation
import OSLog
import Observation

extension ReviewsConfig {
    // The Reviews settings, the Row flash setting and the setting of the notifications, in the
    // types of the rules and the services. A bad entry of the ignore list is left out.
    package init(_ settings: Settings) {
        self.init(
            watch: settings.reviewsWatch, autoFix: settings.reviewsAutoFix,
            resolveConflicts: settings.reviewsResolveConflicts, fixCI: settings.reviewsFixCI,
            teamRequests: settings.reviewsTeamRequests,
            signedCommits: settings.reviewsSignedCommits, rowFlash: settings.rowFlash,
            notifications: settings.notifications, maxSessions: settings.reviewsMaxSessions,
            pause: .seconds(settings.reviewsPauseMinutes * 60),
            pollInterval: .seconds(settings.reviewsPollMinutes * 60),
            requestModel: settings.reviewsRequestModel, reviewModel: settings.reviewsReviewModel,
            ignore: settings.reviewsIgnore.compactMap(IgnoreEntry.init))
    }
}

@MainActor
@Observable
package final class ReviewsParts {
    // The watcher while Watch GitHub is on and the open of the store ended, else nil.
    package var watcher: ReviewsWatcher? {
        switch phase {
        case .on(let open): open.watcher
        case .refused(_, let watcher): watcher
        case .off, .opening: nil
        }
    }
    // The open store, or nil.
    package var store: ReviewsStore? { open?.store }
    package let client: GitHubClient
    // Why the store did not open, while Watch GitHub is on.
    package var storeProblem: ReviewsStoreError? {
        if case .refused(let problem, _) = phase { problem } else { nil }
    }
    // The consent of the automatic request rounds in the open store, or nil while no store is
    // open (ReviewsState.autoFixConsent).
    package private(set) var autoFixConsent: Bool?
    // The consent of the conflict rounds in the open store, or nil while no store is open
    // (ReviewsState.conflictConsent).
    package private(set) var conflictConsent: Bool?
    // The consent of the CI rounds in the open store, or nil while no store is open
    // (ReviewsState.ciConsent).
    package private(set) var ciConsent: Bool?
    // The clones of the polls and their trust, while the store is open.
    package var setup: RepoSetup? { open?.setup }
    // The review rounds, while the store is open and the part can start sessions.
    package var rounds: ReviewRounds? { open?.rounds }
    // The Approve button, while the store is open.
    package var approver: ApproveFlow? { open?.approver }
    // The progress and the result of the review writes of the rows, while the store is open.
    package var writes: ReviewWrites? { open?.writes }
    // The text input of the sessions. The shell owns it and sets it when it makes it. A turn of
    // a request round types its prompt through it (PRSessions.beginTurn).
    @ObservationIgnored package weak var input: (any PromptInput)?

    // The parts of Reviews while the store is open.
    private struct OpenParts {
        let store: ReviewsStore
        let watcher: ReviewsWatcher
        // nil when the part has no clones.
        let setup: RepoSetup?
        // nil when the part cannot start sessions.
        let rounds: ReviewRounds?
        let approver: ApproveFlow
        let writes: ReviewWrites
    }

    private enum Phase {
        case off
        // The open of the store with this number runs.
        case opening(Int)
        // The store did not open: the watcher never polls, and the panel shows why.
        case refused(ReviewsStoreError, ReviewsWatcher)
        case on(OpenParts)
    }

    private static let logger = Logger(bifrost: "reviews")

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let layout: ReviewsLayout
    @ObservationIgnored private let notifier: any Notifier
    @ObservationIgnored private let health: HealthReporter
    @ObservationIgnored private let storeLog: any StoreLog
    @ObservationIgnored private let log: any ReviewsLog
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let focused: @MainActor () -> Bool
    @ObservationIgnored private let refused: @MainActor () -> Void
    @ObservationIgnored private let openPanel: @MainActor () -> Void
    // Reviews stopped (a turn-off, a stop or the quit): the trust panel (its claude ends), the
    // Review panel and the Answer panel close.
    @ObservationIgnored private let closed: @MainActor () -> Void
    // A line for the Event log: the reason of git or of GitHub for a write of a request round
    // that stopped.
    @ObservationIgnored private let eventLine: @MainActor (String) -> Void
    // The steps of the safe writes of the store. A test holds a save with them.
    @ObservationIgnored private let steps: WriteSteps
    // The clones (nil: no clone work, for a test of the other parts), the PTYs of the trust
    // runs, and the home of the ~/.claude.json of the trust read.
    @ObservationIgnored private let repos: RepoStore?
    @ObservationIgnored private let ptys: PTYManager?
    @ObservationIgnored private let trustHome: URL?
    // The parts of the PR sessions. With none, no round runs.
    @ObservationIgnored private let sessionParts: SessionParts?
    // The one worker of the opens and the closes of the store, the removals with no open store
    // and the edits of the settings. Each work starts after the work before it ended, so two
    // stores of one run never hold the lock together, and the quit waits for the last save.
    @ObservationIgnored private let lifecycle = SerialWork()
    // The last command of the panel on the rounds. A test waits for it.
    @ObservationIgnored package private(set) var commandTask: Task<Void, Never>?
    // The follow of the clone states for the rows, while the store is open.
    @ObservationIgnored private var clonesFollow: Task<Void, Never>?
    // The last run of the clones after a poll. A test waits for it.
    @ObservationIgnored package private(set) var setupTask: Task<Void, Never>?
    private var phase = Phase.off
    // The settings of the last change that the part took, or nil before start(). A test waits
    // for a change.
    @ObservationIgnored package private(set) var config: ReviewsConfig?
    @ObservationIgnored private var following: Task<Void, Never>?
    // The number of the last open. An open that ends after a newer open or a close is stale.
    @ObservationIgnored private var opens = 0
    // The confirmed turn-ons while no store was open. The next open gives their consents.
    @ObservationIgnored private var consentWaits: Set<Consent> = []

    // access is the way to GitHub (gh in the app). focused tells whether the window has the
    // focus, refused runs when macOS refuses a notification, and openPanel opens the Reviews
    // panel at a click on a notification. steps are the steps of the safe writes of the store.
    // repos makes the clones, ptys opens the trust runs, and trustHome holds the .claude.json
    // of the trust read. closed runs at each close of Reviews. eventLine adds a line to the Event
    // log.
    package init(
        settings: SettingsStore, layout: ReviewsLayout, access: any GitHubAccess,
        notifier: any Notifier, health: HealthReporter, storeLog: any StoreLog,
        log: any ReviewsLog, clock: any Clock<Duration>, now: @escaping () -> Date,
        focused: @escaping @MainActor () -> Bool, refused: @escaping @MainActor () -> Void,
        openPanel: @escaping @MainActor () -> Void, steps: WriteSteps = .system,
        repos: RepoStore? = nil, ptys: PTYManager? = nil, trustHome: URL? = nil,
        sessions: SessionParts? = nil, closed: @escaping @MainActor () -> Void = {},
        eventLine: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.settings = settings
        self.layout = layout
        client = GitHubClient(access: access)
        self.notifier = notifier
        self.health = health
        // The part lives for the run, so each dropped field of state.json is logged one time.
        self.storeLog = ReviewsStoreLog(base: storeLog)
        self.log = log
        self.clock = clock
        self.now = now
        self.focused = focused
        self.refused = refused
        self.openPanel = openPanel
        self.steps = steps
        self.repos = repos
        self.ptys = ptys
        self.trustHome = trustHome
        sessionParts = sessions
        self.closed = closed
        self.eventLine = eventLine
    }

    isolated deinit {
        following?.cancel()
        clonesFollow?.cancel()
    }

    // The parts of the open store, or nil.
    private var open: OpenParts? {
        if case .on(let open) = phase { open } else { nil }
    }

    // Take the settings of now, then follow each change until stop().
    package func start() {
        guard following == nil else { return }
        let settings = settings
        apply(ReviewsConfig(settings.settings))
        let changes = Observations { ReviewsConfig(settings.settings) }
        following = Task { [weak self] in
            for await config in changes { self?.apply(config) }
        }
    }

    // Stop to follow the settings, stop the watcher and close the store. At a quit, each task of
    // the watcher ends. A second call does nothing more.
    package func stop() {
        following?.cancel()
        following = nil
        close()
    }

    // The quit (Shell.quit): stop to follow the settings, then stop the watcher, the rounds and
    // the clones at once (close). The store closes after the edits of the part and the end of
    // the rounds, while the clones stop. Each git of a clone or of a round ends within
    // RepoGit.stopGrace (1 s) after its SIGTERM, inside the 2 s wait of the quit. The task ends
    // when each git ended and the store wrote its last save and freed its lock, so the quit
    // waits for both. A later stop() does nothing more.
    package func closeForQuit() -> Task<Void, Never> {
        following?.cancel()
        following = nil
        close()
        let lifecycle = lifecycle
        return Task { await lifecycle.idle() }
    }

    // Wait until each open, close, removal and edit of the settings that the part started has
    // ended. A test waits for it.
    package func settled() async {
        await lifecycle.idle()
    }

    // MARK: - The panel

    // True while a pull request waits for the user (ReviewsWatcher.attention): the Reviews button
    // of the side bar shows its dot.
    package var attention: Bool { watcher?.attention ?? false }

    // Run a command of the panel on the watcher or the rounds.
    package func run(_ command: ReviewsCommand) {
        guard let watcher else { return }
        switch command {
        case .refresh: watcher.refresh()
        case .pause(let pr): watcher.pause(pr)
        case .endPause(let pr): watcher.endPause(pr)
        case .remove(let pr): watcher.remove(pr)
        case .review(let pr): roundCommand { await $0.review(pr) }
        case .cancelReview(let pr): roundCommand { await $0.cancel(pr) }
        case .stopSession(let pr): roundCommand { await $0.stopSession(pr) }
        case .handleNow(let pr): roundCommand { await $0.handle(pr, copilot: false) }
        case .handleCopilot(let pr): roundCommand { await $0.handle(pr, copilot: true) }
        case .resolveNow(let pr): roundCommand { await $0.resolveNow(pr) }
        case .tryAgain(let pr): roundCommand { await $0.tryAgain(pr) }
        case .cancelRequest(let pr): roundCommand { await $0.cancelRequest(pr) }
        case .dropUpdates(let pr, let click):
            roundCommand { await $0.dropOutbox(pr, click: click) }
        }
    }

    private func roundCommand(_ work: @escaping @MainActor (ReviewRounds) async -> Void) {
        guard let rounds else { return }
        commandTask = Task { await work(rounds) }
    }

    // The step of the round of the PR, or nil when no round runs.
    package func round(of pr: PRKey) -> RoundPhase? {
        store?.state.prs[pr]?.round?.phase
    }

    // The row of a PR session of the PR in the rows while it is not parked, or nil: the session
    // of its round, else its review session, else its request session.
    package func session(of pr: PRKey, in rows: [SessionRow]) -> SessionRow? {
        guard let state = store?.state.prs[pr] else { return nil }
        let ids = [
            state.round?.sessionID, state.reviewSession?.sessionID,
            state.requestSession?.sessionID,
        ].compactMap { $0?.text }
        for id in ids {
            if let row = rows.first(where: { $0.sessionId == id && $0.state != .parked }) {
                return row
            }
        }
        return nil
    }

    // What the Reviews panel shows, from the settings, the part and whether the services found
    // no claude. With no settings yet, or with Watch GitHub off, Reviews is off. With Watch
    // GitHub on and no part, Reviews starts while the services look for claude, and it says that
    // Claude Code is missing when they found none. With no watcher yet, Reviews starts.
    package static func snapshot(
        settings: Settings?, parts: ReviewsParts?, claudeMissing: Bool
    ) -> ReviewsSnapshot {
        let rowFlash = settings?.rowFlash ?? true
        guard settings?.reviewsWatch == true else {
            return ReviewsSnapshot(phase: .off, rowFlash: rowFlash)
        }
        if parts == nil && claudeMissing {
            return ReviewsSnapshot(phase: .noClaude, rowFlash: rowFlash)
        }
        if let problem = parts?.storeProblem {
            return ReviewsSnapshot(phase: .refused(problem), rowFlash: rowFlash)
        }
        guard let parts, let watcher = parts.watcher else {
            return ReviewsSnapshot(phase: .starting, rowFlash: rowFlash)
        }
        return ReviewsSnapshot(
            phase: .on, toReview: watcher.toReview, mine: watcher.mine, problem: watcher.problem,
            lastPoll: watcher.lastPoll, needsConsent: parts.autoFixConsent != true,
            rowFlash: rowFlash, needsTrust: parts.setup?.needsTrust ?? [:])
    }

    // MARK: - The clones

    // The change events of ~/.claude.json of the trust read, for the trust panel. With no home,
    // the stream ends at once.
    package func trustChanges() -> AsyncStream<Void> {
        guard let trustHome else { return AsyncStream { $0.finish() } }
        return TrustCheck.changes(home: trustHome)
    }

    // Remove all clones. While the store is open, the repo store removes them after the clone
    // that runs, and the set-up runs again at once with the last poll, so it clones the
    // repositories of that poll again. With no open store, the removal takes the lock of the
    // Reviews folder after the open and the close before it. The result is the friendly text of
    // a failure, or nil.
    package func removeAllClones() async -> String? {
        guard let repos else { return nil }
        let removal: @MainActor @Sendable () async -> String? = {
            do throws(RepoError) {
                try await repos.removeAllClones()
                return nil
            } catch {
                return error.message
            }
        }
        if let open {
            // The rounds hold their gate from their stop to the end of the removal.
            let failure: String?
            if let rounds = open.rounds {
                failure = await rounds.removeAll(then: removal)
            } else {
                failure = await removal()
            }
            if let failure { return failure }
            setup?.forgetClones()
            if let answer = watcher?.answer { runSetup(answer) }
            return nil
        }
        let layout = layout
        return await lifecycle.run {
            let lock: FileLock
            do throws(ReviewsStoreError) {
                lock = try await BlockingExecutor.run { () throws(ReviewsStoreError) in
                    try ReviewsStore.takeLock(layout)
                }
            } catch {
                return error.message
            }
            defer { lock.release() }
            return await removal()
        }
    }

    // Clone the repositories of the poll and read their trust (RepoSetup.run), after the run
    // before it.
    private func runSetup(_ answer: PollAnswer) {
        guard let setup else { return }
        let ignore = config?.ignore ?? []
        setupTask = Task { await setup.run(for: answer, ignoring: ignore) }
    }

    // MARK: - The settings

    private func apply(_ new: ReviewsConfig) {
        let old = config
        config = new
        guard new != old else { return }
        // A turn-off ends a confirm that waits for the next open.
        consentWaits = consentWaits.filter { new[keyPath: $0.config] }
        switch (new.watch, phase) {
        case (true, .off): openStore()
        case (false, .off): break
        case (false, _): close()
        case (true, .opening): break
        case (true, .refused(_, let watcher)): watcher.apply(new)
        case (true, .on(let open)):
            open.watcher.apply(new)
            open.rounds?.apply(new)
        }
    }

    // The user confirmed a turn-on of "Handle comments on my PRs automatically" in Settings, and
    // the setting saved (ReviewsLinks.confirmAutoFix). The open store records the consent. With
    // no open store, the next open of this run records it.
    package func autoFixConfirmed() {
        confirmed(.autoFix)
    }

    // The user confirmed a turn-on of "Resolve merge conflicts automatically" in Settings, and
    // the setting saved (ReviewsLinks.confirmResolveConflicts). As autoFixConfirmed().
    package func resolveConflictsConfirmed() {
        confirmed(.conflicts)
    }

    // The user confirmed a turn-on of "Fix failing CI automatically" in Settings, and the setting
    // saved (ReviewsLinks.confirmFixCI). As autoFixConfirmed().
    package func fixCIConfirmed() {
        confirmed(.ci)
    }

    private func confirmed(_ consent: Consent) {
        guard let store else {
            consentWaits.insert(consent)
            return
        }
        recordConsent(consent, in: store)
    }

    // Record the consent in the open store, at once. The store saves it, and the close of the
    // store waits for that save.
    private func recordConsent(_ consent: Consent, in store: ReviewsStore) {
        store.change { [now] in consent.record(in: &$0, now: now()) }
        readConsents(store)
    }

    // The consents of the open store, for the observers of the part.
    private func readConsents(_ store: ReviewsStore) {
        autoFixConsent = store.state.autoFixConsent
        conflictConsent = store.state.conflictConsent
        ciConsent = store.state.ciConsent
    }

    // At the open of a store: for each setting that is on with no consent in the store, a confirm
    // of this run that waits gives the consent, else the setting goes off. One settings edit
    // turns off all these settings.
    private func settleConsents(_ store: ReviewsStore) {
        defer { consentWaits = [] }
        var off: [Consent] = []
        for consent in Consent.allCases {
            guard settings.settings[keyPath: consent.setting],
                store.state[keyPath: consent.state] != true
            else { continue }
            if consentWaits.contains(consent) {
                recordConsent(consent, in: store)
            } else {
                off.append(consent)
            }
        }
        guard !off.isEmpty else { return }
        let settings = settings
        lifecycle.add {
            do throws(SettingsError) {
                try await settings.edit { edit in
                    for consent in off { edit[keyPath: consent.setting] = false }
                }
            } catch {
                Self.logger.error(
                    """
                    Bifrost cannot turn off the automatic work on your pull requests. \
                    \(error.message, privacy: .private)
                    """)
            }
        }
    }

    // MARK: - The store

    // Open the store after the open and the close before it, then make the watcher.
    private func openStore() {
        opens += 1
        let number = opens
        phase = .opening(number)
        let (layout, storeLog, steps, time) = (layout, storeLog, steps, now())
        lifecycle.add { [weak self] in
            let result: Result<ReviewsStore, ReviewsStoreError>
            do throws(ReviewsStoreError) {
                let store = try await ReviewsStore.open(
                    layout: layout, log: storeLog, now: time, steps: steps)
                result = .success(store)
            } catch {
                result = .failure(error)
            }
            guard let self else {
                if case .success(let store) = result { await store.close().value }
                return
            }
            await self.opened(result, number: number)?.value
        }
    }

    // The end of an open. A stale open closes its store at once, and the result is the close.
    private func opened(
        _ result: Result<ReviewsStore, ReviewsStoreError>, number: Int
    ) -> Task<Void, Never>? {
        guard case .opening(let current) = phase, current == number else {
            if case .success(let store) = result { return store.close() }
            return nil
        }
        let watcher = ReviewsWatcher(
            github: client, store: result, notifier: notifier, health: health, log: log,
            clock: clock, now: now, openPanel: openPanel)
        watcher.focused = focused
        watcher.refused = refused
        switch result {
        case .success(let store):
            readConsents(store)
            let setup = makeSetup(store, watcher: watcher)
            let writes = ReviewWrites(
                clock: clock, progressEnded: { [weak watcher] in watcher?.refreshTimes() })
            let approver = ApproveFlow(
                store: store, github: client, writes: writes,
                viewer: { [weak watcher] in watcher?.answer?.viewer },
                ended: { [weak watcher] in watcher?.refresh() }, eventLine: eventLine)
            watcher.held = { [weak writes] in writes?.held ?? [] }
            watcher.reviewedHere = { [weak writes] in writes?.reviewedHere($0) ?? [:] }
            phase = .on(
                OpenParts(
                    store: store, watcher: watcher, setup: setup,
                    rounds: setup.flatMap {
                        makeRounds(store, setup: $0, watcher: watcher, writes: writes)
                    },
                    approver: approver, writes: writes))
            settleConsents(store)
        case .failure(let failure):
            phase = .refused(failure, watcher)
        }
        if let config { watcher.apply(config) }
        return nil
    }

    // MARK: - The panels that write

    // A new flow for an open of the Review panel, or nil while the store is not open.
    package func draftFlow() -> DraftFlow? {
        guard let open else { return nil }
        let watcher = open.watcher
        return DraftFlow(
            store: open.store, github: client, approver: open.approver, writes: open.writes,
            viewer: { [weak watcher] in watcher?.answer?.viewer },
            ended: { [weak watcher] in watcher?.refresh() }, eventLine: eventLine)
    }

    // A new flow for an open of the Answer panel of the PR, or nil while the rounds don't run.
    // The answers go to the request rounds (ReviewRounds.answerQuestions).
    package func answerFlow(for pr: PRKey) -> AnswerFlow? {
        guard let store, let rounds else { return nil }
        return AnswerFlow(pr: pr, store: store) { [weak rounds] answers in
            await rounds?.answerQuestions(pr, answers) ?? false
        }
    }

    // The set-up of the clones of the open store, with its links to the watcher: the rows read
    // its clone states, and each change of them builds the rows again. nil when the part has no
    // clones.
    private func makeSetup(_ store: ReviewsStore, watcher: ReviewsWatcher) -> RepoSetup? {
        guard let repos, let trustHome else { return nil }
        let setup = RepoSetup(
            repos: repos, store: store, ptys: ptys, home: trustHome,
            notify: { [weak watcher] in watcher?.notify($0) }, now: now)
        watcher.clones = { [weak setup] in setup?.clones ?? CloneStates() }
        watcher.answered = { [weak self] in self?.runSetup($0) }
        let changes = Observations { setup.clones }
        clonesFollow = Task { [weak watcher] in
            for await _ in changes { watcher?.refreshTimes() }
        }
        return setup
    }

    // The review rounds of the open store, with their links to the watcher, the setup and the
    // review writes. Each good poll runs the setup, then goes to the rounds. The start of a new
    // review round ends the confirmed review of its PR. nil when the part cannot start sessions.
    private func makeRounds(
        _ store: ReviewsStore, setup: RepoSetup, watcher: ReviewsWatcher, writes: ReviewWrites
    ) -> ReviewRounds? {
        guard let parts = sessionParts, let repos else { return nil }
        let sessions = PRSessions(
            store: store, registry: parts.registry, actions: parts.actions, claude: parts.claude,
            clock: clock, now: now, testPrefix: parts.testPrefix,
            input: { [weak self] in self?.input })
        let rounds = ReviewRounds(
            store: store, github: client, repos: repos, setup: setup, sessions: sessions,
            skills: parts.skills, userHome: parts.userHome,
            config: config ?? ReviewsConfig(), now: now)
        rounds.answer = { [weak watcher] in watcher?.answer }
        rounds.changed = { [weak watcher] in watcher?.refreshTimes() }
        rounds.ended = { [weak watcher] in watcher?.refresh() }
        rounds.notify = { [weak watcher] in watcher?.notify($0) }
        rounds.eventLine = eventLine
        rounds.reviewStarted = { [weak writes] in writes?.forget($0) }
        setup.onTrusted = { [weak rounds] in rounds?.trusted($0) }
        watcher.answered = { [weak self, weak rounds] in
            self?.runSetup($0)
            rounds?.afterPoll($0)
        }
        rounds.start()
        return rounds
    }

    // Stop the watcher, the rounds and the clones at once, close the panels of Reviews, and
    // close the store after the end of the rounds, while the clones stop. The worker ends this
    // close when the store and the clones ended, so the next open never overlaps an old store,
    // round or clone.
    private func close() {
        let old = phase
        if case .off = old { return }
        phase = .off
        closed()
        clonesFollow?.cancel()
        clonesFollow = nil
        autoFixConsent = nil
        conflictConsent = nil
        ciConsent = nil
        var (store, rounds): (ReviewsStore?, ReviewRounds?) = (nil, nil)
        switch old {
        case .on(let open):
            open.rounds?.stop()
            open.watcher.stop()
            (store, rounds) = (open.store, open.rounds)
        case .refused(_, let watcher):
            watcher.stop()
        case .off, .opening:
            // The open sees the close and closes its store at once.
            break
        }
        let stopping = stopClones(old)
        lifecycle.add {
            await rounds?.waitForEnd()
            await store?.close().value
            await stopping.value
        }
    }

    // Stop the set-up and each clone. The task ends when each git of a clone ended and its
    // temporary folder went (RepoStore.cancelClones).
    private func stopClones(_ old: Phase) -> Task<Void, Never> {
        setupTask?.cancel()
        setupTask = nil
        if case .on(let open) = old { open.setup?.stop() }
        let repos = repos
        return Task { await repos?.cancelClones() }
    }
}

// The automatic work on the PRs of the user that needs a consent: the setting, its value in the
// config, the consent in the state and the record of the consent.
private enum Consent: CaseIterable {
    // "Handle comments on my PRs automatically": the request rounds.
    case autoFix
    // "Resolve merge conflicts automatically": the conflict rounds.
    case conflicts
    // "Fix failing CI automatically": the CI rounds.
    case ci

    var setting: WritableKeyPath<Settings, Bool> {
        switch self {
        case .autoFix: \.reviewsAutoFix
        case .conflicts: \.reviewsResolveConflicts
        case .ci: \.reviewsFixCI
        }
    }

    var config: KeyPath<ReviewsConfig, Bool> {
        switch self {
        case .autoFix: \.autoFix
        case .conflicts: \.resolveConflicts
        case .ci: \.fixCI
        }
    }

    var state: KeyPath<ReviewsState, Bool?> {
        switch self {
        case .autoFix: \.autoFixConsent
        case .conflicts: \.conflictConsent
        case .ci: \.ciConsent
        }
    }

    // The consent of the comments also moves the start of new work to now.
    func record(in state: inout ReviewsState, now: Date) {
        switch self {
        case .autoFix: state.consentToAutoFix(now: now)
        case .conflicts: state.consentToConflictFix()
        case .ci: state.consentToCIFix()
        }
    }
}

// The parts of the PR sessions of Reviews: claude, the registry of the session rows, the session
// commands (Stop and Delete), the bundled skills (AppServices.skillsSource), the home of the user
// in the user database (StartPlan.realHome), whose secret paths the sandbox of a request session
// refuses, and whether each session name starts with bifrost-test- (a test home).
package struct SessionParts {
    package let claude: ClaudeRunner
    package let registry: RegistryService
    package let actions: SessionActions
    package let skills: URL
    package let userHome: URL
    package let testPrefix: Bool

    package init(
        claude: ClaudeRunner, registry: RegistryService, actions: SessionActions, skills: URL,
        userHome: URL, testPrefix: Bool
    ) {
        self.claude = claude
        self.registry = registry
        self.actions = actions
        self.skills = skills
        self.userHome = userHome
        self.testPrefix = testPrefix
    }
}

// MARK: - The links of the panel

extension Shell {
    // The links of the Reviews panel to the services. The shell sets the links that need the
    // window in wire().
    static func reviewsLinks(_ services: AppServices) -> ReviewsPanelLinks {
        let links = ReviewsPanelLinks()
        links.snapshot = { [weak services] in
            ReviewsParts.snapshot(
                settings: services?.settings?.settings, parts: services?.reviews,
                claudeMissing: services?.sessions.status == .claudeNotFound)
        }
        links.run = { [weak services] in services?.reviews?.run($0) }
        links.refreshTimes = { [weak services] in services?.reviews?.watcher?.refreshTimes() }
        links.session = { [weak services] pr in
            services?.reviews?.session(of: pr, in: services?.sessions.rows ?? [])
        }
        links.openTrustRun = { [weak services] in await services?.reviews?.setup?.openTrust($0) }
        links.isTrusted = { [weak services] in
            await services?.reviews?.setup?.isTrusted($0) ?? false
        }
        links.trustChanges = { [weak services] in
            services?.reviews?.trustChanges() ?? AsyncStream { $0.finish() }
        }
        links.trusted = { [weak services] in services?.reviews?.setup?.trusted($0) }
        links.trustStepEnded = { [weak services] in services?.reviews?.rounds?.trustStepEnded($0) }
        links.approver = { [weak services] in services?.reviews?.approver }
        links.writes = { [weak services] in services?.reviews?.writes }
        links.makeDraftFlow = { [weak services] in services?.reviews?.draftFlow() }
        links.makeAnswerFlow = { [weak services] in services?.reviews?.answerFlow(for: $0) }
        links.changesToDiscard = { [weak services] pr in
            await services?.reviews?.rounds?.changesToDiscard(pr) ?? .notNow
        }
        links.discard = { [weak services] pr, click in
            await services?.reviews?.rounds?.discardChanges(pr, click: click) ?? .notNow
        }
        return links
    }
}

#if DEBUG
extension Shell {
    // The reviews op of the test port: a click on Review or Pause of the row of the PR, as the
    // button or the menu item of the row runs it (ReviewsPanelModel.choose). The click acts only
    // while the row of now offers the item. The result is nil after the click, else the reason
    // for the answer.
    public func runReviewsTest(_ action: TestReviewsAction, pr text: String) -> String? {
        guard let pr = PRKey(text: text) else { return "\(text) is not the key of a pull request" }
        let links = reviews.links
        let snapshot = links.snapshot()
        guard let row = (snapshot.toReview + snapshot.mine).first(where: { $0.id == pr }) else {
            return "the Reviews panel has no row for \(text)"
        }
        let (item, command): (ReviewsMenuItem, ReviewsCommand) =
            switch action {
            case .review: (.review, .review(pr))
            case .pause: (.pause, .pause(pr))
            }
        guard ReviewsMenu.items(row, hasSession: links.session(pr) != nil).contains(item) else {
            return "the row of \(text) has no \(action.rawValue) item now"
        }
        links.run(command)
        return nil
    }
}
#endif
