// The request job (design 10 and 12). It fixes and answers the review comments on a PR of the
// user. A round reads all the threads, comments and reviews of the PR, chooses its items, and
// starts a sandboxed session. The session edits files and writes its result file. Then Bifrost
// checks the result, and commits, pushes and posts the replies itself, in the order of the
// outbox. The session never waits for a person. A failed round posts nothing and holds its
// items, so nothing tries it again by itself. The runner core in rounds.ts runs this job.

import { githubCommentUrl } from '../../shared/github-url'
import { prKey, REASON_GH_FAILED, repoOf } from '../../shared/reviews'
import { messageOf } from '../actions/session-actions'
import { maskToken } from '../log/mask'
import {
  type Ended,
  type Job,
  type JobContext,
  kindOf,
  prOf,
  type ReadFailure,
  resultFileOf,
} from './jobs'
import {
  autoFixOn,
  firstCopilotReviewId,
  isIgnored,
  needsRound,
  splitWork,
  type WorkItem,
  type WorkLists,
  workSince,
} from './model'
import type { PollData, PrData } from './pr-data'
import { enqueue } from './queue'
import { clonePath, ioPath } from './repo-paths'
import { CommitError, REASON_NOT_OWNED } from './repo-store'
import { writeRequestFiles } from './request-input'
import {
  buildOutbox,
  type PostDeps,
  type PostsOutcome,
  postedComments,
  runPosts,
} from './request-posts'
import type { FixPusher } from './request-push'
import { asPrData, fetchRequestContext, type RequestContext } from './request-query'
import { parseRequestResult, type RequestResult } from './request-result'
import { readUserSandboxProblem, requestPrompt, requestSessionArgs } from './request-session'
import { readResultFile } from './result-file'
import { prSessionName, type StartOutcome } from './review-session'
import {
  needsYouNotice,
  REASON_COMMIT_ERROR,
  REASON_FIX_BLOCKED,
  REASON_FIX_END_FAILED,
  REASON_FIX_NO_RESULT,
  REASON_FIX_PREPARE_FAILED,
  REASON_FIX_START_FAILED,
  REASON_FIX_STOPPED,
  REASON_FIX_TIMEOUT,
  REASON_FORK,
  REASON_NOT_YOURS,
  REASON_PR_READ_FAILED,
  REASON_READ_AFTER_POSTS,
  REASON_TOO_MANY_COMMENTS,
  reasonCommitFailed,
  reasonFixBadResult,
  reasonUnsafeChange,
  WHERE_DELETED,
} from './round-text'
import {
  type ActiveRound,
  emptyPrState,
  handledEntry,
  MAX_AUTHOR,
  MAX_HELD,
  MAX_POSTED,
  MAX_QUOTE,
  MAX_ROUND_ITEMS,
  MAX_WHERE,
  type Outbox,
  type PostedComment,
  type PrState,
  type Question,
  type ReviewsState,
  type SessionRef,
} from './state'

// The reason of a result with a by commit that is not a commit of the PR.
const BY_OUTSIDE = 'a by commit that is not in the pull request'
// The start of each text of a commit failure that commitFix gives.
const COMMIT_TEXT = reasonCommitFailed('')
// The error of a save of the outbox after the round went. The posts stop before the next write.
const ROUND_GONE = 'the round went'

export interface RequestJobDeps {
  pusher: FixPusher
  // The pusher of an outbox that saved the signed method. It sends the fix commit through GitHub.
  signedPusher: FixPusher
  // The wait between two GitHub writes. The default is a timer.
  sleep?(ms: number): Promise<void>
}

interface Parts {
  pusher: FixPusher
  signedPusher: FixPusher
  sleep(ms: number): Promise<void>
}

const lower = (text: string): string => text.toLowerCase()

// True for no round or a request round. A PR is on one tab only, so a request key has no round
// of the other job. This keeps a round of the other job safe all the same.
const requestRound = (round: ActiveRound | null): boolean =>
  round === null || kindOf(round) === 'request'

// The value of an own key only. An item ID such as "constructor" never reads the prototype.
function own<T>(record: Readonly<Record<string, T>>, key: string): T | undefined {
  return Object.hasOwn(record, key) ? record[key] : undefined
}

// The record without the keys.
function without<T>(
  record: Readonly<Record<string, T>>,
  keys: Iterable<string>,
): Record<string, T> {
  const gone = new Set(keys)
  return Object.fromEntries(Object.entries(record).filter(([key]) => !gone.has(key)))
}

// Cut a text to max characters. Keep a surrogate pair whole.
function cut(text: string, max: number): string {
  if (text.length <= max) return text
  const part = text.slice(0, max)
  return /[\uD800-\uDBFF]$/.test(part) ? part.slice(0, -1) : part
}

// Add the item IDs to the held list. Each ID shows one time. The newest MAX_HELD stay.
export function holdItems(held: readonly string[], ids: Iterable<string>): string[] {
  const add = new Set(ids)
  const list = [...held.filter(id => !add.has(id)), ...add]
  return list.length > MAX_HELD ? list.slice(list.length - MAX_HELD) : list
}

// The states of the posts of each item of the outbox.
function itemStates(outbox: Outbox): Map<string, string[]> {
  const states = new Map<string, string[]>()
  for (const post of outbox.posts) {
    if ('itemId' in post) states.set(post.itemId, [...(states.get(post.itemId) ?? []), post.state])
  }
  return states
}

// The items of the outbox whose posts match the test.
function itemsWhere(outbox: Outbox, test: (states: string[]) => boolean): string[] {
  return [...itemStates(outbox)].filter(([, states]) => test(states)).map(([id]) => id)
}

const allDone = (states: string[]): boolean => states.every(state => state === 'done')

// Each item of the outbox whose posts are all done is handled, and it leaves held. Its last
// reply time is the newest time that the round read, so a later trusted comment makes it work
// again.
function settleDone(p: PrState, outbox: Outbox, now: number): PrState {
  const done = itemsWhere(outbox, allDone)
  const handled = { ...p.handled }
  for (const id of done) handled[id] = handledEntry(now, own(outbox.seen, id) ?? null)
  const gone = new Set(done)
  return { ...p, handled, held: p.held.filter(id => !gone.has(id)) }
}

// The outbox goes. Its done items are handled, and its other items wait in held (ruling P4).
export function dropOutbox(p: PrState, now: number): PrState {
  const { outbox } = p
  if (outbox === null) return p
  const settled = settleDone(p, outbox, now)
  const open = itemsWhere(outbox, states => !allDone(states))
  return { ...settled, held: holdItems(settled.held, open), outbox: null }
}

// removeClones deletes the clones. An outbox whose push did not go refers to a commit in a
// deleted clone, so Try again would fail for ever. So that outbox goes.
export function dropUnsentOutbox(p: PrState, now: number): PrState {
  const push = p.outbox?.posts.find(post => post.kind === 'push')
  if (push === undefined || push.state === 'done') return p
  return dropOutbox(p, now)
}

function addPosted(s: ReviewsState, posted: readonly PostedComment[]): ReviewsState {
  if (posted.length === 0) return s
  return { ...s, posted: [...s.posted, ...posted].slice(-MAX_POSTED) }
}

// The work item of an ID of the context, or null when GitHub does not have it any more.
function itemOf(context: RequestContext, id: string): WorkItem | null {
  if (context.threads.some(t => t.id === id)) return { id, kind: 'thread' }
  if (context.comments.some(c => c.id === id)) return { id, kind: 'comment' }
  if (context.reviews.some(r => r.id === id)) return { id, kind: 'review-body' }
  return null
}

// The GitHub times of the comments of an item, oldest first.
function timesOf(context: RequestContext, item: WorkItem): number[] {
  if (item.kind === 'thread') {
    return (context.threads.find(t => t.id === item.id)?.comments ?? []).map(c => c.createdAt)
  }
  if (item.kind === 'comment') {
    const comment = context.comments.find(c => c.id === item.id)
    return comment === undefined ? [] : [comment.createdAt]
  }
  const review = context.reviews.find(r => r.id === item.id)
  return review === undefined ? [] : [review.submittedAt ?? 0]
}

const firstTime = (context: RequestContext, item: WorkItem): number =>
  timesOf(context, item)[0] ?? 0
const seenUntil = (context: RequestContext, item: WorkItem): number =>
  Math.max(0, ...timesOf(context, item))

// The login of the person who asked for an item.
function authorOf(context: RequestContext, id: string): string | undefined {
  const thread = context.threads.find(t => t.id === id)
  if (thread !== undefined) return thread.comments[0]?.author.login
  return [...context.comments, ...context.reviews].find(c => c.id === id)?.author.login
}

// The place of an item for the Answer panel: the file and the line, or the author.
function whereOf(context: RequestContext, id: string): string {
  const thread = context.threads.find(t => t.id === id)
  if (thread !== undefined) {
    return thread.line === null ? thread.path : `${thread.path} line ${thread.line}`
  }
  const login = authorOf(context, id)
  return login === undefined ? WHERE_DELETED : `Comment from ${login}`
}

// The comment of the reviewer for the quote of the Answer panel: the first comment of a thread,
// or the PR comment or the review. Each value is cut before the save (ruling P14). The body is
// untrusted text. A bad link is left out. A comment that GitHub no longer has gives no quote.
function quoteOf(context: RequestContext, id: string): Quote {
  const thread = context.threads.find(t => t.id === id)
  const comment =
    thread !== undefined
      ? thread.comments[0]
      : [...context.comments, ...context.reviews].find(c => c.id === id)
  if (comment === undefined) return {}
  const quote: Quote = {
    author: cut(comment.author.login, MAX_AUTHOR),
    kind: thread !== undefined ? 'thread' : 'comment',
  }
  // A blank body (a review with no text) gives no quote text.
  if (comment.body.trim() !== '') quote.body = cutQuote(comment.body)
  const url = githubCommentUrl(comment.url)
  if (url !== null) quote.url = url
  return quote
}

type Quote = Pick<Question, 'author' | 'body' | 'kind' | 'url'>

// Cut a quote to MAX_QUOTE characters, with an ellipsis at the end.
function cutQuote(text: string): string {
  return text.length <= MAX_QUOTE ? text : `${cut(text, MAX_QUOTE - 1)}\u2026`
}

// The items that a round wants, oldest first by the time of the first comment. A round takes at
// most MAX_ROUND_ITEMS of them. While automatic rounds are off, only the items of a click or an
// answer: the answered questions, all work and older items after Handle now, and the later
// Copilot items after Handle Copilot comments. So a round that an answer starts handles no other
// new comment.
function chooseItems(
  context: RequestContext,
  lists: WorkLists,
  viewer: string,
  s: ReviewsState,
  prState: PrState,
  autoFix: boolean,
): WorkItem[] {
  const baseline = new Set(s.baseline)
  const since = workSince(s)
  const { work } = splitWork(lists, viewer, prState, baseline, since)
  let chosen = work
  if (!autoFix) {
    const plain = { ...prState, handleCopilot: false }
    const later = new Set(
      splitWork(lists, viewer, plain, baseline, since).laterCopilot.map(i => i.id),
    )
    const answered = (id: string): boolean => {
      const question = own(prState.questions, id)
      return question !== undefined && question.answer !== null
    }
    chosen = work.filter(
      item =>
        prState.handleOlder || answered(item.id) || (prState.handleCopilot && later.has(item.id)),
    )
  }
  return [...chosen].sort((a, b) => firstTime(context, a) - firstTime(context, b))
}

// The logins of the reviewers with an open item that is not in the outbox: a question, a held
// item, or an item that waits (ruling S14). runPosts adds the items of the outbox that are not
// done.
function openLogins(ctx: JobContext, key: string, context: RequestContext, viewer: string) {
  const s = ctx.store.get()
  const prState = s.prs[key] ?? emptyPrState()
  const split = splitWork(context, viewer, prState, new Set(s.baseline), workSince(s))
  const logins = new Set<string>()
  for (const item of [...split.work, ...split.older, ...split.questions, ...split.laterCopilot]) {
    const login = authorOf(context, item.id)
    if (login !== undefined) logins.add(login)
  }
  return logins
}

// The change of a failed round after the choice of its items. The items wait in held, and the
// click that started the round is spent, so the round does not start again at the next poll
// (ruling P5).
function holdOf(
  items: Iterable<string>,
  fn: (p: PrState) => PrState = p => p,
): (p: PrState) => PrState {
  const ids = [...items]
  return (p: PrState): PrState => ({
    ...fn(p),
    handleCopilot: false,
    handleOlder: false,
    held: holdItems(p.held, ids),
  })
}

// A failed round after the choice of its items. The items wait in held (holdOf).
function failRound(
  ctx: JobContext,
  key: string,
  token: number,
  message: string,
  items: Iterable<string>,
  fn: (p: PrState) => PrState = p => p,
): Promise<void> {
  return ctx.fail(key, token, message, holdOf(items, fn))
}

// Clear the round with no error, and keep the error of an earlier round.
async function clearRound(
  ctx: JobContext,
  key: string,
  token: number,
  fn: (p: PrState) => PrState = p => p,
): Promise<void> {
  const saved = await ctx.changeRound(key, token, p => ({ ...fn(p), round: null }))
  ctx.release(key, token)
  if (saved) ctx.deps.changed()
  await ctx.pump()
}

// The commit text that the user reads. commitFix gives fixed texts. Another error can hold a
// path, so it gives a fixed text, and the log gets the error.
function commitText(error: unknown): string {
  const text = messageOf(error)
  return text.startsWith(COMMIT_TEXT) || text === REASON_NOT_OWNED ? text : REASON_COMMIT_ERROR
}

// The open questions that a round added after the start of its session.
function newQuestions(p: PrState | undefined, round: ActiveRound): number {
  const questions: Question[] = Object.values(p?.questions ?? {})
  return questions.filter(q => q.answer === null && q.at >= round.startedAt).length
}

interface SendOptions {
  // After posts that end well, the round stays and goes on with its preparation (ruling P6).
  keep: boolean
  // A context that the round read right before. It is the first read of the posts.
  first?: RequestContext
}

// Steps 7 to 9: send the posts of the outbox of the round. Give true when the posts ended well
// and the round stays (keep).
async function sendPosts(
  ctx: JobContext,
  parts: Parts,
  key: string,
  token: number,
  o: SendOptions,
): Promise<boolean> {
  const { deps, store } = ctx
  const start = store.get().prs[key]
  const round = start?.round ?? null
  const outbox = start?.outbox ?? null
  if (!ctx.alive(key, token) || start === undefined || round === null) return false
  if (outbox === null) {
    // A saved posting round with no outbox: its outbox was damaged. Its items wait.
    await failRound(ctx, key, token, REASON_FIX_END_FAILED, Object.keys(round.items ?? {}))
    return false
  }
  const viewer = deps.viewer()
  if (viewer === null) {
    await ctx.fail(key, token, REASON_GH_FAILED)
    return false
  }
  const pr = prOf(key)
  const clone = clonePath(deps.bifrostHome, pr.owner, pr.repo)
  try {
    const first = o.first ? { context: o.first, ok: true as const } : await read(ctx, key, token)
    const logins = first.ok ? openLogins(ctx, key, first.context, viewer) : new Set<string>()
    let reads = 0
    const postDeps: PostDeps = {
      async commit(post) {
        try {
          const fix = { head: outbox.headSha, message: post.message, paths: post.paths }
          const made = await deps.repos.commitFix(clone, pr.number, fix)
          if (!made.ok) return { message: reasonUnsafeChange(made.rule), ok: false }
          // The files of the session that the commit does not have go.
          await ctx.clean(clone, pr.number, made.sha)
          return { ok: true, sha: made.sha }
        } catch (error) {
          deps.log(`The fix commit of ${key} failed. ${messageOf(error)}`)
          // The line of git goes only to the Event log. The row gets the fixed text.
          if (error instanceof CommitError && error.detail !== undefined) {
            const line = maskToken(error.detail, null)
            deps.eventNotice(`Reviews: the fix commit of ${key} failed. git said: ${line}`)
          }
          return { message: commitText(error), ok: false }
        }
      },
      context: () => (reads++ === 0 ? Promise.resolve(first) : read(ctx, key, token)),
      eventDetail: detail =>
        deps.eventNotice(
          `Reviews: GitHub stopped the updates of ${key}. It said: ${maskToken(detail, null)}`,
        ),
      gh: deps.gh,
      now: deps.now,
      // The method that the outbox saved, not the setting of now (ruling S24).
      push: (fix, context, signed) =>
        (signed ? parts.signedPusher : parts.pusher).push({
          baseRef: context.baseRef,
          clone,
          crossRepository: context.isCrossRepository,
          defaultBranch: context.defaultBranch,
          fix,
          headRef: context.headRef,
          number: pr.number,
          owner: pr.owner,
          repo: pr.repo,
        }),
      async save(next) {
        // A round that went (the PR closed) saves nothing, and its posts stop.
        if (!(await ctx.changeRound(key, token, p => ({ ...p, outbox: next })))) {
          throw new Error(ROUND_GONE)
        }
      },
      sleep: parts.sleep,
      // Stop session in the posting phase.
      stopped: () => store.get().prs[key]?.round?.stoppedByUser === true,
      viewer,
    }
    const outcome = await runPosts(postDeps, key, outbox, start.rerequested, logins)
    if (!ctx.alive(key, token)) return false
    if (outcome.ok) return await postsDone(ctx, key, token, outcome, o.keep)
    await postsFailed(ctx, key, token, outcome)
    return false
  } catch (error) {
    if (!ctx.alive(key, token)) return false
    // A throw, for example of a failed save, stops the posts before the next write. The outbox
    // stays as it was saved, for Try again.
    deps.log(`The posts of a request round of ${key} failed. ${messageOf(error)}`)
    await ctx.fail(key, token, REASON_FIX_END_FAILED)
    return false
  }
}

// A fresh read of the PR, unless the round went.
async function read(
  ctx: JobContext,
  key: string,
  token: number,
): Promise<{ ok: true; context: RequestContext } | ({ ok: false } & ReadFailure)> {
  if (!ctx.alive(key, token)) return { message: REASON_FIX_END_FAILED, ok: false }
  return fetchRequestContext(ctx.deps.gh, prOf(key))
}

// Step 8: each item whose posts are all done is handled, the posted comments and the review
// requests are saved, and the outbox clears. With keep, the round stays. Else it clears, a poll
// follows, and one notification goes out when the round added questions.
async function postsDone(
  ctx: JobContext,
  key: string,
  token: number,
  outcome: Extract<PostsOutcome, { ok: true }>,
  keep: boolean,
): Promise<boolean> {
  const { deps } = ctx
  const now = deps.now()
  const fn = (p: PrState): PrState => ({
    ...settleDone(p, outcome.outbox, now),
    outbox: null,
    rerequested: { ...p.rerequested, ...outcome.rerequested },
  })
  const more = (s: ReviewsState): ReviewsState => addPosted(s, outcome.posted)
  if (keep) {
    const saved = await ctx.changeRound(key, token, p => ({ ...fn(p), lastError: null }), more)
    if (saved) deps.changed()
    return saved
  }
  const before = ctx.store.get().prs[key]
  const asked = before?.round == null ? 0 : newQuestions(before, before.round)
  if (!(await ctx.succeed(key, token, fn, more))) return false
  deps.requestPoll()
  if (asked > 0) deps.notify(needsYouNotice(prOf(key), asked))
  return false
}

// Step 9: the round clears, and the row shows the message. A failed round sends no
// notification.
async function postsFailed(
  ctx: JobContext,
  key: string,
  token: number,
  outcome: Extract<PostsOutcome, { ok: false }>,
): Promise<void> {
  const { deps } = ctx
  const now = deps.now()
  const { outbox } = outcome
  const pr = prOf(key)
  if (outcome.conflict) {
    // The fix did not go. The items of the dropped posts wait, and the outbox goes.
    const dropped = itemsWhere(outbox, states => states.includes('dropped'))
    return ctx.fail(
      key,
      token,
      outcome.message,
      p => {
        const settled = settleDone(p, outbox, now)
        return { ...settled, held: holdItems(settled.held, dropped), outbox: null }
      },
      s => addPosted(s, postedComments(key, outbox, now)),
    )
  }
  if (outcome.dropOutbox) {
    // Ruling P4: the commit, the check of the push target, a push that did not land or a cut
    // context stopped the run, and nothing went to GitHub. That step would fail again, so the
    // outbox goes and its items wait.
    await ctx.clean(clonePath(deps.bifrostHome, pr.owner, pr.repo), pr.number, outbox.headSha)
    const open = itemsWhere(outbox, states => !allDone(states))
    return failRound(ctx, key, token, outcome.message, open, p => ({ ...p, outbox: null }))
  }
  // Try again sends the rest.
  return ctx.fail(key, token, outcome.message, p => ({ ...settleDone(p, outbox, now), outbox }))
}

// Step 6: save the result in one save, then send the posts. context is a fresh read of the PR.
// The items of the round get their kinds and their texts from it.
async function accept(
  ctx: JobContext,
  parts: Parts,
  key: string,
  token: number,
  result: RequestResult,
  context: RequestContext,
): Promise<void> {
  const { deps } = ctx
  const round = ctx.store.get().prs[key]?.round
  if (round == null || round.headSha === null || round.baseSha === undefined) return
  const pr = prOf(key)
  const seen = round.items ?? {}
  const now = deps.now()
  const outbox = buildOutbox({
    context,
    head: round.headSha,
    items: Object.keys(seen).flatMap(id => itemOf(context, id) ?? []),
    mergeBase: round.baseSha,
    now,
    result,
    seen,
    // The outbox saves the method of the push, so a resume uses it (ruling S24).
    signed: deps.settings().reviewsSignedCommits === true,
  })
  const questions: Record<string, Question> = {}
  const handled: PrState['handled'] = {}
  // A new outcome of an item ends its question. A needs-you item gets a new question.
  const answered = result.items.map(item => item.id)
  for (const item of result.items) {
    const until = own(seen, item.id) ?? now
    if (item.outcome === 'no-action') handled[item.id] = handledEntry(now, until)
    if (item.outcome !== 'needs-you') continue
    questions[item.id] = {
      answer: null,
      at: now,
      question: item.question,
      seenUntil: until,
      // Ruling P14: the cut comes before the save, so the state file keeps the question.
      where: cut(whereOf(context, item.id), MAX_WHERE),
      ...quoteOf(context, item.id),
    }
  }
  const saved = await ctx.changeRound(key, token, p => ({
    ...p,
    handled: { ...p.handled, ...handled },
    outbox,
    questions: { ...without(p.questions, answered), ...questions },
    round: p.round === null ? null : { ...p.round, phase: 'posting' },
  }))
  if (!saved) return
  deps.changed()
  if (result.commit === null) {
    await ctx.clean(clonePath(deps.bifrostHome, pr.owner, pr.repo), pr.number, round.headSha)
  }
  await sendPosts(ctx, parts, key, token, { first: context, keep: false })
}

// Step 5: the end check gave a result. A failure cleans the worktree at the head, posts nothing
// and holds the items of the round.
async function endRound(
  ctx: JobContext,
  parts: Parts,
  key: string,
  token: number,
  check: Ended,
): Promise<void> {
  const { deps, store } = ctx
  const round = store.get().prs[key]?.round
  if (!ctx.alive(key, token) || round == null) return
  const pr = prOf(key)
  const clone = clonePath(deps.bifrostHome, pr.owner, pr.repo)
  const items = Object.keys(round.items ?? {})
  const head = round.headSha
  const failEnd = async (message: string): Promise<void> => {
    await ctx.clean(clone, pr.number, head)
    if (ctx.alive(key, token)) await failRound(ctx, key, token, message, items)
  }
  try {
    // A session past the time limit, or a session that asks, gets a stop first.
    const stop = check === 'timeout' || check === 'blocked'
    if (stop && round.shortId !== null) await ctx.stopQuietly(round.shortId)
    if (!ctx.alive(key, token)) return
    // The user stopped Claude. Nothing goes to GitHub.
    if (store.get().prs[key]?.round?.stoppedByUser === true) return failEnd(REASON_FIX_STOPPED)
    if (check === 'timeout') return failEnd(REASON_FIX_TIMEOUT)
    if (check === 'gone') return failEnd(REASON_FIX_STOPPED)
    // A session that asks ends with its result only when the result is valid.
    const bad = (reason: string): string => (check === 'blocked' ? REASON_FIX_BLOCKED : reason)
    const mergeBase = round.baseSha
    if (head === null || mergeBase === undefined) return failEnd(bad(REASON_FIX_NO_RESULT))
    // The changes of the session, before any clean.
    const changed = new Set(await deps.repos.changedPaths(clone, pr.number))
    const file = await readResultFile(resultFileOf(deps.bifrostHome, key))
    if (!ctx.alive(key, token)) return
    if (!file.ok) {
      const missing = file.reason === 'missing'
      return failEnd(bad(missing ? REASON_FIX_NO_RESULT : reasonFixBadResult(file.reason)))
    }
    const expect = { changed, headSha: head, items, pr: prKey(pr.owner, pr.repo, pr.number) }
    const parsed = parseRequestResult(file.text, expect)
    if (!parsed.ok) return failEnd(bad(reasonFixBadResult(parsed.reason)))
    // A by commit must be a commit of the PR: after the merge base, and in the round head.
    for (const item of parsed.result.items) {
      if (item.outcome !== 'fixed' || item.by === undefined) continue
      const inPr =
        item.by !== mergeBase &&
        (await deps.repos.isAncestor(clone, mergeBase, item.by)) &&
        (await deps.repos.isAncestor(clone, item.by, head))
      if (!inPr) return failEnd(bad(reasonFixBadResult(BY_OUTSIDE)))
    }
    const context = await read(ctx, key, token)
    if (!ctx.alive(key, token)) return
    if (!context.ok) {
      // The detail of the read goes to the Event log. The items wait, as in failEnd.
      await ctx.clean(clone, pr.number, head)
      if (ctx.alive(key, token)) await ctx.failRead(key, token, context, holdOf(items))
      return
    }
    await accept(ctx, parts, key, token, parsed.result, context.context)
  } catch (error) {
    if (!ctx.alive(key, token)) return
    // The row gets a fixed text, because a Node or git error can hold a path.
    deps.log(`The end of a request round of ${key} failed. ${messageOf(error)}`)
    await failEnd(REASON_FIX_END_FAILED)
  }
}

// Steps 3 and 4: read the full lists of the PR, choose the items, get the worktree and the input
// files ready, check the user settings, then start the session.
async function runRound(
  ctx: JobContext,
  parts: Parts,
  key: string,
  token: number,
  at: number,
): Promise<void> {
  const { deps, store } = ctx
  const { repos } = deps
  const pr = prOf(key)
  const gen = ctx.generation()
  let clone: string | null = null
  let prepared = false
  // The items of the round, after the choice. A failure from then on holds them.
  let chosen: string[] = []
  // A round that went (the PR closed) removes what it made.
  const gone = async (): Promise<void> => {
    if (prepared && clone !== null) await ctx.removeWorktree(clone, pr.number)
  }
  // True when the round must stop: it went, or the runner stopped (Watch GitHub off) or started
  // again.
  const halted = (): boolean => !ctx.alive(key, token) || ctx.stopped(gen)
  const stopped = (): boolean => store.get().prs[key]?.round?.stoppedByUser === true
  const fail = (message: string): Promise<void> => failRound(ctx, key, token, message, chosen)
  // Stop the round and start no session. A round that is still alive goes back to the queue,
  // as after a restart. A round that the user stopped fails.
  const halt = async (): Promise<void> => {
    await gone()
    if (!ctx.alive(key, token)) return
    if (stopped()) return await fail(REASON_FIX_STOPPED)
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
    // Ruling P6: the writes of an earlier round go first, so a new round never replaces them.
    const sentFirst = store.get().prs[key]?.outbox != null
    if (sentFirst) {
      if (!(await sendPosts(ctx, parts, key, token, { keep: true }))) return
      if (halted()) return await halt()
    }
    const first = await fetchRequestContext(deps.gh, pr)
    if (halted()) return await halt()
    if (!first.ok) {
      // After the waiting updates, the text says that they went to GitHub.
      const after = sentFirst && first.message === REASON_PR_READ_FAILED
      return await ctx.failRead(
        key,
        token,
        after ? { ...first, message: REASON_READ_AFTER_POSTS } : first,
      )
    }
    const { context } = first
    // A merged or closed PR: the next poll drops it.
    if (context.state !== 'OPEN') return await clearRound(ctx, key, token)
    if (lower(context.author) !== lower(viewer)) return await ctx.fail(key, token, REASON_NOT_YOURS)
    if (context.isCrossRepository) return await ctx.fail(key, token, REASON_FORK)
    const polled: PrData | null = deps.minePr(key)
    const lists: WorkLists = polled === null ? context : asPrData(context, polled)
    const s = store.get()
    const prState = s.prs[key] ?? emptyPrState()
    const firstCopilot = firstCopilotReviewId(lists)
    const markRead = (p: PrState): PrState => ({
      ...p,
      checkedAt: context.updatedAt,
      firstCopilotReview: p.firstCopilotReview ?? firstCopilot,
    })
    const autoFix = autoFixOn(deps.settings(), s)
    const wanted = chooseItems(context, lists, viewer, s, prState, autoFix)
    if (context.truncated && wanted.length > 0) {
      // A cut context can hide a reply of an earlier round, and the posts would stop on it. So
      // no session starts. All the wanted items wait in held, and checkedAt is saved, so the
      // next poll does not read the PR again.
      const ids = wanted.map(item => item.id)
      return await failRound(ctx, key, token, REASON_TOO_MANY_COMMENTS, ids, markRead)
    }
    const items = wanted.slice(0, MAX_ROUND_ITEMS)
    if (items.length === 0) {
      // Nothing to do. A click is spent.
      return await clearRound(ctx, key, token, p => ({
        ...markRead(p),
        handleCopilot: false,
        handleOlder: false,
      }))
    }
    if (!(await ctx.changeRound(key, token, markRead))) return
    chosen = items.map(item => item.id)
    // A round can start with no click, so the fetch must never show a prompt.
    const fetched = await repos.fetchPr(clone, pr.number, context.baseRef, { noPrompt: true })
    if (halted()) return await halt()
    const earlier = store.get().prs[key]?.request ?? null
    if (earlier !== null) {
      await ctx.removeSession(earlier)
      await ctx.changeRound(key, token, p => ({ ...p, request: null }))
    }
    if (halted()) return await halt()
    // The session works on the fetched head, also when the PR moved since the read. The push
    // handles a branch that moved.
    const worktree = await repos.prepareWorktree(clone, pr.number, fetched.head)
    prepared = true
    if (halted()) return await halt()
    const files = await writeRequestFiles(
      { repos, skillsDir: deps.skillsDir },
      {
        clone,
        context,
        fetched,
        items,
        number: pr.number,
        questions: prState.questions,
        viewer,
      },
    )
    if (halted()) return await halt()
    if (!files.ok) return await fail(files.message)
    if (stopped()) return await fail(REASON_FIX_STOPPED)
    const name = prSessionName(pr, 'request', ctx.namesInUse(), deps.testHome)
    const args = requestSessionArgs({
      clone,
      ioDir: ioPath(clone, pr.number),
      model: deps.testHome ? 'haiku' : deps.settings().reviewsRequestModel,
      name,
      pluginDir: deps.skillsDir,
      prompt: requestPrompt(files.inputFile),
    })
    // The user settings load in the session. So the check comes right before the start.
    const problem = await readUserSandboxProblem(deps.claudeSettings)
    if (halted()) return await halt()
    if (problem !== null) return await fail(problem)
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
      deps.log(`The request session of ${key} did not start. ${started.message}`)
      await ctx.clean(clone, pr.number, fetched.head)
      const late: SessionRef = { name, sessionId: '' }
      return await failRound(ctx, key, token, REASON_FIX_START_FAILED, chosen, p => ({
        ...p,
        request: late,
      }))
    }
    // Claude Code started a session in the clone, so it trusts the clone.
    ctx.trustedByStart(clone)
    ctx.watchRound(key)
    const request: SessionRef = { name, sessionId: started.sessionId, shortId: started.shortId }
    const seen = Object.fromEntries(items.map(item => [item.id, seenUntil(context, item)]))
    const taken = new Set(chosen)
    // Ruling P5: only a session that started spends the click and takes its items out of held.
    const saved = await ctx.changeRound(key, token, p => ({
      ...p,
      handleCopilot: false,
      handleOlder: false,
      held: p.held.filter(id => !taken.has(id)),
      request,
      round:
        p.round === null
          ? null
          : {
              ...p.round,
              // For a request round, the base of the diff is the merge base. The check of a by
              // commit uses it.
              baseSha: fetched.mergeBase,
              headSha: fetched.head,
              items: seen,
              kind: 'request',
              phase: 'running',
              sessionId: started.sessionId,
              shortId: started.shortId,
              // The time limit counts from the start of the session.
              startedAt: deps.now(),
            },
    }))
    if (!saved) {
      await ctx.removeSession(request)
      return await gone()
    }
    deps.changed()
    // A stop of the user during the start.
    if (stopped()) await ctx.stopQuietly(started.shortId)
  } catch (error) {
    if (!ctx.alive(key, token)) return await gone()
    // The row gets a fixed text, because a Node or git error can hold a path.
    deps.log(`A request round of ${key} failed. ${messageOf(error)}`)
    await fail(REASON_FIX_PREPARE_FAILED)
  }
}

// Step 1: after the drops of each poll. The first poll of R3, and the first poll after a
// turn-on, save fixFrom and queue nothing, so the comments from before wait for Handle now.
// Else each PR of the user with new work, and with no request entry, no round and no outbox,
// gets an entry.
// Ruling S20: at the first poll of R3, a user with Watch GitHub on from before R3 never saw a
// confirm that names the fixes. So the flag autoFixConsent is false, and the setting goes off.
// No automatic round starts until the user turns the setting on with its confirm.
async function trigger(ctx: JobContext, poll: PollData): Promise<void> {
  const { deps, store } = ctx
  const settings = deps.settings()
  if (!settings.reviewsAutoFix) return
  const now = deps.now()
  if (store.get().fixFrom === null) {
    let ask = false
    await store.change(s => {
      if (s.fixFrom !== null) return s
      ask = s.turnedOnAt !== null && s.autoFixConsent === null
      return { ...s, ...(ask ? { autoFixConsent: false } : {}), fixFrom: now }
    })
    // The row counts the comments from before as older now.
    deps.changed()
    if (ask) await turnOffAutoFix(ctx)
    return
  }
  if (!autoFixOn(settings, store.get())) return
  const { reviewsIgnore } = settings
  const wanted = (s: ReviewsState): string[] =>
    poll.mine
      .filter(pr => {
        if (isIgnored(pr.owner, pr.repo, reviewsIgnore)) return false
        const prState = s.prs[pr.key] ?? emptyPrState()
        if (prState.round !== null || prState.outbox !== null) return false
        if (s.queue.some(e => e.key === pr.key && e.kind === 'request')) return false
        const split = splitWork(pr, poll.viewer, prState, new Set(s.baseline), workSince(s))
        return needsRound(pr, split, prState, true)
      })
      .map(pr => pr.key)
  if (wanted(store.get()).length === 0) return
  let added = false
  await store.change(s => {
    const keys = wanted(s)
    added = keys.length > 0
    let { queue } = s
    for (const key of keys) queue = enqueue(queue, { at: now, key, kind: 'request' })
    return added ? { ...s, queue } : s
  })
  if (added) deps.changed()
}

// Turn Handle comments automatically off in the settings, so the row of the setting shows the
// truth. A failure only logs: the saved flag stops the automatic rounds.
async function turnOffAutoFix(ctx: JobContext): Promise<void> {
  try {
    await ctx.deps.turnOffAutoFix?.()
  } catch (error) {
    ctx.deps.log(`Bifrost couldn't turn off the automatic fixes. ${messageOf(error)}`)
  }
}

// The PR state without the fields of the request rounds. handled and rerequested stay.
function clearRequest(p: PrState): PrState {
  const cleared: PrState = {
    ...p,
    handleCopilot: false,
    handleOlder: false,
    held: [],
    outbox: null,
    questions: {},
    request: null,
  }
  return requestRound(p.round) ? { ...cleared, lastError: null, round: null } : cleared
}

// Step 12: the PR merged or closed. Stop its round, post nothing more, remove its session, its
// worktree and its queue entry, and clear its request fields.
async function dropKey(ctx: JobContext, key: string): Promise<void> {
  const { store } = ctx
  const pr = store.get().prs[key]
  const round = pr?.round ?? null
  const mine = requestRound(round)
  if (mine) ctx.forget(key)
  const refs: SessionRef[] = []
  if (pr?.request) refs.push(pr.request)
  if (mine && round?.sessionId != null && round.sessionId !== pr?.request?.sessionId) {
    refs.push({
      name: pr?.request?.name ?? '',
      sessionId: round.sessionId,
      ...(round.shortId === null ? {} : { shortId: round.shortId }),
    })
  }
  for (const ref of refs) await ctx.removeSession(ref)
  const clone = ctx.cloneOfRepo(repoOf(key))
  if (mine && clone !== null) await ctx.removeWorktree(clone, prOf(key).number)
  await store.change(s => {
    const p = s.prs[key]
    // A begin between the first forget and this change gave a new token. It goes too.
    if (requestRound(p?.round ?? null)) ctx.forget(key)
    return {
      ...s,
      prs: p === undefined ? s.prs : { ...s.prs, [key]: clearRequest(p) },
      queue: s.queue.filter(e => !(e.key === key && e.kind === 'request')),
    }
  })
  ctx.deps.changed()
}

export function createRequestJob(deps: RequestJobDeps): Job {
  const parts: Parts = {
    pusher: deps.pusher,
    signedPusher: deps.signedPusher,
    sleep: deps.sleep ?? (ms => new Promise<void>(resolve => setTimeout(resolve, ms))),
  }
  return {
    afterPoll: trigger,
    drop: dropKey,
    end: (ctx, key, token, check) => endRound(ctx, parts, key, token, check),
    kind: 'request',
    // Only a complete answer shows that a PR merged or closed.
    openKeys: poll =>
      !poll.mineHasMore && poll.errors.length === 0 ? new Set(poll.mine.map(p => p.key)) : null,
    // Step 13: a preparing round starts again, a running round waits for its session, and a
    // posting round sends the rest of its outbox. runPosts checks each post that was sending.
    recover(_ctx, _key, round) {
      if (round.phase === 'running') return 'wait'
      if (round.phase === 'posting') return 'resume'
      // The user stopped the round. It must not start again.
      return round.stoppedByUser ? { fail: REASON_FIX_STOPPED } : 'queue'
    },
    ref: 'request',
    // The core starts it after a poll that gives the viewer and lists the PR as open.
    resume: (ctx, key, token) =>
      sendPosts(ctx, parts, key, token, { keep: false }).then(() => undefined),
    run: (ctx, key, token, at) => runRound(ctx, parts, key, token, at),
  }
}
