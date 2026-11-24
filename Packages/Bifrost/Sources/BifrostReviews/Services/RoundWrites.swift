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
// - A fix commit never holds an edit of a person. Before the commit, a listed path with a change
//   that no round made (RepoStore.unknownChanges) stops the fix, and after the commit a listed
//   path with another stamp than before it does the same: the commit goes back to changes
//   (RepoStore.uncommit), the writes that say "Fixed by" drop, the other writes go, the items
//   wait in held, and the row shows Needs you (RoundFailure.fixHadEdits). The outbox keeps the
//   stamps of its listed paths (Outbox.stamps): the round saves them from its record at the end
//   of the turn, an own request from the read of its file. They stay after a restart. A change
//   gives uncommit, and an own outbox stays for a later run. An outbox with no stamps takes the
//   files that are there with no record as the changes of the round.
// - A round outbox that drops before its push went also resets the worktree to the head of the
//   round (its commit is made), unless a person uses the session, so the next own request
//   commits on its head.
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
            if !sending.edited.isEmpty {
                (end, failure) = (.drop, .fixHadEdits)
            } else if let conflict = sending.conflict {
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
        // A round whose fix commit is made but not pushed (a conflict, a refusal, a drop of the
        // writes) leaves the fix as HEAD: the worktree goes back to the head of the round, so the
        // next own request commits on it. A pushed fix stays.
        let posts = sending.outbox.posts
        let committed = posts.contains { post in
            // The commit ID is there once the commit was made (a dropped fix keeps it).
            if case .commit(_, _, let made) = post.write { made != nil } else { false }
        }
        let pushed = posts.contains { post in
            if case .push = post.write { post.state == .done } else { false }
        }
        if !outbox.own && end == .drop && committed && !pushed && !sending.resetBlocked {
            await resetWorktree(pr, to: outbox.headSHA, own: false)
        }
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
            // The files of a fix that has an edit that no round made, for the row.
            let files = error.waitsForYou ? (await repos.unknownChanges(pr) ?? []) : []
            await endRound(pr, error, hold: [], files: files)
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
    private func endRound(
        _ pr: PRKey, _ failure: RoundFailure?, hold: [NodeID], files: [String] = []
    ) async {
        await store.update { state in
            guard var prState = state.prs[pr], prState.round?.kind == .request else { return }
            prState.round = nil
            if let failure, failure.waitsForYou {
                prState.waiting = WaitsForYou(
                    reason: failure.message(for: .request), files: files, kind: .other)
                prState.lastError = nil
            } else {
                prState.lastError = failure?.message(for: .request)
            }
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

    fileprivate func readHead(_ pr: PRKey) async throws(GitHubError) -> HeadRead {
        try await HeadQueries.read(pr, client: github)
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

    // The result of the fix commit: the commit, or the listed paths with an edit that no round
    // made. In the second case the worktree holds no commit of the run.
    fileprivate enum CommitResult {
        case made(CommitID)
        case edited([String])
    }

    fileprivate func commit(
        _ paths: [String], message: String, head: CommitID, pr: PRKey, own: Bool,
        stamps: [String: PathStamp]?
    ) async throws(FixCommitFailure) -> CommitResult {
        // The stamps of the listed files before git reads them. The outbox keeps them from the
        // result of the round or from the read of the own request file, also after a restart.
        var before = stamps
        if let kept = before {
            let changed = await repos.pathsChanged(pr, paths, since: kept)
            if !changed.isEmpty {
                // A commit of an earlier run (a quit in the commit) must not stay as HEAD.
                guard await repos.uncommit(pr, to: head) else { throw .uncommitFailed }
                return .edited(changed)
            }
        } else if !own {
            // An outbox with no stamps comes from a version that saved none. With no record of
            // the worktree (a restart), the files that are there now count as the round's.
            if !repos.hasRecord(pr) { await repos.markLeftovers(pr) }
            // The stamps come first: an edit before them shows in the check of the record, and
            // an edit after them shows in the compare after the commit. No edit fits between.
            before = await repos.pathStamps(pr, paths)
            guard let unknown = await repos.unknownChanges(pr) else {
                throw .git("Bifrost couldn't read the changes of its copy.")
            }
            let listed = Set(paths)
            let edited = unknown.filter { listed.contains($0) }
            if !edited.isEmpty { return .edited(edited) }
        }
        if before == nil { before = await repos.pathStamps(pr, paths) }
        let fix = try await FixCommit.make(
            paths: paths, message: message, head: head, pr: pr, git: repos.git)
        // A listed file that changed while git made the commit can be in it: the commit goes back
        // to changes, so no edit of a person goes to GitHub inside it.
        if let before {
            let changed = await repos.pathsChanged(pr, paths, since: before)
            if !changed.isEmpty {
                guard await repos.uncommit(pr, to: head) else { throw .uncommitFailed }
                return .edited(changed)
            }
        }
        // The files of the session that the commit does not hold go, unless a person uses the
        // session now or the worktree has a change that no round made. The changes of an own
        // request that the file does not list stay.
        if !own && !inUse(pr) { await repos.resetIfKnown(pr, to: fix) }
        return .made(fix)
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
    // The listed paths with an edit that no round made, so the writes of the fix dropped.
    private(set) var edited: [String] = []
    // True when a commit with an edit of a person stays as HEAD: no reset may remove it.
    private(set) var resetBlocked = false

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
        // An own outbox has only a commit and a push, which need the state, the author, the fork
        // flag and the push target of the PR. The small read of the head gives them, so no thread
        // page is read. A write of another kind reads the whole PR, as before.
        var full: FullPR?
        let target: PushTarget?
        if outbox.own {
            target = try await freshHead()
        } else {
            let read = try await freshRead()
            full = read
            target = PushTarget(read)
        }
        while let index = OutboxRules.next(outbox) {
            if Task.isCancelled { throw .halted }
            let post = outbox.posts[index]
            switch post.write {
            case .commit(let paths, let message, _):
                try await commit(index, paths: paths, message: message)
            case .push(_, let signed):
                try await push(index, signed: signed, target: target)
            case .reply(let item, _, _, _):
                try await reply(index, item: item, full: try await whole(&full))
            case .resolve(let item):
                try await resolve(index, item: item, full: try await whole(&full))
            case .comment(let item, _, _, _, _):
                try await comment(index, item: item, full: try await whole(&full))
            case .rerequest:
                try await rerequest(index, full: try await whole(&full))
            }
        }
    }

    // The whole read of the PR of this run: the one that the run made, or else a fresh one.
    private func whole(_ read: inout FullPR?) async throws(WriteStop) -> FullPR {
        if let read { return read }
        let full = try await freshRead()
        read = full
        return full
    }

    // MARK: - The writes

    private func commit(_ index: Int, paths: [String], message: String) async throws(WriteStop) {
        try await mark(index, .sending)
        let made: RoundWrites.CommitResult
        do throws(FixCommitFailure) {
            made = try await parts.commit(
                paths, message: message, head: outbox.headSHA, pr: pr, own: outbox.own,
                stamps: outbox.stamps)
        } catch {
            // A quit stopped git: the worktree keeps the fix, and the commit stays sending, so
            // the next run makes it or finds it.
            if Task.isCancelled { throw .halted }
            // A commit with an edit that git could not move back stays as it is: a reset would
            // remove the edit from the worktree.
            if error == .uncommitFailed {
                resetBlocked = true
            } else {
                await parts.resetWorktree(pr, to: outbox.headSHA, own: outbox.own)
            }
            switch error {
            case .uncommitFailed:
                parts.event("Reviews: Bifrost couldn't move the fix commit of \(pr.text) back.")
                throw .drop(.commitFailed)
            case .refused(let refusal): throw .drop(.commitRefused(refusal))
            case .git(let line):
                parts.event("Reviews: the fix commit of \(pr.text) failed. git said: \(line)")
                throw .drop(.commitFailed)
            }
        }
        let fix: CommitID
        switch made {
        case .made(let commit): fix = commit
        case .edited(let files):
            parts.event(
                "Reviews: a file of the fix on \(pr.text) has a change that Claude did not make, "
                    + "so Bifrost made no commit of it: "
                    + "\(files.prefix(3).joined(separator: ", ")).")
            // An own request stays for a run later. The stamps go, so the run commits the files
            // as they are then.
            if outbox.own {
                outbox.stamps = nil
                throw .keep(.ownFilesChanged)
            }
            // A round drops its fix: the writes that say "Fixed by" go, and the others go on.
            OutboxRules.dropFix(&outbox)
            edited = files
            return try await parts.save(outbox, for: pr)
        }
        outbox.posts[index].write = .commit(paths: paths, message: message, commit: fix)
        try await mark(index, .done)
    }

    private func push(_ index: Int, signed: Bool, target: PushTarget?) async throws(WriteStop) {
        var fix: CommitID?
        var paths: [String] = []
        for post in outbox.posts {
            if case .commit(let listed, _, let commit?) = post.write, post.state == .done {
                (fix, paths) = (commit, listed)
            }
        }
        guard let fix, let target else {
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

    // A fresh read of the head of the PR for an own outbox, with the checks that stop the writes
    // (as freshRead). It gives the push target, or nil when the head branch is not a branch name.
    private func freshHead() async throws(WriteStop) -> PushTarget? {
        let read: HeadRead
        do throws(GitHubError) {
            read = try await parts.readHead(pr)
        } catch {
            if Task.isCancelled { throw .halted }
            parts.event("Reviews: Bifrost couldn't read \(pr.text). \(error.message)")
            throw stop(error)
        }
        if Task.isCancelled { throw .halted }
        readFresh = true
        guard read.state == .open else { throw .drop(.prClosed) }
        guard read.author.lowercased() == viewer.lowercased() else { throw .drop(.notYours) }
        guard !read.isFork else { throw .drop(.fork) }
        return PushTarget(read)
    }

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
