// What a good poll leaves in the Reviews state (docs/behaviour/reviews.md, "What each poll
// records"), and the Remove of a row. The watcher calls recordPoll in the same store update for
// each poll, before it builds the rows, so the first poll never flashes an open request. After
// the rows, it calls recordNotices for the notifications of the new requests.
import BifrostFoundation
import Foundation

extension ReviewsState {
    // Record what a good poll says about the requests, and give the requests that arrived with
    // it (ReviewRows.isNewRequest). The rules:
    // - The first poll after the first turn-on records the turn-on: its time, each open request
    //   as a request that does not flash, the open items of the PRs of the user, and the start of
    //   new request work (fixFrom) when the state has none.
    // - A request that came after the turn-on is new. A request from before the turn-on that
    //   shows only later (GitHub gives the first 50) is not.
    // - A direct request that came again after its first sight is new again: it loses its pause,
    //   and Claude's mark and the error of the last round go. A team request keeps its pause.
    // - A request that is not in the answer goes, with its pause and its remove, so it is new
    //   when it comes back. While the answer is cut or has errors, it can still be open, so it
    //   keeps its entry, its pause and its remove.
    // - A removed PR shows again after a new request for the review.
    // - A pause that ended goes.
    // The first sight of a request is never before its request time, so a late clock of this
    // computer never makes a request new at each poll.
    @discardableResult
    package mutating func recordPoll(_ answer: PollAnswer, now: Date) -> Set<PRKey> {
        let first = turnedOnAt == nil
        var marks: [PRKey: RequestMark] = [:]
        var arrived: Set<PRKey> = []
        for pr in answer.toReview {
            let known = requests[pr.key]
            let seen = max(now, pr.requestedAt)
            if first {
                marks[pr.key] = RequestMark(firstSeen: known?.firstSeen ?? seen, baseline: true)
            } else if ReviewRows.isNewRequest(pr, self) {
                marks[pr.key] = RequestMark(firstSeen: seen, baseline: false)
                arrived.insert(pr.key)
                if known != nil {
                    prs[pr.key]?.recommendation = nil
                    prs[pr.key]?.lastError = nil
                }
            } else {
                marks[pr.key] = known ?? RequestMark(firstSeen: seen, baseline: true)
            }
        }
        if answer.toReviewCut || !answer.errors.isEmpty {
            marks.merge(requests) { mark, _ in mark }
        }
        pauses = pauses.filter { key, until in
            until > now && marks[key] != nil && !arrived.contains(key)
        }
        hidden = hidden.filter { key, at in
            guard let pr = answer.toReview.first(where: { $0.key == key }) else {
                return marks[key] != nil
            }
            return pr.requestedAt <= at
        }
        requests = marks
        if first {
            turnedOnAt = now
            baseline = Self.openItems(answer)
            // New request work starts at the first turn-on, as it does after a take-over.
            fixFrom = fixFrom ?? now
        }
        return arrived
    }

    // Record which new requests notify after a good poll, and give them in the order of the rows.
    // rows are the To review rows of the poll, and arrived holds the requests that came with it
    // (recordPoll). A new request notifies one time, at the first poll where its row flashes. The
    // rules:
    // - A request that came while its CI failed does not flash (ReviewRow.flash). Its notice
    //   waits (RequestMark.noticeWaitsForCI) until a poll where its row flashes.
    // - A waiting notice goes with no notification when the row is not a new request any more:
    //   the user reviewed the PR, acted on it in Bifrost or paused it, or others approved it.
    // - A PR with no row keeps its waiting notice, because a cut answer can miss an open request.
    //   A request that is not in the answer loses its mark in recordPoll, and the notice with it.
    // - A request that comes again gets a new mark, so it notifies again, as before.
    package mutating func recordNotices(_ rows: [ReviewRow], arrived: Set<PRKey>) -> [PRKey] {
        var due: [PRKey] = []
        for row in rows {
            guard let mark = requests[row.id], arrived.contains(row.id) || mark.noticeWaitsForCI
            else { continue }
            if row.flash { due.append(row.id) }
            requests[row.id]?.noticeWaitsForCI = row.state == .toReview(.newRequest) && !row.flash
        }
        return due
    }

    // Remove the To review row of the PR in Bifrost: it shows nowhere until a new request for the
    // review. Nothing changes on GitHub. A request time after the clock of this computer is the
    // time of the remove, so the same request never shows the PR again.
    package mutating func hide(_ pr: PullRequest, now: Date) {
        hidden[pr.key] = max(now, pr.requestedAt)
    }

    // The open items of the PRs of the user at the first turn-on: they wait for Handle now.
    private static func openItems(_ answer: PollAnswer) -> [NodeID] {
        var seen: Set<NodeID> = []
        var items: [NodeID] = []
        for pr in answer.mine {
            let open = OpenItems(
                threads: pr.threads, reviews: pr.reviews, comments: pr.comments,
                viewer: answer.viewer, state: PRState(), baseline: [], since: nil)
            for item in open.work + open.older where seen.insert(item.id).inserted {
                items.append(item.id)
            }
        }
        return items
    }
}
