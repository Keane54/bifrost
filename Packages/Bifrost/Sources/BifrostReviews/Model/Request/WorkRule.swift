// What is work for a request round, and when a poll starts one (docs/behaviour/reviews.md,
// "Request rounds"). The rule works on the open items of the PR (OpenItems), on the stored
// Handled, held and Question forms of the state:
// - Work comes only from trusted human authors (a thread, a top-level comment, or the body of a
//   review that requests changes or comments) and from the threads of the first Copilot review.
//   The Copilot summary, the other bots and the outsiders are never work.
// - A handled item is work again only after a newer trusted comment. An item from before fixFrom
//   (or from the first turn-on) waits for Handle now. A held item of a failed round waits for Try
//   again, Handle now or a newer trusted comment. A newer trusted comment from before fixFrom
//   never makes work by itself: the item waits for Handle now. So an item that the take-over held
//   or that the Electron app handled never starts an automatic round from an old comment. A later
//   Copilot thread waits for Handle Copilot comments. An answered question is work.
// - A click counts only through the trigger of its round. A saved Handle now or Handle Copilot
//   comments mark in the state never makes work by itself, so a stale mark (one that the Electron
//   app kept, or one that a stopped round left) never starts or widens an automatic round.
// - With the automatic rounds off (or no consent yet), a round takes only the items of its click
//   or of an answer: all the work after Handle now or Try again, the later Copilot threads after
//   Handle Copilot comments, and the answered questions. So a round that an answer starts takes no
//   other new comment.
// - A round takes at most maxItems items, the oldest first by the time of their first comment. A
//   PR from a fork has no work: Bifrost can't push there.
import Foundation

// One item of a request round: its ID, its kind and the GitHub time of its first comment.
package struct WorkItem: Sendable, Equatable {
    package var id: NodeID
    package var kind: WorkItemKind
    package var since: Date

    package init(id: NodeID, kind: WorkItemKind, since: Date) {
        self.id = id
        self.kind = kind
        self.since = since
    }
}

package enum WorkRule {
    package static let maxItems = 30

    // The items of a round of the PR, oldest first, at most maxItems. autoFix: the automatic
    // rounds are on (ReviewsState.allowsAutoFix). baseline: the items that were open at the
    // first turn-on.
    package static func items(
        _ pr: FullPR, _ state: PRState, fixFrom: Date?, viewer: String, trigger: RoundTrigger,
        autoFix: Bool, baseline: Set<NodeID> = []
    ) -> [WorkItem] {
        Array(
            wanted(
                pr, state, fixFrom: fixFrom, viewer: viewer, trigger: trigger, autoFix: autoFix,
                baseline: baseline
            ).prefix(maxItems))
    }

    // Each item that the round wants, oldest first, with no limit. A round on a cut read holds
    // them all.
    package static func wanted(
        _ pr: FullPR, _ state: PRState, fixFrom: Date?, viewer: String, trigger: RoundTrigger,
        autoFix: Bool, baseline: Set<NodeID> = []
    ) -> [WorkItem] {
        guard !pr.isCrossRepository else { return [] }
        var clicked = state
        clicked.handleOlder = trigger == .handleNow || trigger == .tryAgain
        clicked.handleCopilot = trigger == .copilot
        let open = OpenItems(
            threads: pr.prThreads, reviews: pr.reviews, comments: pr.comments, viewer: viewer,
            state: clicked, baseline: baseline, since: fixFrom)
        var chosen = open.work
        if !autoFix && !clicked.handleOlder {
            var plain = clicked
            plain.handleCopilot = false
            let later = Set(
                OpenItems(
                    threads: pr.prThreads, reviews: pr.reviews, comments: pr.comments,
                    viewer: viewer, state: plain, baseline: baseline, since: fixFrom
                ).laterCopilot.map(\.id))
            chosen = chosen.filter {
                state.questions[$0.id]?.answer != nil
                    || (clicked.handleCopilot && later.contains($0.id))
            }
        }
        let items = chosen.map {
            WorkItem(id: $0.id, kind: $0.kind, since: pr.times(of: $0.id).first ?? .distantPast)
        }
        return items.sorted { ($0.since, $0.id.text) < ($1.since, $1.id.text) }
    }

    // True when a poll queues an automatic round for the PR: the PR is not from a fork, and the
    // poll shows work, or a cut thread list with an update after the last full read (the full
    // read can find work that the poll does not show). The caller checks the gate of the
    // automatic rounds. The state counts with no click: the poll looks only at a PR with no entry
    // in the queue, so a click mark there is stale.
    package static func startsRound(
        _ pr: PullRequest, _ state: PRState, fixFrom: Date?, viewer: String,
        baseline: Set<NodeID> = []
    ) -> Bool {
        guard !pr.isCrossRepository else { return false }
        var plain = state
        plain.handleOlder = false
        plain.handleCopilot = false
        let open = OpenItems(
            threads: pr.threads, reviews: pr.reviews, comments: pr.comments, viewer: viewer,
            state: plain, baseline: baseline, since: fixFrom)
        if !open.work.isEmpty { return true }
        return pr.truncatedThreads && pr.updatedAt > (state.checkedAt ?? .distantPast)
    }
}
