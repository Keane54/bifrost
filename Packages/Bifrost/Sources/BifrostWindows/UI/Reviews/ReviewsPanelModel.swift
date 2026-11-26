// The model of the Reviews panel (docs/behaviour/reviews.md, "The panel"): what the panel shows
// (ReviewsSnapshot), the commands of the panel to the watcher (ReviewsCommand), the links of the
// panel to the services (ReviewsPanelLinks) and the model of one body (ReviewsPanelModel). The
// model gives each text and each state, so the view (ReviewsPanel) only lays them out.
//
// - The panel reads the services only through its links: the snapshot of now, the commands of
//   the watcher, the session of a PR and the opens. The snapshot reads observed values, so the
//   panel follows each change.
// - The Trust needed strip lists each repository whose clone needs the trust of the user, with
//   the count of its PRs that wait. Its Trust button opens the trust panel (TrustPanels).
// - A click on a My PRs row with open questions of Claude opens the Answer panel. A click on
//   another row opens the chat of its PR session while the session works or needs the user, else
//   it does nothing. Cmd+click opens the PR on GitHub: only its https address on github.com. A
//   right-click or a Control-click shows the row menu (ReviewsMenu).
// - Approve (the button, or the item of the menu) approves through ApproveFlow with the click of
//   the user. Its button waits while CI runs. A refusal shows in the error line. Comment and
//   Request changes open the Review panel for Claude's draft.
// - While a review write of a PR runs (an approval, or a send of the Review panel), and for the
//   time of ReviewWrites.hold after GitHub confirmed it, the row shows the progress in the place
//   of its state text and its buttons (ReviewWrites.progress), and the menu has no Approve, no
//   Comment and no Request changes. A refusal ends the progress at once.
// - A display clock ticks while the panel is in a frame. Each tick asks the watcher for new time
//   texts of the rows, with no poll, and moves the time of "Last checked".
import AppKit
import BifrostFoundation
import BifrostLayout
import BifrostLook
import BifrostReviews
import BifrostSessions
import BifrostSettings
import Observation

// What the Reviews panel shows: the state of Reviews and the rows of now. The shell makes it from
// the settings and the Reviews services.
package struct ReviewsSnapshot: Sendable, Equatable {
    package enum Phase: Sendable, Equatable {
        // Watch GitHub is off.
        case off
        // Watch GitHub is on, and the watcher does not run yet: the store opens, or Bifrost
        // still looks for claude.
        case starting
        // Watch GitHub is on, and Bifrost found no claude, so Reviews does not start in this run.
        case noClaude
        // The store did not open: another copy of Bifrost runs Reviews, or the saved state has
        // another version. Reviews does nothing on GitHub.
        case refused(ReviewsStoreError)
        // The watcher runs.
        case on
    }

    package var phase: Phase
    package var toReview: [ReviewRow]
    package var mine: [ReviewRow]
    // The reason of the last poll, when it failed.
    package var problem: GitHubError?
    // The time of the last good poll, or nil before the first one.
    package var lastPoll: Date?
    // True until the user turns on "Handle comments on my PRs automatically" in this app with its
    // confirm.
    package var needsConsent: Bool
    // The Row flash setting.
    package var rowFlash: Bool
    // The repositories whose clone needs the trust of the user, with the count of their PRs
    // (RepoSetup.needsTrust).
    package var needsTrust: [RepoName: Int]
    // True while a refresh that the user asked for with a click runs (ReviewsWatcher.refreshing).
    package var refreshing: Bool

    package init(
        phase: Phase, toReview: [ReviewRow] = [], mine: [ReviewRow] = [],
        problem: GitHubError? = nil, lastPoll: Date? = nil, needsConsent: Bool = false,
        rowFlash: Bool = true, needsTrust: [RepoName: Int] = [:], refreshing: Bool = false
    ) {
        self.phase = phase
        self.toReview = toReview
        self.mine = mine
        self.problem = problem
        self.lastPoll = lastPoll
        self.needsConsent = needsConsent
        self.rowFlash = rowFlash
        self.needsTrust = needsTrust
        self.refreshing = refreshing
    }
}

// A command of the panel to the watcher and the rounds. None of them writes to GitHub: a review
// round leaves only a pending review.
package enum ReviewsCommand: Sendable, Equatable {
    case refresh
    case pause(PRKey)
    case endPause(PRKey)
    case remove(PRKey)
    // Review or Try again: queue a review round.
    case review(PRKey)
    case cancelReview(PRKey)
    case stopSession(PRKey)
    // A PR of the user: Handle now, Handle Copilot comments, Try again and Cancel of the queued
    // request round.
    case handleNow(PRKey)
    case handleCopilot(PRKey)
    // Resolve now: queue a conflict round.
    case resolveNow(PRKey)
    case tryAgain(PRKey)
    case cancelRequest(PRKey)
    // Don't send the rest: the kept writes of a stopped request round go, and nothing is sent.
    case dropUpdates(PRKey, click: UserClick)
}

// The values of the services that the panel reads, and the calls that it makes. Each link has a
// default that does nothing, so a test gives only the links that it needs. The shell sets the
// links that need the window after its init (openChat, openSettings), so a panel reads the links
// at each call.
@MainActor
package final class ReviewsPanelLinks {
    // The snapshot of now. It reads observed values.
    package var snapshot: @MainActor () -> ReviewsSnapshot = { ReviewsSnapshot(phase: .off) }
    package var run: @MainActor (ReviewsCommand) -> Void = { _ in }
    // Build the rows again at the time of now, with no poll (ReviewsWatcher.refreshTimes).
    package var refreshTimes: @MainActor () -> Void = {}
    // The row of the PR session of the PR while it is not parked, or nil.
    package var session: @MainActor (PRKey) -> SessionRow? = { _ in nil }
    // Open the chat of the session (the Open action).
    package var openChat: @MainActor (String) -> Void = { _ in }
    // Open Settings > Reviews.
    package var openSettings: @MainActor () -> Void = {}
    // Open the Answer panel of the open questions of Claude on the PR.
    package var openAnswer: @MainActor (PRKey) -> Void = { _ in }
    // Open the Review panel for Claude's draft of the PR.
    package var openDraft: @MainActor (PRKey) -> Void = { _ in }
    // The Approve button (ApproveFlow) while Reviews runs, or nil.
    package var approver: @MainActor () -> ApproveFlow? = { nil }
    // The progress and the result of the review writes of the rows while Reviews runs, or nil.
    package var writes: @MainActor () -> ReviewWrites? = { nil }
    // A new flow of the Review panel, or nil while Reviews doesn't run.
    package var makeDraftFlow: @MainActor () -> DraftFlow? = { nil }
    // A new flow of the Answer panel for the PR, or nil while Reviews doesn't run.
    package var makeAnswerFlow: @MainActor (PRKey) -> AnswerFlow? = { _ in nil }
    // The check of Discard these changes: the changed files of the copy of the PR, or why the
    // discard can't run (ReviewRounds.changesToDiscard).
    package var changesToDiscard: @MainActor (PRKey) async -> DiscardOutcome = { _ in .notNow }
    // Discard these changes with the click of the user, after the confirm
    // (ReviewRounds.discardChanges).
    package var discard: @MainActor (PRKey, UserClick) async -> DiscardOutcome = { _, _ in .notNow }
    // Ask in Bifrost's own dialog. True only after a click on the confirm button. The shell sets
    // it.
    package var confirm: @MainActor (ConfirmText) async -> Bool = { _ in false }

    // The trust panel (TrustPanels): the trust run in the clone of a repository, the trust read
    // of that clone, the change events of ~/.claude.json, and the end of a trust step.
    package var openTrustRun: @MainActor (RepoName) async -> PTYRun? = { _ in nil }
    package var isTrusted: @MainActor (RepoName) async -> Bool = { _ in false }
    package var trustChanges: @MainActor () -> AsyncStream<Void> = { AsyncStream { $0.finish() } }
    package var trusted: @MainActor (RepoName) -> Void = { _ in }
    // The user closed the trust panel and the trust read sees no trust: the repository gets one
    // start, which claude judges.
    package var trustStepEnded: @MainActor (RepoName) -> Void = { _ in }
    // The layout of the window and the terminal font, for the trust panel. The shell sets them.
    package var openPanel: @MainActor (PanelID) -> Void = { _ in }
    package var closePanel: @MainActor (PanelID) -> Void = { _ in }
    package var terminalFont: @MainActor () -> NSFont = {
        .monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    package init() {}
}

@MainActor
@Observable
package final class ReviewsPanelModel {
    // What the body of the panel shows.
    package enum Body: Equatable {
        // Watch GitHub is off: the line and Open Settings.
        case off
        // No answer yet: "Checking GitHub…".
        case starting
        // A line in place of the rows: Bifrost found no claude, the store did not open, or gh is
        // missing or logged out before the first good poll.
        case notice(String)
        // The first poll failed: only the gh line shows.
        case failed
        // The tab has no row.
        case empty
        case rows
    }

    // The time between two ticks of the display clock.
    nonisolated package static let tick = Duration.seconds(30)

    nonisolated package static let offText =
        "Reviews is off. Turn on Watch GitHub in Settings to see your pull requests."
    nonisolated package static let checkingText = "Checking GitHub\u{2026}"
    nonisolated package static let noClaudeText =
        "Reviews needs Claude Code, and Bifrost can't find it. Install it, then open Bifrost again."
    nonisolated package static let emptyText = "Nothing needs you here."
    nonisolated package static let openSettingsText = "Open Settings"
    nonisolated package static let autoFixHint =
        "Want Claude to fix and answer new review comments for you? Turn on "
        + "\(ReviewsSettingsRow.autoFix.rawValue) in Settings."

    // The open tab.
    package var tab = ReviewsTab.toReview
    // The time of the panel. The display clock moves it.
    package private(set) var now: Date
    // The reason of the last failed action of the panel, until the user closes it.
    package private(set) var error: String?

    @ObservationIgnored package let links: ReviewsPanelLinks
    @ObservationIgnored private let opener: any AppOpener
    @ObservationIgnored private let look: PanelLook
    @ObservationIgnored private let menu: @MainActor () -> BifrostMenu?
    @ObservationIgnored private let wallNow: () -> Date
    @ObservationIgnored private let zone: TimeZone
    @ObservationIgnored private let timer: TimerSlot
    // The Trust button of a repository of the strip.
    @ObservationIgnored private let openTrust: @MainActor (RepoName) -> Void
    // The last open of a PR on GitHub. A test waits for it.
    @ObservationIgnored package private(set) var opening: Task<Void, Never>?
    // The last approval of a click. A test waits for it.
    @ObservationIgnored package private(set) var approval: Task<Void, Never>?
    // The last Discard these changes, from the read of the files to the command. A test waits
    // for it.
    @ObservationIgnored package private(set) var discarding: Task<Void, Never>?

    // opener opens the PR in the browser. menu gives the Bifrost menu of the window. The clock
    // runs the display clock, and now gives the wall time.
    package init(
        links: ReviewsPanelLinks, opener: any AppOpener, look: PanelLook,
        menu: @escaping @MainActor () -> BifrostMenu?, clock: any Clock<Duration>,
        now: @escaping () -> Date, zone: TimeZone = .current,
        openTrust: @escaping @MainActor (RepoName) -> Void = { _ in }
    ) {
        self.links = links
        self.openTrust = openTrust
        self.opener = opener
        self.look = look
        self.menu = menu
        wallNow = now
        self.zone = zone
        timer = TimerSlot(clock: clock)
        self.now = now()
    }

    package var metrics: CanvasMetrics { look.metrics }

    // The look of the controls at the Interface scale and the Panel transparency.
    package var style: PanelStyle {
        PanelStyle(metrics: look.metrics, transparency: look.panelTransparency)
    }

    package var snapshot: ReviewsSnapshot { links.snapshot() }

    // MARK: - What the panel shows

    package var body: Body {
        let snapshot = snapshot
        switch snapshot.phase {
        case .off: return .off
        case .starting: return .starting
        case .noClaude: return .notice(Self.noClaudeText)
        case .refused(let failure): return .notice(failure.message)
        case .on: break
        }
        guard snapshot.lastPoll != nil else {
            guard let problem = snapshot.problem else { return .starting }
            switch problem {
            case .notInstalled, .notLoggedIn: return .notice(problem.message)
            case .notSent, .refused, .timedOut, .badAnswer, .unknownOutcome: return .failed
            }
        }
        return rows(tab).isEmpty ? .empty : .rows
    }

    // The rows of the tab.
    package func rows(_ tab: ReviewsTab) -> [ReviewRow] {
        tab == .toReview ? snapshot.toReview : snapshot.mine
    }

    package func count(_ tab: ReviewsTab) -> Int { rows(tab).count }

    // True when the count of the tab is red: a To review row flashes (ReviewRow.flash: a new
    // request whose CI does not fail), or Claude needs the user on a My PRs row. The Row flash
    // setting stops the flash of the rows, not the red count.
    package func isHot(_ tab: ReviewsTab) -> Bool {
        switch tab {
        case .toReview:
            return snapshot.toReview.contains(where: \.flash)
        case .mine:
            return snapshot.mine.contains {
                if case .mine(_, let claude) = $0.state { claude.needsTheUser } else { false }
            }
        }
    }

    // True when the row flashes: a new request whose CI does not fail, with the Row flash
    // setting on.
    package func flashes(_ row: ReviewRow) -> Bool {
        row.flash && snapshot.rowFlash
    }

    // The tabs show while the watcher runs and has an answer or a failure.
    package var showsTabs: Bool {
        guard snapshot.phase == .on else { return false }
        return body != .starting
    }

    // The hint of the automatic comment handling shows on My PRs until the user turns it on in
    // this app with its confirm.
    package var showsHint: Bool {
        guard tab == .mine, snapshot.needsConsent else { return false }
        return body == .rows || body == .empty
    }

    // The Trust needed strip: each repository whose clone needs trust, by name, with the count
    // of its PRs. It shows while the watcher runs.
    package var trustRows: [(repo: RepoName, waiting: Int)] {
        let snapshot = snapshot
        guard snapshot.phase == .on else { return [] }
        return snapshot.needsTrust.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    // The text of the count of a line of the strip.
    nonisolated package static func waitingText(_ waiting: Int) -> String {
        waiting == 1 ? "1 pull request waiting" : "\(waiting) pull requests waiting"
    }

    nonisolated package static let trustTitle = "Trust needed"
    nonisolated package static let trustButton = "Trust"
    nonisolated package static let trustTip =
        "Opens Claude Code in Bifrost's copy of this repository, so you can accept the trust "
        + "prompt."

    // The Trust button of the repository: the trust panel opens with a terminal in its clone.
    package func trust(_ repo: RepoName) {
        openTrust(repo)
    }

    // "Last checked 09:07", with the day for a poll of another day, or nil before the first good
    // poll.
    package var lastChecked: String? {
        guard snapshot.phase == .on, let poll = snapshot.lastPoll else { return nil }
        let text = TimeText.clockOrDay(
            poll.millisecondsSince1970, now: now.millisecondsSince1970, zone: zone)
        return "Last checked \(text)"
    }

    // The friendly line of gh when the last poll failed, under the rows. A failure that the body
    // already shows has no line.
    package var ghLine: String? {
        guard snapshot.phase == .on, let problem = snapshot.problem else { return nil }
        if case .notice = body { return nil }
        return problem.message
    }

    // The row of the PR in its tab, or nil when the PR has no row.
    package func row(_ pr: PRKey) -> ReviewRow? {
        let snapshot = snapshot
        return snapshot.toReview.first { $0.id == pr } ?? snapshot.mine.first { $0.id == pr }
    }

    // The items of the row menu of the PR, or nil when the PR has no row. Approve, Comment and
    // Request changes are not there while a review write of the PR has a progress.
    package func menuItems(_ pr: PRKey) -> [ReviewsMenuItem]? {
        let writing = progress(pr) != nil
        return row(pr).map {
            ReviewsMenu.items($0, hasSession: links.session(pr) != nil).filter {
                !writing || !Self.writeItems.contains($0)
            }
        }
    }

    // The items that start a review write: Approve, and the Review panel of Claude's draft.
    private static let writeItems: Set<ReviewsMenuItem> = [.approve, .comment, .requestChanges]

    // The progress of the review write of the PR, or nil. The row shows it in the place of its
    // state text and its buttons.
    package func progress(_ pr: PRKey) -> ReviewWriteProgress? {
        links.writes()?.progress(pr)
    }

    // The state text that the row shows, or nil. While a review write of the PR has a progress,
    // the row shows no state text: a text such as "Approval recommended" or "Changes required" is
    // old once you click, and the progress tells what happens (user decision, 2026-11-19).
    package func shownStatus(_ row: ReviewRow) -> RowLabel? {
        guard progress(row.id) == nil, !row.status.text.isEmpty else { return nil }
        return row.status
    }

    // True when a button of the row acts now: Approve waits while CI runs. Approve, Comment and
    // Request changes wait while a review write of the PR has a progress. Each other button acts.
    package func isEnabled(_ item: ReviewsMenuItem, _ row: ReviewRow) -> Bool {
        // Open session on a My PRs row acts only while the PR has a session.
        if item == .openSession { return links.session(row.id) != nil }
        guard Self.writeItems.contains(item) else { return true }
        guard progress(row.id) == nil else { return false }
        return item != .approve || row.approve == .ready
    }

    nonisolated package static let removeTip =
        "Hide this pull request in Bifrost. Nothing changes on GitHub. It comes back if someone "
        + "asks for your review again."
    nonisolated package static let draftTip =
        "Check Claude's draft, change it if you like, and send it."

    // The tip of a button of the row, or nil.
    package func tip(_ item: ReviewsMenuItem, _ row: ReviewRow) -> String? {
        switch item {
        case .approve:
            if row.approve == .waitsForCI { return ApproveRefusal.ciRunning.message }
            return row.state == .toReview(.draftReady)
                ? "Submit Claude's draft review on GitHub as an approval."
                : "Approve this pull request on GitHub."
        case .comment, .requestChanges: return Self.draftTip
        case .remove: return Self.removeTip
        default: return nil
        }
    }

    // MARK: - The actions

    // A click on the row of the PR. Cmd+click opens the PR on GitHub. A plain click on a My PRs
    // row with open questions opens the Answer panel. Else a plain click opens the chat of the PR
    // session while the session works or needs the user, else it does nothing.
    package func click(_ pr: PRKey, command: Bool) {
        guard let row = row(pr) else { return }
        if command {
            openOnGitHub(pr)
            return
        }
        if row.tab == .mine && row.questions > 0 {
            links.openAnswer(pr)
            return
        }
        guard let session = links.session(pr), [.working, .needsYou].contains(session.state)
        else { return }
        links.openChat(session.sessionId)
    }

    // A choice of the row menu, or a button of the row. It acts only while the item applies to
    // the row of now.
    package func choose(_ item: ReviewsMenuItem, for pr: PRKey) {
        guard menuItems(pr)?.contains(item) == true else { return }
        switch item {
        case .openOnGitHub: openOnGitHub(pr)
        case .openSession:
            if let session = links.session(pr) { links.openChat(session.sessionId) }
        // Approve needs the click of the user (approve(_:click:)).
        case .approve: break
        case .comment, .requestChanges: links.openDraft(pr)
        case .review: links.run(.review(pr))
        case .tryAgain:
            links.run(row(pr)?.tab == .mine ? .tryAgain(pr) : .review(pr))
        case .remove: links.run(.remove(pr))
        case .cancelReview: links.run(.cancelReview(pr))
        case .stopSession: links.run(.stopSession(pr))
        case .pause: links.run(.pause(pr))
        case .endPause: links.run(.endPause(pr))
        case .answerClaude: links.openAnswer(pr)
        case .handleNow: links.run(.handleNow(pr))
        case .handleCopilot: links.run(.handleCopilot(pr))
        case .resolveNow: links.run(.resolveNow(pr))
        case .cancel: links.run(.cancelRequest(pr))
        case .dropUpdates: links.run(.dropUpdates(pr, click: UserClick()))
        case .discardChanges: discard(pr)
        }
    }

    // Discard these changes: Bifrost's own dialog names the files first, and only Discard
    // discards them. Cancel changes nothing. A discard that can't run, or a copy with no change
    // now, shows why in the error line.
    private func discard(_ pr: PRKey) {
        let links = links
        error = nil
        discarding = Task { [weak self] in
            let check = await links.changesToDiscard(pr)
            guard case .files(let files) = check else {
                self?.error = check.message
                return
            }
            guard await links.confirm(Self.discardConfirm(files)) else { return }
            let outcome = await links.discard(pr, UserClick())
            if let message = outcome.message { self?.error = message }
        }
    }

    // The most file names that the confirm of Discard these changes shows.
    nonisolated package static let discardNames = 5

    // The confirm of Discard these changes, with the names of the files.
    nonisolated package static func discardConfirm(_ files: [String]) -> ConfirmText {
        let count = files.count
        let shown = files.prefix(discardNames)
        var names = shown.dropLast().joined(separator: ", ")
        if count > discardNames {
            names += (names.isEmpty ? "" : ", ") + (shown.last ?? "")
            names += " and \(count - discardNames) more"
        } else if let last = shown.last {
            names += names.isEmpty ? last : " and \(last)"
        }
        let title =
            count == 1 ? "Discard the changes in 1 file?" : "Discard the changes in \(count) files?"
        return ConfirmText(
            title: title,
            body: "They aren't on GitHub, and you can't get them back: \(names). Files that git "
                + "ignores in Bifrost's copy go too.",
            confirm: "Discard")
    }

    // Show the row menu of the PR at the point (screen coordinates) over the window.
    package func showMenu(_ pr: PRKey, at point: NSPoint, in window: NSWindow) {
        guard let menu = menu() else { return }
        ReviewsMenu.show(pr, model: self, at: .point(point), in: window, menu: menu)
    }

    // Approve the PR with the click of the user: the button or the item of the menu. It acts
    // only while the row of now offers Approve and the approval of the PR has no progress. The
    // task starts in the click, so the row shows Approving at once and a second click finds the
    // progress. A refusal shows in the error line.
    package func approve(_ pr: PRKey, click: UserClick) {
        guard let row = row(pr), isEnabled(.approve, row), let approver = links.approver() else {
            return
        }
        error = nil
        approval = Task.immediate { [weak self] in
            do throws(ApproveRefusal) {
                try await approver.approve(pr, click: click)
            } catch {
                self?.error = error.message
            }
        }
    }

    // True while a refresh that the user asked for runs: the Refresh icon turns.
    package var isRefreshing: Bool { snapshot.phase == .on && snapshot.refreshing }

    package func refresh() {
        links.run(.refresh)
    }

    package func openSettings() {
        links.openSettings()
    }

    package func closeError() {
        error = nil
    }

    // Open the PR in the browser: only its https address on github.com. A failure shows in the
    // error line.
    private func openOnGitHub(_ pr: PRKey) {
        let url = pr.webURL
        guard url.scheme == "https", url.host() == "github.com" else { return }
        let opener = opener
        opening = Task { [weak self] in
            do throws(ActionRefusal) {
                try await opener.openInBrowser(url)
            } catch {
                self?.error = error.message
            }
        }
    }

    // MARK: - The display clock

    // Take the time of now, ask for new time texts, and tick.
    func start() {
        advance()
    }

    // The body is in no frame now: the tick stops.
    func stop() {
        timer.stop()
    }

    private func advance() {
        now = wallNow()
        links.refreshTimes()
        timer.start(after: Self.tick) { [weak self] in self?.advance() }
    }

    #if DEBUG
    // The task of the display clock, or nil. A test waits for it.
    var tickTask: Task<Void, Never>? { timer.task }
    #endif
}
