// The outbox of a request round: the fix commit, the push, then the GitHub writes, in the order
// of buildOutbox. runPosts saves each post as sending before its write and as done after it. So
// after a quit, or after a write with an unknown result, the next run checks GitHub first and
// never sends a post two times. Each write goes to a thread or a comment that is in the fresh
// context of the PR. The only writes are the push of the pusher and the functions of
// request-writes.ts.

import { prKey as keyOf, REASON_GH_TIMEOUT } from '../../shared/reviews'
import type { Gh } from './gh'
import { isTrustedHuman, type WorkItem } from './model'
import type { Author, PrComment } from './pr-data'
import type { PushOutcome } from './request-push'
import type { RequestContext } from './request-query'
import type { RequestResult } from './request-result'
import {
  commentOnPr,
  defuseMentions,
  fixedBy,
  quoteRequest,
  replyToThread,
  requestReviewer,
  resolveThread,
  ZWSP,
} from './request-writes'
import { BAD_ANSWER } from './review-query'
import {
  REASON_BAD_PR,
  REASON_FIX_PR_CLOSED,
  REASON_FORK,
  REASON_NOT_RESOLVED,
  REASON_NOT_YOURS,
  REASON_OWN_PENDING,
  REASON_POSTS_READ_FAILED,
  REASON_PR_READ_FAILED,
  REASON_PUSH_CONFLICT,
  REASON_PUSH_TARGET,
  REASON_REPLY_PENDING,
  REASON_TOO_MANY_COMMENTS,
  REASON_WRITE_TIMEOUT,
  REASON_WRITE_UNREADABLE,
  reasonPostsStopped,
  reasonUserStoppedPosts,
} from './round-text'
import type { Outbox, Post, PostedComment } from './state'

// The wait between two writes, against the secondary rate limit of GitHub.
export const POST_GAP_MS = 1_000
// A reply or a PR comment that Bifrost sent has a GitHub time after the start of the outbox. The
// check also accepts a time up to this long before the start, because the clock of GitHub and
// the clock of this computer can differ.
export const SENT_WINDOW_MS = 5 * 60_000

type CommitPost = Post & { kind: 'commit' }
type TextPost = Post & { kind: 'reply' | 'comment' }

export interface PostDeps {
  gh: Gh
  viewer: string
  now(): number
  sleep(ms: number): Promise<void>
  context(): Promise<
    { ok: true; context: RequestContext } | { ok: false; message: string; detail?: string }
  >
  commit(post: CommitPost): Promise<{ ok: true; sha: string } | { ok: false; message: string }>
  // signed is the method that the outbox saved: true sends the fix commit through GitHub.
  push(fix: string, context: RequestContext, signed: boolean): Promise<PushOutcome>
  // A failed save rejects. The run then stops before the next write.
  save(outbox: Outbox): Promise<void>
  // True when the user stopped the round. The run then stops before the next write.
  stopped(): boolean
  // The raw error text of gh or GitHub for a failed read or write. It goes only to the Event log.
  // The row gets the fixed text of the failure.
  eventDetail(detail: string): void
}

// conflict is true when the push did not go and Bifrost dropped the posts of the fix. In a
// failure, wrote is true when a write of the outbox reached GitHub or can have reached it, in
// this run or in an earlier run. dropOutbox is true when wrote is false and the run stopped at a
// step that fails again in each run: the commit, the check of the push target, a push that did
// not land, or a cut context. Then the outbox can go and its items can wait (ruling P4). posted
// holds the comments of a run that ended well.
export type PostsOutcome =
  | { ok: true; outbox: Outbox; posted: PostedComment[]; rerequested: Record<string, string> }
  | {
      ok: false
      outbox: Outbox
      message: string
      conflict: boolean
      wrote: boolean
      dropOutbox: boolean
    }

const COMMIT_ID = 'commit'
const PUSH_ID = 'push'
const REREQUEST_ID = 'rerequest'

// The text of the request that a PR comment quotes: a top-level comment or a review body.
function requestBody(context: RequestContext, item: WorkItem): string {
  const list = item.kind === 'comment' ? context.comments : context.reviews
  return list.find(entry => entry.id === item.id)?.body ?? ''
}

// The writes of a valid result. A fixed or no-fix thread gets a reply and a resolve. A fixed or
// no-fix PR comment or review body gets a PR comment that quotes the request. A no-action or
// needs-you item gets no post. With signed, the push post saves that the fix commit goes through
// GitHub (ruling S24).
export function buildOutbox(o: {
  result: RequestResult
  context: RequestContext
  items: readonly WorkItem[]
  seen: Record<string, number>
  head: string
  mergeBase: string
  now: number
  signed?: boolean
}): Outbox {
  const posts: Post[] = []
  if (o.result.commit !== null) {
    const { message, paths } = o.result.commit
    posts.push({ id: COMMIT_ID, kind: 'commit', message, paths: [...paths], state: 'todo' })
    posts.push({ id: PUSH_ID, kind: 'push', state: 'todo', ...(o.signed ? { signed: true } : {}) })
  }
  const outcomes = new Map(o.result.items.map(item => [item.id, item]))
  // A second post with the same ID would make the state file refuse the whole outbox.
  const seenIds = new Set<string>()
  for (const item of o.items) {
    if (seenIds.has(item.id)) continue
    seenIds.add(item.id)
    const outcome = outcomes.get(item.id)
    if (outcome?.outcome !== 'fixed' && outcome?.outcome !== 'no-fix') continue
    // A text of null is the "Fixed by" text.
    const sent =
      outcome.outcome === 'no-fix'
        ? { text: outcome.reply }
        : { text: null, ...(outcome.by === undefined ? {} : { by: outcome.by }) }
    const itemId = item.id
    if (item.kind === 'thread') {
      posts.push({ id: `reply:${itemId}`, itemId, kind: 'reply', state: 'todo', ...sent })
      posts.push({ id: `resolve:${itemId}`, itemId, kind: 'resolve', state: 'todo' })
    } else {
      const quote = quoteRequest(requestBody(o.context, item))
      posts.push({
        id: `comment:${itemId}`,
        itemId,
        kind: 'comment',
        quote,
        state: 'todo',
        ...sent,
      })
    }
  }
  posts.push({ id: REREQUEST_ID, kind: 'rerequest', state: 'todo' })
  return {
    headSha: o.head,
    mergeBase: o.mergeBase,
    posts,
    seen: { ...o.seen },
    startedAt: o.now,
  }
}

const isText = (post: Post): post is TextPost => post.kind === 'reply' || post.kind === 'comment'
// A fixed item with no by is fixed by the commit of the round. Its post needs the push.
const needsPush = (post: Post): boolean => isText(post) && post.text === null && !post.by
const lower = (login: string): string => login.toLowerCase()

// The value of an own key only. A key such as "constructor" never reads the prototype.
const own = <T>(record: Readonly<Record<string, T>>, key: string): T | undefined =>
  Object.hasOwn(record, key) ? record[key] : undefined

// The commit that the "Fixed by" text names. After a merge, the push gives the merge commit, but
// the text names the local fix commit. A signed push gives the commit that GitHub made from the
// fix commit, and the text names that commit, because the local commit is not on GitHub (ruling
// S26).
function fixOf(outbox: Outbox): string | undefined {
  const push = outbox.posts.find(post => post.kind === 'push')
  if (push?.kind === 'push' && push.signed === true) return push.sha
  return outbox.posts.find((post): post is CommitPost => post.kind === 'commit')?.sha
}

// The text that a reply or a PR comment sends, or null when the "Fixed by" text has no commit.
// Each text goes through defuseMentions one time. The quote went through it in buildOutbox.
function bodyOf(post: TextPost, outbox: Outbox): string | null {
  let text = post.text
  if (text === null) {
    const sha = post.by ?? fixOf(outbox)
    if (sha === undefined) return null
    text = fixedBy(sha)
  }
  const sent = defuseMentions(text)
  return post.kind === 'comment' && post.quote !== '' ? `${post.quote}\n\n${sent}` : sent
}

// The comments that Bifrost posted, or found on GitHub, for the done posts of the outbox.
export function postedComments(prKey: string, outbox: Outbox, at: number): PostedComment[] {
  const out: PostedComment[] = []
  for (const post of outbox.posts) {
    if (!isText(post) || post.state !== 'done' || post.commentId === undefined) continue
    const body = bodyOf(post, outbox)
    if (body !== null) out.push({ at, body, id: post.commentId, prKey })
  }
  return out
}

// GitHub can keep a body with other line ends, or with no zero-width space.
const flatText = (text: string): string => text.replace(/\r\n?/g, '\n').replaceAll(ZWSP, '').trim()
const sameText = (a: string, b: string): boolean => flatText(a) === flatText(b)

// The read texts that say GitHub or Bifrost will try again. In reasonPostsStopped, the user
// chooses Try again, and the text names GitHub already.
const READ_TEXT: Readonly<Record<string, string>> = {
  [BAD_ANSWER]: REASON_WRITE_UNREADABLE,
  [REASON_GH_TIMEOUT]: REASON_WRITE_TIMEOUT,
  [REASON_PR_READ_FAILED]: REASON_POSTS_READ_FAILED,
}

// Why Bifrost must not write on this PR, or null.
function refusal(context: RequestContext, viewer: string, key: string): string | null {
  if (lower(keyOf(context.owner, context.repo, context.number)) !== lower(key)) {
    return REASON_BAD_PR
  }
  if (context.state !== 'OPEN') return REASON_FIX_PR_CLOSED
  if (viewer === '' || lower(context.author) !== lower(viewer)) return REASON_NOT_YOURS
  if (context.isCrossRepository) return REASON_FORK
  if (context.viewerPending) return REASON_OWN_PENDING
  return null
}

// The login of the person who asked for an item: the first comment of a thread, a PR comment
// or a review body.
function authorOf(context: RequestContext, itemId: string): string | undefined {
  const thread = context.threads.find(t => t.id === itemId)
  if (thread !== undefined) return thread.comments[0]?.author.login
  return [...context.comments, ...context.reviews].find(c => c.id === itemId)?.author.login
}

type Step = PostsOutcome | null

// Send the posts of the outbox that are not done or dropped, in order. The outbox that the
// outcome gives holds the state of each post. openLogins holds each reviewer with an open item
// that is not in the outbox: a question, a held item or an item that waits for Handle now.
export async function runPosts(
  deps: PostDeps,
  prKey: string,
  start: Outbox,
  rerequested: Readonly<Record<string, string>>,
  openLogins: ReadonlySet<string>,
): Promise<PostsOutcome> {
  const outbox = structuredClone(start)
  const { posts } = outbox
  const viewer = lower(deps.viewer)
  // A post that is sending now was cut off by a quit, or had an unknown result.
  const cutOff = new Set(posts.filter(post => post.state === 'sending').map(post => post.id))
  const nextRequested: Record<string, string> = { ...rerequested }
  // A push of an earlier run that did not go. The other posts of that run were sent or wait here.
  let conflict = posts.some(post => post.kind === 'push' && post.state === 'dropped')
    ? REASON_PUSH_CONFLICT
    : null
  // True after the first write of this run, for the wait between two writes.
  let started = false
  // A post of an earlier run that is done or sending can have reached GitHub. A done post that
  // wrote nothing also counts, so the value can be true with no write, but never false after one.
  // The push has its own value, because a fetch after a failed push can show that GitHub does not
  // have the fix.
  const sent = (post: Post): boolean => post.state === 'done' || post.state === 'sending'
  let wrote = posts.some(post => post.kind !== 'commit' && post.kind !== 'push' && sent(post))
  let pushed = posts.some(post => post.kind === 'push' && sent(post))

  // drop: the step that stopped the run fails again in each run (ruling P4).
  const stop = (message: string, drop = false): PostsOutcome => ({
    conflict: false,
    dropOutbox: drop && !wrote && !pushed,
    message,
    ok: false,
    outbox,
    wrote: wrote || pushed,
  })
  // The count of the updates that are done, and of all updates. It leaves out the local commit.
  const counts = (): [number, number] => {
    const updates = posts.filter(post => post.kind !== 'commit' && post.state !== 'dropped')
    return [updates.filter(post => post.state === 'done').length, updates.length]
  }
  // A failed GitHub write or read. The detail goes to the Event log.
  const failed = (message: string, detail?: string): PostsOutcome => {
    if (detail !== undefined) deps.eventDetail(detail)
    const reason = Object.hasOwn(READ_TEXT, message) ? (READ_TEXT[message] ?? message) : message
    return stop(reasonPostsStopped(...counts(), reason))
  }
  const save = (): Promise<void> => deps.save(structuredClone(outbox))
  const mark = async (post: Post, state: Post['state']): Promise<void> => {
    post.state = state
    await save()
  }
  // End a post with no write, and go on with the next post.
  const settle = async (post: Post, state: 'done' | 'dropped'): Promise<Step> => {
    await mark(post, state)
    return null
  }
  // Wait between two writes, then save the post as sending. A GitHub API write can reach
  // GitHub from this point. The push sets pushed from its outcome. A stop of the user ends the
  // run here, before the write.
  const beforeWrite = async (post: Post): Promise<Step> => {
    if (started) await deps.sleep(POST_GAP_MS)
    if (deps.stopped()) return stop(reasonUserStoppedPosts(...counts()))
    started = true
    await mark(post, 'sending')
    if (post.kind !== 'push') wrote = true
    return null
  }
  const isViewer = (a: Author): boolean => lower(a.login) === viewer
  const sentBefore = (comments: readonly PrComment[], body: string): PrComment | undefined =>
    comments.find(
      c =>
        isViewer(c.author) &&
        sameText(c.body, body) &&
        c.createdAt >= outbox.startedAt - SENT_WINDOW_MS,
    )
  const replyOf = (itemId: string): Post | undefined =>
    posts.find(post => post.kind === 'reply' && post.itemId === itemId)

  const read = await deps.context()
  if (!read.ok) return failed(read.message, read.detail)
  const why = refusal(read.context, deps.viewer, prKey)
  if (why !== null) return stop(why)
  // A cut context can hide a sent reply or show a thread as gone. So no post runs on it.
  if (read.context.truncated) return stop(REASON_TOO_MANY_COMMENTS, true)
  const { context } = read
  const pushDone = (): boolean => posts.some(post => post.kind === 'push' && post.state === 'done')

  const runCommit = async (post: CommitPost): Promise<Step> => {
    await mark(post, 'sending')
    // A second commitFix gives the same commit, so a cut-off commit runs again.
    const r = await deps.commit(post)
    // The text of a commit failure is shown as it is.
    if (!r.ok) return stop(r.message, true)
    post.sha = r.sha
    await mark(post, 'done')
    return null
  }

  const runPush = async (post: Post & { kind: 'push' }): Promise<Step> => {
    const commit = posts.find((p): p is CommitPost => p.kind === 'commit')
    const fix = commit?.state === 'done' ? commit.sha : undefined
    if (fix === undefined) return stop(REASON_PUSH_TARGET, true)
    // The pusher fetches the branch first and pushes nothing when the fix is there. So a cut-off
    // push runs again.
    const halt = await beforeWrite(post)
    if (halt !== null) return halt
    const r = await deps.push(fix, context, post.signed === true)
    if (r.ok) {
      pushed = true
      post.sha = r.sha
      await mark(post, 'done')
      return null
    }
    if (r.detail !== undefined) deps.eventDetail(r.detail)
    // The branch on GitHub does not have the fix, so no push of this outbox is on GitHub, also
    // not a cut-off push of an earlier run. A signed push also gives not-landed when it refused
    // the fix before any write.
    if (r.reason === 'not-landed') {
      pushed = false
      return stop(r.message, true)
    }
    // The pusher checks the target before any network call, so this push wrote nothing. Each
    // other refusal can come after the push reached GitHub.
    if (r.reason === 'refused' && r.message === REASON_PUSH_TARGET) return stop(r.message, true)
    if (r.reason === 'refused') {
      pushed = true
      return stop(r.message)
    }
    // A conflict or a branch that kept moving pushes nothing. The fix did not go. Its posts must
    // not say that it did.
    for (const p of posts) {
      if (p.kind === 'commit' || p.kind === 'push' || (needsPush(p) && p.state !== 'done')) {
        p.state = 'dropped'
      }
    }
    for (const p of posts) {
      if (p.kind === 'resolve' && replyOf(p.itemId)?.state === 'dropped') p.state = 'dropped'
    }
    conflict = r.message
    await save()
    return null
  }

  const runReply = async (post: Post & { kind: 'reply' }): Promise<Step> => {
    const thread = context.threads.find(t => t.id === post.itemId)
    // The thread is gone, so there is nothing to reply to.
    if (thread === undefined) return settle(post, 'done')
    const body = needsPush(post) && !pushDone() ? null : bodyOf(post, outbox)
    if (body === null) return settle(post, 'dropped')
    const found = cutOff.has(post.id) ? sentBefore(thread.comments, body) : undefined
    if (found !== undefined) {
      post.commentId = found.id
      return settle(post, 'done')
    }
    const halt = await beforeWrite(post)
    if (halt !== null) return halt
    const r = await replyToThread(deps.gh, { body, threadId: thread.id })
    if (!r.ok) return failed(r.message, r.detail)
    // The reply is in a draft review of the user. The post stays sending, so the next run looks
    // for the reply on GitHub after the user submits or deletes the draft.
    if (r.value.pending) return stop(REASON_REPLY_PENDING)
    post.commentId = r.value.id
    await mark(post, 'done')
    return null
  }

  const runResolve = async (post: Post & { kind: 'resolve' }): Promise<Step> => {
    const thread = context.threads.find(t => t.id === post.itemId)
    if (thread === undefined || thread.isResolved) return settle(post, 'done')
    // A resolve runs only after the reply of its item.
    if (replyOf(post.itemId)?.state !== 'done') return settle(post, 'dropped')
    // A trusted person wrote in the thread after the round read it. The thread stays open, and
    // the next round handles the new comment. With no seen time, each trusted comment is newer.
    const seen = own(outbox.seen, post.itemId) ?? Number.NEGATIVE_INFINITY
    const newer = thread.comments.some(
      c => isTrustedHuman(c.author, deps.viewer) && !isViewer(c.author) && c.createdAt > seen,
    )
    if (newer) return settle(post, 'dropped')
    const halt = await beforeWrite(post)
    if (halt !== null) return halt
    const r = await resolveThread(deps.gh, thread.id)
    if (!r.ok) return failed(r.message, r.detail)
    if (!r.value.resolved) return failed(REASON_NOT_RESOLVED)
    await mark(post, 'done')
    return null
  }

  const runComment = async (post: Post & { kind: 'comment' }): Promise<Step> => {
    const known = [...context.comments, ...context.reviews].some(c => c.id === post.itemId)
    if (!known) return settle(post, 'done')
    const body = needsPush(post) && !pushDone() ? null : bodyOf(post, outbox)
    if (body === null) return settle(post, 'dropped')
    const found = cutOff.has(post.id) ? sentBefore(context.comments, body) : undefined
    if (found !== undefined) {
      post.commentId = found.id
      return settle(post, 'done')
    }
    const halt = await beforeWrite(post)
    if (halt !== null) return halt
    const r = await commentOnPr(deps.gh, { body, prId: context.id })
    if (!r.ok) return failed(r.message, r.detail)
    post.commentId = r.value.id
    await mark(post, 'done')
    return null
  }

  // Ask each human reviewer whose latest review requests changes and whose threads are all
  // resolved for a new review. Never Copilot or another bot, and one time for each head.
  const runRerequest = async (post: Post & { kind: 'rerequest' }): Promise<Step> => {
    const again = await deps.context()
    if (!again.ok) return failed(again.message, again.detail)
    const refused = refusal(again.context, deps.viewer, prKey)
    if (refused !== null) return stop(refused)
    // A cut context can hide an open thread or a decision, so Bifrost asks nobody.
    if (again.context.truncated) return settle(post, 'dropped')
    const now = again.context
    const head = now.headSha
    const asked = new Set(now.requested.map(lower))
    // A login of a cut-off run that GitHub has as requested was asked before the quit.
    if (cutOff.has(post.id)) {
      for (const login of post.logins ?? []) {
        if (asked.has(lower(login))) nextRequested[login] = head
      }
    }
    const threadsOf = (login: string) =>
      now.threads.filter(t => lower(t.comments[0]?.author.login ?? '') === lower(login))
    // A reviewer with an open item waits: an item of the input, or an item of this outbox with a
    // post that is not done, for example a fix that a push conflict dropped.
    const open = new Set([...openLogins].map(lower))
    for (const p of posts) {
      if (!('itemId' in p) || p.state === 'done') continue
      const author = authorOf(context, p.itemId) ?? authorOf(now, p.itemId)
      if (author !== undefined) open.add(lower(author))
    }
    const targets = now.decisions.filter(
      d =>
        d.state === 'CHANGES_REQUESTED' &&
        !d.bot &&
        d.userId !== null &&
        lower(d.login) !== viewer &&
        !asked.has(lower(d.login)) &&
        !open.has(lower(d.login)) &&
        threadsOf(d.login).every(t => t.isResolved) &&
        own(nextRequested, d.login) !== head,
    )
    if (targets.length === 0) return settle(post, 'done')
    post.logins = targets.map(d => d.login)
    for (const target of targets) {
      const halt = await beforeWrite(post)
      if (halt !== null) return halt
      const r = await requestReviewer(deps.gh, { prId: now.id, userId: target.userId ?? '' })
      if (!r.ok) return failed(r.message, r.detail)
      nextRequested[target.login] = head
    }
    await mark(post, 'done')
    return null
  }

  for (const post of posts) {
    if (post.state === 'done' || post.state === 'dropped') continue
    let step: Step = null
    switch (post.kind) {
      case 'commit':
        step = await runCommit(post)
        break
      case 'push':
        step = await runPush(post)
        break
      case 'reply':
        step = await runReply(post)
        break
      case 'resolve':
        step = await runResolve(post)
        break
      case 'comment':
        step = await runComment(post)
        break
      case 'rerequest':
        step = await runRerequest(post)
        break
    }
    if (step !== null) return step
  }

  if (conflict !== null) {
    return {
      conflict: true,
      dropOutbox: false,
      message: conflict,
      ok: false,
      outbox,
      wrote: wrote || pushed,
    }
  }
  return {
    ok: true,
    outbox,
    posted: postedComments(prKey, outbox, deps.now()),
    rerequested: nextRequested,
  }
}
