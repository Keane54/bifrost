// The rules of the outbox of a request round (docs/behaviour/reviews.md, "The push and the
// writes") over its stored form (Outbox): the plan of the writes of a checked outcome, the next
// unsent write, the text of each reply, the drop of the writes of a fix that did not go, the
// search for a reply that GitHub has already, the reviewers to ask again and the end of the
// outbox in the PR state. RoundWrites runs the writes in the order of the plan.
import BifrostFoundation
import Foundation

package enum OutboxRules {
    // A reply or a PR comment that Bifrost sent has a GitHub time after the start of the outbox.
    // The search also takes a time up to this long before the start, because the clock of GitHub
    // and the clock of this Mac can differ.
    package static let sentWindow = Duration.seconds(5 * 60)
    // The IDs of the writes that are not about one item: the names of their kinds, as in the
    // outboxes of the Electron app.
    package static let commitID = PlannedWrite.Kind.commit.rawValue
    package static let pushID = PlannedWrite.Kind.push.rawValue
    package static let rerequestID = PlannedWrite.Kind.rerequest.rawValue

    // The writes of a checked outcome, in their order: the fix commit and its push, then for each
    // item of the round (in its order) its reply and its resolve (a thread) or its PR comment with
    // the quote of the request (a top-level comment or the body of a review), then the new review
    // requests. A Fixed or No fix item gets writes; a No action or Needs you item gets none. An
    // item that the fresh read does not have gets none. signed: the fix goes through a commit
    // that GitHub signs; the outbox keeps the choice.
    package static func plan(
        _ outcome: RequestOutcome, order: [NodeID], full: FullPR, seen: [NodeID: Date],
        head: CommitID, mergeBase: CommitID, startedAt: Date, signed: Bool
    ) -> Outbox {
        var posts: [OutboxPost] = []
        if let commit = outcome.commit {
            posts.append(
                OutboxPost(
                    id: commitID, state: .todo,
                    write: .commit(paths: commit.paths, message: commit.message, commit: nil)))
            posts.append(
                OutboxPost(id: pushID, state: .todo, write: .push(commit: nil, signed: signed)))
        }
        let results = Dictionary(outcome.items.map { ($0.id, $0.outcome) }) { first, _ in first }
        var done: Set<NodeID> = []
        for item in order + outcome.items.map(\.id) where done.insert(item).inserted {
            let text: String?
            let by: CommitID?
            switch results[item] {
            case .fixed(let commit)?: (text, by) = (nil, commit)
            case .noFix(let reply)?: (text, by) = (reply, nil)
            default: continue
            }
            if full.threads.contains(where: { $0.thread.id == item }) {
                posts.append(
                    OutboxPost(
                        id: "reply:\(item.text)", state: .todo,
                        write: .reply(item: item, text: text, by: by, comment: nil)))
                posts.append(
                    OutboxPost(
                        id: "resolve:\(item.text)", state: .todo, write: .resolve(item: item)))
            } else if let request = full.request(of: item) {
                posts.append(
                    OutboxPost(
                        id: "comment:\(item.text)", state: .todo,
                        write: .comment(
                            item: item, quote: ReplyText.quoted(request.comment.body), text: text,
                            by: by, comment: nil)))
            }
        }
        posts.append(OutboxPost(id: rerequestID, state: .todo, write: .rerequest(logins: nil)))
        return Outbox(
            headSHA: head, mergeBase: mergeBase, startedAt: startedAt, seen: seen, posts: posts)
    }

    // The index of the next write to run: the first that is not done or dropped.
    package static func next(_ outbox: Outbox) -> Int? {
        outbox.posts.firstIndex { $0.state == .todo || $0.state == .sending }
    }

    // True when the fix commit of the outbox is not made yet: the worktree holds Claude's fix, so
    // a stop must not reset it.
    package static func commitOpen(_ outbox: Outbox) -> Bool {
        outbox.posts.contains {
            if case .commit = $0.write { $0.state == .todo || $0.state == .sending } else { false }
        }
    }

    // True when a GitHub error of a read or a write would come again in each run, so the outbox
    // goes: GitHub refused the call (an HTTP 4xx status, or GraphQL errors with no result), and
    // not for one of its limits (a rate limit, or the limit of new comments: "was submitted too
    // quickly"). A failure of the network, a time limit, an answer that Bifrost can't read and a
    // missing gh or gh login keep the outbox for Try again.
    package static func lasts(_ error: GitHubError) -> Bool {
        guard case .refused(let line) = error else { return false }
        let text = line.lowercased()
        let limits = ["rate limit", "abuse detection", "submitted too quickly"]
        return !limits.contains { text.contains($0) }
    }

    // True when the post is a "Fixed by" text of the fix commit of the round: it needs the push.
    package static func needsPush(_ post: OutboxPost) -> Bool {
        switch post.write {
        case .reply(_, nil, nil, _), .comment(_, _, nil, nil, _): true
        default: false
        }
    }

    // True when the push of the fix is done.
    package static func pushDone(_ outbox: Outbox) -> Bool {
        outbox.posts.contains {
            if case .push = $0.write { $0.state == .done } else { false }
        }
    }

    // The commit that a "Fixed by" text names: the commit that GitHub made for a signed fix, else
    // the fix commit of the round. After a merge, the text names the fix commit, which the merge
    // holds.
    package static func fixCommit(_ outbox: Outbox) -> CommitID? {
        for post in outbox.posts {
            if case .push(let commit?, true) = post.write, post.state == .done { return commit }
        }
        for post in outbox.posts {
            if case .commit(_, _, let commit?) = post.write, post.state == .done { return commit }
        }
        return nil
    }

    // The text that a reply or a PR comment sends, with each mention broken, or nil when its
    // "Fixed by" text has no commit on GitHub yet. The quote of a PR comment comes first. The
    // quote was broken when the plan made it.
    package static func body(of post: OutboxPost, in outbox: Outbox) -> String? {
        let text: String?
        let by: CommitID?
        let quote: String
        switch post.write {
        case .reply(_, let reply, let commit, _): (text, by, quote) = (reply, commit, "")
        case .comment(_, let request, let reply, let commit, _):
            (text, by, quote) = (reply, commit, request)
        default: return nil
        }
        let sent: String
        if let text {
            sent = text
        } else if let commit = by ?? (pushDone(outbox) ? fixCommit(outbox) : nil) {
            sent = ReplyText.fixedBy(commit)
        } else {
            return nil
        }
        return ReplyText.comment(quote: quote, reply: ReplyText.breakMentions(sent))
    }

    // The fix did not go (a conflict, a rewrite or a branch that kept moving): the commit, the
    // push, each write that needs the fix and is not done, and the resolve of each dropped reply
    // drop. The other writes stay.
    package static func dropFix(_ outbox: inout Outbox) {
        for index in outbox.posts.indices {
            let post = outbox.posts[index]
            switch post.write {
            case .commit, .push: outbox.posts[index].state = .dropped
            default:
                if needsPush(post) && post.state != .done { outbox.posts[index].state = .dropped }
            }
        }
        let droppedReplies = Set(
            outbox.posts.compactMap { post -> NodeID? in
                if case .reply(let item, _, _, _) = post.write, post.state == .dropped {
                    return item
                }
                return nil
            })
        for index in outbox.posts.indices {
            if case .resolve(let item) = outbox.posts[index].write, droppedReplies.contains(item) {
                outbox.posts[index].state = .dropped
            }
        }
    }

    // The comment of the viewer that holds the sent text, made at most sentWindow before the start
    // of the outbox, or nil. A reply that a quit or an unknown answer cut off is found this way,
    // so it never goes two times.
    package static func sentComment(
        _ body: String, in comments: [PRComment], viewer: String, since start: Date
    ) -> PRComment? {
        let from = start.addingTimeInterval(-Double(sentWindow.components.seconds))
        return comments.first {
            $0.author.login.lowercased() == viewer.lowercased() && $0.createdAt >= from
                && ReplyText.isSame($0.body, as: body)
        }
    }

    // True when a trusted person (not the viewer, not a bot) wrote in the thread after the round
    // read it. The thread then stays open, and the next round handles the new comment. With no
    // read time, each trusted comment is newer.
    package static func answeredAfter(_ thread: PRThread, seen: Date?, viewer: String) -> Bool {
        thread.comments.contains {
            !$0.author.isBot && Authors.isTrusted($0.author, viewer: viewer)
                && $0.createdAt > (seen ?? .distantPast)
        }
    }

    // The reviewers to ask for a new review: each person whose latest review requests changes,
    // with a user ID, who is not the viewer and not a bot (so never Copilot), whom GitHub does
    // not list as requested, who has no open item (open holds lower-case logins), whose threads
    // are all resolved, and whom Bifrost did not ask on this head commit.
    package static func reviewersToAsk(
        _ full: FullPR, viewer: String, open: Set<String>, asked: [String: CommitID]
    ) -> [FullPR.Decision] {
        let requested = Set(full.requested.map { $0.lowercased() })
        return full.decisions.filter { decision in
            let login = decision.login.lowercased()
            let threads = full.threads.filter {
                $0.thread.comments.first?.author.login.lowercased() == login
            }
            return decision.state == .changesRequested && !decision.isBot
                && decision.userID != nil && login != viewer.lowercased()
                && !requested.contains(login) && !open.contains(login)
                && threads.allSatisfy(\.thread.isResolved)
                && asked[decision.login] != full.headSHA
        }
    }

    // The writes to GitHub that are done, and all of them, with no commit and no dropped write.
    package static func counts(_ outbox: Outbox) -> (done: Int, total: Int) {
        let updates = outbox.posts.filter {
            if case .commit = $0.write { return false }
            return $0.state != .dropped
        }
        return (updates.count { $0.state == .done }, updates.count)
    }

    // The comments that Bifrost posted or found on GitHub: each done reply and PR comment with its
    // ID and its text.
    package static func posted(_ outbox: Outbox, pr: PRKey, at time: Date) -> [PostedComment] {
        outbox.posts.compactMap { post in
            guard post.state == .done, let body = body(of: post, in: outbox) else { return nil }
            switch post.write {
            case .reply(_, _, _, let id?), .comment(_, _, _, _, let id?):
                return PostedComment(id: id, pr: pr, body: body, at: time)
            default: return nil
            }
        }
    }

    // Each item whose writes are all done is handled, with the time that the round read as its
    // reply time, and leaves the held items. Each item with a dropped write and no write that
    // waits is held (for example a resolve that a newer trusted comment dropped), as at a drop of
    // the outbox (PRState.dropOutbox), so each end of the writes treats it the same way. An item
    // with a write that waits stays in the outbox. The result is the handled items.
    @discardableResult
    package static func settle(_ state: inout PRState, _ outbox: Outbox, now: Date) -> Set<NodeID>
    {
        var states: [NodeID: [PostState]] = [:]
        var order: [NodeID] = []
        for post in outbox.posts {
            guard let item = post.item else { continue }
            if states[item] == nil { order.append(item) }
            states[item, default: []].append(post.state)
        }
        let done = Set(states.filter { $0.value.allSatisfy { $0 == .done } }.keys)
        for item in done {
            state.handled[item] = Handled(at: now, lastReplyAt: outbox.seen[item] ?? now)
        }
        state.held.removeAll { done.contains($0) }
        state.hold(
            order.filter { item in
                let all = states[item] ?? []
                return all.contains(.dropped) && all.allSatisfy { $0 == .done || $0 == .dropped }
            })
        return done
    }

    // The items of the outbox with a write that is not done, in the order of the writes.
    package static func openItems(_ outbox: Outbox) -> [NodeID] {
        var seen: Set<NodeID> = []
        return outbox.posts.compactMap { post in
            guard let item = post.item, post.state != .done, seen.insert(item).inserted else {
                return nil
            }
            return item
        }
    }
}
