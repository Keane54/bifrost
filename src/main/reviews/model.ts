import {
  type ClaudeState,
  COPILOT_LOGIN,
  type MyPrRow,
  type ReviewStatus,
  type ReviewsSnapshot,
  type ToReviewRow,
  type ToReviewState,
  TRUSTED_ASSOCIATIONS,
} from '../../shared/reviews'
import { sortMine, sortToReview } from '../../shared/reviews-order'
import type { Settings } from '../../shared/settings'
import type { Author, PollData, PrComment, PrData, PrReview } from './pr-data'
import { emptyPrState, type PrState, type ReviewsState } from './state'

// The pure rules of the Reviews panel. No I/O. The watcher calls these functions.

export function isCopilot(a: Author): boolean {
  return a.bot && a.login === COPILOT_LOGIN
}

export function isTrustedHuman(a: Author, viewer: string): boolean {
  return !a.bot && TRUSTED_ASSOCIATIONS.includes(a.association) && a.login !== viewer
}

// The Copilot review with the earliest submittedAt. A review that is not submitted does not count.
export function firstCopilotReviewId(pr: PrData): string | null {
  let best: PrReview | null = null
  for (const review of pr.reviews) {
    if (!isCopilot(review.author) || review.submittedAt === null) continue
    if (best === null || review.submittedAt < (best.submittedAt ?? Number.POSITIVE_INFINITY)) {
      best = review
    }
  }
  return best === null ? null : best.id
}

export interface WorkItem {
  id: string
  kind: 'thread' | 'comment' | 'review-body'
}

export interface WorkSplit {
  work: WorkItem[]
  older: WorkItem[]
  laterCopilot: WorkItem[]
}

// A handled item is work again when a trusted human commented after the last reply of Bifrost.
// A null lastReplyAt means that the item stays handled.
function commentedAfterReply(
  comments: readonly PrComment[],
  lastReplyAt: number | null,
  viewer: string,
): boolean {
  if (lastReplyAt === null) return false
  return comments.some(c => isTrustedHuman(c.author, viewer) && c.createdAt > lastReplyAt)
}

// Design 10.2. Only a PR with full data (a My PR) gives a useful result.
export function splitWork(
  pr: PrData,
  viewer: string,
  prState: PrState,
  baseline: ReadonlySet<string>,
): WorkSplit {
  const split: WorkSplit = { laterCopilot: [], older: [], work: [] }
  const firstCopilot = firstCopilotReviewId(pr)

  // Put an item in the right list. A reopened item is always work.
  const place = (item: WorkItem, reopened: boolean): void => {
    if (!reopened && !prState.handleOlder && baseline.has(item.id)) split.older.push(item)
    else split.work.push(item)
  }
  const handledState = (id: string) => prState.handled[id]

  for (const thread of pr.threads) {
    const first = thread.comments[0]
    if (thread.isResolved || first === undefined) continue
    const handled = handledState(thread.id)
    const reopened =
      handled !== undefined && commentedAfterReply(thread.comments, handled.lastReplyAt, viewer)
    if (handled !== undefined && !reopened) continue
    const item: WorkItem = { id: thread.id, kind: 'thread' }
    if (isTrustedHuman(first.author, viewer)) {
      place(item, reopened)
    } else if (isCopilot(first.author)) {
      if (thread.reviewId !== null && thread.reviewId === firstCopilot) place(item, reopened)
      else if (prState.handleCopilot) split.work.push(item)
      else split.laterCopilot.push(item)
    }
  }

  for (const review of pr.reviews) {
    if (!isTrustedHuman(review.author, viewer) || review.body.trim() === '') continue
    if (handledState(review.id) !== undefined) continue
    place({ id: review.id, kind: 'review-body' }, false)
  }

  for (const comment of pr.comments) {
    if (!isTrustedHuman(comment.author, viewer)) continue
    if (handledState(comment.id) !== undefined) continue
    place({ id: comment.id, kind: 'comment' }, false)
  }

  return split
}

// The latest decision of each human reviewer. A comment review does not change a decision.
function humanDecisions(pr: PrData, viewer: string): Map<string, PrReview> {
  const latest = new Map<string, PrReview>()
  for (const review of pr.reviews) {
    const { author } = review
    if (author.bot || author.login === viewer || review.submittedAt === null) continue
    if (review.state === 'COMMENTED' || review.state === 'PENDING') continue
    const before = latest.get(author.login)
    if (before === undefined || (before.submittedAt ?? 0) <= review.submittedAt) {
      latest.set(author.login, review)
    }
  }
  return latest
}

// Design 9.2. The first match wins.
export function reviewStatus(pr: PrData, viewer: string, split: WorkSplit): ReviewStatus {
  const decisions = [...humanDecisions(pr, viewer).values()]
  if (decisions.some(r => r.state === 'CHANGES_REQUESTED')) return 'changes-requested'
  const open = split.work.length > 0 || split.older.some(item => item.kind === 'thread')
  if (open) return 'comments'
  if (decisions.some(r => r.state === 'APPROVED')) return 'approved'
  return 'pending'
}

export interface RequestContext {
  now: number
  known: { baseline: boolean } | undefined
  pauseEndsAt: number | null
  teamRequests: boolean
  session: 'reviewing' | 'queued' | null
}

// Design 8.2. The result is null for a team request when team requests are off.
export function toReviewState(
  pr: PrData,
  viewer: string,
  ctx: RequestContext,
): ToReviewState | null {
  if (ctx.session !== null) return ctx.session
  if (pr.viewerPendingReviewId !== null) return 'draft-ready'
  if (ctx.pauseEndsAt !== null && ctx.now < ctx.pauseEndsAt) return 'paused'
  if (pr.reviewDecision === 'APPROVED') return 'approved-by-others'
  if (!pr.requestedUsers.includes(viewer)) return ctx.teamRequests ? 'team' : null
  return ctx.known?.baseline === true ? 'waiting' : 'new'
}

// The ignore list holds "owner/*" or "owner/repo". The match ignores case.
export function isIgnored(owner: string, repo: string, ignore: readonly string[]): boolean {
  const full = `${owner}/${repo}`.toLowerCase()
  const all = `${owner}/*`.toLowerCase()
  return ignore.some(entry => {
    const value = entry.trim().toLowerCase()
    return value === full || value === all
  })
}

export interface SnapshotInput {
  poll: PollData
  state: ReviewsState
  now: number
  settings: Pick<Settings, 'reviewsTeamRequests' | 'reviewsIgnore'>
  session(key: string): 'reviewing' | 'queued' | null
  claude(key: string): {
    claude: ClaudeState
    fixing: number
    error: string | null
    sessionId: string | null
  }
}

function reviewers(pr: PrData, viewer: string): string[] {
  const names: string[] = []
  const add = (login: string): void => {
    if (login === viewer) return
    const name = login === COPILOT_LOGIN ? 'Copilot' : login
    if (!names.includes(name)) names.push(name)
  }
  for (const login of pr.requestedUsers) add(login)
  for (const review of pr.reviews) add(review.author.login)
  return names
}

export function buildSnapshot(input: SnapshotInput): ReviewsSnapshot {
  const { poll, state, now, settings } = input
  const baseline = new Set(state.baseline)
  const toReview: ToReviewRow[] = []
  for (const pr of poll.toReview) {
    if (isIgnored(pr.owner, pr.repo, settings.reviewsIgnore)) continue
    const pauseEndsAt = state.pauses[pr.key] ?? null
    const rowState = toReviewState(pr, poll.viewer, {
      known: state.requests[pr.key],
      now,
      pauseEndsAt,
      session: input.session(pr.key),
      teamRequests: settings.reviewsTeamRequests,
    })
    if (rowState === null) continue
    toReview.push({
      additions: pr.additions,
      author: pr.author,
      deletions: pr.deletions,
      flash: rowState === 'new',
      key: pr.key,
      number: pr.number,
      owner: pr.owner,
      pauseEndsAt: rowState === 'paused' ? pauseEndsAt : null,
      repo: pr.repo,
      requestedAt: pr.requestedAt,
      sessionId: null,
      state: rowState,
      title: pr.title,
    })
  }
  const mine: MyPrRow[] = []
  for (const pr of poll.mine) {
    if (isIgnored(pr.owner, pr.repo, settings.reviewsIgnore)) continue
    const prState = state.prs[pr.key] ?? emptyPrState()
    const split = splitWork(pr, poll.viewer, prState, baseline)
    const claude = input.claude(pr.key)
    mine.push({
      claude: claude.claude,
      error: claude.error,
      failedChecks: pr.failedChecks,
      fixing: claude.fixing,
      key: pr.key,
      laterCopilot: split.laterCopilot.length,
      number: pr.number,
      olderOpen: split.older.length,
      owner: pr.owner,
      repo: pr.repo,
      reviewers: reviewers(pr, poll.viewer),
      sessionId: claude.sessionId,
      status: reviewStatus(pr, poll.viewer, split),
      title: pr.title,
      updatedAt: pr.updatedAt,
    })
  }
  return {
    availability: 'ok',
    message: null,
    mine: sortMine(mine),
    polledAt: now,
    toReview: sortToReview(toReview),
    trust: [],
  }
}

// The items to mark as seen at the first turn-on, and the To review keys that are open then.
// A truncated PR adds no items, because its lists are not complete.
export function baselineOf(poll: PollData): { items: string[]; requests: string[] } {
  const items = new Set<string>()
  for (const pr of poll.mine) {
    if (pr.truncated) continue
    const split = splitWork(pr, poll.viewer, emptyPrState(), new Set())
    for (const item of [...split.work, ...split.older]) items.add(item.id)
  }
  return { items: [...items], requests: poll.toReview.map(pr => pr.key) }
}
