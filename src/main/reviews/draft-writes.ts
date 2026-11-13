// The writes of the Review panel (user decision, 2026-11-13). Bifrost changes the draft review of
// Claude only when the user clicks Send review, Discard draft or Approve instead in the panel.
// draft-panel.ts is the only caller. A write changes the summary or one comment of that draft,
// removes one comment, deletes the draft, or submits it. The text of each submit holds its event.
// No variable gives the event. Each value goes as a -f field. draftAllowed guards each write.
// test/main/reviews/github-writes-source.test.ts guards these rules.

import { ITEM_ID, SEND_VERDICTS, type SendVerdict } from '../../shared/reviews'
import { sameTarget } from './approve-review'
import type { Gh } from './gh'
import { send, type WriteOutcome } from './request-writes'
import { asRec, asString } from './review-query'
import {
  REASON_DISCARD_FAILED,
  REASON_DISCARD_UNKNOWN,
  REASON_DRAFT_EDIT_FAILED,
  REASON_DRAFT_EDIT_UNKNOWN,
  REASON_DRAFT_NOT_PENDING,
  REASON_DRAFT_REFUSED,
  REASON_SEND_FAILED,
  REASON_SEND_NOT_AS_SENT,
  REASON_SEND_UNKNOWN,
  reasonDraftFailed,
} from './round-text'

const EDIT_BODY = `mutation EditBody($review: ID!, $body: String!) {
  updatePullRequestReview(input: { pullRequestReviewId: $review, body: $body }) {
    pullRequestReview { id state }
  }
}`

const EDIT_COMMENT = `mutation EditComment($comment: ID!, $body: String!) {
  updatePullRequestReviewComment(input: { pullRequestReviewCommentId: $comment, body: $body }) {
    pullRequestReviewComment { id }
  }
}`

const REMOVE_COMMENT = `mutation RemoveComment($comment: ID!) {
  deletePullRequestReviewComment(input: { id: $comment }) {
    pullRequestReview { id }
  }
}`

const DISCARD_DRAFT = `mutation DiscardDraft($review: ID!) {
  deletePullRequestReview(input: { pullRequestReviewId: $review }) {
    pullRequestReview { id }
  }
}`

const SEND_COMMENT = `mutation SendComment($review: ID!) {
  submitPullRequestReview(input: { pullRequestReviewId: $review, event: COMMENT }) {
    pullRequestReview { id state }
  }
}`

const SEND_CHANGES = `mutation SendChanges($review: ID!) {
  submitPullRequestReview(input: { pullRequestReviewId: $review, event: REQUEST_CHANGES }) {
    pullRequestReview { id state }
  }
}`

// The submit of each verdict of the "Send as" switch, and the state that GitHub then gives to the
// review.
const SUBMITS: Record<SendVerdict, { query: string; state: string }> = {
  comment: { query: SEND_COMMENT, state: 'COMMENTED' },
  'request-changes': { query: SEND_CHANGES, state: 'CHANGES_REQUESTED' },
}

// The row and the mark of the review of Claude, from the state of Bifrost. key is the PR key of
// the row, headSha is the reviewed commit, and reviewId is the draft review of Claude.
export interface DraftTarget {
  key: string
  headSha: string
  reviewId: string
}

// The draft review in the fresh read of GitHub. key is the PR key of the PR link that GitHub
// gave. commit and reviewId come from the pending review of the viewer. comments holds the IDs of
// the comments that the read gave.
export interface DraftScope {
  key: string
  commit: string | null
  reviewId: string
  comments: ReadonlySet<string>
}

export type DraftWrite =
  | { kind: 'body'; body: string }
  | { kind: 'comment'; commentId: string; body: string }
  | { kind: 'remove'; commentId: string }
  | { kind: 'discard' }
  | { kind: 'submit'; verdict: string }

const isId = (x: unknown): x is string => typeof x === 'string' && x !== ''

// The write guard (ruling B10). It allows a write only for the PR of the row, only for the
// reviewed commit, and only for the draft review of the mark. A comment write needs a comment
// that the fresh read gave. A submit allows only the two verdicts of the switch. The Approve
// button has its own guard in approve-review.ts.
export function draftAllowed(target: DraftTarget, scope: DraftScope, write: DraftWrite): boolean {
  if (!sameTarget(target, scope.key, scope.commit)) return false
  if (!isId(target.reviewId) || scope.reviewId !== target.reviewId) return false
  if (write.kind === 'comment' || write.kind === 'remove') {
    return ITEM_ID.test(write.commentId) && scope.comments.has(write.commentId)
  }
  if (write.kind === 'submit') return (SEND_VERDICTS as readonly string[]).includes(write.verdict)
  return true
}

// The texts of a failed write of each kind. A change of the summary or of a comment can run again,
// so its texts say that the user can send again.
const TEXTS: Record<DraftWrite['kind'], { failed: string; unknown: string }> = {
  body: { failed: REASON_DRAFT_EDIT_FAILED, unknown: REASON_DRAFT_EDIT_UNKNOWN },
  comment: { failed: REASON_DRAFT_EDIT_FAILED, unknown: REASON_DRAFT_EDIT_UNKNOWN },
  discard: { failed: REASON_DISCARD_FAILED, unknown: REASON_DISCARD_UNKNOWN },
  remove: { failed: REASON_DRAFT_EDIT_FAILED, unknown: REASON_DRAFT_EDIT_UNKNOWN },
  submit: { failed: REASON_SEND_FAILED, unknown: REASON_SEND_UNKNOWN },
}

const DONE: WriteOutcome<null> = { ok: true, value: null }
const REFUSED: WriteOutcome<null> = { message: REASON_DRAFT_REFUSED, ok: false, unknown: false }

function sendWrite(gh: Gh, scope: DraftScope, write: DraftWrite): ReturnType<typeof send> {
  switch (write.kind) {
    case 'body':
      return send(gh, EDIT_BODY, { body: write.body, review: scope.reviewId })
    case 'comment':
      return send(gh, EDIT_COMMENT, { body: write.body, comment: write.commentId })
    case 'remove':
      return send(gh, REMOVE_COMMENT, { comment: write.commentId })
    case 'discard':
      return send(gh, DISCARD_DRAFT, { review: scope.reviewId })
    case 'submit':
      return send(gh, SUBMITS[write.verdict as SendVerdict].query, { review: scope.reviewId })
  }
}

// The outcome of one write. Each message is a friendly text. The raw text of gh or GitHub stays
// in detail, for the Event log only. Each mutation has one field, so the data of the answer has
// one value. The code names the fields only in the mutation texts.
function outcomeOf(write: DraftWrite, r: Awaited<ReturnType<typeof send>>): WriteOutcome<null> {
  const texts = TEXTS[write.kind]
  if (!r.ok) {
    // A node that is gone counts as deleted.
    if (r.notFound === true && (write.kind === 'remove' || write.kind === 'discard')) return DONE
    const detail = r.detail === undefined ? {} : { detail: r.detail }
    if (r.unknown) return { message: texts.unknown, ok: false, unknown: true, ...detail }
    if (r.detail !== undefined)
      return { ...detail, message: texts.failed, ok: false, unknown: false }
    return { message: reasonDraftFailed(r.message), ok: false, unknown: false }
  }
  const values = Object.values(r.data)
  const value = values.length === 1 ? asRec(values[0]) : {}
  const unknown: WriteOutcome<null> = { message: texts.unknown, ok: false, unknown: true }
  if (write.kind === 'comment') {
    return isId(asRec(value.pullRequestReviewComment).id) ? DONE : unknown
  }
  const review = asRec(value.pullRequestReview)
  if (!isId(review.id)) return unknown
  const state = asString(review.state)
  if (write.kind === 'body' && state !== 'PENDING') {
    return { message: REASON_DRAFT_NOT_PENDING, ok: false, unknown: false }
  }
  // GitHub saved the review, but not as the user sent it.
  if (write.kind === 'submit' && state !== SUBMITS[write.verdict as SendVerdict].state) {
    return { message: REASON_SEND_NOT_AS_SENT, ok: false, unknown: true }
  }
  return DONE
}

// Run one write of the Review panel. A refusal of the guard sends nothing.
export async function writeDraft(
  gh: Gh,
  target: DraftTarget,
  scope: DraftScope,
  write: DraftWrite,
): Promise<WriteOutcome<null>> {
  if (!draftAllowed(target, scope, write)) return REFUSED
  return outcomeOf(write, await sendWrite(gh, scope, write))
}
