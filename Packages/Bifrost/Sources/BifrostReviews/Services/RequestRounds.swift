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
//   notification; a round that adds questions notifies once. A round whose writes stopped keeps
//   the items where the outbox rules put them. Don't send the rest drops an outbox that stays for
//   Try again, and sends nothing (dropOutbox).
import BifrostFoundation
import BifrostSessions
import Foundation

extension ReviewRounds {
    // MARK: - The poll

    // Queue a request round for each PR of the user of the poll with new work, while the
    // automatic rounds are on (ReviewsState.allowsAutoFix). A PR from a fork, an ignored PR, and a
    // PR with a round, an outbox or an entry get none.
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
                && !state.queue.contains { $0.pr == pr.key && $0.kind == .request }
                && WorkRule.startsRound(
                    pr, prState, fixFrom: fixFrom, viewer: poll.viewer, baseline: baseline)
        }.map(\.key)
        guard !keys.isEmpty else { return }
        var added: [PRKey] = []
        store.change { state in
            for pr in keys
            where !state.queue.contains(where: { $0.pr == pr && $0.kind == .request }) {
                state.queue.append(QueueEntry(pr: pr, kind: .request, at: time))
                added.append(pr)
            }
        }
        changed()
        for pr in added {
            queue.add(QueuedJob(pr: pr, kind: .request, since: time, trigger: .newWork))
        }
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

    // Cancel on a PR of the user: the queued request round goes with its click. A round that
    // runs stays.
    package func cancelRequest(_ pr: PRKey) async {
        guard store.state.prs[pr]?.round == nil, queue.runningJob(of: pr) == nil else { return }
        queue.cancel(pr)
        await store.update { state in
            state.queue.removeAll { $0.pr == pr && $0.kind == .request }
            state.prs[pr]?.handleOlder = false
            state.prs[pr]?.handleCopilot = false
        }
        changed()
    }

    // Don't send the rest, on a PR of the user whose writes stopped and wait for Try again (a
    // kept outbox): the outbox goes, its done items are handled and the others wait in held, and
    // the reason of the stop clears. Nothing goes to GitHub. A round that runs or posts keeps its
    // outbox, and while Remove all clones runs nothing changes.
    package func dropOutbox(_ pr: PRKey, click: UserClick) async {
        guard !removing, store.state.prs[pr]?.round == nil,
            store.state.prs[pr]?.outbox != nil, queue.runningJob(of: pr) == nil
        else { return }
        let time = now()
        await store.update { state in
            guard var prState = state.prs[pr], prState.round == nil else { return }
            prState.dropOutbox(now: time)
            prState.lastError = nil
            state.prs[pr] = prState
        }
        changed()
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
            state.prs[pr] = prState
            state.queue.append(QueueEntry(pr: pr, kind: .request, at: time))
        }
        changed()
        queue.add(QueuedJob(pr: pr, kind: .request, since: time, trigger: trigger))
    }

    // MARK: - The jobs

    // The round of a request job. saved: the round of the state, of a job that goes on after a
    // restart: a running round waits for its session, and a posting round sends the rest of its
    // writes.
    func runRequest(_ job: QueuedJob, saved: ActiveRound?) async {
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
        await settleRequest(job, round) { () async throws(RequestRound.Stop) in
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
                writes: writes, skills: skills, userHome: userHome, now: now),
            trigger: job.trigger ?? Self.requestTrigger(store.state.prs[pr]),
            model: config.requestModel, signed: config.signedCommits,
            autoFix: { [weak self] in self?.config.autoFix ?? false },
            viewer: { [weak self] in self?.answer()?.viewer },
            stopRequested: { [weak self] in self?.userStopped(pr) ?? false },
            takeTryOnce: { [weak self] in self?.setup.takeOneStart(pr.repo) ?? false },
            startedSession: { [weak self] in self?.startedSession(pr.repo) },
            changed: { [weak self] in self?.changed() },
            holdHalts: { [weak self] in self?.holdHalts(pr) },
            releaseHalts: { [weak self] in self?.releaseHalts(pr) ?? false })
    }

    // Run the steps of the request round, then end it by how they stopped: an outcome notifies
    // once when it added questions, and polls at once; a failure holds the items of the round
    // and shows its reason, with no notification; writes that stopped show their reason and poll
    // at once, because GitHub can hold a part of them.
    private func settleRequest(
        _ job: QueuedJob, _ round: RequestRound,
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
            case .failed(let failure): await failRequest(pr, failure, hold: round.chosen)
            case .wrote(let failure):
                await failRequest(pr, failure, hold: [])
                ended()
            case .waitForTrust(let refused): await waitForTrust(job, refused: refused)
            case .halted:
                await Task { await self.halted(job, chosen: round.chosen) }.value
            }
        }
    }

    // MARK: - The ends

    // A failed request round: the round clears, its items wait in held, the click is spent, and
    // the row shows the reason with Try again. So a failure never starts again by itself.
    func failRequest(_ pr: PRKey, _ failure: RoundFailure, hold items: [NodeID]) async {
        await store.update { state in
            guard var prState = state.prs[pr] else { return }
            prState.round = nil
            prState.lastError = failure.message(for: .request)
            prState.handleOlder = false
            prState.handleCopilot = false
            prState.hold(items)
            state.prs[pr] = prState
        }
        changed()
    }

    // The PR of the user merged or closed: its request session, worktree, input folder and queue
    // entry go, and its request fields clear with its clicks, held items, questions and outbox.
    // The handled items and the asked reviewers stay. Nothing posts.
    func dropRequest(_ pr: PRKey) async {
        await sessions.remove(pr, .request)
        await repos.removePR(pr)
        await store.update { state in
            state.queue.removeAll { $0.pr == pr && $0.kind == .request }
            guard var prState = state.prs[pr] else { return }
            prState.handleOlder = false
            prState.handleCopilot = false
            prState.held = []
            prState.outbox = nil
            prState.questions = [:]
            prState.requestSession = nil
            if prState.round == nil || prState.round?.kind == .request {
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
