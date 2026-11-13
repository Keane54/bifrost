// The review job (design 11 and 12). It gets the worktree and the input files ready, starts a
// read-only review session, checks the result file and writes a pending review on GitHub. Only
// the user submits the review. A failed round never posts, and nothing tries a failed round
// again by itself. The runner core in rounds.ts runs this job.

import { mkdir, mkdtemp, readFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { prKey, REASON_GH_FAILED, repoOf } from '../../shared/reviews'
import { messageOf } from '../actions/session-actions'
import { type DiffFile, parseDiff } from './diff-lines'
import {
  type Ended,
  type Job,
  type JobContext,
  kindOf,
  type PrRef,
  prOf,
  resultFileOf,
} from './jobs'
import { postPendingReview } from './pending-review'
import type { PollData } from './pr-data'
import { clonePath, ioPath, isInside } from './repo-paths'
import { parseReviewResult, placeComments, readResultFile } from './result-file'
import { REASON_INPUT_FAILED, writeRoundFiles } from './review-input'
import { fetchReviewContext, type ReviewContext } from './review-query'
import {
  reviewPrompt,
  reviewSessionArgs,
  reviewSessionName,
  type StartOutcome,
} from './review-session'
import {
  draftNotice,
  REASON_BLOCKED,
  REASON_CLOSED_WHILE_POSTING,
  REASON_END_FAILED,
  REASON_NO_RESULT,
  REASON_OWN_DRAFT,
  REASON_PR_CHANGED,
  REASON_PR_CLOSED,
  REASON_PREPARE_FAILED,
  REASON_START_FAILED,
  REASON_STOPPED,
  REASON_TIMEOUT,
  reasonBadResult,
  reviewedNotice,
} from './round-text'
import {
  type ActiveRound,
  type DraftComment,
  MAX_DRAFTS,
  type PrState,
  type RecommendationMark,
  type SessionRef,
} from './state'

// True for no round or a review round. A PR is on one tab only, so a review key has no round of
// the other job. This keeps a round of the other job safe all the same.
const reviewRound = (round: ActiveRound | null): boolean =>
  round === null || kindOf(round) === 'review'

// The PR state without the fields of the review rounds.
function clearReview(p: PrState): PrState {
  const cleared = { ...p, actedAt: null, recommendation: null, review: null }
  return reviewRound(p.round) ? { ...cleared, lastError: null, round: null } : cleared
}

// True when the pending review of the user is the draft review that Bifrost made on this head.
// A new round would add each comment and the summary to it a second time.
function isOwnDraft(ctx: JobContext, key: string, context: ReviewContext): boolean {
  const own = ctx.store.get().prs[key]?.recommendation?.reviewId ?? null
  const { pending } = context
  return own !== null && pending?.id === own && pending.commit === context.headSha
}

// Save the result of a round that worked, and clear the round.
function succeed(
  ctx: JobContext,
  key: string,
  token: number,
  head: string,
  mark: RecommendationMark,
  drafts: DraftComment[],
): Promise<boolean> {
  return ctx.succeed(
    key,
    token,
    p => ({ ...p, lastReviewedCommit: head, recommendation: mark }),
    s => (drafts.length === 0 ? s : { ...s, drafts: [...s.drafts, ...drafts].slice(-MAX_DRAFTS) }),
  )
}

// Steps 3 and 4: get the worktree and the input files ready, then start the session.
async function runRound(ctx: JobContext, key: string, token: number, at: number): Promise<void> {
  const { deps, store } = ctx
  const { repos } = deps
  const pr = prOf(key)
  const gen = ctx.generation()
  let clone: string | null = null
  let prepared = false
  // A round that went (the request went) removes what it made.
  const gone = async (): Promise<void> => {
    if (prepared && clone !== null) await ctx.removeWorktree(clone, pr.number)
  }
  // True when the round must stop: it went, or the runner stopped (Watch GitHub off) or started
  // again.
  const halted = (): boolean => !ctx.alive(key, token) || ctx.stopped(gen)
  // Stop the round and start no session. A round that is still alive goes back to the queue,
  // as after a restart. A round that the user stopped fails.
  const halt = async (): Promise<void> => {
    await gone()
    if (!ctx.alive(key, token)) return
    if (store.get().prs[key]?.round?.stoppedByUser === true) {
      return await ctx.fail(key, token, REASON_STOPPED)
    }
    await ctx.putBack(key, token, at)
  }
  try {
    clone = ctx.cloneOfRepo(repoOf(key)) ?? (await ctx.cloneRepo(repoOf(key)))
    if (halted()) return await halt()
    const viewer = deps.viewer()
    if (viewer === null) return await ctx.putBack(key, token, at)
    // An untrusted clone gets a start only when it has its one try.
    if (!ctx.isTrusted(clone) && !ctx.takeTryOnce(clone)) {
      return await ctx.putBack(key, token, at)
    }
    const first = await fetchReviewContext(deps.gh, pr, viewer)
    if (halted()) return await halt()
    if (!first.ok) return await ctx.failRead(key, token, first)
    const { context } = first
    if (context.state !== 'OPEN') return await ctx.fail(key, token, REASON_PR_CLOSED)
    if (isOwnDraft(ctx, key, context)) return await ctx.fail(key, token, REASON_OWN_DRAFT)
    const fetched = await repos.fetchPr(clone, pr.number, context.baseRef)
    if (halted()) return await halt()
    if (fetched.head !== context.headSha) return await ctx.fail(key, token, REASON_PR_CHANGED)
    const earlier = store.get().prs[key]?.review ?? null
    if (earlier !== null) {
      await ctx.removeSession(earlier)
      await ctx.changeRound(key, token, p => ({ ...p, review: null }))
    }
    if (halted()) return await halt()
    const worktree = await repos.prepareWorktree(clone, pr.number, fetched.head)
    prepared = true
    if (halted()) return await halt()
    const files = await writeRoundFiles(
      { repos, skillsDir: deps.skillsDir },
      { clone, context, fetched, number: pr.number, viewer },
    )
    if (halted()) return await halt()
    if (!files.ok) return await ctx.fail(key, token, files.message)
    if (store.get().prs[key]?.round?.stoppedByUser === true) {
      return await ctx.fail(key, token, REASON_STOPPED)
    }
    const name = reviewSessionName(pr, ctx.namesInUse(), deps.testHome)
    const args = reviewSessionArgs({
      ioDir: ioPath(clone, pr.number),
      model: deps.testHome ? 'haiku' : deps.settings().reviewsReviewModel,
      name,
      pluginDir: deps.skillsDir,
      prompt: reviewPrompt(files.inputFile),
    })
    ctx.markStarting(key, true)
    let started: StartOutcome
    try {
      started = await deps.sessions.start({ args, cwd: worktree, name })
    } finally {
      ctx.markStarting(key, false)
    }
    if (!ctx.alive(key, token)) {
      if (started.ok) {
        await ctx.removeSession({ name, sessionId: started.sessionId, shortId: started.shortId })
      } else if (!started.trust) {
        // The session can still run. Remove it when its row shows.
        ctx.addLate(name)
      }
      return await gone()
    }
    if (!started.ok && started.trust) {
      // A trust error acts as an untrusted clone.
      ctx.refusedTrust(clone)
      return await ctx.putBack(key, token, at)
    }
    if (!started.ok) {
      // The session can still run. The name stays, so Bifrost finds its row later. The row
      // gets a fixed text, because the message of claude can hold a path.
      deps.log(`The review session of ${key} did not start. ${started.message}`)
      await ctx.clean(clone, pr.number, fetched.head)
      const late: SessionRef = { name, sessionId: '' }
      return await ctx.fail(key, token, REASON_START_FAILED, p => ({ ...p, review: late }))
    }
    // Claude Code started a session in the clone, so it trusts the clone.
    ctx.trustedByStart(clone)
    ctx.diffs.set(key, files.files)
    ctx.watchRound(key)
    const review: SessionRef = { name, sessionId: started.sessionId, shortId: started.shortId }
    const saved = await ctx.changeRound(key, token, p => ({
      ...p,
      review,
      round:
        p.round === null
          ? null
          : {
              ...p.round,
              baseSha: fetched.base,
              headSha: fetched.head,
              phase: 'running',
              sessionId: started.sessionId,
              shortId: started.shortId,
              // The time limit counts from the start of the session, so a slow clone or
              // checkout does not take time from the session.
              startedAt: deps.now(),
            },
    }))
    if (!saved) {
      await ctx.removeSession(review)
      return await gone()
    }
    deps.changed()
    // A stop of the user during the start.
    if (store.get().prs[key]?.round?.stoppedByUser === true) {
      await ctx.stopQuietly(started.shortId)
    }
  } catch (error) {
    if (!ctx.alive(key, token)) return await gone()
    // The row gets a fixed text, because a Node or git error can hold a path.
    deps.log(`A review round of ${key} failed. ${messageOf(error)}`)
    await ctx.fail(key, token, REASON_PREPARE_FAILED)
  }
}

async function endRound(ctx: JobContext, key: string, token: number, check: Ended): Promise<void> {
  const round = ctx.store.get().prs[key]?.round
  if (!ctx.alive(key, token) || round == null) return
  const pr = prOf(key)
  const clone = clonePath(ctx.deps.bifrostHome, pr.owner, pr.repo)
  try {
    // A session past the time limit, or a session that asks, gets a stop first.
    const stop = check === 'timeout' || check === 'blocked'
    if (stop && round.shortId !== null) await ctx.stopQuietly(round.shortId)
    // Step 7. The clean comes before the post, so the save of a good round is one step.
    await ctx.clean(clone, pr.number, round.headSha)
    if (!ctx.alive(key, token)) return
    if (check === 'timeout') return await ctx.fail(key, token, REASON_TIMEOUT)
    if (check === 'gone') return await ctx.fail(key, token, REASON_STOPPED)
    // A session that asks ends with its result only when the result is valid.
    await finish(ctx, key, token, pr, clone, check === 'blocked' ? REASON_BLOCKED : null)
  } catch (error) {
    if (!ctx.alive(key, token)) return
    // The row gets a fixed text, because a Node error can hold a path.
    ctx.deps.log(`The end of a review round of ${key} failed. ${messageOf(error)}`)
    await ctx.fail(key, token, REASON_END_FAILED)
  }
}

// After a restart, make the diff of the round again from the clone, in a folder of Bifrost.
// Never from the input folder, because the session can change the files there.
async function rebuildDiff(
  ctx: JobContext,
  clone: string,
  round: ActiveRound,
): Promise<DiffFile[] | null> {
  if (round.baseSha === undefined || round.headSha === null) return null
  const root = join(ctx.deps.bifrostHome, 'reviews')
  let folder: string | null = null
  try {
    await mkdir(root, { mode: 0o700, recursive: true })
    folder = await mkdtemp(join(root, 'diff-'))
    const file = join(folder, 'full.diff')
    await ctx.deps.repos.writeDiff(clone, round.baseSha, round.headSha, file, 'merge-base')
    return parseDiff(await readFile(file, 'utf8'))
  } catch (error) {
    ctx.deps.log(`Bifrost couldn't make the diff of a review again. ${messageOf(error)}`)
    return null
  } finally {
    if (folder !== null && isInside(root, folder)) {
      await rm(folder, { force: true, recursive: true }).catch(() => undefined)
    }
  }
}

// Steps 5 and 6: read and check the result, then post the pending review. blocked is the
// reason for a missing or bad result, when the session ended at a prompt.
async function finish(
  ctx: JobContext,
  key: string,
  token: number,
  pr: PrRef,
  clone: string,
  blocked: string | null,
): Promise<void> {
  const { deps, store } = ctx
  const round = store.get().prs[key]?.round
  if (round == null || round.headSha === null) return await ctx.fail(key, token, REASON_NO_RESULT)
  const head = round.headSha
  // The user stopped the review. Nothing goes to GitHub.
  if (round.stoppedByUser) return await ctx.fail(key, token, REASON_STOPPED)
  const read = await readResultFile(resultFileOf(deps.bifrostHome, key))
  if (!ctx.alive(key, token)) return
  if (!read.ok) {
    if (blocked !== null) return await ctx.fail(key, token, blocked)
    const missing = read.reason === 'missing'
    return await ctx.fail(key, token, missing ? REASON_NO_RESULT : reasonBadResult(read.reason))
  }
  const files = ctx.diffs.get(key) ?? (await rebuildDiff(ctx, clone, round))
  if (!ctx.alive(key, token)) return
  if (files === null) return await ctx.fail(key, token, REASON_INPUT_FAILED)
  const expect = { files, headSha: head, pr: prKey(pr.owner, pr.repo, pr.number) }
  const parsed = parseReviewResult(read.text, expect)
  if (!parsed.ok) return await ctx.fail(key, token, blocked ?? reasonBadResult(parsed.reason))
  const { result } = parsed
  const placed = placeComments(result, files)
  const mark = (reviewId: string | null): RecommendationMark => ({
    at: deps.now(),
    headSha: head,
    reviewId,
    value: result.recommendation,
    why: result.why,
  })
  const notice = { number: pr.number, repo: pr.repo }
  if (
    result.recommendation === 'approve' &&
    placed.summary === '' &&
    placed.comments.length === 0
  ) {
    if (await succeed(ctx, key, token, head, mark(null), [])) deps.notify(reviewedNotice(notice))
    return
  }
  const posting = await ctx.changeRound(key, token, p => ({
    ...p,
    round: p.round === null ? null : { ...p.round, phase: 'posting' },
  }))
  if (!posting) return
  const viewer = deps.viewer()
  if (viewer === null) return await ctx.fail(key, token, REASON_GH_FAILED)
  const again = await fetchReviewContext(deps.gh, pr, viewer)
  if (!ctx.alive(key, token)) return
  if (!again.ok) return await ctx.failRead(key, token, again)
  if (again.context.state !== 'OPEN') return await ctx.fail(key, token, REASON_PR_CLOSED)
  if (store.get().prs[key]?.round?.stoppedByUser === true) {
    return await ctx.fail(key, token, REASON_STOPPED)
  }
  // The pending review of the user, if any, comes from this second read. The commit is the
  // reviewed commit, also when the author pushed during the round.
  const outcome = await postPendingReview(deps.gh, {
    comments: placed.comments,
    headSha: head,
    number: pr.number,
    owner: pr.owner,
    pending: again.context.pending,
    repo: pr.repo,
    summary: placed.summary,
  })
  // Any failed post ends the round. The message of an unknown result says that Bifrost cannot
  // tell if GitHub saved the draft. Nothing posts again by itself.
  if (!outcome.ok) return await ctx.fail(key, token, outcome.message)
  const at = deps.now()
  const draft = (path: string, line: number, body: string): DraftComment => ({
    at,
    body,
    line,
    path,
    prKey: key,
    reviewId: outcome.reviewId,
  })
  const drafts = placed.comments.map(c => draft(c.path, c.line, c.body))
  if (placed.summary !== '') drafts.push(draft('', 0, placed.summary))
  if (await succeed(ctx, key, token, head, mark(outcome.reviewId), drafts)) {
    deps.requestPoll()
    deps.notify(draftNotice(notice, result.recommendation))
  }
}

// Step 12: the request of the key went. Stop its round, remove its session, its worktree and
// its queue entry, and clear its review fields. Nothing posts.
async function dropKey(ctx: JobContext, key: string): Promise<void> {
  const { store } = ctx
  const pr = store.get().prs[key]
  const round = pr?.round ?? null
  const own = reviewRound(round)
  if (own) ctx.forget(key)
  const refs: SessionRef[] = []
  if (pr?.review) refs.push(pr.review)
  if (own && round?.sessionId != null && round.sessionId !== pr?.review?.sessionId) {
    refs.push({
      name: pr?.review?.name ?? '',
      sessionId: round.sessionId,
      ...(round.shortId === null ? {} : { shortId: round.shortId }),
    })
  }
  for (const ref of refs) await ctx.removeSession(ref)
  const { number } = prOf(key)
  const clone = ctx.cloneOfRepo(repoOf(key))
  if (own && clone !== null) await ctx.removeWorktree(clone, number)
  await store.change(s => {
    const p = s.prs[key]
    // A begin between the first forget and this change gave a new token. It goes too.
    if (reviewRound(p?.round ?? null)) ctx.forget(key)
    return {
      ...s,
      prs: p === undefined ? s.prs : { ...s.prs, [key]: clearReview(p) },
      queue: s.queue.filter(e => !(e.key === key && e.kind === 'review')),
    }
  })
  ctx.deps.changed()
}

export function createReviewJob(): Job {
  return {
    drop: dropKey,
    end: endRound,
    kind: 'review',
    // Only a complete answer shows that a request went.
    openKeys: (poll: PollData) =>
      !poll.toReviewHasMore && poll.errors.length === 0
        ? new Set(poll.toReview.map(p => p.key))
        : null,
    // Step 13: a restart starts a preparing round again. A running round waits for its session.
    // A posting round fails, because Bifrost cannot tell if GitHub saved the draft review.
    recover(_ctx, _key, round) {
      if (round.phase === 'running') return 'wait'
      if (round.phase === 'posting') return { fail: REASON_CLOSED_WHILE_POSTING }
      // The user stopped the round. It must not start again.
      return round.stoppedByUser ? { fail: REASON_STOPPED } : 'queue'
    },
    ref: 'review',
    // recover never gives resume for a review round. A posting round fails as at a restart.
    resume: (ctx, key, token) => ctx.fail(key, token, REASON_CLOSED_WHILE_POSTING),
    run: runRound,
  }
}
