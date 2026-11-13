import {
  type ClaudeState,
  COPILOT_LOGIN,
  type DraftAction,
  type MyPrRow,
  type QuestionRow,
  type Reviewer,
  type ReviewerStance,
  type ReviewStatus,
  type ReviewsSnapshot,
  type ToReviewRow,
  type ToReviewState,
  TRUSTED_ASSOCIATIONS,
  type TrustNeed,
} from '../../shared/reviews'
import { sortMine, sortToReview } from '../../shared/reviews-order'
import type { Settings } from '../../shared/settings'
import type { CiState } from './ci'
import type { Author, PollData, PrComment, PrData, PrReview } from './pr-data'
import {
  type DraftComment,
  emptyPrState,
  type Outbox,
  type PrState,
  type Question,
  type RecommendationMark,
  type ReviewsState,
} from './state'

// The pure rules of the Reviews panel. No I/O. The watcher calls these functions.

export function isCopilot(a: Author): boolean {
  return a.bot && a.login === COPILOT_LOGIN
}

// GitHub ignores case in a login, so a comment of the viewer is never trusted work.
export function isTrustedHuman(a: Author, viewer: string): boolean {
  const own = a.login.toLowerCase() === viewer.toLowerCase()
  return !a.bot && TRUSTED_ASSOCIATIONS.includes(a.association) && !own
}

// The lists of a PR that the work rule reads. A PrData has them, and so has the full request
// context of a round.
export type WorkLists = Pick<PrData, 'threads' | 'reviews' | 'comments'>

// The Copilot review with the earliest submittedAt. A review that is not submitted does not count.
export function firstCopilotReviewId(pr: Pick<PrData, 'reviews'>): string | null {
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
  // The items with an open question. They wait for the answer of the user.
  questions: WorkItem[]
  // The items that a post of the outbox names. The outbox sends or drops their posts first.
  posting: WorkItem[]
}

// True when a trusted human commented after the time.
function trustedAfter(comments: readonly PrComment[], time: number, viewer: string): boolean {
  return comments.some(c => isTrustedHuman(c.author, viewer) && c.createdAt > time)
}

// A handled item is work again when a trusted human commented after the last reply of Bifrost.
// A null lastReplyAt (an R1 entry) means that the item stays handled.
function commentedAfterReply(
  comments: readonly PrComment[],
  lastReplyAt: number | null,
  viewer: string,
): boolean {
  return lastReplyAt !== null && trustedAfter(comments, lastReplyAt, viewer)
}

// The value of an own key only. An item ID such as "constructor" never reads the prototype.
function own<T>(record: Readonly<Record<string, T>>, id: string): T | undefined {
  return Object.hasOwn(record, id) ? record[id] : undefined
}

// The item IDs that the posts of the outbox name.
function outboxItems(outbox: Outbox | null): Set<string> {
  const ids = new Set<string>()
  for (const post of outbox?.posts ?? []) if ('itemId' in post) ids.add(post.itemId)
  return ids
}

// The list of an item that Bifrost knows from an earlier round, or 'new' for the rules of a new
// item, or 'skip' when the item is not in a list. The first match wins:
// 1. A post of the outbox names the item: posting.
// 2. An open question with no trusted comment after seenUntil: questions. It waits for the answer.
// 3. A held item (a failed round) is older until Handle now. A trusted comment after checkedAt
//    (the full read of the failed round) makes it work. An earlier comment does not, so a failed
//    round never starts again by itself. An answered question that is held waits too.
// 4. An answered question, or an open question with a trusted comment after seenUntil: work.
// 5. A handled item is skipped, until a trusted comment after its last reply makes it work.
type Known = 'work' | 'older' | 'questions' | 'posting' | 'skip' | 'new'

interface KnownContext {
  prState: PrState
  viewer: string
  // The item IDs of the outbox and the held item IDs.
  posting: ReadonlySet<string>
  held: ReadonlySet<string>
}

function knownList(id: string, comments: readonly PrComment[], ctx: KnownContext): Known {
  const { prState, viewer } = ctx
  if (ctx.posting.has(id)) return 'posting'
  const question: Question | undefined = own(prState.questions, id)
  const open = question !== undefined && question.answer === null
  if (open && !trustedAfter(comments, question.seenUntil, viewer)) return 'questions'
  if (ctx.held.has(id)) {
    const { checkedAt } = prState
    const reopened = checkedAt !== null && trustedAfter(comments, checkedAt, viewer)
    return prState.handleOlder || reopened ? 'work' : 'older'
  }
  if (question !== undefined) return 'work'
  const handled = own(prState.handled, id)
  if (handled === undefined) return 'new'
  return commentedAfterReply(comments, handled.lastReplyAt, viewer) ? 'work' : 'skip'
}

// Design 10.2. Only a PR with full data (a My PR) gives a useful result.
// An item that is not in the baseline, but was created before since, is also older.
// This covers the items beyond the page that the poll reads. A null since gives no time rule.
// The first Copilot review is the saved one when Bifrost saved it. So a deleted first review
// never makes a later review the first.
export function splitWork(
  pr: WorkLists,
  viewer: string,
  prState: PrState,
  baseline: ReadonlySet<string>,
  since: number | null,
): WorkSplit {
  const split: WorkSplit = { laterCopilot: [], older: [], posting: [], questions: [], work: [] }
  const firstCopilot = prState.firstCopilotReview ?? firstCopilotReviewId(pr)
  const ctx: KnownContext = {
    held: new Set(prState.held),
    posting: outboxItems(prState.outbox),
    prState,
    viewer,
  }

  // Put a new item in the right list.
  const place = (item: WorkItem, createdAt: number | null): void => {
    const before = since !== null && createdAt !== null && createdAt < since
    if (!prState.handleOlder && (baseline.has(item.id) || before)) split.older.push(item)
    else split.work.push(item)
  }
  // Put an item that Bifrost knows in its list. Give false for a new item.
  const placeKnown = (item: WorkItem, comments: readonly PrComment[]): boolean => {
    const known = knownList(item.id, comments, ctx)
    if (known === 'new') return false
    if (known !== 'skip') split[known].push(item)
    return true
  }

  for (const thread of pr.threads) {
    const first = thread.comments[0]
    if (thread.isResolved || first === undefined) continue
    const human = isTrustedHuman(first.author, viewer)
    if (!human && !isCopilot(first.author)) continue
    const item: WorkItem = { id: thread.id, kind: 'thread' }
    // A reopened item is work, also a later Copilot thread.
    if (placeKnown(item, thread.comments)) continue
    if (human || (thread.reviewId !== null && thread.reviewId === firstCopilot)) {
      place(item, first.createdAt)
    } else if (prState.handleCopilot) split.work.push(item)
    else split.laterCopilot.push(item)
  }

  for (const review of pr.reviews) {
    if (!isTrustedHuman(review.author, viewer) || review.body.trim() === '') continue
    // An approval or a dismissed review needs no action.
    if (review.state !== 'CHANGES_REQUESTED' && review.state !== 'COMMENTED') continue
    const item: WorkItem = { id: review.id, kind: 'review-body' }
    if (!placeKnown(item, [])) place(item, review.submittedAt)
  }

  for (const comment of pr.comments) {
    if (!isTrustedHuman(comment.author, viewer)) continue
    const item: WorkItem = { id: comment.id, kind: 'comment' }
    if (!placeKnown(item, [])) place(item, comment.createdAt)
  }

  return split
}

// The start of new work: fixFrom, or the first turn-on for a state from before R3.
export function workSince(state: ReviewsState): number | null {
  return state.fixFrom ?? state.turnedOnAt
}

// True when new comments start request rounds by themselves: the setting is on, and no saved
// flag of ruling S20 waits for the confirm of the user.
export function autoFixOn(
  settings: Pick<Settings, 'reviewsAutoFix'>,
  state: Pick<ReviewsState, 'autoFixConsent'>,
): boolean {
  return settings.reviewsAutoFix && state.autoFixConsent !== false
}

// True when a poll must queue a request round for the PR. A PR from a fork never gets a round.
// A cut thread list with a newer updatedAt can hide new work, so the round reads the full lists
// first. It starts a session only when the full lists give work.
export function needsRound(
  pr: PrData,
  split: WorkSplit,
  prState: PrState,
  autoFix: boolean,
): boolean {
  if (pr.isCrossRepository || !autoFix) return false
  if (split.work.length > 0) return true
  return pr.truncatedThreads && pr.updatedAt > (prState.checkedAt ?? 0)
}

// The open questions of a PR, oldest first.
function openQuestions(prState: PrState): QuestionRow[] {
  return Object.entries(prState.questions)
    .filter(([, q]) => q.answer === null)
    .sort(([a, qa], [b, qb]) => qa.at - qb.at || a.localeCompare(b))
    .map(([id, q]) => ({
      id,
      question: q.question,
      where: q.where,
      ...(q.author === undefined ? {} : { author: q.author }),
      ...(q.body === undefined ? {} : { body: q.body }),
      ...(q.url === undefined ? {} : { url: q.url }),
      ...(q.kind === undefined ? {} : { kind: q.kind }),
    }))
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
// Only an open thread in work, older, questions or posting gives Comments. A review body or a PR
// comment stays work for a later round, but it does not change the status word (final review I1).
export function reviewStatus(pr: PrData, viewer: string, split: WorkSplit): ReviewStatus {
  const decisions = humanDecisions(pr, viewer)
  if (decisions.some(r => r.state === 'CHANGES_REQUESTED')) return 'changes-requested'
  const lists = [split.work, split.older, split.questions, split.posting]
  const open = lists.some(list => list.some(item => item.kind === 'thread'))
  if (open) return 'comments'
  if (decisions.some(r => r.state === 'APPROVED')) return 'approved'
  return 'pending'
}

// The context of one To review row.
export interface ToReviewContext {
  now: number
  known: { baseline: boolean } | undefined
  pauseEndsAt: number | null
  teamRequests: boolean
  session: 'reviewing' | 'queued' | 'trust-needed' | null
  // The result of the last round of the PR, from outcomeOf.
  outcome: 'drafted' | 'reviewed' | 'failed' | null
  // True when the user acted on the request (a round started or ended).
  acted: boolean
  // True when a click of Approve worked, and no poll shows it yet.
  approved?: boolean
  // True when Send review of the Review panel worked, and no poll shows it yet.
  sent?: boolean
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
  ctx: ToReviewContext,
): ToReviewState | null {
  if (ctx.session !== null) return ctx.session
  const direct = pr.requestedUsers.includes(viewer)
  // With team requests off, Bifrost hides a team-only request in all states except a session.
  if (!direct && !ctx.teamRequests) return null
  // The poll can still show the draft that the click submitted.
  if (ctx.approved === true) return 'you-approved'
  if (ctx.sent === true) return 'you-reviewed'
  if (pr.viewerPendingReviewId !== null || ctx.outcome === 'drafted') return 'draft-ready'
  // A new request on the same commit stays new, so it flashes as before.
  const fresh = direct && ctx.known?.baseline !== true && !ctx.acted
  if (viewerApproved(pr) && !fresh) return 'you-approved'
  if (ctx.outcome === 'reviewed') return 'reviewed'
  if (ctx.outcome === 'failed') return 'failed'
  if (ctx.pauseEndsAt !== null && ctx.now < ctx.pauseEndsAt) return 'paused'
  if (pr.reviewDecision === 'APPROVED') return 'approved-by-others'
  if (!direct) return 'team'
  return ctx.known?.baseline === true || ctx.acted ? 'waiting' : 'new'
}

// The result of an Approve click (user decision, 2026-11-13). approve.ts keeps one entry for
// each PR in memory. at is the time of the click while the write runs, and the end of the write
// after that.
export type ApproveEntry =
  | { phase: 'running' | 'approved'; at: number }
  | { phase: 'failed' | 'unknown'; at: number; message: string }

// The entry while its write runs, and until a poll that starts after the end of the write. That
// poll shows the true state on GitHub. Else null. The entries of the Approve button and of the
// Review panel use this rule.
export function liveEntry<E extends { phase: string; at: number }>(
  entry: E | null | undefined,
  pollStartedAt: number,
): E | null {
  if (entry == null) return null
  return entry.phase === 'running' || entry.at > pollStartedAt ? entry : null
}

export function liveApproval(
  entry: ApproveEntry | null | undefined,
  pollStartedAt: number,
): ApproveEntry | null {
  return liveEntry(entry, pollStartedAt)
}

// The result of an action of the Review panel (user decision, 2026-11-13). draft-panel.ts keeps
// one entry for each PR in memory, with the same times as an ApproveEntry. gone is the ID of the
// pending review that the action submitted or deleted: the snapshot does not show it, also when
// the last poll still has it.
export type DraftEntry = { action: DraftAction; at: number } & (
  | { phase: 'running' }
  | { phase: 'sent' | 'discarded'; gone: string }
  | { phase: 'failed' | 'unknown'; message: string }
)

// The states that give the opinion of a reviewer. A COMMENTED or PENDING review does not change it.
const OPINIONS: readonly string[] = ['APPROVED', 'CHANGES_REQUESTED', 'DISMISSED']

// The one rule of "already approved" (fix round 1). The poll (viewerApproved) and the fresh check
// before the write (approve.ts) both use it: the newest opinion of the viewer is an approval of
// the head commit.
export function approvedOnHead(
  reviews: readonly { state: string; commit: string | null; submittedAt: number | null }[],
  head: string,
): boolean {
  let newest: (typeof reviews)[number] | null = null
  for (const r of reviews) {
    if (!OPINIONS.includes(r.state)) continue
    if (newest === null || (r.submittedAt ?? -1) >= (newest.submittedAt ?? -1)) newest = r
  }
  return head !== '' && newest?.state === 'APPROVED' && newest.commit === head
}

// True when the latest opinion of the viewer in the poll is an approval of the head commit.
export function viewerApproved(pr: Pick<PrData, 'headSha' | 'viewerReviews'>): boolean {
  return approvedOnHead(pr.viewerReviews, pr.headSha)
}

// True when the mark lets the user approve: Claude suggests Approve, or the user deleted the
// draft of Claude with Approve instead (user decision, 2026-11-13).
export function approvable(mark: RecommendationMark): boolean {
  return mark.value === 'approve' || mark.deleted === true
}

// True when a To review row can get the Approve button: a reviewed or draft-ready row that shows
// an Approve mark for the head commit, with no approval of the viewer on that commit.
export function canApprove(
  rowState: ToReviewState,
  pr: Pick<PrData, 'headSha' | 'viewerReviews' | 'ci'>,
  mark: RecommendationMark | null,
): boolean {
  if (rowState !== 'reviewed' && rowState !== 'draft-ready') return false
  // A PR with failing CI gets no approval (user decision, 2026-11-13).
  if (pr.ci === 'failing') return false
  if (mark === null || !approvable(mark)) return false
  return mark.headSha === pr.headSha && !viewerApproved(pr)
}

// True when a To review row offers the Review panel: a draft-ready row that shows a Comment or a
// Request changes mark with a draft review of Claude (ruling B4).
export function canEditDraft(rowState: ToReviewState, mark: RecommendationMark | null): boolean {
  return rowState === 'draft-ready' && mark !== null && mark.reviewId !== null && !approvable(mark)
}

// The panel button of a row. An action that runs disables it. A result that is not known hides it
// until the next poll. After a known failure, the user can click again.
function draftButton(shown: boolean, entry: DraftEntry | null): ToReviewRow['draft'] {
  if (!shown || entry?.phase === 'unknown') return null
  return entry?.phase === 'running' ? 'running' : 'ready'
}

// What Claude drafted for a mark: a summary and the count of comments, from the drafts that
// Bifrost saved for the draft review. A mark with no draft drafted nothing. Null when Bifrost
// kept no draft of the review.
function draftedOf(
  mark: RecommendationMark | null,
  drafts: readonly DraftComment[],
): ToReviewRow['drafted'] {
  if (mark === null || mark.deleted === true) return null
  if (mark.reviewId === null) return { comments: 0, summary: false }
  const own = drafts.filter(d => d.reviewId === mark.reviewId)
  if (own.length === 0) return null
  return { comments: own.filter(d => d.path !== '').length, summary: own.some(d => d.path === '') }
}

// The Approve button of a row. A write that runs disables it. A result that is not known hides
// it until the next poll. After a known failure, the user can click again.
function approveButton(
  shown: boolean,
  entry: ApproveEntry | null,
  ci: CiState,
): ToReviewRow['approve'] {
  if (!shown || entry?.phase === 'unknown' || entry?.phase === 'approved') return null
  if (entry?.phase === 'running') return 'running'
  // The button waits until CI has passed.
  return ci === 'running' ? 'ci-running' : 'ready'
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
  settings: Pick<Settings, 'reviewsTeamRequests' | 'reviewsIgnore' | 'reviewsAutoFix'>
  session(key: string): 'reviewing' | 'queued' | 'trust-needed' | null
  // The row ID of a review session of the PR that is not parked.
  sessionOf(key: string): string | null
  trust: TrustNeed[]
  // The start time of the last good poll.
  pollStartedAt: number
  // The result of the last Approve click of the PR, or null.
  approval?(key: string): ApproveEntry | null
  // The result of the last action of the Review panel for the PR, or null.
  draft?(key: string): DraftEntry | null
  claude(key: string): {
    claude: ClaudeState
    fixing: number
    error: string | null
    sessionId: string | null
  }
}

// The stance of one reviewer. The latest opinion decides (an approval, a change request, or a
// dismissal, newest by time). A later comment does not change it. A dismissed opinion, and
// Copilot, give no colour. With no opinion, a comment gives the comment stance.
function stanceOf(pr: PrData, login: string): ReviewerStance {
  if (login === COPILOT_LOGIN) return 'none'
  let latest: PrReview | null = null
  let commented = false
  for (const review of [...pr.reviews, ...pr.decisions]) {
    if (review.author.login !== login) continue
    if (review.state === 'COMMENTED') commented = true
    if (review.state === 'COMMENTED' || review.state === 'PENDING') continue
    if (latest === null || (review.submittedAt ?? 0) >= (latest.submittedAt ?? 0)) latest = review
  }
  if (latest === null) return commented ? 'commented' : 'none'
  if (latest.state === 'APPROVED') return 'approved'
  return latest.state === 'CHANGES_REQUESTED' ? 'changes' : 'none'
}

function reviewers(pr: PrData, viewer: string): Reviewer[] {
  const names: Reviewer[] = []
  const add = (login: string): void => {
    if (login === viewer) return
    const name = login === COPILOT_LOGIN ? 'Copilot' : login
    if (!names.some(n => n.name === name)) names.push({ name, stance: stanceOf(pr, login) })
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
  outcome: ToReviewContext['outcome'],
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
  for (const polled of poll.toReview) {
    if (isIgnored(polled.owner, polled.repo, settings.reviewsIgnore)) continue
    // The user removed the PR in Bifrost. It counts nowhere until a new request (ruling B3).
    if (Object.hasOwn(state.hidden, polled.key)) continue
    const draftEntry = liveEntry(input.draft?.(polled.key), input.pollStartedAt)
    // The last poll can still show the draft that the panel submitted or deleted.
    const gone = draftEntry?.phase === 'sent' || draftEntry?.phase === 'discarded'
    const pr =
      gone && draftEntry.gone === polled.viewerPendingReviewId
        ? { ...polled, viewerPendingReviewId: null }
        : polled
    const pauseEndsAt = state.pauses[pr.key] ?? null
    const known = state.requests[pr.key]
    const prState = state.prs[pr.key]
    const outcome = outcomeOf(prState, pr.headSha, input.pollStartedAt)
    const entry = liveApproval(input.approval?.(pr.key), input.pollStartedAt)
    const rowState = toReviewState(pr, poll.viewer, {
      acted: prState?.actedAt != null && known !== undefined && prState.actedAt >= known.firstSeen,
      approved: entry?.phase === 'approved',
      known,
      now,
      outcome,
      pauseEndsAt,
      sent: draftEntry?.phase === 'sent',
      session: input.session(pr.key),
      teamRequests: settings.reviewsTeamRequests,
    })
    if (rowState === null) continue
    const mark = shownMark(rowState, pr, prState, outcome)
    const shown = canApprove(rowState, pr, mark)
    const issue = entry?.phase === 'failed' || entry?.phase === 'unknown' ? entry : null
    const withMark = rowState === 'reviewed' || rowState === 'draft-ready'
    const draftIssue =
      draftEntry?.phase === 'failed' || draftEntry?.phase === 'unknown' ? draftEntry : null
    toReview.push({
      additions: pr.additions,
      approvals: pr.approvals,
      approve: approveButton(shown, entry, pr.ci),
      approveIssue:
        issue !== null && withMark
          ? { message: issue.message, unknown: issue.phase === 'unknown' }
          : null,
      author: pr.author,
      ci: pr.ci === 'failing' || pr.ci === 'running' ? pr.ci : null,
      deletions: pr.deletions,
      draft: draftButton(canEditDraft(rowState, mark), draftEntry),
      draftDeleted: mark?.deleted === true,
      drafted: draftedOf(mark, state.drafts),
      draftIssue:
        draftIssue !== null && withMark
          ? {
              action: draftIssue.action,
              message: draftIssue.message,
              unknown: draftIssue.phase === 'unknown',
            }
          : null,
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
    const split = splitWork(pr, poll.viewer, prState, baseline, workSince(state))
    const claude = input.claude(pr.key)
    // With automatic rounds off, the new work also waits for Handle now.
    const waiting = split.older.length + (autoFixOn(settings, state) ? 0 : split.work.length)
    mine.push({
      claude: claude.claude,
      error: claude.error,
      failedChecks: pr.failedChecks,
      fixing: claude.fixing,
      key: pr.key,
      lastError: prState.lastError ?? null,
      laterCopilot: split.laterCopilot.length,
      number: pr.number,
      olderOpen: waiting,
      owner: pr.owner,
      questions: openQuestions(prState),
      repo: pr.repo,
      reviewers: reviewers(pr, poll.viewer),
      sessionId: claude.sessionId,
      status: reviewStatus(pr, poll.viewer, split),
      title: pr.title,
      truncated: isTruncated(pr),
      unsent: prState.outbox !== null,
      updatedAt: pr.updatedAt,
    })
  }
  return {
    autoFixConfirm: state.autoFixConsent === false,
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
