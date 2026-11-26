// The fixture of the tests of the Review panel (the draft form and the findings form) and of the
// Approve button of the Reviews panel: the panels on the real flows over a Reviews store in a
// temporary folder and FakeGitHub, so no test reaches GitHub. A close of a panel releases its
// body, as the canvas of the window does.
import AppKit
import BifrostFoundation
import BifrostLayout
import BifrostLook
import BifrostReviews
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostWindows

// The polls of the watcher as ReviewWrites reads them (ReviewsWatcher.polls). A test starts a
// poll and gives its good answer.
@MainActor
final class FakeWatcherPolls {
    private(set) var count = PollCount()

    // A poll starts and gives a good answer.
    func answered() {
        count.started += 1
        count.answered = count.started
    }
}

@MainActor
final class DraftPanelFixture {
    static let viewer = "viewer-a"
    // The wall time of the tests.
    static let wall = Date(timeIntervalSince1970: 1_794_312_000)
    // The private note of the findings mark. No write may hold it.
    static let note = "PRIVATE-NOTE-4c1e\nLine two of the note."
    // The findings of the findings mark, in the order of the result: a minor finding off the
    // diff, a bug on the diff (a range), a nit on the diff, a minor finding with no place and a
    // nit with no place.
    static let findings: [Finding] = [
        Finding(
            kind: .minor, place: FindingPlace(path: "src/b.swift", line: 40, side: .right),
            body: "This log line names the wrong file.", onDiff: false),
        Finding(
            kind: .bug,
            place: FindingPlace(path: "src/a.swift", line: 12, side: .right, startLine: 10),
            body: "This loop never ends when the list is empty.", onDiff: true),
        Finding(
            kind: .nit, place: FindingPlace(path: "src/a.swift", line: 3, side: .right),
            body: "A clearer name would help here.", onDiff: true),
        Finding(kind: .minor, place: nil, body: "No test covers the retry.", onDiff: false),
        Finding(kind: .nit, place: nil, body: "Fix the spelling of the comment.", onDiff: false),
    ]

    let folder: TemporaryFolder
    let store: ReviewsStore
    let github = FakeGitHub()
    let client: GitHubClient
    let approver: ApproveFlow
    // The progress of the review writes on the rows, on the clock of the time that a row shows
    // the result of a write.
    let writes: ReviewWrites
    let clock = ManualClock()
    let watcherPolls = FakeWatcherPolls()
    let links = ReviewsPanelLinks()
    let panels: ReviewsPanels
    let opened = Recorder<PanelID>()
    let closed = Recorder<PanelID>()
    let pr: PRKey
    let head: CommitID
    let review: NodeID
    let claudeComment: NodeID
    let userComment: NodeID
    // The To review row of the PR in the snapshot.
    var row: ReviewRow

    // Claude's draft of the value on PR 7, with Claude's comment and one that the user added on
    // GitHub; the row offers the Review panel. For an Approve mark, the row offers Approve: on
    // Claude's old Approve draft it opens that draft, and with draft false (no draft) it approves
    // at once.
    init(_ value: Recommendation = .comment, draft: Bool = true) async throws {
        UITestApp.prepare()
        folder = try TemporaryFolder()
        let layout = ReviewsLayout(
            folder: URL(filePath: folder.realPath + "/reviews", directoryHint: .isDirectory))
        store = try await ReviewsStore.open(layout: layout, log: Recorder<StoreEvent>())
        client = GitHubClient(access: github)
        pr = try #require(PRKey(text: "Owner-A/Repo-A#7"))
        head = try #require(CommitID(String(repeating: "c", count: 40)))
        review = try #require(NodeID("PRR_claude"))
        claudeComment = try #require(NodeID("PRRC_claude"))
        userComment = try #require(NodeID("PRRC_user"))
        let (store, client) = (store, client)
        let watcherPolls = watcherPolls
        let writes = ReviewWrites(
            clock: clock, polls: { watcherPolls.count },
            ownReviews: { pr in
                try? await DraftQueries.ownReviews(pr, viewer: Self.viewer, on: client)
            }, now: { Self.wall })
        self.writes = writes
        let approver = ApproveFlow(
            store: store, github: client, writes: writes, viewer: { Self.viewer })
        self.approver = approver
        let event: DraftEvent? =
            switch value {
            case .comment: .comment
            case .requestChanges: .requestChanges
            case .approve: nil
            }
        row =
            draft
            ? ReviewRow(
                id: pr, state: .toReview(.draftReady), repo: "Repo-A", title: "Add the cache",
                status: RowLabel(text: "Draft ready", tone: .amber, tip: nil),
                approve: value == .approve ? .ready : nil, draft: event,
                approveCheck: value == .approve ? .draft : nil)
            : ReviewRow(
                id: pr, state: .toReview(.reviewed), repo: "Repo-A", title: "Add the cache",
                status: RowLabel(text: "Approval recommended", tone: .green, tip: nil),
                approve: .ready)
        panels = ReviewsPanels(
            links: links, opener: FakeOpener(), look: PanelLook(), menu: { nil },
            clock: ManualClock(), now: { Date() })
        let (opened, closed, panels) = (opened, closed, panels)
        links.snapshot = { [weak self] in
            ReviewsSnapshot(phase: .on, toReview: self.map { [$0.row] } ?? [])
        }
        links.approver = { approver }
        links.writes = { writes }
        links.makeDraftFlow = {
            DraftFlow(
                store: store, github: client, approver: approver, writes: writes,
                viewer: { Self.viewer })
        }
        links.makeFindingsFlow = {
            FindingsFlow(
                store: store, github: client, approver: approver, writes: writes,
                viewer: { Self.viewer })
        }
        links.openPanel = { opened.record($0) }
        links.closePanel = { [weak panels] in
            closed.record($0)
            panels?.releaseBody(for: $0)
        }
        await setMark(value, draft: draft)
        let pr = pr
        let review = review
        await store.update { state in
            state.drafts = [
                DraftRecord(
                    reviewID: review, pr: pr, path: "src/a.swift", line: 11, body: "Use <.",
                    at: Date(timeIntervalSince1970: 1_794_312_000))
            ]
        }
        answerFresh()
        github.answers[DraftQueries.draftName] = .success(
            DraftAnswers.draft(
                "PRR_claude", body: "Summary.", commit: head,
                comments: [
                    DraftRead.Comment(
                        id: claudeComment, path: "src/a.swift", line: 11, body: "Use <."),
                    DraftRead.Comment(id: userComment, path: "src/b.swift", line: 3, body: "Mine."),
                ]))
        github.answers[ReviewQueries.reviewName] = .success(DraftAnswers.reviewNow(commit: head))
        // Your own reviews on the PR: none, unless a test gives some.
        github.answers[DraftQueries.ownReviewsName] = .success(DraftAnswers.ownReviews([]))
    }

    // The next poll of the watcher gives a good answer, and then, as in the shell, any unsure
    // Comment is checked against your own reviews. This waits for that check.
    func pollAnswered() async {
        watcherPolls.answered()
        writes.checkComments()
        await writes.checkTask(pr)?.value
    }

    // Claude's mark of the value on the head, with its draft review unless draft is false, and
    // with the findings and the note.
    func setMark(
        _ value: Recommendation, draft: Bool = true, findings: [Finding] = [], note: String = ""
    ) async {
        let mark = RecommendationMark(
            value: value, why: "Two small bugs.", headSHA: head, reviewID: draft ? review : nil,
            at: Date(timeIntervalSince1970: 1_794_312_000), note: note, findings: findings)
        await setMark(mark, on: pr)
    }

    // Claude's Approve mark with no draft on the head, with the note and the findings of the
    // findings form, on the PR of the fixture or on another PR. A later time gives a new mark.
    func setFindingsMark(
        at: Date = Date(timeIntervalSince1970: 1_794_312_000), on pr: PRKey? = nil
    ) async {
        let mark = RecommendationMark(
            value: .approve, why: "the retry change is correct", headSHA: head, reviewID: nil,
            at: at, note: Self.note, findings: Self.findings)
        await setMark(mark, on: pr ?? self.pr)
    }

    private func setMark(_ mark: RecommendationMark, on pr: PRKey) async {
        await store.update { state in
            var prState = state.prs[pr] ?? PRState()
            prState.recommendation = mark
            state.prs[pr] = prState
        }
    }

    // The fresh read: Claude's draft is the pending review on the head, unless pending is false.
    func answerFresh(head: CommitID? = nil, pending: Bool = true) {
        github.answers[DraftQueries.freshName] = .success(
            DraftAnswers.fresh(
                pr, head: head ?? self.head,
                pending: pending ? DraftAnswers.Pending(id: "PRR_claude", commit: self.head) : nil))
    }

    func answer(_ write: GitHubWrite, state: String? = nil) {
        github.answers[FakeGitHub.key(write)] = .success(DraftAnswers.written(write, state: state))
    }

    var draft: ReviewDraftPanels { panels.draft }

    // Open the Review panel and wait for the read of the draft.
    func open() async {
        draft.open(pr)
        await draft.task?.value
    }

    var written: [GitHubWrite] {
        github.calls.compactMap { if case .write(let write) = $0 { write } else { nil } }
    }

    // Move the clock to the end of the time that the row shows the result of a write, and wait
    // for the end of the progress.
    func endHold() async {
        let hold = writes.holdTask(pr)
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: ReviewWrites.hold)
        await hold?.value
    }

    func end() async {
        panels.releaseBody(for: .reviewDraft)
        await store.close().value
        folder.remove()
    }
}
