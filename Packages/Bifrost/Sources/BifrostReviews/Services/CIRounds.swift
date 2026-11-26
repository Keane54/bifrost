// The CI part of the PR rounds (docs/behaviour/reviews.md, "My PRs"): the poll, the CI question
// and its answer, and the run and the end of each CI job, as an extension of ReviewRounds, which
// owns the queue, the gates (the halts, the one start of an untrusted clone, Remove all clones)
// and the other parts. CIRound holds the steps of one round.
// - A good poll queues a CI round for each PR of the user that CIRule.startsRound accepts: the
//   setting "Fix failing CI automatically" and its consent, a failed Actions job on the head, and
//   one round for each failure (the head and the failed job IDs that the CI mark keeps).
// - A CI round keeps each failure in the CI question of its head, never in lastError, so the row
//   shows Needs you and no automatic round starts on that head before the user answers.
// - An end where Claude did not try the failure (no text, a busy session, the work of a person,
//   an own request, the trust step, Remove all clones) puts back the job key that the round
//   replaced, so the same failure can start a round later. An end with no text waits
//   WorkRule.readRetry on the same head and jobs (in memory, as for the conflict rounds).
// - A pushed fix joins the chain of the head, and a pushed fix and a re-run poll at once. An
//   answered question goes at the end of the round that used it.
// - An answer of the user queues one round into the same session and clears the job key of its
//   head, so a round that does not try the failure leaves the answer for the next poll; "I'll
//   handle it" marks the head as the head of the user, so no CI round starts on it.
import BifrostFoundation
import Foundation

extension ReviewRounds {
    // MARK: - The poll

    // Queue a CI round for each PR of the user of the poll that CIRule accepts, unless the same
    // head and jobs wait after an end with no text. busy is as for the conflict rounds
    // (conflictBusy). A conflict entry that queueConflicts added first stops the rule.
    func queueCIWork(_ poll: PollAnswer) {
        let state = store.state
        let config = config
        guard state.allowsCIFix(config.fixCI) else { return }
        let keys = poll.mine.filter { pr in
            !waitsAfterQuietCI(pr)
                && CIRule.startsRound(
                    pr, state.prs[pr.key] ?? PRState(), state: state, config: config,
                    busy: conflictBusy(pr.key))
        }.map(\.key)
        guard !keys.isEmpty else { return }
        let time = now()
        var added: [PRKey] = []
        store.change { state in
            for pr in keys where !state.queue.contains(where: { $0.pr == pr }) {
                state.queue.append(QueueEntry(pr: pr, kind: .ci, at: time))
                added.append(pr)
            }
        }
        changed()
        for pr in added { queue.add(QueuedJob(pr: pr, kind: .ci, since: time)) }
    }

    // True while a round ended with no text on this head and these failed jobs less than
    // WorkRule.readRetry ago (for example, the poll showed the failure and the fresh read showed
    // the checks still running). A new head or new jobs never wait. The wait is in memory only.
    private func waitsAfterQuietCI(_ pr: PullRequest) -> Bool {
        guard let quiet = quietCI[pr.key], quiet.head.hex == pr.headSHA,
            quiet.key == pr.checks.jobKey
        else { return false }
        return timeline.now() - quiet.at < WorkRule.readRetry
    }

    // MARK: - The question

    // The CI question that the row of the PR counts (CIRule.visibleQuestion): a question with no
    // answer on the head of the PR of the last poll, while the setting and its consent allow the
    // CI work. The failed jobs are the names of the failed Actions jobs of that poll, or the names
    // of the question when the poll has none.
    package func ciQuestion(of pr: PRKey) -> OpenCIQuestion? {
        guard let polled = answer()?.mine.first(where: { $0.key == pr }) else { return nil }
        let state = store.state
        guard
            let question = CIRule.visibleQuestion(
                polled, state.prs[pr]?.ci, allowed: state.allowsCIFix(config.fixCI))
        else { return nil }
        let names = polled.checks.failedJobs.map(\.name)
        return OpenCIQuestion(question: question, failedJobs: names.isEmpty ? question.jobs : names)
    }

    // The answer of the user to the CI question of the PR (ciQuestion). A text has from 1 to
    // Question.maxAnswer UTF-16 units after the trim: it becomes the answer of the question, and
    // one CI round goes into the queue (with one start of an untrusted clone). The same save
    // clears the job key of the head: the queued entry stops a second round, the round of the
    // answer saves the key again, and a round that ends with no try leaves no key, so the next
    // poll starts a round that reads the answer. "I'll handle it"
    // marks the head as the head of the user, the question goes, and no round starts. Nothing
    // changes while Remove all clones runs, when the question is hidden or answered, or for a
    // text of the wrong length. The result is true when the state saved the answer.
    @discardableResult
    package func answerCI(_ pr: PRKey, _ answer: QuestionAnswer) async -> Bool {
        guard !removing, let open = ciQuestion(of: pr) else { return false }
        let head = open.question.head
        switch answer {
        case .text(let raw):
            let text = raw.trimmed()
            guard !text.isEmpty, text.utf16.count <= Question.maxAnswer else { return false }
            let time = now()
            let saved = await store.update { state in
                guard var ci = state.prs[pr]?.ci, var question = ci.question,
                    question.head == head, question.answer == nil
                else { return }
                question.answer = text
                ci.question = question
                if ci.handledHead == head {
                    ci.handledHead = nil
                    ci.handled = []
                }
                state.prs[pr]?.ci = ci
                if !state.queue.contains(where: { $0.pr == pr && $0.kind == .ci }) {
                    state.queue.append(QueueEntry(pr: pr, kind: .ci, at: time))
                }
            }
            changed()
            guard store.state.prs[pr]?.ci?.question?.answer == text else { return false }
            // An answer on a clone that needs trust gives one start, which claude judges.
            setup.allowOneStart(pr.repo)
            queue.add(QueuedJob(pr: pr, kind: .ci, since: time))
            return saved
        case .handleMyself:
            let saved = await store.update { state in
                guard var ci = state.prs[pr]?.ci, ci.question?.head == head else { return }
                ci.userHandles = head
                ci.question = nil
                state.prs[pr]?.ci = ci
            }
            changed()
            return saved && store.state.prs[pr]?.ci?.userHandles == head
        }
    }

    // MARK: - The jobs

    // The round of a CI job. saved: the round of the state, of a job that goes on after a
    // restart: a running round waits for its session, and a posting round pushes its fix again.
    // yields: the times that the job let an own request go first.
    func runCI(_ job: QueuedJob, saved: ActiveRound?, yields: Int = 0) async {
        let pr = job.pr
        let polled = answer()?.mine.first { $0.key == pr }
        let round = makeCIRound(job, polled: polled)
        // The failure of the poll waits after an end with no text.
        let failure = polled.flatMap { pull in
            CommitID(pull.headSHA).map { (head: $0, key: pull.checks.jobKey) }
        }
        if let saved {
            await settleCI(job, round, failure: failure) { () async throws(CIRound.Stop) in
                saved.phase == .posting
                    ? try await round.resumePosting(saved) : try await round.resume(saved)
            }
            return
        }
        let time = now()
        await store.update { state in
            state.queue.removeAll { $0.pr == pr && $0.kind == .ci }
            var prState = state.prs[pr] ?? PRState()
            prState.round = ActiveRound(
                phase: .preparing, startedAt: time, at: job.since, kind: .ci)
            state.prs[pr] = prState
        }
        changed()
        await settleCI(job, round, failure: failure, yields: yields) {
            () async throws(CIRound.Stop) in
            try await round.start()
        }
    }

    // One CI round of the job on the services of the rounds. The head and the failed jobs of the
    // poll name the failure until the round reads the head.
    private func makeCIRound(_ job: QueuedJob, polled: PullRequest?) -> CIRound {
        let pr = job.pr
        return CIRound(
            pr: pr,
            parts: CIRound.Parts(
                store: store, github: github, repos: repos, setup: setup, sessions: sessions,
                own: own, writes: writes, skills: skills, userHome: userHome, now: now),
            head: polled.flatMap { CommitID($0.headSHA) },
            jobNames: polled?.checks.failedJobs.map(\.name) ?? [], title: polled?.title ?? "",
            model: config.requestModel,
            signed: { [weak self] in self?.config.signedCommits ?? false },
            consent: { [weak self] in
                guard let self else { return nil }
                return self.store.state.ciConsent(self.config.fixCI)
            },
            hooks: roundHooks(pr))
    }

    // Run the steps of the CI round, then end it by how they stopped: a pushed fix and a re-run
    // poll at once; a question of Claude and the limits question notify once; a failure gives the
    // CI question its text, and a push or a re-run that GitHub can hold polls at once; an end
    // where Claude did not try the failure puts the old key back; an own request of the user goes
    // first, then the round starts again.
    private func settleCI(
        _ job: QueuedJob, _ round: CIRound, failure: (head: CommitID, key: [JobID])?,
        yields: Int = 0, _ steps: () async throws(CIRound.Stop) -> CIRound.Ended
    ) async {
        let pr = job.pr
        do throws(CIRound.Stop) {
            let end = try await steps()
            quietCI[pr] = nil
            await endedCI(pr, end, round: round)
        } catch {
            // A cancel stops the round, whatever the step that saw it gave.
            let stop: CIRound.Stop = Task.isCancelled ? .halted : error
            switch stop {
            case .failed(let failure):
                quietCI[pr] = nil
                await failCI(pr, failure, round: round)
                switch failure {
                case .push, .rerun: ended()
                case .limits, .session, .commit: break
                }
            case .quiet:
                // The failure of the poll waits, so the next polls do not start the same round.
                // A closed gate keeps no wait, so turning it on works at the next poll.
                if let failure, store.state.allowsCIFix(config.fixCI) {
                    quietCI[pr] = (failure.head, failure.key, timeline.now())
                }
                await endCI(pr) { prState in
                    prState.ci = Self.keyBack(prState.ci, round.saved)
                    // The gate closed before the first re-run write, so no re-run runs.
                    if let head = round.unsentRetry, prState.ci?.retrying == head {
                        prState.ci?.retrying = nil
                    }
                }
            case .untried:
                await endCI(pr) { $0.ci = Self.keyBack($0.ci, round.saved) }
            case .forYou(let waiting):
                await endCI(pr) { prState in
                    prState.ci = Self.keyBack(prState.ci, round.saved)
                    prState.keepWaiting(waiting, adoptsKind: true)
                }
            case .ownRequestFirst:
                await putKeyBack(pr, round)
                await yieldToOwnRequest(
                    job, yields: yields, chosen: [],
                    busy: { await failCI(pr, .session(.sessionBusy), round: round) },
                    restart: { await runCI(job, saved: nil, yields: $0) })
            case .waitForTrust(let refused):
                await putKeyBack(pr, round)
                await waitForTrust(job, refused: refused)
            case .halted:
                // The task of the round is cancelled, so the clean-up runs in a task of its own.
                // The clones went, so the round did not try the failure.
                let removed = queue.halt(of: pr) == .clonesRemoved
                await Task {
                    if removed { await self.putKeyBack(pr, round) }
                    await self.halted(job, chosen: [])
                }.value
            }
        }
    }

    // MARK: - The ends

    // A good end of a round: the round goes, and the CI mark of the head gets the result.
    private func endedCI(_ pr: PRKey, _ end: CIRound.Ended, round: CIRound) async {
        let (head, jobs, time) = (round.head, round.jobNames, now())
        switch end {
        case .pushed(let commit):
            // The fix joins the chain of the head, so it counts in the budget of that head. The
            // round proved the copy clean (the safety net before the turn, and the check of the
            // work of a person before the commit), so an old reason to wait goes.
            await endCI(pr) { prState in
                prState.waiting = nil
                guard let head else { return }
                var ci = CIRule.chainMark(prState.ci, head: head)
                if !ci.chain.contains(commit) { ci.chain.append(commit) }
                if ci.question?.answer != nil { ci.question = nil }
                prState.ci = ci
            }
            ended()
        case .retried:
            await endCI(pr) { prState in
                if prState.ci?.question?.answer != nil { prState.ci?.question = nil }
            }
            ended()
        case .asked(let text):
            await endCI(pr) { prState in
                guard let head else { return }
                var ci = CIRule.chainMark(prState.ci, head: head)
                ci.question = CIQuestion(
                    text: text, head: head, jobs: jobs, at: time, byClaude: true)
                prState.ci = ci
            }
            notify(.needsYou(pr, questions: 1))
        case .limits:
            // The round had no session: the mark of its chain keeps the failure, so it asks one
            // time.
            let (mark, key) = (round.mark, round.key)
            await endCI(pr) { prState in
                guard let head, var ci = mark else { return }
                ci.handledHead = head
                ci.handled = key
                ci.question = CIQuestion(
                    text: CIStop.limits.question, head: head, jobs: jobs, at: time,
                    byClaude: false)
                prState.ci = ci
            }
            notify(.needsYou(pr, questions: 1))
        }
    }

    // A failed CI round: the round goes, and the CI question of the head gets the text
    // (CIStop.question), so the row shows Needs you and no automatic round starts on the head. An
    // empty text (a moved or a rewritten branch) gives no question. The line of git or of GitHub
    // goes to the Event log. A fix of an unsigned push whose outcome Bifrost can't tell joins the
    // chain, so a failure on it keeps the budget.
    func failCI(_ pr: PRKey, _ failure: CIStop, round: CIRound) async {
        if let line = failure.eventLine(for: pr) {
            eventLine(TokenMask.mask(line, token: nil))
        }
        let (message, time, head, jobs, fix) = (
            failure.question, now(), round.head, round.jobNames, round.unknownFix
        )
        if head == nil, let line = failure.unshownLine(for: pr) {
            // No question can show the text, so the Event log keeps a trace of it.
            eventLine(TokenMask.mask(line, token: nil))
        }
        await endCI(pr) { prState in
            guard let head else { return }
            var ci = CIRule.chainMark(prState.ci, head: head)
            if let fix, !ci.chain.contains(fix) { ci.chain.append(fix) }
            if !message.isEmpty {
                ci.question = CIQuestion(
                    text: message, head: head, jobs: jobs, at: time, byClaude: false)
            } else if ci.question?.answer != nil {
                ci.question = nil
            }
            prState.ci = ci
        }
    }

    // The end of a CI round in one save: the round goes, then change.
    private func endCI(_ pr: PRKey, _ change: (inout PRState) -> Void) async {
        await store.update { state in
            guard var prState = state.prs[pr] else { return }
            if prState.round?.kind == .ci { prState.round = nil }
            change(&prState)
            state.prs[pr] = prState
        }
        changed()
    }

    // The job key that the round saved goes back to the key that it replaced, before the round
    // yields or waits.
    private func putKeyBack(_ pr: PRKey, _ round: CIRound) async {
        guard round.saved != nil else { return }
        await store.update { state in
            guard var prState = state.prs[pr] else { return }
            prState.ci = Self.keyBack(prState.ci, round.saved)
            state.prs[pr] = prState
        }
        changed()
    }

    // MARK: - The marks

    // The mark with the key that the round replaced, when its key is still the one that the
    // round saved. Else the mark as it is.
    nonisolated static func keyBack(_ mark: CIMark?, _ saved: CIRound.SavedKey?) -> CIMark? {
        guard var mark, let saved, mark.handledHead == saved.head, mark.handled == saved.key
        else { return mark }
        (mark.handledHead, mark.handled) = saved.before
        return mark
    }

    // The mark of a round that never got its turn: the job key of its head clears, so the round
    // of the queue saves it again.
    nonisolated static func untriedKey(_ mark: CIMark?, head: CommitID?) -> CIMark? {
        guard var mark, let head, mark.handledHead == head else { return mark }
        mark.handledHead = nil
        mark.handled = []
        return mark
    }

    // The mark of a CI round that was posting its re-run when Bifrost quit: GitHub can have the
    // re-run, so it never goes again. The question of its head sends the user to GitHub, and the
    // row does not show Retrying CI for it. With no head, the mark stays as it is.
    nonisolated static func postingRerunCI(
        _ mark: CIMark?, head: CommitID?, at time: Date
    ) -> CIMark? {
        guard let head else { return mark }
        var ci = CIRule.chainMark(mark, head: head)
        if ci.retrying == head { ci.retrying = nil }
        ci.question = CIQuestion(
            text: CIStop.unknownRerun.question, head: head, jobs: [], at: time, byClaude: false)
        return ci
    }

    // The mark of a CI round that the user stopped: the question of its head gets the text of the
    // stop. With no head, the mark stays as it is.
    nonisolated static func stoppedCI(_ mark: CIMark?, head: CommitID?, at time: Date) -> CIMark? {
        guard let head else { return mark }
        var ci = CIRule.chainMark(mark, head: head)
        ci.question = CIQuestion(
            text: CIStop.session(.stopped).question, head: head, jobs: [], at: time,
            byClaude: false)
        return ci
    }
}
