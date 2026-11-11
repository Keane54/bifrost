import {
  type ClaudeState,
  COPILOT_LOGIN,
  type MyPrRow,
  type ReviewStatus,
  type ReviewsSnapshot,
  type ToReviewRow,
  type ToReviewState,
  TRUSTED_ASSOCIATIONS,
  type TrustNeed,
} from '../../shared/reviews'
import { sortMine, sortToReview } from '../../shared/reviews-order'
import type { Settings } from '../../shared/settings'
import type { Author, PollData, PrComment, PrData, PrReview } from './pr-data'
import { emptyPrState, type PrState, type RecommendationMark, type ReviewsState } from './state'

// The pure rules of the Reviews panel. No I/O. The watcher calls these functions.

export function isCopilot(a: Author): boolean {
  return a.bot && a.login === COPILOT_LOGIN
}

export function isTrustedHuman(a: Author, viewer: string): boolean {
  return !a.bot && TRUSTED_ASSOCIATIONS.includes(a.association) && a.login !== viewer
}

// The Copilot review with the earliest submittedAt. A review that is not submitted does not count.
export function firstCopilotReviewId(pr: PrData): string | null {
  let bestId: string | null = null
  let bestTime = Number.POSITIVE_INFINITY
  for (const review of pr.reviews) {
    if (!isCopilot(review.author) || review.submittedAt === null) continue
    if (bestId === null || review.submittedAt < bestTime) {
      bestId = review.id
      bestTime = review.submittedAt
    }
  }
  return bestId
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
// An item that is not in the baseline, but was created before turnedOnAt, is also older.
// This covers the items beyond the page that the poll reads. A null turnedOnAt gives no time rule.
export function splitWork(
  pr: PrData,
  viewer: string,
  prState: PrState,
  baseline: ReadonlySet<string>,
  turnedOnAt: number | null,
): WorkSplit {
  const split: WorkSplit = { laterCopilot: [], older: [], work: [] }
  const firstCopilot = firstCopilotReviewId(pr)

  // Put an item in the right list. A reopened item is always work.
  const place = (item: WorkItem, createdAt: number | null, reopened: boolean): void => {
    const before = turnedOnAt !== null && createdAt !== null && createdAt < turnedOnAt
    if (!reopened && !prState.handleOlder && (baseline.has(item.id) || before)) {
      split.older.push(item)
    } else {
      split.work.push(item)
    }
  }

  for (const thread of pr.threads) {
    const first = thread.comments[0]
    if (thread.isResolved || first === undefined) continue
    const handled = prState.handled[thread.id]
    const reopened =
      handled !== undefined && commentedAfterReply(thread.comments, handled.lastReplyAt, viewer)
    if (handled !== undefined && !reopened) continue
    const item: WorkItem = { id: thread.id, kind: 'thread' }
    if (reopened) {
      // A reopened item is always work, also a later Copilot thread.
      if (isTrustedHuman(first.author, viewer) || isCopilot(first.author)) split.work.push(item)
    } else if (isTrustedHuman(first.author, viewer)) {
      place(item, first.createdAt, false)
    } else if (isCopilot(first.author)) {
      if (thread.reviewId !== null && thread.reviewId === firstCopilot) {
        place(item, first.createdAt, false)
      } else if (prState.handleCopilot) split.work.push(item)
      else split.laterCopilot.push(item)
    }
  }

  for (const review of pr.reviews) {
    if (!isTrustedHuman(review.author, viewer) || review.body.trim() === '') continue
    // An approval or a dismissed review needs no action.
    if (review.state !== 'CHANGES_REQUESTED' && review.state !== 'COMMENTED') continue
    if (prState.handled[review.id] !== undefined) continue
    place({ id: review.id, kind: 'review-body' }, review.submittedAt, false)
  }

  for (const comment of pr.comments) {
    if (!isTrustedHuman(comment.author, viewer)) continue
    if (prState.handled[comment.id] !== undefined) continue
    place({ id: comment.id, kind: 'comment' }, comment.createdAt, false)
  }

  return split
}

// The latest decision of each human reviewer. A comment review does not change a decision.
// The decisions come from latestOpinionatedReviews, not from the first page of reviews
// (final review I2).
function humanDecisions(pr: PrData, viewer: string): PrReview[] {
  const latest = new Map<string, { review: PrReview; time: number }>()
  for (const review of pr.decisions) {
    const { author } = review
    if (author.bot || author.login === viewer || review.submittedAt === null) continue
    if (review.state === 'COMMENTED' || review.state === 'PENDING') continue
    const before = latest.get(author.login)
    if (before === undefined || before.time <= review.submittedAt) {
      latest.set(author.login, { review, time: review.submittedAt })
    }
  }
  return [...latest.values()].map(entry => entry.review)
}

// Design 9.2. The first match wins.
// The decision of a reviewer is the latest APPROVED, CHANGES_REQUESTED or DISMISSED review.
// A COMMENTED or PENDING review does not change it (the GitHub rule).
// Only an open thread in work or older gives Comments. A review body or a PR comment stays work
// for a later round, but it does not change the status word (final review I1).
export function reviewStatus(pr: PrData, viewer: string, split: WorkSplit): ReviewStatus {
  const decisions = humanDecisions(pr, viewer)
  if (decisions.some(r => r.state === 'CHANGES_REQUESTED')) return 'changes-requested'
  const open = [...split.work, ...split.older].some(item => item.kind === 'thread')
  if (open) return 'comments'
  if (decisions.some(r => r.state === 'APPROVED')) return 'approved'
  return 'pending'
}

export interface RequestContext {
  now: number
  known: { baseline: boolean } | undefined
  pauseEndsAt: number | null
  teamRequests: boolean
  session: 'reviewing' | 'queued' | 'trust-needed' | null
  // The result of the last round of the PR, from outcomeOf.
  outcome: 'drafted' | 'reviewed' | 'failed' | null
  // True when the user acted on the request (a round started or ended).
  acted: boolean
}

// The result of the last round of a PR.
// failed: the last round gave an error.
// reviewed: the mark has no review ID and its head is the PR head (no draft was needed).
// drafted: the mark has a review ID and is newer than the poll, so the poll does not show the
// new draft yet.
export function outcomeOf(
  pr: PrState | undefined,
  headSha: string,
  pollStartedAt: number,
): 'drafted' | 'reviewed' | 'failed' | null {
  if (pr === undefined) return null
  if (pr.lastError !== null) return 'failed'
  const mark = pr.recommendation
  if (mark === null) return null
  if (mark.reviewId === null) return mark.headSha === headSha ? 'reviewed' : null
  return mark.at > pollStartedAt ? 'drafted' : null
}

// Design 8.2. The result is null for a team request when team requests are off.
export function toReviewState(
  pr: PrData,
  viewer: string,
  ctx: RequestContext,
): ToReviewState | null {
  if (ctx.session !== null) return ctx.session
  const direct = pr.requestedUsers.includes(viewer)
  // With team requests off, Bifrost hides a team-only request in all states except a session.
  if (!direct && !ctx.teamRequests) return null
  if (pr.viewerPendingReviewId !== null || ctx.outcome === 'drafted') return 'draft-ready'
  if (ctx.outcome === 'reviewed') return 'reviewed'
  if (ctx.outcome === 'failed') return 'failed'
  if (ctx.pauseEndsAt !== null && ctx.now < ctx.pauseEndsAt) return 'paused'
  if (pr.reviewDecision === 'APPROVED') return 'approved-by-others'
  if (!direct) return 'team'
  return ctx.known?.baseline === true || ctx.acted ? 'waiting' : 'new'
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
  session(key: string): 'reviewing' | 'queued' | 'trust-needed' | null
  // The row ID of a review session of the PR that is not parked.
  sessionOf(key: string): string | null
  trust: TrustNeed[]
  // The start time of the last good poll.
  pollStartedAt: number
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
  for (const review of pr.decisions) add(review.author.login)
  return names
}

// True when GitHub has more items in one or more lists of the PR than the query reads.
export function isTruncated(pr: PrData): boolean {
  return pr.truncatedThreads || pr.truncatedReviews || pr.truncatedComments || pr.truncatedChecks
}

// The mark of a To review row. Only a draft-ready or a reviewed row shows it, and only while the
// mark belongs to the pending review of the user, or while the poll does not show the new draft
// yet. An older mark is stale.
function shownMark(
  rowState: ToReviewState,
  pr: PrData,
  prState: PrState | undefined,
  outcome: RequestContext['outcome'],
): RecommendationMark | null {
  if (rowState !== 'draft-ready' && rowState !== 'reviewed') return null
  const mark = prState?.recommendation ?? null
  if (mark === null) return null
  return outcome === 'drafted' || mark.reviewId === pr.viewerPendingReviewId ? mark : null
}

export function buildSnapshot(input: SnapshotInput): ReviewsSnapshot {
  const { poll, state, now, settings } = input
  const baseline = new Set(state.baseline)
  const toReview: ToReviewRow[] = []
  for (const pr of poll.toReview) {
    if (isIgnored(pr.owner, pr.repo, settings.reviewsIgnore)) continue
    const pauseEndsAt = state.pauses[pr.key] ?? null
    const known = state.requests[pr.key]
    const prState = state.prs[pr.key]
    const outcome = outcomeOf(prState, pr.headSha, input.pollStartedAt)
    const rowState = toReviewState(pr, poll.viewer, {
      acted: prState?.actedAt != null && known !== undefined && prState.actedAt >= known.firstSeen,
      known,
      now,
      outcome,
      pauseEndsAt,
      session: input.session(pr.key),
      teamRequests: settings.reviewsTeamRequests,
    })
    if (rowState === null) continue
    const mark = shownMark(rowState, pr, prState, outcome)
    toReview.push({
      additions: pr.additions,
      author: pr.author,
      deletions: pr.deletions,
      error: rowState === 'failed' ? (prState?.lastError ?? null) : null,
      flash: rowState === 'new',
      key: pr.key,
      number: pr.number,
      owner: pr.owner,
      pauseEndsAt: rowState === 'paused' ? pauseEndsAt : null,
      recommendation: mark?.value ?? null,
      repo: pr.repo,
      requestedAt: pr.requestedAt,
      sessionId: input.sessionOf(pr.key),
      state: rowState,
      team: !pr.requestedUsers.includes(poll.viewer),
      title: pr.title,
      why: mark?.why ?? null,
    })
  }
  const mine: MyPrRow[] = []
  for (const pr of poll.mine) {
    if (isIgnored(pr.owner, pr.repo, settings.reviewsIgnore)) continue
    const prState = state.prs[pr.key] ?? emptyPrState()
    const split = splitWork(pr, poll.viewer, prState, baseline, state.turnedOnAt)
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
      truncated: isTruncated(pr),
      updatedAt: pr.updatedAt,
    })
  }
  return {
    availability: 'ok',
    message: null,
    mine: sortMine(mine),
    polledAt: now,
    toReview: sortToReview(toReview),
    trust: input.trust,
  }
}

// The items to mark as seen at the first turn-on, and the To review keys that are open then.
// A truncated PR adds its visible items. The time rule of splitWork covers the rest.
export function baselineOf(poll: PollData): { items: string[]; requests: string[] } {
  const items = new Set<string>()
  for (const pr of poll.mine) {
    const split = splitWork(pr, poll.viewer, emptyPrState(), new Set(), null)
    for (const item of [...split.work, ...split.older]) items.add(item.id)
  }
  return { items: [...items], requests: poll.toReview.map(pr => pr.key) }
}
