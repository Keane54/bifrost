// The two approve writes of the To review tab (user decision, 2026-11-13). Bifrost approves a pull
// request only when the user clicks Approve on its row. approve.ts is the only caller. One write
// approves the reviewed commit with no text. The other submits the draft review of Claude as an
// approval, and keeps its body as it is. The text of each mutation holds the event APPROVE. No
// variable gives the event. Each value goes as a -f field. approveAllowed guards each write.
// test/main/reviews/github-writes-source.test.ts guards these rules.

import { PR_KEY } from '../../shared/reviews'
import type { Gh } from './gh'
import { OBJECT_ID } from './repo-store'
import { send, type WriteOutcome } from './request-writes'
import { asRec, asString, type Rec } from './review-query'
import {
  REASON_APPROVE_FAILED,
  REASON_APPROVE_NOT_APPROVED,
  REASON_APPROVE_REFUSED,
  REASON_APPROVE_UNKNOWN,
  reasonApproveFailed,
} from './round-text'

// The only verdict that the guard allows.
export const APPROVE = 'APPROVE'

const APPROVE_HEAD = `mutation ApproveHead($pr: ID!, $commit: GitObjectID!) {
  addPullRequestReview(input: { pullRequestId: $pr, commitOID: $commit, event: APPROVE }) {
    pullRequestReview { id state }
  }
}`

const APPROVE_DRAFT = `mutation ApproveDraft($review: ID!) {
  submitPullRequestReview(input: { pullRequestReviewId: $review, event: APPROVE }) {
    pullRequestReview { id state }
  }
}`

// The row and the mark of the review of Claude, from the state of Bifrost. key is the PR key of
// the row. headSha is the reviewed commit. reviewId is the draft review of Claude, or null when
// Bifrost posted nothing.
export interface ApproveTarget {
  key: string
  headSha: string
  reviewId: string | null
}

// The approve write with no draft, from the fresh read of the PR. key is the PR key of the read,
// commit is its head commit, and prId is the node ID of the PR.
export interface HeadWrite {
  verdict: string
  key: string
  commit: string
  prId: string
}

// The submit of the draft review, from the fresh read of the PR. reviewId and commit come from
// the pending review of the viewer.
export interface DraftWrite {
  verdict: string
  key: string
  commit: string | null
  reviewId: string
}

const isId = (x: unknown): x is string => typeof x === 'string' && x !== ''

// The part of the write guard that ties a write to the row (ruling A3): the key of the fresh read
// is the PR key of the row, and the commit is the reviewed commit. The guard of the Review panel
// uses the same check (ruling B10).
export function sameTarget(
  target: { key: string; headSha: string },
  key: string,
  commit: string | null,
): boolean {
  if (!PR_KEY.test(target.key) || key !== target.key) return false
  return OBJECT_ID.test(target.headSha) && commit === target.headSha
}

// The write guard (ruling A3). It allows only the verdict APPROVE, only for the PR of the row and
// only for the reviewed commit. A draft write submits only the draft review of the mark. A write
// with no draft needs a mark with no draft review.
export function approveAllowed(target: ApproveTarget, write: HeadWrite | DraftWrite): boolean {
  if (write.verdict !== APPROVE) return false
  if (!sameTarget(target, write.key, write.commit)) return false
  if ('reviewId' in write) return isId(write.reviewId) && write.reviewId === target.reviewId
  return target.reviewId === null && isId(write.prId)
}

const REFUSED: WriteOutcome<never> = { message: REASON_APPROVE_REFUSED, ok: false, unknown: false }

// The outcome of one approve write. Each message is a text for the row. The raw text of gh or
// GitHub stays in detail, for the Event log only. Each mutation has one field, so the data of the
// answer has one value. The code names the two fields only in the mutation texts.
function outcomeOf(r: Awaited<ReturnType<typeof send>>): WriteOutcome<{ state: string }> {
  if (!r.ok && r.unknown) {
    const unknown = { message: REASON_APPROVE_UNKNOWN, ok: false as const, unknown: true }
    return r.detail === undefined ? unknown : { ...unknown, detail: r.detail }
  }
  if (!r.ok && r.detail !== undefined) {
    return { detail: r.detail, message: REASON_APPROVE_FAILED, ok: false, unknown: false }
  }
  if (!r.ok) return { message: reasonApproveFailed(r.message), ok: false, unknown: false }
  const values = Object.values(r.data)
  const review: Rec = values.length === 1 ? asRec(asRec(values[0]).pullRequestReview) : {}
  if (!isId(review.id)) return { message: REASON_APPROVE_UNKNOWN, ok: false, unknown: true }
  const state = asString(review.state)
  // GitHub saved a review, but not as an approval.
  if (state !== 'APPROVED')
    return { message: REASON_APPROVE_NOT_APPROVED, ok: false, unknown: true }
  return { ok: true, value: { state } }
}

// Approve the reviewed commit with no text. A refusal of the guard sends nothing.
export async function approveHead(
  gh: Gh,
  target: ApproveTarget,
  write: HeadWrite,
): Promise<WriteOutcome<{ state: string }>> {
  if (!approveAllowed(target, write)) return REFUSED
  const r = await send(gh, APPROVE_HEAD, { commit: write.commit, pr: write.prId })
  return outcomeOf(r)
}

// Submit the draft review of Claude as an approval. Its body stays as it is. A refusal of the
// guard sends nothing.
export async function approveDraft(
  gh: Gh,
  target: ApproveTarget,
  write: DraftWrite,
): Promise<WriteOutcome<{ state: string }>> {
  if (!approveAllowed(target, write)) return REFUSED
  const r = await send(gh, APPROVE_DRAFT, { review: write.reviewId })
  return outcomeOf(r)
}
