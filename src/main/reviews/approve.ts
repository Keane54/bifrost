// The Approve button of the To review tab (user decision, 2026-11-13). Only a click of the user
// starts an approval (ruling A1): reviews:approve calls approve with the PR key, and main finds
// all other values in its own state. Right before the write, Bifrost reads the PR from GitHub
// again and refuses when the PR or the draft changed (ruling A2). Bifrost never tries a write
// again by itself (ruling A4). The row shows a friendly text, and the raw text of gh goes to the
// Event log only (ruling A5). approve-review.ts holds the two writes and their guard. Approve
// instead of the Review panel (ruling B9) deletes the draft first and marks it deleted. The
// approval then has no draft, as for a mark with nothing to post.

import { PR_KEY, prKey } from '../../shared/reviews'
import { messageOf } from '../actions/session-actions'
import { maskToken } from '../log/mask'
import { APPROVE, approveDraft, approveHead } from './approve-review'
import type { Gh } from './gh'
import { prOf } from './jobs'
import {
  type ApproveEntry,
  approvable,
  approvedOnHead,
  liveApproval,
  viewerApproved,
} from './model'
import type { PrData } from './pr-data'
import type { WriteOutcome } from './request-writes'
import { fetchReviewContext, type ReviewContext } from './review-query'
import {
  REASON_APPROVE_CHANGED,
  REASON_APPROVE_CLOSED,
  REASON_APPROVE_DONE,
  REASON_APPROVE_DRAFT_COMMIT,
  REASON_APPROVE_ERROR,
  REASON_APPROVE_NO_DRAFT,
  REASON_APPROVE_NOT_SUGGESTED,
  REASON_APPROVE_OWN,
  REASON_APPROVE_PENDING,
  REASON_APPROVE_UNKNOWN,
} from './round-text'
import type { RecommendationMark, ReviewsState } from './state'

export const REFUSED_NOT_APPROVABLE = 'refused: this pull request cannot be approved now'

export interface ApproverDeps {
  gh: Gh
  store: { get(): ReviewsState }
  // The To review PR with this key from the last poll, or null.
  toReviewPr(key: string): PrData | null
  viewer(): string | null
  // The start time of the last good poll.
  pollStartedAt(): number
  now(): number
  // A change that the panel shows. The caller builds the snapshot again.
  changed(): void
  requestPoll(): void
  // A line for the Event log.
  eventNotice(text: string): void
  log(m: string): void
}

export interface Approver {
  // Approve the To review PR of the key. A click that the row must not allow gets
  // REFUSED_NOT_APPROVABLE, and Bifrost reads and writes nothing. Each other result goes to the
  // entry of the key.
  approve(key: string): Promise<void>
  // The result of the last click for the key, while it counts (liveApproval), or null.
  entry(key: string): ApproveEntry | null
}

// The PR link that GitHub gives: https://github.com/<owner>/<repo>/pull/<number>.
const PR_URL = /^https:\/\/github\.com\/([^/]+)\/([^/]+)\/pull\/([1-9][0-9]{0,9})$/

// The PR key of a PR link of GitHub, or '' for another text. The write guard compares this key
// with the key of the row, so the write goes only to the PR that GitHub gave for the row.
export function prKeyOfUrl(url: string): string {
  const m = PR_URL.exec(url)
  if (m === null) return ''
  const key = prKey(m[1] ?? '', m[2] ?? '', Number(m[3]))
  return PR_KEY.test(key) ? key : ''
}

// The fresh check of ruling A2. The text for the row when Bifrost must not write, else null.
export function approveRefusal(
  c: ReviewContext,
  viewer: string,
  mark: RecommendationMark,
): string | null {
  if (c.state !== 'OPEN') return REASON_APPROVE_CLOSED
  if (c.author.toLowerCase() === viewer.toLowerCase()) return REASON_APPROVE_OWN
  if (!approvable(mark)) return REASON_APPROVE_NOT_SUGGESTED
  if (c.headSha !== mark.headSha) return REASON_APPROVE_CHANGED
  if (approvedOnHead(c.reviews, c.headSha)) return REASON_APPROVE_DONE
  // GitHub allows one pending review for each user. An approval with no draft cannot go next to it.
  if (mark.reviewId === null) return c.pending === null ? null : REASON_APPROVE_PENDING
  // The context reads only the pending reviews. So a draft that is not pending is missing.
  if (c.pending === null || c.pending.id !== mark.reviewId) return REASON_APPROVE_NO_DRAFT
  return c.pending.commit === mark.headSha ? null : REASON_APPROVE_DRAFT_COMMIT
}

// The same mark: the round of a new review can change the mark during the read.
const sameMark = (a: RecommendationMark | null, b: RecommendationMark): boolean =>
  a !== null &&
  a.value === b.value &&
  a.headSha === b.headSha &&
  a.reviewId === b.reviewId &&
  a.deleted === b.deleted

export function createApprover(deps: ApproverDeps): Approver {
  const entries = new Map<string, ApproveEntry>()

  const entry = (key: string): ApproveEntry | null =>
    liveApproval(entries.get(key), deps.pollStartedAt())

  // A round or a queue entry of the key makes the row show another state.
  const busy = (s: ReviewsState, key: string): boolean =>
    s.prs[key]?.round != null || s.queue.some(e => e.key === key)

  // The mark of a row that shows the Approve button, or null. The checks use the last poll and the
  // state of Bifrost only, so a refusal reads nothing from GitHub.
  function markToApprove(key: string): RecommendationMark | null {
    if (!PR_KEY.test(key)) return null
    const now = entry(key)
    if (now !== null && now.phase !== 'failed') return null
    const pr = deps.toReviewPr(key)
    const s = deps.store.get()
    const mark = s.prs[key]?.recommendation ?? null
    if (pr === null || mark === null || busy(s, key) || !approvable(mark)) return null
    return mark.headSha === pr.headSha && !viewerApproved(pr) ? mark : null
  }

  // Read the PR again, check it, then write. sent is true from the start of the write.
  async function run(
    key: string,
    viewer: string,
    mark: RecommendationMark,
    sent: { now: boolean },
  ): Promise<ApproveEntry> {
    const failed = (message: string): ApproveEntry => ({ at: deps.now(), message, phase: 'failed' })
    const read = await fetchReviewContext(deps.gh, prOf(key), viewer)
    if (!read.ok) {
      if (read.detail !== undefined) {
        deps.eventNotice(
          `Reviews: GitHub couldn't load ${key}. It said: ${maskToken(read.detail, null)}`,
        )
      }
      return failed(read.message)
    }
    const c = read.context
    const s = deps.store.get()
    if (busy(s, key) || !sameMark(s.prs[key]?.recommendation ?? null, mark)) {
      return failed(REASON_APPROVE_NOT_SUGGESTED)
    }
    const refusal = approveRefusal(c, viewer, mark)
    if (refusal !== null) return failed(refusal)
    const target = { headSha: mark.headSha, key, reviewId: mark.reviewId }
    // The key comes from the link that GitHub gave, not from the values that Bifrost sent.
    const readKey = prKeyOfUrl(c.url)
    sent.now = true
    const out: WriteOutcome<{ state: string }> =
      mark.reviewId === null
        ? await approveHead(deps.gh, target, {
            commit: c.headSha,
            key: readKey,
            prId: c.prId,
            verdict: APPROVE,
          })
        : await approveDraft(deps.gh, target, {
            commit: c.pending?.commit ?? null,
            key: readKey,
            reviewId: c.pending?.id ?? '',
            verdict: APPROVE,
          })
    const at = deps.now()
    if (out.ok) return { at, phase: 'approved' }
    if (out.detail !== undefined) {
      // GitHub can have saved a write with an unknown result.
      const what = out.unknown
        ? `Bifrost couldn't tell if GitHub saved the approval of ${key}.`
        : `GitHub didn't take the approval of ${key}.`
      deps.eventNotice(`Reviews: ${what} It said: ${maskToken(out.detail, null)}`)
    }
    return { at, message: out.message, phase: out.unknown ? 'unknown' : 'failed' }
  }

  async function approve(key: string): Promise<void> {
    const mark = markToApprove(key)
    const viewer = deps.viewer()
    if (mark === null || viewer === null) throw new Error(REFUSED_NOT_APPROVABLE)
    entries.set(key, { at: deps.now(), phase: 'running' })
    deps.changed()
    const sent = { now: false }
    let result: ApproveEntry
    try {
      result = await run(key, viewer, mark, sent)
    } catch (error) {
      deps.log(`Bifrost couldn't approve ${key}. ${messageOf(error)}`)
      // After the start of the write, GitHub can have saved the approval.
      const message = sent.now ? REASON_APPROVE_UNKNOWN : REASON_APPROVE_ERROR
      result = { at: deps.now(), message, phase: sent.now ? 'unknown' : 'failed' }
    }
    entries.set(key, result)
    deps.changed()
    // The next poll shows the true state on GitHub.
    if (result.phase === 'approved' || result.phase === 'unknown') deps.requestPoll()
  }

  return { approve, entry }
}
