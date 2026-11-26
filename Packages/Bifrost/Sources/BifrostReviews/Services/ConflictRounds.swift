// The conflict part of the PR rounds (docs/behaviour/reviews.md, "Merge conflicts"): the poll,
// Resolve now, and the run and the end of each conflict job, as an extension of ReviewRounds,
// which owns the queue, the gates (the halts, the one start of an untrusted clone, Remove all
// clones) and the other parts. ConflictRound holds the steps of one round.
// - A good poll queues a conflict round for each PR of the user that ConflictRule accepts: the
//   setting "Resolve merge conflicts automatically" and its consent, and one attempt for each
//   pair of a head and a base (the conflict mark). Resolve now starts one also with the gate
//   closed, and also on a pair that was tried.
// - A conflict round keeps each failure in the conflict mark of its pair, never in lastError, so
//   the row shows "Has conflicts" with the reason and no automatic round tries the pair again. A
//   round that ends with no text (the PR closed, GitHub sees no conflict now, the head moved, the
//   gate closed) removes its working mark: the pair was not tried. A round that the work of a
//   person stops (the safety net, or an own request file of its turn) removes its working mark
//   too, and the row shows Needs you.
// - A pushed merge keeps its commit in the mark, goes on the CI chain of the head, and polls at
//   once.
// - A record of a PR that Bifrost could not read in full can lack the mark of a pair that a
//   round tried, or the CI mark of its head. Each such PR counts its pair of the next poll as
//   tried and spends the CI budget of its head, so the damage never starts a second automatic try
//   (settleMarksInDoubt).
import BifrostFoundation
import Foundation
import OSLog

extension ReviewRounds {
    private static let conflictLogger = Logger(bifrost: "reviews")

    // MARK: - The poll

    // Queue a conflict round for each PR of the user of the poll that ConflictRule accepts. busy
    // is true while a job, an own request, a drop or a discard of the PR runs, or a person uses
    // its request session: a round started then could only wait or fail as busy.
    func queueConflicts(_ poll: PollAnswer) {
        settleMarksInDoubt(poll)
        let state = store.state
        let config = config
        guard state.allowsConflictFix(config.resolveConflicts) else { return }
        let keys = poll.mine.filter { pr in
            !waitsAfterQuietEnd(pr)
                && ConflictRule.startsRound(
                pr, state.prs[pr.key] ?? PRState(), state: state, config: config,
                busy: conflictBusy(pr.key))
        }.map(\.key)
        guard !keys.isEmpty else { return }
        let time = now()
        var added: [PRKey] = []
        store.change { state in
            for pr in keys where !state.queue.contains(where: { $0.pr == pr }) {
                state.queue.append(QueueEntry(pr: pr, kind: .conflict, at: time))
                added.append(pr)
            }
        }
        changed()
        for pr in added { queue.add(QueuedJob(pr: pr, kind: .conflict, since: time)) }
    }

    // True while a round ended with no text on this head and base less than WorkRule.readRetry
    // ago (for example, the poll said conflicting and the fresh read did not). A poll that sees
    // the same pair waits, so a flap of GitHub costs no clone check and no read at each poll. A
    // new head or base, and a click, never wait. The wait is in memory only.
    private func waitsAfterQuietEnd(_ pr: PullRequest) -> Bool {
        guard let quiet = quietPairs[pr.key], quiet.pair == Self.pair(pr) else { return false }
        return timeline.now() - quiet.at < WorkRule.readRetry
    }

    // The CI rounds use the same rule (queueCIWork).
    func conflictBusy(_ pr: PRKey) -> Bool {
        queue.runningJob(of: pr) != nil || ownRuns[pr] != nil || drops[pr] != nil
            || discards[pr] != nil || sessions.requestInUse(pr)
    }

    // The records that the read of the file could not read in full: each PR of the poll with such
    // a record, or each PR of the poll when the file lost records, counts the pair of the poll as
    // tried (a failed mark with no reason, so the row offers Resolve now), and spends the CI
    // budget of the head of the poll (a CI mark of that head with no fix and no re-run left), so
    // its next failure gets the limits question. The CI part needs only the head. The doubt of a
    // record ends at the first poll that lists the PR with its head and its base, so both parts
    // ran; the doubt of lost records ends at the first complete poll.
    private func settleMarksInDoubt(_ poll: PollAnswer) {
        let state = store.state
        guard state.marksInDoubt || state.prs.values.contains(where: \.markInDoubt) else { return }
        let time = now()
        let complete = !poll.mineCut && poll.errors.isEmpty
        var tried: [PRKey] = []
        var spent: [PRKey] = []
        store.change { state in
            for pr in poll.mine {
                guard state.marksInDoubt || state.prs[pr.key]?.markInDoubt == true,
                    let head = CommitID(pr.headSHA)
                else { continue }
                var prState = state.prs[pr.key] ?? PRState()
                if prState.ci?.chain.contains(head) != true {
                    prState.ci = CIMark(
                        chain: [head], fixes: CIRule.maxFixes, retries: CIRule.maxRetries)
                    spent.append(pr.key)
                }
                if let base = CommitID(pr.baseSHA) {
                    prState.markInDoubt = false
                    if prState.conflict?.matches(pr) != true {
                        prState.conflict = ConflictMark(
                            head: head, base: base, at: time, outcome: .failed(""))
                        tried.append(pr.key)
                    }
                }
                state.prs[pr.key] = prState
            }
            if complete { state.marksInDoubt = false }
        }
        for pr in tried {
            Self.conflictLogger.notice(
                """
                The record of \(pr.text, privacy: .private) did not read in full, so Bifrost \
                counts its head and base as tried.
                """)
        }
        for pr in spent {
            Self.conflictLogger.notice(
                """
                The record of \(pr.text, privacy: .private) did not read in full, so Bifrost \
                counts the CI budget of its head as spent.
                """)
        }
        changed()
    }

    // MARK: - The click

    // Resolve now: queue one conflict round of a PR of the user of the last poll whose row is
    // resolvable (MyPRRules.isResolvable: conflicts, not a fork, no round, no entry of its side
    // and no outbox), while nothing else of the PR runs. The click goes in the state
    // (PRState.resolveNow), so a restart keeps it, and the round spends it at its end. The
    // setting does not gate it, and it also acts on a pair that was tried.
    package func resolveNow(_ pr: PRKey) async {
        guard !removing, let polled = answer()?.mine.first(where: { $0.key == pr }) else {
            return
        }
        let state = store.state
        guard MyPRRules.isResolvable(polled, state.prs[pr] ?? PRState(), queue: state.queue),
            queue.runningJob(of: pr) == nil, ownRuns[pr] == nil, drops[pr] == nil,
            discards[pr] == nil
        else { return }
        let time = now()
        // A click on a clone that needs trust gives one start, which claude judges.
        setup.allowOneStart(pr.repo)
        await store.update { state in
            var prState = state.prs[pr] ?? PRState()
            prState.resolveNow = true
            state.prs[pr] = prState
            if !state.queue.contains(where: { $0.pr == pr && $0.kind == .conflict }) {
                state.queue.append(QueueEntry(pr: pr, kind: .conflict, at: time))
            }
        }
        changed()
        queue.add(QueuedJob(pr: pr, kind: .conflict, since: time))
    }

    // MARK: - The jobs

    // The round of a conflict job. saved: the round of the state, of a job that goes on after a
    // restart: a running round waits for its session, and a posting round pushes its merge again.
    // yields: the times that the job let an own request go first.
    func runConflict(_ job: QueuedJob, saved: ActiveRound?, yields: Int = 0) async {
        let pr = job.pr
        let round = makeConflictRound(job)
        let polled = answer()?.mine.first { $0.key == pr }.flatMap(Self.pair)
        if let saved {
            await settleConflict(job, round, polled: polled) {
                () async throws(ConflictRound.Stop) in
                saved.phase == .posting
                    ? try await round.resumePosting(saved) : try await round.resume(saved)
            }
            return
        }
        let time = now()
        await store.update { state in
            state.queue.removeAll { $0.pr == pr && $0.kind == .conflict }
            var prState = state.prs[pr] ?? PRState()
            prState.round = ActiveRound(
                phase: .preparing, startedAt: time, at: job.since, kind: .conflict)
            state.prs[pr] = prState
        }
        changed()
        await settleConflict(job, round, polled: polled, yields: yields) {
            () async throws(ConflictRound.Stop) in
            try await round.start()
        }
    }

    // One conflict round of the job on the services of the rounds. The pair of the poll names
    // the attempt until the round reads the head.
    private func makeConflictRound(_ job: QueuedJob) -> ConflictRound {
        let pr = job.pr
        let polled = answer()?.mine.first { $0.key == pr }
        return ConflictRound(
            pr: pr,
            parts: ConflictRound.Parts(
                store: store, github: github, repos: repos, setup: setup, sessions: sessions,
                own: own, skills: skills, userHome: userHome, now: now),
            pair: polled.flatMap(Self.pair), title: polled?.title ?? "",
            clicked: store.state.prs[pr]?.resolveNow == true, model: config.requestModel,
            allowed: { [weak self] in
                guard let self else { return false }
                return self.store.state.allowsConflictFix(self.config.resolveConflicts)
            },
            hooks: roundHooks(pr))
    }

    // Run the steps of the conflict round, then end it by how they stopped: a pushed merge polls
    // at once; a failure goes to the mark, and a push that may have reached GitHub polls at once;
    // an own request of the user goes first, then the round starts again.
    private func settleConflict(
        _ job: QueuedJob, _ round: ConflictRound, polled: ConflictRound.Pair?, yields: Int = 0,
        _ steps: () async throws(ConflictRound.Stop) -> CommitID
    ) async {
        let pr = job.pr
        do throws(ConflictRound.Stop) {
            let merge = try await steps()
            quietPairs[pr] = nil
            await pushedConflict(pr, merge: merge, pair: round.pair)
            ended()
        } catch {
            // A cancel stops the round, whatever the step that saw it gave.
            let stop: ConflictRound.Stop = Task.isCancelled ? .halted : error
            switch stop {
            case .failed(let failure):
                await failConflict(pr, failure, pair: round.pair)
                if case .push = failure { ended() }
            case .quiet:
                // The pair of the poll waits, so the next polls do not start the same round.
                // A closed setting keeps no wait, so turning it on works at the next poll.
                if let polled, store.state.allowsConflictFix(config.resolveConflicts) {
                    quietPairs[pr] = (polled, timeline.now())
                }
                await endQuietly(pr)
            case .busy: await endQuietly(pr)
            case .forYou(let waiting): await keepForPerson(pr, waiting, pair: round.pair)
            case .waitForTrust(let refused): await waitForTrust(job, refused: refused)
            case .ownRequestFirst:
                await yieldToOwnRequest(
                    job, yields: yields, chosen: [],
                    busy: { await failConflict(pr, .session(.sessionBusy), pair: round.pair) },
                    restart: { await runConflict(job, saved: nil, yields: $0) })
            case .halted: await Task { await self.halted(job, chosen: []) }.value
            }
        }
    }

    // MARK: - The ends

    // A merge on GitHub: the round and its click end, the mark keeps the merge, and a CI chain
    // whose last commit is the head gets the merge, so the merge counts in the budget of the head
    // that the user pushed.
    private func pushedConflict(_ pr: PRKey, merge: CommitID, pair: ConflictRound.Pair?) async {
        let time = now()
        await store.update { state in
            guard var prState = state.prs[pr] else { return }
            if prState.round?.kind == .conflict { prState.round = nil }
            prState.resolveNow = false
            // The prepare of the round proved the copy clean, so an old reason no longer holds.
            prState.waiting = nil
            if let pair {
                prState.conflict = ConflictMark(
                    head: pair.head, base: pair.base, at: time, outcome: .pushed(merge))
                if var ci = prState.ci, ci.chain.last == pair.head {
                    ci.chain.append(merge)
                    prState.ci = ci
                }
            }
            state.prs[pr] = prState
        }
        changed()
    }

    // A failed conflict round: the round and its click end, and the mark of the pair gets the
    // text (ConflictFailure.message), so the row shows it and no automatic round tries the pair
    // again. With no pair, the working mark of the state gets it. An empty text (a quiet end)
    // removes the working mark instead. The detail of git or of the push goes to the Event log.
    func failConflict(_ pr: PRKey, _ failure: ConflictFailure, pair: ConflictRound.Pair?) async {
        if let detail = failure.detail {
            eventLine(
                TokenMask.mask(
                    "Reviews: Bifrost didn't push a merge of the base branch into \(pr.text). "
                        + "git said: \(detail)", token: nil))
        }
        let (message, time) = (failure.message, now())
        guard !message.isEmpty else {
            await endQuietly(pr)
            return
        }
        quietPairs[pr] = nil
        if pair == nil, Self.working(store.state.prs[pr]?.conflict) == nil {
            // No mark can show the text, so the Event log keeps a trace of it.
            eventLine(
                TokenMask.mask(
                    "Reviews: Bifrost couldn't resolve the conflicts of \(pr.text). \(message)",
                    token: nil))
        }
        await store.update { state in
            guard var prState = state.prs[pr] else { return }
            if prState.round?.kind == .conflict { prState.round = nil }
            prState.resolveNow = false
            if let pair = pair ?? Self.working(prState.conflict) {
                prState.conflict = ConflictMark(
                    head: pair.head, base: pair.base, at: time, outcome: .failed(message))
            }
            state.prs[pr] = prState
        }
        changed()
    }

    // A round that ends with no text: the round and its click end, and the working mark goes, so
    // the pair counts as not tried.
    private func endQuietly(_ pr: PRKey) async {
        await store.update { state in
            guard var prState = state.prs[pr] else { return }
            if prState.round?.kind == .conflict { prState.round = nil }
            prState.resolveNow = false
            prState.conflict = Self.withoutWorking(prState.conflict)
            state.prs[pr] = prState
        }
        changed()
    }

    // The work of a person stopped the round: the round and its click end, the working mark
    // goes (the pair was not tried), and the row shows Needs you with the reason and the files of
    // the safety net. A reason that the row has already (an own request that did not go) says
    // more; the files of the round are newer.
    private func keepForPerson(_ pr: PRKey, _ waiting: WaitsForYou?, pair: ConflictRound.Pair?)
        async
    {
        await store.update { state in
            guard var prState = state.prs[pr] else { return }
            if prState.round?.kind == .conflict { prState.round = nil }
            prState.resolveNow = false
            prState.conflict = Self.withoutWorking(prState.conflict)
            if let waiting { prState.keepWaiting(waiting, adoptsKind: true) }
            state.prs[pr] = prState
        }
        changed()
    }

    // The pair of the attempt of the PR for a stop: the working mark of the state, else the pair
    // of the last poll.
    func conflictPair(_ pr: PRKey) -> ConflictRound.Pair? {
        Self.working(store.state.prs[pr]?.conflict)
            ?? answer()?.mine.first { $0.key == pr }.flatMap(Self.pair)
    }

    // MARK: - The marks

    // The pair of a PR of the poll, when it gives the full head commit and base commit.
    nonisolated static func pair(_ pr: PullRequest) -> ConflictRound.Pair? {
        guard let head = CommitID(pr.headSHA), let base = CommitID(pr.baseSHA) else { return nil }
        return ConflictRound.Pair(head: head, base: base)
    }

    // The pair of a mark of a round that runs (working), or nil.
    nonisolated static func working(_ mark: ConflictMark?) -> ConflictRound.Pair? {
        guard let mark, mark.outcome == .working else { return nil }
        return ConflictRound.Pair(head: mark.head, base: mark.base)
    }

    // The mark with no working outcome: a working mark goes, and another mark stays.
    nonisolated static func withoutWorking(_ mark: ConflictMark?) -> ConflictMark? {
        working(mark) == nil ? mark : nil
    }

    // A working mark of a round that the user stopped gets the text of the stop.
    nonisolated static func stopped(_ mark: ConflictMark?) -> ConflictMark? {
        guard var mark, mark.outcome == .working else { return mark }
        mark.outcome = .failed(ConflictFailure.session(.stopped).message)
        return mark
    }
}
