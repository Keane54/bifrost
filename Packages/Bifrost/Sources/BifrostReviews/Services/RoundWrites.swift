// The writes of a request round (docs/behaviour/reviews.md, "The push and the writes"): the fix
// commit, the push, then the GitHub writes, in the order of the outbox (OutboxRules.plan). Each
// write goes exactly once:
// - The outbox is saved before each write, with the write as sending, and after it, with the
//   write as done. A save that fails stops the writes before the next write.
// - A write that a quit or an unknown answer cut off stays sending. The next run looks on GitHub
//   for it first: a reply or a PR comment of the viewer with the same text, made at most
//   OutboxRules.sentWindow before the start of the outbox. The fix commit of an earlier run is
//   found in the worktree (FixCommit), the push checks the branch first (Pusher, SignedPusher), a
//   resolve skips a resolved thread, and a review request skips a reviewer that GitHub lists as
//   requested.
// - A write that GitHub may have made (GitHubError.writeMayHaveHappened) is never sent again by
//   itself: the writes stop, the outbox stays, and only Try again goes on with it.
// - A stop that would come again in each run drops the outbox, so it never blocks the PR: a
//   refusal of GitHub (OutboxRules.lasts), a refused push target or a branch that the server
//   refuses. A failure of the network or of the login of gh keeps the outbox for Try again. The
//   user can drop a kept outbox (ReviewRounds.dropOutbox).
// - Each write goes to a thread or a comment of a fresh read of the PR. A merged or closed PR, a
//   PR that is not the user's, a fork and a cut read stop the writes. A draft review of the user
//   stops them too, because the replies would go into it. Before each later write, a read of
//   the state of the PR checks that it is still open.
// - A cancel (a quit) stops the writes at once and keeps the state, also in the fix commit and in
//   the push: a resume goes on from the write that was sending.
// - The writes wait postGap between two writes, for the limits of GitHub.
// - The push of a fix that did not go (a conflict, a rewrite, a branch that kept moving) drops
//   the writes that say "Fixed by", and the other writes go. Its items then wait in held.
// - An item whose writes all went is handled. Each posted reply is kept with its ID and its text.
//   Each reviewer whose latest review requests changes and whose threads are all resolved gets a
//   new review request, one time for each head commit, never a bot.
// - A person can use the request session of the PR after its turn. While its row works or shows
//   a box (inUse), the writes do not reset the worktree, so the work of the person stays. The
//   next round resets the worktree after its wait, when the changes are changes of a round
//   (RepoStore.unknownChanges).
// - The outbox of an own request of the user (Outbox.own, OwnRequests) has only the commit and
//   the push. It writes no reply, so a cut read and a draft review of the user do not stop it. It
//   never resets the worktree: after a good commit the changes that the file does not list stay,
//   and a commit that is refused or that does not reach GitHub becomes changes again
//   (RepoStore.uncommit).
// - A reset after the fix commit of a round runs only when the worktree has no change that no
//   round made (RepoStore.resetIfKnown), so a change of a person after the turn stays.
import BifrostFoundation
import Foundation
import OSLog

@MainActor
package final class RoundWrites {
    // The wait between two writes, against the secondary rate limit of GitHub.
    package static let postGap = Duration.seconds(1)

    private static let logger = Logger(bifrost: "reviews")

    private let store: ReviewsStore
    private let github: GitHubClient
    private let repos: RepoStore
    private let clock: any Clock<Duration>
    private let now: () -> Date
    private let viewer: () -> String?
    // A line for the user in the Event log: the reason of git or of GitHub for a write that
    // stopped. The row shows a fixed text.
    private let eventLine: (String) -> Void
    // True while a person can use the request session of the PR (PRSessions.requestInUse).
    private let inUse: (PRKey) -> Bool

    package init(
        store: ReviewsStore, github: GitHubClient, repos: RepoStore, clock: any Clock<Duration>,
        now: @escaping () -> Date, viewer: @escaping () -> String?,
        eventLine: @escaping (String) -> Void, inUse: @escaping (PRKey) -> Bool = { _ in false }
    ) {
        self.store = store
        self.github = github
        self.repos = repos
        self.clock = clock
        self.now = now
        self.viewer = viewer
        self.eventLine = eventLine
        self.inUse = inUse
    }

    // Send the writes of the outbox of the PR that are not done or dropped, in order. The caller
    // saved the outbox first. At the end the state holds the outbox rules of the end: after the
    // last write, each done item is handled and the outbox goes; after a stop, the outbox goes
    // (its done items are handled, the others held) when the stop would come again in each run,
    // else it stays for Try again. The round of the state does not change. A cancel (a quit)
    // stops at once, also in the fix commit or the push, and keeps the state as it is.
    package func run(_ outbox: Outbox, for pr: PRKey) async throws(RoundFailure) {
        guard let viewer = viewer() else { throw .readFailed(.notLoggedIn) }
        let sending = OutboxSend(pr: pr, outbox: outbox, viewer: viewer, parts: self)
        let end: OutboxEnd
        let failure: RoundFailure?
        do throws(WriteStop) {
            try await sending.send()
            if let conflict = sending.conflict {
                (end, failure) = (.drop, .pushFailed(conflict))
            } else {
                (end, failure) = (.done, nil)
            }
        } catch {
            switch error {
            case .halted: throw .stopped
            case .drop(let reason): (end, failure) = (.drop, reason)
            case .keep(let reason): (end, failure) = (.keep, reason)
            }
        }
        await finish(pr, sending.outbox, end, asked: sending.asked)
        // The change of the user did not reach GitHub, and its outbox goes: it stays in the
        // worktree as changes.
        if outbox.own && end == .drop { await repos.uncommit(pr, to: outbox.headSHA) }
        if let failure {
            Self.logger.notice(
                """
                The writes of \(pr.text, privacy: .private) stopped. \
                \(failure.message(for: .request), privacy: .private)
                """)
            throw failure
        }
    }

    // At start: a request round that was posting when Bifrost quit sends the writes of its outbox
    // that are not done, then ends. A posting round with no outbox (a damaged outbox goes at the
    // read of the file) fails, and its items wait in held. A cancel keeps the round for the next
    // start.
    package func resume(_ pr: PRKey) async {
        guard let round = store.state.prs[pr]?.round, round.kind == .request,
            round.phase == .posting
        else { return }
        guard let outbox = store.state.prs[pr]?.outbox else {
            await endRound(pr, .endFailed, hold: Self.ordered(round.items))
            return
        }
        do throws(RoundFailure) {
            try await run(outbox, for: pr)
            await endRound(pr, nil, hold: [])
        } catch {
            if Task.isCancelled { return }
            await endRound(pr, error, hold: [])
        }
    }

    // MARK: - The end

    private enum OutboxEnd {
        // Each write went: the done items are handled, and the outbox goes.
        case done
        // The outbox goes: its done items are handled, and the others are held.
        case drop
        // The outbox stays for Try again: its done items are handled.
        case keep
    }

    // Save the end of the outbox, the reviewers that the writes asked, and each posted reply.
    private func finish(
        _ pr: PRKey, _ outbox: Outbox, _ end: OutboxEnd, asked: [String: CommitID]
    ) async {
        let time = now()
        let posted = OutboxRules.posted(outbox, pr: pr, at: time)
        await store.update { state in
            guard var prState = state.prs[pr], prState.outbox != nil else { return }
            switch end {
            case .done:
                OutboxRules.settle(&prState, outbox, now: time)
                prState.outbox = nil
            case .drop:
                prState.outbox = outbox
                prState.dropOutbox(now: time)
            case .keep:
                OutboxRules.settle(&prState, outbox, now: time)
                prState.outbox = outbox
            }
            prState.askedReviewers.merge(asked) { _, new in new }
            state.prs[pr] = prState
            let known = Set(state.posted.map(\.id))
            state.posted = Array(
                (state.posted + posted.filter { !known.contains($0.id) })
                    .suffix(ReviewsState.maxPosted))
        }
    }

    // The end of a resumed round: the round clears, with the reason of a failure.
    private func endRound(_ pr: PRKey, _ failure: RoundFailure?, hold: [NodeID]) async {
        await store.update { state in
            guard var prState = state.prs[pr], prState.round?.kind == .request else { return }
            prState.round = nil
            prState.lastError = failure?.message(for: .request)
            prState.handleOlder = false
            prState.handleCopilot = false
            prState.hold(hold)
            state.prs[pr] = prState
        }
    }

    // The items of a round in the order of their times, then of their IDs.
    private static func ordered(_ items: [NodeID: Date]) -> [NodeID] {
        items.sorted { ($0.value, $0.key.text) < ($1.value, $1.key.text) }.map(\.key)
    }

    // MARK: - The parts of a run

    fileprivate var storeState: ReviewsState { store.state }

    // Save the outbox of the PR. A failed save, or a PR whose outbox went (a drop), stops the
    // writes.
    fileprivate func save(_ outbox: Outbox, for pr: PRKey) async throws(WriteStop) {
        let saved = await store.update { state in
            guard state.prs[pr]?.outbox != nil else { return }
            state.prs[pr]?.outbox = outbox
        }
        guard saved, store.state.prs[pr]?.outbox == outbox else { throw .keep(.endFailed) }
    }

    fileprivate func read(_ pr: PRKey) async throws(GitHubError) -> FullPR {
        try await RequestQueries.full(pr, client: github)
    }

    fileprivate func lifecycle(_ pr: PRKey) async throws(GitHubError) -> PRLifecycle {
        try await RequestQueries.state(pr, client: github)
    }

    fileprivate func write(_ write: GitHubWrite) async throws(GitHubError) -> Data {
        try await github.write(write)
    }

    fileprivate func pause() async throws(WriteStop) {
        try? await clock.sleep(for: Self.postGap)
        if Task.isCancelled { throw .halted }
    }

    fileprivate func commit(
        _ paths: [String], message: String, head: CommitID, pr: PRKey, own: Bool
    ) async throws(FixCommitFailure) -> CommitID {
        let fix = try await FixCommit.make(
            paths: paths, message: message, head: head, pr: pr, git: repos.git)
        // The files of the session that the commit does not hold go, unless a person uses the
        // session now or the worktree has a change that no round made. The changes of an own
        // request that the file does not list stay.
        if !own && !inUse(pr) { await repos.resetIfKnown(pr, to: fix) }
        return fix
    }

    // Reset the worktree of the PR to the head of the round, also when a refused fix commit is
    // its HEAD, unless a person uses the session now. The worktree of an own request keeps its
    // files, and only a commit that git made goes back to changes.
    fileprivate func resetWorktree(_ pr: PRKey, to head: CommitID, own: Bool) async {
        if own {
            await repos.uncommit(pr, to: head)
            return
        }
        guard !inUse(pr) else { return }
        await repos.resetIfKnown(pr, to: head)
    }

    fileprivate func push(
        _ fix: CommitID, head: CommitID, paths: [String], signed: Bool, pr: PRKey,
        target: PushTarget
    ) async throws(PushRefusal) -> PushResult {
        let address = repos.address(of: pr.repo)
        if signed {
            return try await SignedPusher(git: repos.git, address: address, github: github)
                .push(fix, head: head, paths: paths, pr: pr, to: target)
        }
        return try await Pusher(git: repos.git, address: address)
            .push(fix, head: head, pr: pr, to: target)
    }

    // A line for the Event log, with each secret hidden.
    fileprivate func event(_ text: String) {
        eventLine(TokenMask.mask(text, token: nil))
    }
}

// How the writes of an outbox stop.
private enum WriteStop: Error {
    // A cancel: the state stays as it is.
    case halted
    // The outbox goes: the stop would come again in each run.
    case drop(RoundFailure)
    // The outbox stays for Try again.
    case keep(RoundFailure)
}

// One run of the writes of an outbox: the outbox as it changes, and what the run read.
@MainActor
private final class OutboxSend {
    let pr: PRKey
    private(set) var outbox: Outbox
    // The reviewers that the run asked, with the head commit of each request.
    private(set) var asked: [String: CommitID] = [:]
    // The push that did not go, so the writes of the fix dropped.
    private(set) var conflict: PushRefusal?

    private let viewer: String
    private let parts: RoundWrites
    // The writes that were sending at the start: a quit or an unknown answer cut them off.
    private let cutOff: Set<String>
    // True after the first write of this run, for the wait between two writes.
    private var wrote = false
    // True from a fresh read of the PR to the next write: that write needs no other check of the
    // state of the PR.
    private var readFresh = false

    init(pr: PRKey, outbox: Outbox, viewer: String, parts: RoundWrites) {
        self.pr = pr
        self.outbox = outbox
        self.viewer = viewer
        self.parts = parts
        cutOff = Set(outbox.posts.filter { $0.state == .sending }.map(\.id))
    }

    func send() async throws(WriteStop) {
        if Task.isCancelled { throw .halted }
        let full = try await freshRead()
        while let index = OutboxRules.next(outbox) {
            if Task.isCancelled { throw .halted }
            let post = outbox.posts[index]
            switch post.write {
            case .commit(let paths, let message, _):
                try await commit(index, paths: paths, message: message)
            case .push(_, let signed):
                try await push(index, signed: signed, full: full)
            case .reply(let item, _, _, _):
                try await reply(index, item: item, full: full)
            case .resolve(let item):
                try await resolve(index, item: item, full: full)
            case .comment(let item, _, _, _, _):
                try await comment(index, item: item, full: full)
            case .rerequest:
                try await rerequest(index, full: full)
            }
        }
    }

    // MARK: - The writes

    private func commit(_ index: Int, paths: [String], message: String) async throws(WriteStop) {
        try await mark(index, .sending)
        let fix: CommitID
        do throws(FixCommitFailure) {
            fix = try await parts.commit(
                paths, message: message, head: outbox.headSHA, pr: pr, own: outbox.own)
        } catch {
            // A quit stopped git: the worktree keeps the fix, and the commit stays sending, so
            // the next run makes it or finds it.
            if Task.isCancelled { throw .halted }
            await parts.resetWorktree(pr, to: outbox.headSHA, own: outbox.own)
            switch error {
            case .refused(let refusal): throw .drop(.commitRefused(refusal))
            case .git(let line):
                parts.event("Reviews: the fix commit of \(pr.text) failed. git said: \(line)")
                throw .drop(.commitFailed)
            }
        }
        outbox.posts[index].write = .commit(paths: paths, message: message, commit: fix)
        try await mark(index, .done)
    }

    private func push(_ index: Int, signed: Bool, full: FullPR) async throws(WriteStop) {
        var fix: CommitID?
        var paths: [String] = []
        for post in outbox.posts {
            if case .commit(let listed, _, let commit?) = post.write, post.state == .done {
                (fix, paths) = (commit, listed)
            }
        }
        guard let fix, let target = PushTarget(full) else {
            throw .drop(.pushFailed(.target))
        }
        try await beforeWrite(index)
        let result: PushResult
        do throws(PushRefusal) {
            result = try await parts.push(
                fix, head: outbox.headSHA, paths: paths, signed: signed, pr: pr, target: target)
        } catch {
            // A quit stopped git or gh: the push stays sending, and the next run checks the
            // branch first.
            if Task.isCancelled { throw .halted }
            if let detail = error.detail {
                let who = signed ? "GitHub" : "git"
                parts.event("Reviews: the push of \(pr.text) stopped. \(who) said: \(detail)")
            }
            if error.keepsOtherWrites {
                OutboxRules.dropFix(&outbox)
                conflict = error
                return try await parts.save(outbox, for: pr)
            }
            // A push that can still go stays sending: the next run checks the branch first.
            switch error {
            case .git, .unknown: throw .keep(.pushFailed(error))
            default: throw .drop(.pushFailed(error))
            }
        }
        outbox.posts[index].write = .push(commit: result.commit, signed: signed)
        try await mark(index, .done)
    }

    private func reply(_ index: Int, item: NodeID, full: FullPR) async throws(WriteStop) {
        // The thread is gone, so there is nothing to reply to.
        guard let thread = full.threads.first(where: { $0.thread.id == item })?.thread else {
            return try await mark(index, .done)
        }
        guard let body = OutboxRules.body(of: outbox.posts[index], in: outbox) else {
            return try await mark(index, .dropped)
        }
        if cutOff.contains(outbox.posts[index].id),
            let found = OutboxRules.sentComment(
                body, in: thread.comments, viewer: viewer, since: outbox.startedAt)
        {
            setComment(index, found.id)
            return try await mark(index, .done)
        }
        try await beforeWrite(index)
        let node = try await send(.replyToThread(thread: item, body: body), index)
        // The reply went into a draft review of the user. It stays sending, so the next run looks
        // for it on GitHub after the user sends or deletes the draft.
        if node["state"]?.string == "PENDING" { throw .keep(.replyPending) }
        guard let id = node["id"]?.string.flatMap(NodeID.init) else {
            throw .keep(stopped(.badAnswer))
        }
        setComment(index, id)
        try await mark(index, .done)
    }

    private func resolve(_ index: Int, item: NodeID, full: FullPR) async throws(WriteStop) {
        guard let thread = full.threads.first(where: { $0.thread.id == item })?.thread,
            !thread.isResolved
        else { return try await mark(index, .done) }
        // A resolve goes only after the reply of its item.
        let reply = outbox.posts.first {
            if case .reply(item, _, _, _) = $0.write { true } else { false }
        }
        guard reply?.state == .done else { return try await mark(index, .dropped) }
        // A trusted person wrote in the thread after the round read it: the thread stays open,
        // and the next round handles the new comment.
        if OutboxRules.answeredAfter(thread, seen: outbox.seen[item], viewer: viewer) {
            return try await mark(index, .dropped)
        }
        try await beforeWrite(index)
        let node = try await send(.resolveThread(item), index)
        guard node["isResolved"] == .bool(true) else { throw .keep(stopped(.badAnswer)) }
        try await mark(index, .done)
    }

    private func comment(_ index: Int, item: NodeID, full: FullPR) async throws(WriteStop) {
        guard full.request(of: item) != nil else { return try await mark(index, .done) }
        guard let body = OutboxRules.body(of: outbox.posts[index], in: outbox) else {
            return try await mark(index, .dropped)
        }
        if cutOff.contains(outbox.posts[index].id),
            let found = OutboxRules.sentComment(
                body, in: full.comments, viewer: viewer, since: outbox.startedAt)
        {
            setComment(index, found.id)
            return try await mark(index, .done)
        }
        guard let node = full.id else { throw .keep(stopped(.badAnswer)) }
        try await beforeWrite(index)
        let answer = try await send(.addPRComment(pr: node, body: body), index)
        guard let id = answer["node"]?.object?["id"]?.string.flatMap(NodeID.init) else {
            throw .keep(stopped(.badAnswer))
        }
        setComment(index, id)
        try await mark(index, .done)
    }

    // Ask each reviewer of OutboxRules.reviewersToAsk for a new review, on a second fresh read
    // that shows the resolves of this run.
    private func rerequest(_ index: Int, full first: FullPR) async throws(WriteStop) {
        let full = try await freshRead()
        // A cut read can hide an open thread or a decision, so Bifrost asks nobody.
        if full.truncated { return try await mark(index, .dropped) }
        let state = parts.storeState
        var known = (state.prs[pr]?.askedReviewers ?? [:]).merging(asked) { _, new in new }
        let requested = Set(full.requested.map { $0.lowercased() })
        // A reviewer of a cut-off request that GitHub lists as requested was asked before.
        if cutOff.contains(outbox.posts[index].id),
            case .rerequest(let logins?) = outbox.posts[index].write
        {
            for login in logins where requested.contains(login.lowercased()) {
                asked[login] = full.headSHA
                known[login] = full.headSHA
            }
        }
        let targets = OutboxRules.reviewersToAsk(
            full, viewer: viewer, open: openLogins(full, first), asked: known)
        guard !targets.isEmpty, let node = full.id else { return try await mark(index, .done) }
        outbox.posts[index].write = .rerequest(logins: targets.map(\.login))
        try await beforeWrite(index)
        _ = try await send(.requestReviews(pr: node, users: targets.compactMap(\.userID)), index)
        for target in targets { asked[target.login] = full.headSHA }
        try await mark(index, .done)
    }

    // MARK: - The steps

    // A fresh read of the PR, and the checks that stop the writes.
    private func freshRead() async throws(WriteStop) -> FullPR {
        let full: FullPR
        do throws(GitHubError) {
            full = try await parts.read(pr)
        } catch {
            if Task.isCancelled { throw .halted }
            parts.event("Reviews: Bifrost couldn't read \(pr.text). \(error.message)")
            throw stop(error)
        }
        if Task.isCancelled { throw .halted }
        readFresh = true
        guard full.state == .open else { throw .drop(.prClosed) }
        guard full.author.lowercased() == viewer.lowercased() else { throw .drop(.notYours) }
        guard !full.isCrossRepository else { throw .drop(.fork) }
        // An own request writes no reply.
        if outbox.own { return full }
        // A cut read can hide a sent reply or show a thread as gone.
        guard !full.truncated else { throw .drop(.tooManyComments) }
        guard !full.viewerPending else { throw .keep(.ownPending) }
        return full
    }

    // Wait between two writes, check that the PR is still open (a fresh read just checked it),
    // then save the write as sending. GitHub can have the write from this point.
    private func beforeWrite(_ index: Int) async throws(WriteStop) {
        if wrote { try await parts.pause() }
        if Task.isCancelled { throw .halted }
        if !readFresh { try await checkOpen() }
        readFresh = false
        wrote = true
        try await mark(index, .sending)
    }

    // A merged or closed PR stops the writes, and its outbox goes.
    private func checkOpen() async throws(WriteStop) {
        let state: PRLifecycle
        do throws(GitHubError) {
            state = try await parts.lifecycle(pr)
        } catch {
            if Task.isCancelled { throw .halted }
            parts.event("Reviews: Bifrost couldn't read \(pr.text). \(error.message)")
            throw stop(error)
        }
        if Task.isCancelled { throw .halted }
        guard state == .open else { throw .drop(.prClosed) }
    }

    // Send one GitHub write, and give the object of its answer. A refusal (the write did not
    // happen) puts the write back to todo; a write that GitHub may have made stays sending.
    // Either way the writes stop: a refusal that would come again in each run drops the outbox,
    // and its item waits in held; else the outbox stays.
    private func send(_ write: GitHubWrite, _ index: Int) async throws(WriteStop)
        -> [String: JSONValue]
    {
        let data: Data
        do throws(GitHubError) {
            data = try await parts.write(write)
        } catch {
            // A quit stopped gh: the write stays sending, and the next run looks for it first.
            if Task.isCancelled { throw .halted }
            parts.event(
                "Reviews: GitHub stopped the updates of \(pr.text). It said: \(error.message)")
            if !error.writeMayHaveHappened { try? await mark(index, .todo) }
            throw stop(error)
        }
        guard let node = write.answerNode(data) else { throw .keep(stopped(.badAnswer)) }
        return node
    }

    private func stopped(_ error: GitHubError) -> RoundFailure {
        let counts = OutboxRules.counts(outbox)
        return .writesStopped(done: counts.done, total: counts.total, error)
    }

    // The stop of a failed read or write of GitHub: a refusal that would come again in each run
    // drops the outbox, and each other failure keeps it for Try again.
    private func stop(_ error: GitHubError) -> WriteStop {
        guard OutboxRules.lasts(error) else { return .keep(stopped(error)) }
        let counts = OutboxRules.counts(outbox)
        return .drop(.writesRefused(done: counts.done, total: counts.total, error))
    }

    private func setComment(_ index: Int, _ id: NodeID) {
        switch outbox.posts[index].write {
        case .reply(let item, let text, let by, _):
            outbox.posts[index].write = .reply(item: item, text: text, by: by, comment: id)
        case .comment(let item, let quote, let text, let by, _):
            outbox.posts[index].write = .comment(
                item: item, quote: quote, text: text, by: by, comment: id)
        default: break
        }
    }

    // Set the state of the write and save the outbox.
    private func mark(_ index: Int, _ state: PostState) async throws(WriteStop) {
        outbox.posts[index].state = state
        try await parts.save(outbox, for: pr)
    }

    // The lower-case logins of the reviewers with an open item: work, an older item, a question
    // or a later Copilot thread of the PR, or an item of the outbox with a write that is not
    // done (for example a fix that a conflict dropped).
    private func openLogins(_ full: FullPR, _ first: FullPR) -> Set<String> {
        let state = parts.storeState
        let items = OpenItems(
            threads: full.prThreads, reviews: full.reviews, comments: full.comments,
            viewer: viewer, state: state.prs[pr] ?? PRState(), baseline: Set(state.baseline),
            since: state.fixFrom ?? state.turnedOnAt)
        let ids =
            (items.work + items.older + items.questions + items.laterCopilot).map(\.id)
            + OutboxRules.openItems(outbox)
        return Set(
            ids.compactMap {
                (full.request(of: $0) ?? first.request(of: $0))?.comment.author.login.lowercased()
            })
    }
}
