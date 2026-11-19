// The Reviews panel (docs/behaviour/reviews.md, "The panel"): the tabs and their counts, the
// flash, the bodies of each state of Reviews, the clicks, the row menu, the hint of the automatic
// comment handling and the display clock. The tests give the panel a snapshot of their own and
// record its commands, and a fake opener, so no test reaches GitHub or opens a browser.
import AppKit
import BifrostChat
import BifrostFoundation
import BifrostLayout
import BifrostLook
import BifrostReviews
import BifrostSessions
import BifrostTestSupport
import Foundation
import Observation
import SwiftUI
import Testing

@testable import BifrostWindows

// The services of the tests: the snapshot that the panel reads, and the calls of the panel.
@MainActor
@Observable
private final class Feed {
    // 2026-11-10 12:00:00 UTC, a Tuesday.
    nonisolated static let polled = Date(timeIntervalSince1970: 1_794_312_000)

    var snapshot = ReviewsSnapshot(phase: .on, lastPoll: Feed.polled)
    @ObservationIgnored var commands: [ReviewsCommand] = []
    @ObservationIgnored var chats: [String] = []
    @ObservationIgnored var sessions: [PRKey: SessionRow] = [:]
    @ObservationIgnored var timeRefreshes = 0
    @ObservationIgnored var settingsOpens = 0
}

// The wall time of the panel, which a test moves.
@MainActor
private final class Wall {
    var date = Feed.polled.addingTimeInterval(60)
}

@MainActor
private struct Parts {
    let feed = Feed()
    let opener = FakeOpener()
    let clock = ManualClock()
    let wall = Wall()
    let look = PanelLook()
    let menu: BifrostMenu
    let panels: ReviewsPanels

    init() {
        UITestApp.prepare()
        let links = ReviewsPanelLinks()
        let (feed, wall) = (feed, wall)
        links.snapshot = { feed.snapshot }
        links.run = { feed.commands.append($0) }
        links.refreshTimes = { feed.timeRefreshes += 1 }
        links.session = { feed.sessions[$0] }
        links.openChat = { feed.chats.append($0) }
        links.openSettings = { feed.settingsOpens += 1 }
        let menu = BifrostMenu(look: look, tooltips: TooltipController(), clock: ManualClock())
        // The menu bar of a test that runs at the same time does not close this menu.
        menu.appNotifications = NotificationCenter()
        menu.visibleFrame = { _ in NSRect(x: 0, y: 0, width: 1200, height: 800) }
        self.menu = menu
        panels = ReviewsPanels(
            links: links, opener: opener, look: look, menu: { menu }, clock: clock,
            now: { wall.date }, zone: .gmt)
    }

    func host() throws -> ReviewsHost {
        try #require(panels.body(for: .reviews) as? ReviewsHost)
    }

    func model() throws -> ReviewsPanelModel {
        try host().rootView.model
    }
}

private func key(_ text: String) throws -> PRKey {
    try #require(PRKey(text: text))
}

private func toReview(_ text: String, _ state: ToReviewState) throws -> ReviewRow {
    let pr = try key(text)
    return ReviewRow(
        id: pr, state: .toReview(state), repo: pr.repo.name, title: "Fix the parser",
        notes: ["user-a", "+12 \u{2212}3", "2h ago"],
        status: RowLabel(
            text: state == .newRequest ? "" : RowText.toReview(state, now: Feed.polled),
            tone: .plain, tip: nil))
}

private func mine(_ text: String, _ claude: ClaudeState) throws -> ReviewRow {
    let pr = try key(text)
    return ReviewRow(
        id: pr, state: .mine(.pending, claude), repo: pr.repo.name, title: "Add the cache",
        review: RowText.status(.pending, cut: false), status: RowText.claude(claude))
}

@MainActor
@Suite("the Reviews panel", .serialized, .testTimeLimit, .tags(.window))
struct ReviewsPanelTests {
    // The Trust needed strip lists each repository that needs trust by name, with the count of
    // its PRs. Its Trust button opens the trust panel for that repository, which asks Reviews
    // for a trust run in its clone. A run that does not open says why. With Reviews off, the
    // strip does not show.
    // A stop of Reviews (Watch GitHub off) closes the terminal of the trust panel, so its claude
    // gets SIGHUP, and closes the panel.
    @Test func aStopOfReviewsClosesTheTrustPanelAndEndsItsClaude() async throws {
        let p = Parts()
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let root = folder.realPath + "/repos"
        try FileManager.default.createDirectory(
            atPath: root + "/owner-a/repo-a", withIntermediateDirectories: true)
        let checked = try #require(
            await TrustRuns.check(
                folder: URL(filePath: root + "/owner-a/repo-a"),
                root: URL(filePath: root, directoryHint: .isDirectory)))
        let spawner = FakeSpawner()
        let ptys = PTYManager(
            claude: ClaudeRunner(path: "/bin/claude", baseEnvironment: [:], runner: NoRunner()),
            spawner: spawner)
        let closed = Recorder<PanelID>()
        p.panels.links.openTrustRun = { _ in
            try? await ptys.openTrust(checked, size: TerminalSize(cols: 100, rows: 30))
        }
        p.panels.links.closePanel = { closed.record($0) }
        let repo = try #require(RepoName("owner-a/repo-a"))
        p.panels.trust.open(repo)
        #expect(p.panels.trust.body(for: .trust) != nil)
        await p.panels.trust.opening?.value
        let terminal = try #require(p.panels.trust.terminal)
        #expect(terminal.state == .running)
        p.panels.trust.reviewsStopped()
        #expect(spawner.fakes.map(\.signals) == [[.hangup]])
        #expect(terminal.state == .closed)
        #expect(p.panels.trust.terminal == nil)
        #expect(p.panels.trust.repo == nil)
        #expect(closed.values == [.trust])
    }

    // A close of the trust panel reads the trust one last time: a trust that the user gave just
    // before the close ends the trust step.
    @Test func aCloseOfTheTrustPanelReadsTheTrustOnce() async throws {
        let p = Parts()
        let repo = try #require(RepoName("owner-a/repo-a"))
        let reads = Recorder<RepoName>()
        let trusted = Recorder<RepoName>()
        p.panels.links.isTrusted = {
            reads.record($0)
            return true
        }
        p.panels.links.trusted = { trusted.record($0) }
        p.panels.trust.open(repo)
        _ = p.panels.trust.body(for: .trust)
        await p.panels.trust.opening?.value
        p.panels.trust.releaseBody(for: .trust)
        await p.panels.trust.lastRead?.value
        #expect(reads.values == [repo])
        #expect(trusted.values == [repo])
    }

    // A close of the trust panel with no trust that the read sees still ends the trust step:
    // Reviews gets the end, so the repository gets one start that claude judges.
    @Test func aCloseWithNoTrustEndsTheTrustStep() async throws {
        let p = Parts()
        let repo = try #require(RepoName("owner-a/repo-a"))
        let trusted = Recorder<RepoName>()
        let ended = Recorder<RepoName>()
        p.panels.links.isTrusted = { _ in false }
        p.panels.links.trusted = { trusted.record($0) }
        p.panels.links.trustStepEnded = { ended.record($0) }
        p.panels.trust.open(repo)
        _ = p.panels.trust.body(for: .trust)
        await p.panels.trust.opening?.value
        p.panels.trust.releaseBody(for: .trust)
        await p.panels.trust.lastRead?.value
        #expect(trusted.values.isEmpty)
        #expect(ended.values == [repo])
    }

    @Test func theTrustStripOpensTheTrustPanelOfItsRepository() async throws {
        let p = Parts()
        let a = try #require(RepoName("owner-b/repo-b"))
        let b = try #require(RepoName("owner-a/repo-a"))
        p.feed.snapshot.needsTrust = [a: 1, b: 3]
        let model = try p.model()
        #expect(model.trustRows.map(\.repo) == [b, a])
        #expect(model.trustRows.map(\.waiting) == [3, 1])
        #expect(ReviewsPanelModel.waitingText(1) == "1 pull request waiting")
        #expect(ReviewsPanelModel.waitingText(3) == "3 pull requests waiting")
        let opened = Recorder<PanelID>()
        let asked = Recorder<RepoName>()
        p.panels.links.openPanel = { opened.record($0) }
        p.panels.links.openTrustRun = {
            asked.record($0)
            return nil
        }
        model.trust(b)
        #expect(opened.values == [.trust])
        #expect(p.panels.trust.repo == b)
        await p.panels.trust.opening?.value
        #expect(asked.values == [b])
        #expect(p.panels.trust.problem == TrustPanels.openFailedText(b))
        #expect(p.panels.trust.body(for: .trust) != nil)
        #expect(p.panels.trust.body(for: .reviews) == nil)
        // The panel closes: the repository goes.
        p.panels.trust.releaseBody(for: .trust)
        #expect(p.panels.trust.repo == nil)
        p.feed.snapshot.phase = .off
        #expect(model.trustRows.isEmpty)
    }

    @Test func theTabsShowTheirCounts() async throws {
        let p = Parts()
        p.feed.snapshot.toReview = [
            try toReview("owner-a/repo-a#1", .waitingForYou),
            try toReview("owner-a/repo-a#2", .teamRequest),
            try toReview("owner-a/repo-b#3", .approvedByOthers),
        ]
        p.feed.snapshot.mine = [
            try mine("owner-a/repo-c#4", .waiting), try mine("owner-a/repo-c#5", .fork),
        ]
        let model = try p.model()
        #expect(model.showsTabs)
        #expect(model.count(.toReview) == 3 && model.count(.mine) == 2)
        #expect(model.tab == .toReview && model.body == .rows)
        #expect(model.rows(.toReview).map(\.id.number) == [1, 2, 3])
        model.tab = .mine
        #expect(model.rows(model.tab).map(\.id.number) == [4, 5])
        // A tab with no row says so.
        p.feed.snapshot.mine = []
        #expect(model.count(.mine) == 0 && model.body == .empty)
        #expect(ReviewsPanelModel.emptyText == "Nothing needs you here.")
    }

    // The count of To review is red while a row flashes, and the count of My PRs while Claude
    // needs the user.
    @Test func theTabCountIsRedWhileARowFlashes() async throws {
        let p = Parts()
        p.feed.snapshot.toReview = [try toReview("owner-a/repo-a#1", .waitingForYou)]
        p.feed.snapshot.mine = [try mine("owner-a/repo-c#4", .waiting)]
        let model = try p.model()
        #expect(!model.isHot(.toReview) && !model.isHot(.mine))
        p.feed.snapshot.toReview.append(try toReview("owner-a/repo-a#2", .newRequest))
        #expect(model.isHot(.toReview) && !model.isHot(.mine))
        p.feed.snapshot.mine.append(try mine("owner-a/repo-c#5", .needsYou(2)))
        #expect(model.isHot(.mine))
    }

    // Only a new request flashes, and only while the Row flash setting is on. The setting stops
    // the flash of the row, and the count of the tab stays red.
    @Test func rowFlashOffStopsTheFlash() async throws {
        let p = Parts()
        let new = try toReview("owner-a/repo-a#1", .newRequest)
        let waiting = try toReview("owner-a/repo-a#2", .waitingForYou)
        p.feed.snapshot.toReview = [new, waiting]
        let model = try p.model()
        #expect(model.flashes(new) && !model.flashes(waiting))
        p.feed.snapshot.rowFlash = false
        #expect(!model.flashes(new) && !model.flashes(waiting))
        #expect(model.isHot(.toReview))
    }

    // The host and each view in it take no focus and are not in the Tab loop of the window, so
    // the rows are not focusable.
    @Test func theRowsAreNotFocusable() async throws {
        let p = Parts()
        p.feed.snapshot.toReview = [
            try toReview("owner-a/repo-a#1", .newRequest),
            try toReview("owner-a/repo-b#3", .approvedByOthers),
        ]
        let host = try p.host()
        #expect(p.panels.body(for: .reviews) === host)
        #expect(p.panels.body(for: .settings) == nil)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        #expect(!host.acceptsFirstResponder && !host.canBecomeKeyView)
        window.makeFirstResponder(host)
        #expect(window.firstResponder !== host)
        var views: [NSView] = [host]
        var seen = 0
        while let view = views.popLast() {
            seen += 1
            #expect(!view.acceptsFirstResponder, "\(type(of: view))")
            #expect(!view.canBecomeKeyView, "\(type(of: view))")
            views += view.subviews
        }
        #expect(seen > 1)
        // Tab moves the focus to no view of the panel.
        window.selectNextKeyView(nil)
        let responder = window.firstResponder as? NSView
        #expect(responder == nil || responder?.isDescendant(of: host) == false)
    }

    // A plain click on a row with no session, or with a session that neither works nor needs the
    // user, does nothing: no chat, no browser and no command. A session that works opens.
    @Test func aClickOnARowWithNoSessionDoesNothing() async throws {
        let p = Parts()
        let pr = try key("owner-a/repo-a#1")
        p.feed.snapshot.toReview = [try toReview(pr.text, .reviewing)]
        let model = try p.model()
        model.click(pr, command: false)
        p.feed.sessions[pr] = SessionRow.test(sessionId: "bifrost-test-pr-1", state: .idle)
        model.click(pr, command: false)
        p.feed.sessions[pr] = SessionRow.test(sessionId: "bifrost-test-pr-1", state: .parked)
        model.click(pr, command: false)
        #expect(p.feed.chats.isEmpty && p.feed.commands.isEmpty)
        #expect(p.opener.calls.isEmpty && model.opening == nil)
        p.feed.sessions[pr] = SessionRow.test(sessionId: "bifrost-test-pr-1", state: .working)
        model.click(pr, command: false)
        p.feed.sessions[pr] = SessionRow.test(sessionId: "bifrost-test-pr-1", state: .needsYou)
        model.click(pr, command: false)
        #expect(p.feed.chats == ["bifrost-test-pr-1", "bifrost-test-pr-1"])
        // A PR with no row does nothing.
        model.click(try key("owner-a/repo-a#9"), command: false)
        #expect(p.feed.chats.count == 2)
    }

    // The round items: Review while a round can start (Try again on a failed row, as its
    // button), Cancel review for a review that waits, and Open session and Stop session while the
    // PR has a session that is not parked. Each goes to the rounds; Open session opens the chat.
    // A row whose round cannot start (CI fails, or Claude's draft is pending) has no Review.
    @Test func theRoundItemsGoToTheRounds() async throws {
        let p = Parts()
        let new = try key("owner-a/repo-a#1")
        let failed = try key("owner-a/repo-a#2")
        let queued = try key("owner-a/repo-a#3")
        let reviewing = try key("owner-a/repo-a#4")
        let blocked = try key("owner-a/repo-a#5")
        var newRow = try toReview(new.text, .newRequest)
        newRow.reviewable = true
        var failedRow = try toReview(failed.text, .failed("No result."))
        failedRow.reviewable = true
        p.feed.snapshot.toReview = [
            newRow, failedRow, try toReview(queued.text, .queued),
            try toReview(reviewing.text, .reviewing), try toReview(blocked.text, .waitingForYou),
        ]
        p.feed.sessions[reviewing] = SessionRow.test(
            sessionId: "bifrost-test-pr-4", state: .working)
        let model = try p.model()
        #expect(model.menuItems(new) == [.openOnGitHub, .review, .pause])
        #expect(ReviewsMenu.buttons(newRow) == [.review, .pause])
        #expect(model.menuItems(failed) == [.openOnGitHub, .tryAgain])
        #expect(ReviewsMenu.buttons(failedRow) == [.tryAgain])
        #expect(model.menuItems(queued) == [.openOnGitHub, .cancelReview])
        #expect(
            model.menuItems(reviewing) == [.openOnGitHub, .openSession, .stopSession])
        #expect(model.menuItems(blocked) == [.openOnGitHub])
        #expect(ReviewsMenu.buttons(try toReview(blocked.text, .waitingForYou)).isEmpty)
        model.choose(.review, for: new)
        model.choose(.tryAgain, for: failed)
        model.choose(.cancelReview, for: queued)
        model.choose(.stopSession, for: reviewing)
        model.choose(.openSession, for: reviewing)
        // These items do not apply to these rows.
        model.choose(.review, for: blocked)
        model.choose(.review, for: failed)
        model.choose(.stopSession, for: new)
        #expect(
            p.feed.commands == [
                .review(new), .review(failed), .cancelReview(queued), .stopSession(reviewing),
            ])
        #expect(p.feed.chats == ["bifrost-test-pr-4"])
    }

    // The items of a My PRs row, in the order of the Electron menu: Answer Claude while Claude has
    // open questions; Handle now and Handle Copilot comments while their items wait and Claude
    // waits, needs the user or failed; Try again on a failed row; Don't send the rest while the
    // writes of a stopped round wait; Cancel for a queued round; Stop session while a round runs.
    // A fork row has Open on GitHub only. Each item goes to the request rounds, Don't send the
    // rest with a click, and Answer Claude opens the Answer panel.
    @Test func theMyPRsItemsGoToTheRequestRounds() async throws {
        let p = Parts()
        let waiting = try key("owner-a/repo-a#1")
        let asks = try key("owner-a/repo-a#2")
        let failed = try key("owner-a/repo-a#3")
        let queued = try key("owner-a/repo-a#4")
        let fixing = try key("owner-a/repo-a#5")
        let fork = try key("owner-a/repo-a#6")
        var waitingRow = try mine(waiting.text, .waiting)
        waitingRow.waiting = 2
        waitingRow.laterCopilot = 1
        var asksRow = try mine(asks.text, .needsYou(1))
        asksRow.questions = 1
        var forkRow = try mine(fork.text, .fork)
        forkRow.waiting = 3
        var failedRow = try mine(failed.text, .error("No result."))
        failedRow.unsentUpdates = true
        var queuedRow = try mine(queued.text, .queued)
        queuedRow.unsentUpdates = true
        p.feed.snapshot.mine = [
            waitingRow, asksRow, failedRow, queuedRow, try mine(fixing.text, .fixing(2)), forkRow,
        ]
        p.feed.sessions[fixing] = SessionRow.test(sessionId: "bifrost-test-pr-5", state: .working)
        let answers = Recorder<PRKey>()
        p.panels.links.openAnswer = { answers.record($0) }
        let model = try p.model()
        #expect(model.menuItems(waiting) == [.openOnGitHub, .handleNow, .handleCopilot])
        #expect(model.menuItems(asks) == [.openOnGitHub, .answerClaude])
        #expect(model.menuItems(failed) == [.openOnGitHub, .tryAgain, .dropUpdates])
        #expect(model.menuItems(queued) == [.openOnGitHub, .cancel])
        #expect(model.menuItems(fixing) == [.openOnGitHub, .openSession, .stopSession])
        #expect(model.menuItems(fork) == [.openOnGitHub])
        model.choose(.handleNow, for: waiting)
        model.choose(.handleCopilot, for: waiting)
        model.choose(.answerClaude, for: asks)
        model.choose(.tryAgain, for: failed)
        model.choose(.dropUpdates, for: failed)
        model.choose(.cancel, for: queued)
        model.choose(.stopSession, for: fixing)
        // These items do not apply to these rows.
        model.choose(.handleNow, for: fork)
        model.choose(.cancel, for: fixing)
        model.choose(.dropUpdates, for: queued)
        #expect(
            p.feed.commands == [
                .handleNow(waiting), .handleCopilot(waiting), .tryAgain(failed),
                .dropUpdates(failed, click: UserClick()), .cancelRequest(queued),
                .stopSession(fixing),
            ])
        #expect(answers.values == [asks])
    }

    // Approve shows as a button, and in the menu while CI doesn't run; while CI runs the button
    // waits with its tip. A Looks good row with Approve has no Review button. Claude's Comment or
    // Request changes draft gives its button and item, which open the Review panel. Approve needs
    // the click of the user, so a choice with no click does nothing.
    @Test func theApproveAndDraftItemsFollowTheRow() async throws {
        let p = Parts()
        let ready = try key("owner-a/repo-a#1")
        let waits = try key("owner-a/repo-a#2")
        let draft = try key("owner-a/repo-a#3")
        let plain = try key("owner-a/repo-a#4")
        var readyRow = try toReview(ready.text, .reviewed)
        readyRow.reviewable = true
        readyRow.approve = .ready
        var waitsRow = try toReview(waits.text, .draftReady)
        waitsRow.approve = .waitsForCI
        var draftRow = try toReview(draft.text, .draftReady)
        draftRow.draft = .requestChanges
        var plainRow = try toReview(plain.text, .reviewed)
        plainRow.reviewable = true
        p.feed.snapshot.toReview = [readyRow, waitsRow, draftRow, plainRow]
        let drafts = Recorder<PRKey>()
        p.panels.links.openDraft = { drafts.record($0) }
        let model = try p.model()
        #expect(ReviewsMenu.buttons(readyRow) == [.approve])
        #expect(model.menuItems(ready) == [.openOnGitHub, .approve, .review])
        #expect(model.isEnabled(.approve, readyRow))
        #expect(model.tip(.approve, readyRow) == "Approve this pull request on GitHub.")
        #expect(ReviewsMenu.buttons(waitsRow) == [.approve])
        #expect(model.menuItems(waits) == [.openOnGitHub])
        #expect(!model.isEnabled(.approve, waitsRow))
        #expect(model.tip(.approve, waitsRow) == "CI is still running. Approve when it has passed.")
        #expect(ReviewsMenu.buttons(draftRow) == [.requestChanges])
        #expect(model.menuItems(draft) == [.openOnGitHub, .requestChanges])
        #expect(
            model.tip(.requestChanges, draftRow)
                == "Check Claude's draft, change it if you like, and send it.")
        #expect(ReviewsMenu.buttons(plainRow) == [.review])
        model.choose(.requestChanges, for: draft)
        model.choose(.comment, for: draft)
        model.choose(.approve, for: ready)
        #expect(drafts.values == [draft])
        #expect(model.approval == nil && p.feed.commands.isEmpty)
    }

    // Cmd+click opens the https address of the PR on github.com, and only that address. It opens
    // no chat, also for a session that works. The PR number and Open on GitHub open the same
    // address.
    @Test func commandClickOpensOnlyAGitHubAddress() async throws {
        let p = Parts()
        let pr = try key("Owner-A/Repo.B#101")
        p.feed.snapshot.mine = [try mine(pr.text, .fixing(2))]
        p.feed.sessions[pr] = SessionRow.test(sessionId: "bifrost-test-pr-101", state: .working)
        let model = try p.model()
        model.click(pr, command: true)
        await model.opening?.value
        let address = "https://github.com/Owner-A/Repo.B/pull/101"
        #expect(p.opener.calls == [.browse(address)])
        #expect(p.feed.chats.isEmpty)
        model.choose(.openOnGitHub, for: pr)
        await model.opening?.value
        #expect(p.opener.calls == [.browse(address), .browse(address)])
        // A failed open shows its reason in the error line until the user closes it.
        p.opener.failure = .openFailed("The browser did not open.")
        model.click(pr, command: true)
        await model.opening?.value
        #expect(model.error == ActionRefusal.openFailed("The browser did not open.").message)
        model.closeError()
        #expect(model.error == nil)
        #expect(p.feed.commands.isEmpty)
    }

    // The row menu has only the items that apply to the row, in the order of the Electron menu,
    // and a choice that no longer applies to the row of now does nothing. The menu shows as the
    // Bifrost menu of the window.
    @Test func theMenuShowsOnlyTheItemsThatApply() async throws {
        let p = Parts()
        let new = try key("owner-a/repo-a#1")
        let paused = try key("owner-a/repo-a#2")
        let approved = try key("owner-a/repo-a#3")
        let waiting = try key("owner-a/repo-a#4")
        let own = try key("owner-a/repo-c#5")
        p.feed.snapshot.toReview = [
            try toReview(new.text, .newRequest),
            try toReview(paused.text, .paused(until: Feed.polled.addingTimeInterval(600))),
            try toReview(approved.text, .approvedByOthers),
            try toReview(waiting.text, .waitingForYou),
        ]
        p.feed.snapshot.mine = [try mine(own.text, .fork)]
        let model = try p.model()
        #expect(model.menuItems(new) == [.openOnGitHub, .pause])
        #expect(model.menuItems(paused) == [.openOnGitHub, .endPause])
        #expect(model.menuItems(approved) == [.openOnGitHub, .remove])
        #expect(model.menuItems(waiting) == [.openOnGitHub])
        #expect(model.menuItems(own) == [.openOnGitHub])
        #expect(model.menuItems(try key("owner-a/repo-a#9")) == nil)
        #expect(
            ReviewsMenuItem.allCases.map(\.label) == [
                "Open on GitHub", "Open session", "Approve", "Comment", "Request changes",
                "Review", "Try again", "Remove", "Cancel review", "Stop session", "Pause",
                "End pause now", "Answer Claude", "Handle now", "Handle Copilot comments",
                "Cancel", "Don't send the rest",
            ])
        model.choose(.pause, for: new)
        model.choose(.endPause, for: paused)
        model.choose(.remove, for: approved)
        // These items do not apply to these rows.
        model.choose(.remove, for: new)
        model.choose(.pause, for: waiting)
        model.choose(.endPause, for: own)
        #expect(p.feed.commands == [.pause(new), .endPause(paused), .remove(approved)])
        // The Bifrost menu shows the items of the row, and follows the row of now.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        model.showMenu(new, at: NSPoint(x: 20, y: 300), in: window)
        #expect(p.menu.isOpen)
        let labels = p.menu.panels.first?.list.state.rows.map(\.spec?.label)
        #expect(labels == ["Open on GitHub", "Pause"])
        p.feed.snapshot.toReview.removeAll { $0.id == new }
        #expect(await waitUntil { !p.menu.isOpen })
    }

    // In the window, a right-click and a Control-click on a row show its menu at the click, and
    // a Cmd+click opens its PR on GitHub. A click outside the rows does nothing.
    @Test func thePointerReachesTheRowUnderIt() async throws {
        let p = Parts()
        let pr = try key("owner-a/repo-a#1")
        p.feed.snapshot.toReview = [try toReview(pr.text, .newRequest)]
        let host = try p.host()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        #expect(
            await waitUntil {
                host.layoutSubtreeIfNeeded()
                return host.rootView.frames.rows[pr] != nil
            })
        let rect = try #require(host.rootView.frames.rows[pr])
        func event(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags, y: CGFloat)
            -> NSEvent?
        {
            var point = CGPoint(x: rect.midX, y: y)
            if !host.isFlipped { point.y = host.bounds.height - point.y }
            return NSEvent.mouseEvent(
                with: type, location: host.convert(point, to: nil), modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 1)
        }
        host.rightMouseDown(with: try #require(event(.rightMouseDown, [], y: rect.midY)))
        #expect(p.menu.isOpen)
        p.menu.close()
        host.mouseDown(with: try #require(event(.leftMouseDown, .control, y: rect.midY)))
        #expect(p.menu.isOpen)
        p.menu.close()
        host.mouseDown(with: try #require(event(.leftMouseDown, .command, y: rect.midY)))
        await host.rootView.model.opening?.value
        #expect(p.opener.calls == [.browse("https://github.com/owner-a/repo-a/pull/1")])
        // Under the last row there is no row.
        let below = rect.maxY + 40
        #expect(!host.showMenu(try #require(event(.rightMouseDown, [], y: below))))
        #expect(!p.menu.isOpen && p.opener.calls.count == 1)
    }

    // A refused store shows its message in place of the rows, with no tabs: another copy, a
    // newer version and an unknown version each have a friendly line.
    @Test func anotherCopyShowsItsLine() async throws {
        let p = Parts()
        p.feed.snapshot = ReviewsSnapshot(phase: .refused(.otherCopy))
        let model = try p.model()
        #expect(model.body == .notice("Reviews is running in another copy of Bifrost."))
        #expect(!model.showsTabs && model.lastChecked == nil && model.ghLine == nil)
        for failure in [ReviewsStoreError.laterVersion, .unknownVersion] {
            p.feed.snapshot = ReviewsSnapshot(phase: .refused(failure))
            #expect(model.body == .notice(failure.message))
        }
        #expect(
            ReviewsStoreError.laterVersion.message
                == "Reviews is off because a newer version of Bifrost saved its data. Update "
                + "this copy of Bifrost to use Reviews here.")
    }

    // Watch GitHub off shows the line and Open Settings. Before the first answer the panel says
    // that it checks GitHub. gh missing before the first good poll shows its line in place of
    // the rows, and a later failed poll keeps the rows with the gh line under them.
    @Test func eachStateOfReviewsHasItsBody() async throws {
        let p = Parts()
        p.feed.snapshot = ReviewsSnapshot(phase: .off)
        let model = try p.model()
        #expect(model.body == .off && !model.showsTabs)
        #expect(
            ReviewsPanelModel.offText
                == "Reviews is off. Turn on Watch GitHub in Settings to see your pull requests.")
        model.openSettings()
        #expect(p.feed.settingsOpens == 1)
        p.feed.snapshot = ReviewsSnapshot(phase: .starting)
        #expect(model.body == .starting && !model.showsTabs)
        // With no claude, Reviews does not start in this run, and the panel says why.
        p.feed.snapshot = ReviewsSnapshot(phase: .noClaude)
        #expect(model.body == .notice(ReviewsPanelModel.noClaudeText) && !model.showsTabs)
        #expect(
            ReviewsPanelModel.noClaudeText
                == "Reviews needs Claude Code, and Bifrost can't find it. Install it, then open "
                + "Bifrost again.")
        #expect(model.lastChecked == nil && model.ghLine == nil)
        p.feed.snapshot = ReviewsSnapshot(phase: .on)
        #expect(model.body == .starting && !model.showsTabs)
        p.feed.snapshot.problem = .notInstalled
        #expect(model.body == .notice(GitHubError.notInstalled.message) && model.showsTabs)
        #expect(model.ghLine == nil)
        p.feed.snapshot.problem = .timedOut
        #expect(model.body == .failed && model.ghLine == "GitHub didn't answer in time.")
        p.feed.snapshot.lastPoll = Feed.polled
        p.feed.snapshot.toReview = [try toReview("owner-a/repo-a#1", .waitingForYou)]
        #expect(model.body == .rows && model.ghLine == "GitHub didn't answer in time.")
        p.feed.snapshot.problem = .notLoggedIn
        #expect(model.body == .rows && model.ghLine == GitHubError.notLoggedIn.message)
        model.refresh()
        #expect(p.feed.commands == [.refresh])
    }

    // The hint of the automatic comment handling shows on My PRs until the consent, with Open
    // Settings.
    @Test func theHintShowsOnMyPRsUntilTheConsent() async throws {
        let p = Parts()
        p.feed.snapshot.needsConsent = true
        let model = try p.model()
        #expect(!model.showsHint)
        model.tab = .mine
        #expect(model.body == .empty && model.showsHint)
        #expect(
            ReviewsPanelModel.autoFixHint
                == "Want Claude to fix and answer new review comments for you? Turn on Handle "
                + "comments on my PRs automatically in Settings.")
        p.feed.snapshot.needsConsent = false
        #expect(!model.showsHint)
    }

    // The display clock asks for new time texts at the start and at each tick, with no poll, and
    // "Last checked" follows the time of the panel. A release stops the clock.
    @Test func theDisplayClockRefreshesTheTimeTexts() async throws {
        let p = Parts()
        let model = try p.model()
        #expect(p.feed.timeRefreshes == 1)
        #expect(model.lastChecked == "Last checked 12:00")
        await p.clock.waitForSleepers(1)
        p.wall.date = Feed.polled.addingTimeInterval(86_400)
        let tick = model.tickTask
        p.clock.advance(by: ReviewsPanelModel.tick)
        await tick?.value
        #expect(p.feed.timeRefreshes == 2)
        #expect(model.lastChecked == "Last checked Tue 12:00")
        #expect(p.feed.commands.isEmpty)
        p.panels.releaseBody(for: .reviews)
        await p.clock.waitUntilNoSleepers()
    }
}
