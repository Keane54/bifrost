// The request part of the PR rounds (docs/behaviour/reviews.md, "Request rounds" and "The push and
// the writes"): the clicks on a PR of the user, the automatic rounds of a poll, and the run and
// the end of each request job, as an extension of ReviewRounds, which owns the queue, the gates
// (the halts, the one start of an untrusted clone, Remove all clones) and the review part.
// - A good poll queues a round for each PR of the user with new work only while the automatic
//   rounds are on and the user confirmed them in this app (ReviewsState.allowsAutoFix). Handle
//   now, Handle Copilot comments, Try again and an answer start one also with the gate closed.
// - A round (RequestRound) sends the writes of an earlier outbox first, then works, then sends
//   its own writes (RoundWrites). A round that was posting when Bifrost quit sends the rest of
//   its writes at the next start.
// - A failed round holds its items, so nothing tries it again by itself, and sends no
//   notification; a round that adds questions notifies once. A round whose full read failed
//   chose no items, so the poll waits WorkRule.readRetry before it queues the PR again. A round
//   whose writes stopped keeps the items where the outbox rules put them. Don't send the rest
//   drops an outbox that stays for Try again, and sends nothing (dropOutbox).
// - An own request of the user (OwnRequests) goes when a turn of the request session of the PR
//   ends and after each poll, while no round of the PR runs and nobody uses the session
//   (checkOwnRequest). A round that finds an own request file before it changes the worktree
//   lets the own request go first, then starts again (settleRequest).
import BifrostFoundation
import BifrostSessions
import Foundation

extension ReviewRounds {
    // MARK: - The poll

    // Queue a request round for each PR of the user of the poll with new work, while the
    // automatic rounds are on (ReviewsState.allowsAutoFix). A PR from a fork, an ignored PR, a PR
    // with a round, an outbox or an entry of a round on a PR of the user (a request, conflict or
    // CI entry), and a PR that waits after a failed full read get none.
    func queueNewWork(_ poll: PollAnswer) {
        let state = store.state
        let config = config
        guard state.allowsAutoFix(config.autoFix) else { return }
        let fixFrom = state.fixFrom ?? state.turnedOnAt
        let baseline = Set(state.baseline)
        let time = now()
        let keys = poll.mine.filter { pr in
            let prState = state.prs[pr.key] ?? PRState()
            return !IgnoreRule.matches(config.ignore, pr.key.repo) && prState.round == nil
                && prState.outbox == nil && queue.runningJob(of: pr.key) == nil
                && !state.queue.contains { $0.pr == pr.key && $0.kind.isMine }
                && !waitsAfterReadFailure(pr.key, prState)
                && WorkRule.startsRound(
                    pr, prState, fixFrom: fixFrom, viewer: poll.viewer, baseline: baseline)
        }.map(\.key)
        guard !keys.isEmpty else { return }
        var added: [PRKey] = []
        store.change { state in
            for pr in keys where !state.queue.contains(where: { $0.pr == pr && $0.kind.isMine }) {
                state.queue.append(QueueEntry(pr: pr, kind: .request, at: time))
                added.append(pr)
            }
        }
        changed()
        for pr in added {
            queue.add(QueuedJob(pr: pr, kind: .request, since: time, trigger: .newWork))
        }
    }

    // True while the last round of the PR failed at its full read less than WorkRule.readRetry
    // ago, and its error stays. A read that keeps failing then costs one read in each wait, not
    // one at each poll, and a short error still gives a round after the wait. A good round clears
    // the error, and a click never waits.
    func waitsAfterReadFailure(_ pr: PRKey, _ prState: PRState) -> Bool {
        guard prState.lastError != nil, let failed = readFailures[pr] else { return false }
        return timeline.now() - failed < WorkRule.readRetry
    }

    // MARK: - The own requests

    // After a poll: the own request of each PR of the user with a request session or an own
    // outbox. A cut list of the PRs of the user can lack a PR, so it acts on the PRs it has.
    func checkOwnRequests(_ poll: PollAnswer) {
        let state = store.state
        for pr in poll.mine {
            guard let prState = state.prs[pr.key],
                prState.requestSession != nil || prState.outbox?.own == true
            else { continue }
            checkOwnRequest(pr.key, in: poll)
        }
    }

    // Act on the own request of the user on the PR (OwnRequests) in a task of ReviewRounds, while
    // no round of the PR runs and nobody uses its request session (it is idle with no box,
    // stopped or gone). A PR that the poll does not list as a PR of the user, a PR from a fork,
    // a PR with a drop, and a PR whose own request runs get nothing. While Remove all clones runs
    // or after stop(), nothing starts. The end of the task wakes the queue: no round of the PR
    // starts while it runs (isReady).
    func checkOwnRequest(_ pr: PRKey, in poll: PollAnswer? = nil) {
        guard !removing, !stopped, ownRuns[pr] == nil, drops[pr] == nil, discards[pr] == nil,
            queue.runningJob(of: pr) == nil, store.state.prs[pr]?.round == nil,
            let polled = (poll ?? answer())?.mine.first(where: { $0.key == pr }),
            !polled.isCrossRepository, !sessions.requestInUse(pr)
        else { return }
        let own = own
        ownRuns[pr] = Task {
            await own.run(pr)
            ownRuns[pr] = nil
            queue.wake()
        }
    }

    // The round of the job found an own request of the user before it changed the worktree. The
    // own request goes first, in the task of the round: like the writes of an earlier round, a
    // halt does not cancel it, and a halt that came while it ran stops the round right after it.
    // Then the round starts again from its first step, so it reads the new head of the PR. A
    // round yields at most maxYields times; after that it fails as busy.
    // The conflict round does the same (ConflictRounds.swift). busy: the end of a round that
    // yielded too many times. chosen: the items that a halt gives back. restart: the round again,
    // with the count of its yields.
    func yieldToOwnRequest(
        _ job: QueuedJob, yields: Int, chosen: [NodeID], busy: () async -> Void,
        restart: (_ yields: Int) async -> Void
    ) async {
        let pr = job.pr
        guard yields < Self.maxYields else {
            await busy()
            return
        }
        holdHalts(pr)
        await own.run(pr)
        let halted = releaseHalts(pr)
        if halted || Task.isCancelled {
            await Task { await self.halted(job, chosen: chosen) }.value
            return
        }
        changed()
        await restart(yields + 1)
    }

    // The most times that one request job lets an own request go first.
    static let maxYields = 2

    // MARK: - Discard these changes

    // The check of Discard these changes when the user picks it: the changed files of the
    // worktree of the PR, sorted, for the confirm. A copy with no change now gives nothing, and
    // the reason of the row clears (there is nothing to discard). notNow while the discard can't
    // run (canDiscard), failed when git fails.
    package func changesToDiscard(_ pr: PRKey) async -> DiscardOutcome {
        guard canDiscard(pr) else { return .notNow }
        guard let paths = await repos.changedPaths(pr) else { return .failed }
        guard canDiscard(pr) else { return .notNow }
        guard !paths.isEmpty else {
            await clearWaiting(pr)
            return .nothing
        }
        return .files(paths.sorted())
    }

    // Discard these changes, after the confirm of the user (docs/behaviour/reviews.md, "Your own
    // requests"), in a task of ReviewRounds (discards): no round, own request or second discard
    // of the PR starts while it runs, and waitForEnd() waits for it. The worktree goes back to
    // the commit that it is at (RepoStore.discard, which also removes the files that git does
    // not track and records what stays), an own request file goes, and the reason of the row
    // clears, so Handle now can start the round. Only a reset that git did clears the reason.
    package func discardChanges(_ pr: PRKey, click: UserClick) async -> DiscardOutcome {
        guard canDiscard(pr) else { return .notNow }
        let task = Task { await discardNow(pr) }
        discards[pr] = task
        let outcome = await task.value
        discards[pr] = nil
        queue.wake()
        return outcome
    }

    // A worktree at the merge with the markers of a conflict round goes back to the head of the
    // PR, so a later own request works on the head.
    private func discardNow(_ pr: PRKey) async -> DiscardOutcome {
        guard let at = await repos.worktreeCommit(pr), let paths = await repos.changedPaths(pr)
        else {
            eventLine("Reviews: Bifrost couldn't read its copy of \(pr.text), so it kept it.")
            return .failed
        }
        guard canDiscard(pr, discarding: true) else { return .notNow }
        guard !paths.isEmpty else {
            await clearWaiting(pr)
            return .nothing
        }
        await repos.removeOwnRequest(pr)
        own.forgetRoundMark(pr)
        guard await repos.discard(pr, to: at.conflictHead ?? at.commit) else {
            eventLine(
                "Reviews: Bifrost couldn't discard the changes in its copy of \(pr.text). git "
                    + "didn't reset it.")
            return .failed
        }
        await clearWaiting(pr)
        eventLine("Reviews: Bifrost discarded the changes in its copy of \(pr.text).")
        return .discarded
    }

    // The reason of the row and its files clear.
    private func clearWaiting(_ pr: PRKey) async {
        await store.update { $0.prs[pr]?.waiting = nil }
        changed()
    }

    // True when Discard these changes can run on the PR: its row waits for the user, and nothing
    // can change its worktree now (no round, job, own request, drop, discard or kept outbox,
    // nobody uses its session, no Remove all clones). discarding: the call comes from the
    // discard itself.
    private func canDiscard(_ pr: PRKey, discarding: Bool = false) -> Bool {
        guard let prState = store.state.prs[pr] else { return false }
        return !removing && prState.waiting != nil && prState.round == nil
            && prState.outbox == nil && queue.runningJob(of: pr) == nil && ownRuns[pr] == nil
            && drops[pr] == nil && (discarding || discards[pr] == nil)
            && !sessions.requestInUse(pr)
    }

    // MARK: - The clicks

    // Handle now (all the work, also the older and the held items) or Handle Copilot comments
    // (the threads of the later Copilot reviews): queue one request round of a PR of the user.
    package func handle(_ pr: PRKey, copilot: Bool) async {
        await queueRound(pr, trigger: copilot ? .copilot : .handleNow)
    }

    // Try again on a PR of the user: one request round on the held and the older items, after
    // the rest of the writes of an earlier round.
    package func tryAgain(_ pr: PRKey) async {
        await queueRound(pr, trigger: .tryAgain)
    }

    // Cancel on a PR of the user: each queued round of the PR of the user (a request, conflict
    // or CI round) goes with its click. A round that runs stays.
    package func cancelRequest(_ pr: PRKey) async {
        guard store.state.prs[pr]?.round == nil, queue.runningJob(of: pr) == nil else { return }
        queue.cancel(pr)
        await store.update { state in
            state.queue.removeAll { $0.pr == pr && $0.kind.isMine }
            state.prs[pr]?.handleOlder = false
            state.prs[pr]?.handleCopilot = false
            state.prs[pr]?.resolveNow = false
        }
        changed()
    }

    // Don't send the rest, on a PR of the user whose writes stopped and wait for Try again (a
    // kept outbox): the outbox goes, its done items are handled and the others wait in held, and
    // the reason of the stop clears. Nothing goes to GitHub. A round that runs or posts, and an
    // own request that runs, keep the outbox, and while Remove all clones runs nothing changes.
    package func dropOutbox(_ pr: PRKey, click: UserClick) async {
        guard !removing, store.state.prs[pr]?.round == nil,
            store.state.prs[pr]?.outbox != nil, queue.runningJob(of: pr) == nil,
            ownRuns[pr] == nil
        else { return }
        let time = now()
        let outbox = store.state.prs[pr]?.outbox
        await store.update { state in
            guard var prState = state.prs[pr], prState.round == nil else { return }
            prState.dropOutbox(now: time)
            prState.lastError = nil
            prState.waiting = nil
            state.prs[pr] = prState
        }
        changed()
        // The commit of an own request did not reach GitHub: the change of the user stays in the
        // worktree as changes.
        if let outbox, outbox.own { await repos.uncommit(pr, to: outbox.headSHA) }
    }

    // The answers of the user to the open questions of the PR. Each answer names an open
    // question, and a text has from 1 to Question.maxAnswer characters after the trim; else
    // nothing changes and the result is false. An item that the user handles is handled with the
    // time of the question as its reply time. An answered item leaves the held items, so the
    // round finds it as work, and the texts queue one request round (after the round that runs).
    @discardableResult
    package func answerQuestions(_ pr: PRKey, _ answers: [NodeID: QuestionAnswer]) async -> Bool {
        guard !removing, !answers.isEmpty, let prState = store.state.prs[pr] else {
            return false
        }
        var texts: [NodeID: String] = [:]
        for (id, answer) in answers {
            guard let question = prState.questions[id], question.answer == nil else {
                return false
            }
            if case .text(let raw) = answer {
                let text = raw.trimmed()
                guard !text.isEmpty, text.utf16.count <= Question.maxAnswer else { return false }
                texts[id] = text
            }
        }
        let time = now()
        let queued = store.state.queue.contains { $0.pr == pr && $0.kind == .request }
        await store.update { state in
            guard var prState = state.prs[pr] else { return }
            for (id, answer) in answers {
                guard let question = prState.questions[id] else { continue }
                switch answer {
                case .text: prState.questions[id]?.answer = texts[id]
                case .handleMyself:
                    prState.questions[id] = nil
                    prState.handled[id] = Handled(at: time, lastReplyAt: question.seenUntil)
                }
            }
            prState.held.removeAll { answers.keys.contains($0) }
            state.prs[pr] = prState
            if !texts.isEmpty && !queued {
                state.queue.append(QueueEntry(pr: pr, kind: .request, at: time))
            }
        }
        changed()
        if !texts.isEmpty {
            setup.allowOneStart(pr.repo)
            queue.add(QueuedJob(pr: pr, kind: .request, since: time, trigger: .answer))
        }
        return true
    }

    // Queue one request round of a PR of the user of the last poll that has no round and no
    // entry, with the click in the state, so a restart keeps it. A PR from a fork gets none.
    private func queueRound(_ pr: PRKey, trigger: RoundTrigger) async {
        guard !removing, let polled = answer()?.mine.first(where: { $0.key == pr }),
            !polled.isCrossRepository
        else { return }
        let state = store.state
        guard state.prs[pr]?.round == nil,
            !state.queue.contains(where: { $0.pr == pr && $0.kind == .request }),
            queue.runningJob(of: pr) == nil
        else { return }
        let time = now()
        setup.allowOneStart(pr.repo)
        await store.update { state in
            var prState = state.prs[pr] ?? PRState()
            if trigger == .copilot {
                prState.handleCopilot = true
            } else {
                prState.handleOlder = true
            }
            prState.lastError = nil
            prState.waiting = nil
            state.prs[pr] = prState
            state.queue.append(QueueEntry(pr: pr, kind: .request, at: time))
        }
        changed()
        queue.add(QueuedJob(pr: pr, kind: .request, since: time, trigger: trigger))
    }

    // MARK: - The jobs

    // The round of a request job. saved: the round of the state, of a job that goes on after a
    // restart: a running round waits for its session, and a posting round sends the rest of its
    // writes. yields: the times that the job let an own request go first.
    func runRequest(_ job: QueuedJob, saved: ActiveRound?, yields: Int = 0) async {
        let pr = job.pr
        if let saved {
            switch saved.phase {
            case .running:
                let round = makeRequestRound(job)
                await settleRequest(job, round) { () async throws(RequestRound.Stop) in
                    try await round.resume(saved)
                }
            case .posting:
                await writes.resume(pr)
                changed()
                ended()
            case .preparing:
                break
            }
            return
        }
        let time = now()
        await store.update { state in
            state.queue.removeAll { $0.pr == pr && $0.kind == .request }
            var prState = state.prs[pr] ?? PRState()
            prState.round = ActiveRound(
                phase: .preparing, startedAt: time, at: job.since, kind: .request)
            state.prs[pr] = prState
        }
        changed()
        let round = makeRequestRound(job)
        await settleRequest(job, round, yields: yields) { () async throws(RequestRound.Stop) in
            try await round.start()
        }
    }

    // One request round of the job on the services of the rounds. A job with no trigger (an
    // entry of the file) takes the click that the state saved. The outbox of the round keeps the
    // setting of the signed commits of now.
    private func makeRequestRound(_ job: QueuedJob) -> RequestRound {
        let pr = job.pr
        return RequestRound(
            pr: pr,
            parts: RequestRound.Parts(
                store: store, github: github, repos: repos, setup: setup, sessions: sessions,
                writes: writes, own: own, skills: skills, userHome: userHome, now: now),
            trigger: job.trigger ?? Self.requestTrigger(store.state.prs[pr]),
            model: config.requestModel, signed: config.signedCommits,
            autoFix: { [weak self] in self?.config.autoFix ?? false },
            hooks: roundHooks(pr),
            holdHalts: { [weak self] in self?.holdHalts(pr) },
            releaseHalts: { [weak self] in self?.releaseHalts(pr) ?? false })
    }

    // Run the steps of the request round, then end it by how they stopped: an outcome notifies
    // once when it added questions, and polls at once; a failure holds the items of the round
    // and shows its reason, with no notification; writes that stopped show their reason and poll
    // at once, because GitHub can hold a part of them; an own request of the user goes first,
    // then the round starts again.
    private func settleRequest(
        _ job: QueuedJob, _ round: RequestRound, yields: Int = 0,
        _ steps: () async throws(RequestRound.Stop) -> RequestRound.Ended
    ) async {
        let pr = job.pr
        do throws(RequestRound.Stop) {
            switch try await steps() {
            case .accepted(_, let added):
                if added > 0 { notify(.needsYou(pr, questions: added)) }
                ended()
            case .nothing, .closed:
                break
            }
        } catch {
            let stop: RequestRound.Stop = Task.isCancelled ? .halted : error
            switch stop {
            case .failed(let failure):
                await failRequest(pr, failure, hold: round.chosen, files: round.unsavedFiles)
            case .wrote(let failure):
                await failRequest(pr, failure, hold: [], files: round.unsavedFiles)
                ended()
            case .waitForTrust(let refused): await waitForTrust(job, refused: refused)
            case .ownRequestFirst:
                await yieldToOwnRequest(
                    job, yields: yields, chosen: round.chosen,
                    busy: { await failRequest(pr, .sessionBusy, hold: round.chosen) },
                    restart: { await runRequest(job, saved: nil, yields: $0) })
            case .halted:
                await Task { await self.halted(job, chosen: round.chosen) }.value
            }
        }
    }

    // MARK: - The ends

    // A failed request round: the round clears, its items wait in held, the click is spent, and
    // the row shows the reason with Try again. So a failure never starts again by itself. A
    // failure that only the user can clear (changes that no round made) shows Needs you with
    // its reason instead, and Handle now starts the round again.
    // files: the changes that the safety net found (WaitsForYou.files).
    func failRequest(
        _ pr: PRKey, _ failure: RoundFailure, hold items: [NodeID], files: [String] = []
    ) async {
        if case .readFailed = failure { readFailures[pr] = timeline.now() }
        await store.update { state in
            guard var prState = state.prs[pr] else { return }
            prState.round = nil
            if failure.waitsForYou {
                prState.keepWaiting(
                    WaitsForYou(
                        reason: failure.message(for: .request), files: files,
                        kind: failure == .fixHadEdits ? .other : .unpushedRequest),
                    adoptsKind: false)
                prState.lastError = nil
            } else {
                prState.lastError = failure.message(for: .request)
            }
            prState.handleOlder = false
            prState.handleCopilot = false
            prState.hold(items)
            state.prs[pr] = prState
        }
        changed()
    }

    // The PR of the user merged or closed: its request session, worktree, input folder and queue
    // entries (request, conflict and CI) go, and its request fields clear with its clicks, held
    // items, questions, outbox, conflict mark and CI mark. The handled items and the asked
    // reviewers stay. Nothing posts.
    func dropRequest(_ pr: PRKey) async {
        readFailures[pr] = nil
        own.forgetRoundMark(pr)
        await sessions.remove(pr, .request)
        await repos.removePR(pr)
        await store.update { state in
            state.queue.removeAll { $0.pr == pr && $0.kind.isMine }
            guard var prState = state.prs[pr] else { return }
            prState.handleOlder = false
            prState.handleCopilot = false
            prState.resolveNow = false
            prState.held = []
            prState.outbox = nil
            prState.questions = [:]
            prState.requestSession = nil
            prState.waiting = nil
            prState.conflict = nil
            prState.ci = nil
            if prState.round == nil || prState.round?.kind.isMine == true {
                prState.round = nil
                prState.lastError = nil
            }
            state.prs[pr] = prState
        }
        changed()
    }

    // The click that an entry of the file waits with: Handle now, Handle Copilot comments, or new
    // work (an automatic round or an answer).
    static func requestTrigger(_ prState: PRState?) -> RoundTrigger {
        if prState?.handleOlder == true { return .handleNow }
        return prState?.handleCopilot == true ? .copilot : .newWork
    }
}
