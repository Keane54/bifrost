// The Review panel of the To review tab (user decision, 2026-11-13). The user checks the draft
// review of Claude, edits it in Bifrost, and then sends it, deletes it, or approves instead. Only
// a click of the user starts a write: each IPC of the panel calls one function of this module with
// the PR key, and Send review also gives the edits. Main finds each ID in its own state and in a
// fresh read of GitHub (ruling B10). The edits stay in the panel until Send review (ruling B5).
// Right before the writes, Bifrost reads the PR and the draft again, and refuses when they changed
// (rulings B7 to B9). Bifrost never sends a write again by itself (ruling A4). The panel and the
// row get a friendly text, and the raw text of gh goes to the Event log only (ruling A5).
// draft-writes.ts holds the writes and their guard.

import { isRecord } from '../../shared/plain-object'
import {
  type DraftAction,
  type DraftCommentView,
  type DraftEdits,
  type DraftOpen,
  type DraftResult,
  type DraftView,
  ITEM_ID,
  MAX_DRAFT_COMMENTS,
  MAX_REVIEW_TEXT,
  PR_KEY,
  SEND_VERDICTS,
} from '../../shared/reviews'
import { messageOf } from '../actions/session-actions'
import { maskToken } from '../log/mask'
import { prKeyOfUrl } from './approve'
import { type DraftRead, fetchDraft } from './draft-query'
import { type DraftScope, type DraftTarget, type DraftWrite, writeDraft } from './draft-writes'
import type { Gh } from './gh'
import { prOf } from './jobs'
import { type ApproveEntry, approvable, approvedOnHead, type DraftEntry, liveEntry } from './model'
import type { PrData } from './pr-data'
import type { WriteOutcome } from './request-writes'
import { fetchReviewContext, type ReviewContext } from './review-query'
import {
  REASON_APPROVE_DONE,
  REASON_DISCARD_UNKNOWN,
  REASON_DRAFT_BLANK,
  REASON_DRAFT_CHANGED,
  REASON_DRAFT_CLOSED,
  REASON_DRAFT_COMMIT,
  REASON_DRAFT_EDITED,
  REASON_DRAFT_EMPTY,
  REASON_DRAFT_ERROR,
  REASON_DRAFT_GONE,
  REASON_DRAFT_NEEDS_SUMMARY,
  REASON_DRAFT_OWN,
  REASON_DRAFT_TOO_MANY,
  REASON_INSTEAD_FAILED,
  REASON_INSTEAD_UNKNOWN,
  REASON_SEND_UNKNOWN,
} from './round-text'
import type { DraftComment, RecommendationMark, ReviewsState } from './state'
import type { ReviewsStateStore } from './state-store'

export const REFUSED_NO_DRAFT = 'refused: this draft cannot be changed now'
export const REFUSED_BAD_EDITS = 'refused: bad review edits'

// The last lines of a diff hunk that the panel shows, and the longest line, in characters.
const HUNK_LINES = 4
const HUNK_WIDTH = 300

export interface DraftDeps {
  gh: Gh
  store: Pick<ReviewsStateStore, 'get' | 'change'>
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

// The Approve button of the row, for Approve instead. run approves the PR of the row with the
// approver of approve.ts. result gives the entry of that approval.
export interface ApproveStep {
  run(): Promise<void>
  result(): ApproveEntry | null
}

export interface DraftEditor {
  // Read the draft review of the mark from GitHub for the panel. A row with no draft of Claude
  // gets REFUSED_NO_DRAFT, and Bifrost reads nothing.
  open(key: string): Promise<DraftOpen>
  // Apply the edits to the draft review, then submit it (ruling B7).
  send(key: string, edits: DraftEdits): Promise<DraftResult>
  // Delete the draft review of the mark (ruling B8).
  discard(key: string): Promise<DraftResult>
  // Delete the draft review of the mark, then approve the head with no text (ruling B9).
  approveInstead(key: string, approve: ApproveStep): Promise<DraftResult>
  // The result of the last action for the key, while it counts (liveEntry), or null.
  entry(key: string): DraftEntry | null
}

// A mark with a draft review of Claude.
type DraftMark = RecommendationMark & { reviewId: string }

// The fresh read before an action: the PR, the draft (when the action reads it) and the scope of
// the write guard.
interface Fresh {
  c: ReviewContext
  draft: DraftRead | null
  scope: DraftScope
}

type Refusal = { ok: false; message: string }

// The draft that the panel showed when it opened: the review, the summary, and the text of each
// comment by its ID. Each write compares the fresh read with it (fix round 1).
export interface OpenedDraft {
  reviewId: string
  body: string
  comments: ReadonlyMap<string, string>
}

// The fresh check of the PR (rulings B7 to B9). The text for the panel when Bifrost must not
// write, else null. head is true when the action needs the reviewed commit as the PR head.
export function draftRefusal(
  c: ReviewContext,
  viewer: string,
  mark: DraftMark,
  head: boolean,
): string | null {
  if (c.state !== 'OPEN') return REASON_DRAFT_CLOSED
  if (c.author.toLowerCase() === viewer.toLowerCase()) return REASON_DRAFT_OWN
  // The context reads only the pending reviews. So a draft that is not pending is missing.
  if (c.pending === null || c.pending.id !== mark.reviewId) return REASON_DRAFT_GONE
  if (c.pending.commit !== mark.headSha) return REASON_DRAFT_COMMIT
  return head && c.headSha !== mark.headSha ? REASON_DRAFT_CHANGED : null
}

// The check of the draft that the read gave: the review of the mark, pending, of the viewer, on
// the reviewed commit, with all its comments.
function draftProblem(d: DraftRead, mark: DraftMark): string | null {
  if (d.id !== mark.reviewId || d.state !== 'PENDING' || !d.mine) return REASON_DRAFT_GONE
  if (d.commit !== mark.headSha) return REASON_DRAFT_COMMIT
  return d.truncated ? REASON_DRAFT_TOO_MANY : null
}

// True when a text of the fresh read changed on GitHub after the open: it is not the text that the
// panel showed, and it is not the edit of the user. The edit then must not go over it.
const newer = (fresh: string, shown: string | undefined, edit: string | null): boolean =>
  fresh !== shown && fresh !== edit

// The writes of Send review, in order: the summary, each changed comment, each removed comment,
// and then the submit. Each check comes before the first write. Bifrost writes a text only where
// the edit is not the text of the fresh read. So a second Send after a partial failure writes only
// the rest. A comment that the user removed and that is gone from GitHub needs no write.
export function planSend(
  draft: DraftRead,
  edits: DraftEdits,
  opened: OpenedDraft,
): { ok: true; writes: DraftWrite[] } | Refusal {
  const read = new Map(draft.comments.map(c => [c.id, c]))
  const edited = new Map(edits.comments.map(c => [c.id, c.body]))
  const refuse = (message: string): Refusal => ({ message, ok: false })
  if (newer(draft.body, opened.body, edits.body)) return refuse(REASON_DRAFT_EDITED)
  for (const c of draft.comments) {
    // The user added a comment on GitHub after the open, or changed one.
    if (!opened.comments.has(c.id) || !edited.has(c.id)) return refuse(REASON_DRAFT_EDITED)
    const edit = edited.get(c.id) ?? null
    if (newer(c.body, opened.comments.get(c.id), edit)) return refuse(REASON_DRAFT_EDITED)
  }
  // A comment that the user keeps is gone from GitHub.
  if (edits.comments.some(c => c.body !== null && !read.has(c.id))) {
    return refuse(REASON_DRAFT_EDITED)
  }
  const kept = edits.comments.flatMap(c => (c.body === null ? [] : [{ body: c.body, id: c.id }]))
  if (kept.some(c => c.body.trim() === '')) return refuse(REASON_DRAFT_BLANK)
  const summary = edits.body.trim() !== ''
  // GitHub needs a text for each event. Request changes needs a summary.
  if (edits.verdict === 'request-changes' && !summary) return refuse(REASON_DRAFT_NEEDS_SUMMARY)
  if (!summary && kept.length === 0) return refuse(REASON_DRAFT_EMPTY)
  const writes: DraftWrite[] = []
  if (edits.body !== draft.body) writes.push({ body: edits.body, kind: 'body' })
  for (const c of kept) {
    if (c.body !== read.get(c.id)?.body)
      writes.push({ body: c.body, commentId: c.id, kind: 'comment' })
  }
  for (const c of edits.comments) {
    if (c.body === null && read.has(c.id)) writes.push({ commentId: c.id, kind: 'remove' })
  }
  writes.push({ kind: 'submit', verdict: edits.verdict })
  return { ok: true, writes }
}

// The last lines of a diff hunk, each cut to HUNK_WIDTH.
function lastLines(hunk: string): string[] {
  if (hunk === '') return []
  return hunk
    .replace(/\r\n?/g, '\n')
    .split('\n')
    .slice(-HUNK_LINES)
    .map(line => line.slice(0, HUNK_WIDTH))
}

// The view of the panel. One saved draft of Claude, with the same path and line, makes one comment
// a comment of Claude. Each other comment is a comment that the user added on GitHub.
function viewOf(
  key: string,
  mark: DraftMark,
  c: ReviewContext,
  draft: DraftRead,
  drafts: readonly DraftComment[],
): DraftView {
  const claude = drafts.filter(d => d.reviewId === mark.reviewId && d.path !== '')
  const comments = draft.comments.map((x): DraftCommentView => {
    const i = claude.findIndex(d => d.path === x.path && d.line === x.line)
    if (i !== -1) claude.splice(i, 1)
    return {
      body: x.body,
      hunk: lastLines(x.hunk),
      id: x.id,
      line: x.line,
      path: x.path,
      startLine: x.startLine,
      yours: i === -1,
    }
  })
  return {
    body: draft.body,
    changed: c.headSha !== mark.headSha,
    comments,
    key,
    recommendation: mark.value,
    why: mark.why,
  }
}

// The same mark: the round of a new review can change the mark during the read.
const sameMark = (a: RecommendationMark | null | undefined, b: RecommendationMark): boolean =>
  a != null && a.value === b.value && a.headSha === b.headSha && a.reviewId === b.reviewId

// A round or a queue entry of the key makes the row show another state.
const busy = (s: ReviewsState, key: string): boolean =>
  s.prs[key]?.round != null || s.queue.some(e => e.key === key)

// The text of an unknown result for a write that started, for each action.
const UNKNOWN_TEXT: Record<DraftAction, string> = {
  approve: REASON_DISCARD_UNKNOWN,
  discard: REASON_DISCARD_UNKNOWN,
  send: REASON_SEND_UNKNOWN,
}

export function createDraftEditor(deps: DraftDeps): DraftEditor {
  const entries = new Map<string, DraftEntry>()
  // The draft that the panel of each key showed when it opened.
  const opened = new Map<string, OpenedDraft>()

  const entry = (key: string): DraftEntry | null =>
    liveEntry(entries.get(key), deps.pollStartedAt())

  const failed = (action: DraftAction, message: string): DraftEntry => ({
    action,
    at: deps.now(),
    message,
    phase: 'failed',
  })
  const unknown = (action: DraftAction, message: string): DraftEntry => ({
    action,
    at: deps.now(),
    message,
    phase: 'unknown',
  })

  // The mark of a row with a draft of Claude that the panel can change, or null. The checks use
  // the last poll and the state of Bifrost only, so a refusal reads nothing from GitHub.
  function markToEdit(key: string): DraftMark | null {
    if (!PR_KEY.test(key)) return null
    const now = entry(key)
    if (now !== null && now.phase !== 'failed') return null
    const s = deps.store.get()
    const mark = s.prs[key]?.recommendation ?? null
    if (deps.toReviewPr(key) === null || mark === null || busy(s, key)) return null
    if (mark.reviewId === null || approvable(mark)) return null
    return { ...mark, reviewId: mark.reviewId }
  }

  function stillMark(key: string, mark: DraftMark): boolean {
    const s = deps.store.get()
    return !busy(s, key) && sameMark(s.prs[key]?.recommendation, mark)
  }

  // Set the mark of the PR, when it is still the mark of the action.
  async function setMark(key: string, mark: DraftMark, next: RecommendationMark | null) {
    try {
      await deps.store.change(s => {
        const p = s.prs[key]
        if (p === undefined || !sameMark(p.recommendation, mark)) return s
        return { ...s, prs: { ...s.prs, [key]: { ...p, recommendation: next } } }
      })
    } catch (error) {
      // GitHub has the change. The next poll shows it.
      deps.log(`Bifrost couldn't save the draft change of ${key}. ${messageOf(error)}`)
    }
  }

  function logFailure(key: string, detail: string | undefined, what: string): void {
    if (detail === undefined) return
    deps.eventNotice(`Reviews: ${what} ${key}. It said: ${maskToken(detail, null)}`)
  }

  function logWrite(key: string, out: Exclude<WriteOutcome<null>, { ok: true }>): void {
    const what = out.unknown
      ? "Bifrost couldn't tell if GitHub saved a change to the draft review of"
      : "GitHub didn't take a change to the draft review of"
    logFailure(key, out.detail, what)
  }

  // Read the PR and the draft again, and check them.
  async function readFresh(
    key: string,
    viewer: string,
    mark: DraftMark,
    need: { head: boolean; comments: boolean },
  ): Promise<{ ok: true; fresh: Fresh } | Refusal> {
    const read = await fetchReviewContext(deps.gh, prOf(key), viewer)
    if (!read.ok) {
      logFailure(key, read.detail, "GitHub couldn't load")
      return { message: read.message, ok: false }
    }
    const c = read.context
    const refusal = draftRefusal(c, viewer, mark, need.head)
    if (refusal !== null) return { message: refusal, ok: false }
    let draft: DraftRead | null = null
    if (need.comments) {
      const r = await fetchDraft(deps.gh, mark.reviewId)
      if (!r.ok) {
        logFailure(key, r.detail, "GitHub couldn't load the draft review of")
        return { message: r.message, ok: false }
      }
      const problem = draftProblem(r.draft, mark)
      if (problem !== null) return { message: problem, ok: false }
      draft = r.draft
    }
    const scope: DraftScope = {
      comments: new Set(draft?.comments.map(x => x.id) ?? []),
      commit: c.pending?.commit ?? null,
      // The key comes from the link that GitHub gave, not from the values that Bifrost sent.
      key: prKeyOfUrl(c.url),
      reviewId: c.pending?.id ?? '',
    }
    return { fresh: { c, draft, scope }, ok: true }
  }

  const targetOf = (key: string, mark: DraftMark): DraftTarget => ({
    headSha: mark.headSha,
    key,
    reviewId: mark.reviewId,
  })

  // Run one action. sent is true from the start of the write that can end the draft. poll is
  // false when a later step asks for the poll.
  async function act(
    key: string,
    action: DraftAction,
    work: (sent: { now: boolean }) => Promise<DraftEntry>,
    poll = true,
  ): Promise<DraftResult> {
    entries.set(key, { action, at: deps.now(), phase: 'running' })
    deps.changed()
    const sent = { now: false }
    let result: DraftEntry
    try {
      result = await work(sent)
    } catch (error) {
      deps.log(`Bifrost couldn't finish a Review panel action on ${key}. ${messageOf(error)}`)
      // After the start of the write, GitHub can have saved it.
      result = sent.now ? unknown(action, UNKNOWN_TEXT[action]) : failed(action, REASON_DRAFT_ERROR)
    }
    entries.set(key, result)
    deps.changed()
    // The next poll shows the true state on GitHub. An unknown result always asks for it.
    if (result.phase === 'unknown' || (result.phase !== 'failed' && poll)) deps.requestPoll()
    if (result.phase === 'failed' || result.phase === 'unknown') {
      return { message: result.message, ok: false }
    }
    return { ok: true }
  }

  function start(key: string): { mark: DraftMark; viewer: string } {
    const mark = markToEdit(key)
    const viewer = deps.viewer()
    if (mark === null || viewer === null) throw new Error(REFUSED_NO_DRAFT)
    return { mark, viewer }
  }

  // The start of a write: the panel must have opened the draft of the mark.
  function startWrite(key: string): { mark: DraftMark; viewer: string; shown: OpenedDraft } {
    const { mark, viewer } = start(key)
    const shown = opened.get(key)
    if (shown === undefined || shown.reviewId !== mark.reviewId) throw new Error(REFUSED_NO_DRAFT)
    return { mark, shown, viewer }
  }

  // After a good edit write, the opened draft holds the text that Bifrost wrote. So a resend after
  // a partial failure does not take this text for a change on GitHub.
  function remember(key: string, write: DraftWrite): void {
    const shown = opened.get(key)
    if (shown === undefined) return
    if (write.kind === 'body') opened.set(key, { ...shown, body: write.body })
    if (write.kind === 'comment') {
      opened.set(key, {
        ...shown,
        comments: new Map(shown.comments).set(write.commentId, write.body),
      })
    }
  }

  async function open(key: string): Promise<DraftOpen> {
    const { mark, viewer } = start(key)
    const read = await readFresh(key, viewer, mark, { comments: true, head: false })
    if (!read.ok) return read
    const { c, draft } = read.fresh
    if (draft === null) return { message: REASON_DRAFT_GONE, ok: false }
    opened.set(key, {
      body: draft.body,
      comments: new Map(draft.comments.map(x => [x.id, x.body])),
      reviewId: mark.reviewId,
    })
    return { draft: viewOf(key, mark, c, draft, deps.store.get().drafts), ok: true }
  }

  async function send(key: string, edits: DraftEdits): Promise<DraftResult> {
    const { mark, shown, viewer } = startWrite(key)
    return act(key, 'send', async sent => {
      const read = await readFresh(key, viewer, mark, { comments: true, head: true })
      if (!read.ok) return failed('send', read.message)
      const { draft, scope } = read.fresh
      if (draft === null || !stillMark(key, mark)) return failed('send', REASON_DRAFT_GONE)
      const plan = planSend(draft, edits, shown)
      if (!plan.ok) return failed('send', plan.message)
      for (const write of plan.writes) {
        if (write.kind === 'submit') sent.now = true
        const out = await writeDraft(deps.gh, targetOf(key, mark), scope, write)
        if (out.ok) {
          remember(key, write)
          continue
        }
        logWrite(key, out)
        // A change of the draft can run again. A submit with an unknown result never does.
        const submitUnknown = write.kind === 'submit' && out.unknown
        return submitUnknown ? unknown('send', out.message) : failed('send', out.message)
      }
      // The review is not a draft any more, so the mark goes.
      opened.delete(key)
      await setMark(key, mark, null)
      return { action: 'send', at: deps.now(), gone: mark.reviewId, phase: 'sent' }
    })
  }

  // Delete the draft of the mark. For Approve instead, the PR head must be the reviewed commit,
  // the user must not have approved it yet, and the mark keeps its value with deleted set. A
  // comment that the open did not give stops the delete, because the panel did not warn about it.
  async function discardFor(key: string, action: 'discard' | 'approve'): Promise<DraftResult> {
    const { mark, shown, viewer } = startWrite(key)
    const approve = action === 'approve'
    const work = async (sent: { now: boolean }): Promise<DraftEntry> => {
      const read = await readFresh(key, viewer, mark, { comments: true, head: approve })
      if (!read.ok) return failed(action, read.message)
      const { c, draft } = read.fresh
      if (draft === null || !stillMark(key, mark)) return failed(action, REASON_DRAFT_GONE)
      if (draft.comments.some(x => !shown.comments.has(x.id))) {
        return failed(action, REASON_DRAFT_EDITED)
      }
      if (approve && approvedOnHead(c.reviews, c.headSha))
        return failed(action, REASON_APPROVE_DONE)
      sent.now = true
      const write: DraftWrite = { kind: 'discard' }
      const out = await writeDraft(deps.gh, targetOf(key, mark), read.fresh.scope, write)
      if (!out.ok) {
        logWrite(key, out)
        return out.unknown ? unknown(action, out.message) : failed(action, out.message)
      }
      const deleted: RecommendationMark = { ...mark, deleted: true, reviewId: null }
      opened.delete(key)
      await setMark(key, mark, approve ? deleted : null)
      return { action, at: deps.now(), gone: mark.reviewId, phase: 'discarded' }
    }
    // The approval asks for the poll after its write.
    return await act(key, action, work, !approve)
  }

  async function approveInstead(key: string, approve: ApproveStep): Promise<DraftResult> {
    const deleted = await discardFor(key, 'approve')
    if (!deleted.ok) return deleted
    try {
      await approve.run()
    } catch (error) {
      deps.log(`Bifrost deleted the draft of ${key}, but couldn't approve. ${messageOf(error)}`)
      // The delete is done, so the next poll shows the row as it is now.
      deps.requestPoll()
      return { message: REASON_INSTEAD_FAILED, ok: false }
    }
    const result = approve.result()
    if (result?.phase === 'approved') return { ok: true }
    const message = result?.phase === 'unknown' ? REASON_INSTEAD_UNKNOWN : REASON_INSTEAD_FAILED
    return { message, ok: false }
  }

  return {
    approveInstead,
    discard: key => discardFor(key, 'discard'),
    entry,
    open,
    send,
  }
}

const EDIT_KEYS = ['body', 'comments', 'verdict']
const COMMENT_KEYS = ['body', 'id']

const hasKeys = (o: Record<string, unknown>, keys: readonly string[]): boolean => {
  const own = Object.keys(o).sort()
  return own.length === keys.length && own.every((k, i) => k === keys[i])
}

function refuseEdits(): never {
  throw new Error(REFUSED_BAD_EDITS)
}

// The edits that the page sent with Send review (ruling B10): the verdict of the switch, the
// summary, and each comment with its ID and its text or null. Each field is checked, and each text
// is at most the limit of GitHub. Give a copy. Else refuse with REFUSED_BAD_EDITS.
export function checkDraftEdits(value: unknown): DraftEdits {
  if (!isRecord(value) || !hasKeys(value, EDIT_KEYS)) refuseEdits()
  const { body, comments, verdict } = value
  const choice = SEND_VERDICTS.find(v => v === verdict)
  if (choice === undefined) refuseEdits()
  if (typeof body !== 'string' || body.length > MAX_REVIEW_TEXT) refuseEdits()
  if (!Array.isArray(comments) || comments.length > MAX_DRAFT_COMMENTS) refuseEdits()
  const ids = new Set<string>()
  const out: DraftEdits['comments'] = []
  for (const c of comments) {
    if (!isRecord(c) || !hasKeys(c, COMMENT_KEYS)) refuseEdits()
    const { body: text, id } = c
    if (typeof id !== 'string' || !ITEM_ID.test(id) || ids.has(id)) refuseEdits()
    if (text !== null && (typeof text !== 'string' || text.length > MAX_REVIEW_TEXT)) {
      refuseEdits()
    }
    ids.add(id)
    out.push({ body: text, id })
  }
  return { body, comments: out, verdict: choice }
}
