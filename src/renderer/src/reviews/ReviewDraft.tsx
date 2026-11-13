// The body of the Review panel (user decision, 2026-11-13): the recommendation of Claude, the
// summary, each comment of the draft review with its place and the end of its diff hunk, and the
// footer. All text from GitHub can come from anyone, so it shows only as text nodes and as the
// values of text boxes.
import {
  type DraftCommentView,
  type DraftView,
  MAX_REVIEW_TEXT,
  RECOMMENDATION_TEXT,
  type Recommendation,
  SEND_VERDICTS,
  type SendVerdict,
} from '../../../shared/reviews'
import { cx } from '../lib/cx'
import {
  CHANGED_TEXT,
  confirmText,
  LOCKED_TEXT,
  placeText,
  VERDICT_TEXT,
  yoursCount,
} from './draft-text'

export interface ReviewDraftProps {
  draft: DraftView
  body: string
  // The text of each comment that the user changed, by comment ID.
  texts: Readonly<Record<string, string>>
  // The comments that the user removed, by comment ID.
  removed: Readonly<Record<string, boolean>>
  verdict: SendVerdict
  // The action that waits for the confirm of the user, or null.
  confirm: 'discard' | 'approve' | null
  busy: boolean
  // True when the row of the snapshot no longer offers the draft, for example after an unknown
  // result. The panel then allows no action, and says why.
  locked: boolean
  onBody(text: string): void
  onText(id: string, text: string): void
  onRemove(id: string, removed: boolean): void
  onVerdict(verdict: SendVerdict): void
  onDiscard(): void
  onApprove(): void
  onSend(): void
  // Keep the draft: the user does not confirm the delete.
  onKeep(): void
}

const LABEL = 'mt-3 mb-1 text-[10px] tracking-wide text-text-dim uppercase'
const BOX = cx(
  'w-full resize-y border-panel-edge bg-black/35 px-1.5 py-1 text-text',
  'placeholder:text-text-dim disabled:opacity-40',
)
const BUTTON = cx(
  'border bg-black/35 px-2 leading-5 hover:text-text-strong',
  'not-disabled:active:bg-accent/12 disabled:opacity-40',
)
const HUNK = cx(
  'overflow-x-auto bg-black/40 px-2 py-1 font-mono text-[11px] leading-snug',
  'text-text-dim',
)
// A strip of the panel above the footer, and the footer.
const STRIP = 'flex shrink-0 flex-wrap items-center gap-2 border-t border-panel-edge px-3 py-1.5'
const PLAIN = 'border-panel-edge text-text'
const LINK =
  'shrink-0 cursor-pointer text-text-dim underline transition-colors duration-150 hover:text-text disabled:opacity-40'

const TONE: Record<Recommendation, string> = {
  approve: 'text-review-approve',
  comment: 'text-review-comment',
  'request-changes': 'text-review-changes',
}

// The colour of the switch and of Send review follows the switch: amber or red.
const VERDICT_TONE: Record<SendVerdict, { on: string; send: string }> = {
  comment: {
    on: 'bg-review-comment/12 text-review-comment',
    send: 'border-review-comment bg-review-comment/15 text-text-strong',
  },
  'request-changes': {
    on: 'bg-review-changes/12 text-review-changes',
    send: 'border-review-changes bg-review-changes/15 text-text-strong',
  },
}

function CommentBox({
  busy,
  comment,
  onRemove,
  onText,
  removed,
  text,
}: {
  busy: boolean
  comment: DraftCommentView
  onRemove(id: string, removed: boolean): void
  onText(id: string, text: string): void
  removed: boolean
  text: string
}): React.JSX.Element {
  const place = placeText(comment)
  return (
    <div className='mb-2 border border-panel-edge' data-draft-comment={comment.id}>
      <div className='flex items-baseline gap-2 bg-section px-2 py-0.5'>
        <span className='min-w-0 flex-1 break-words text-text'>{place}</span>
        {comment.yours && <span className='shrink-0 text-text-dim'>Added by you</span>}
        <button
          className={LINK}
          disabled={busy}
          onClick={() => onRemove(comment.id, !removed)}
          type='button'
        >
          {removed ? 'Undo' : 'Remove'}
        </button>
      </div>
      {removed ? (
        <p className='px-2 py-1 text-text-dim'>You removed this comment.</p>
      ) : (
        <>
          {comment.hunk.length > 0 && <pre className={HUNK}>{comment.hunk.join('\n')}</pre>}
          <textarea
            aria-label={`Comment on ${place}`}
            className={cx(BOX, 'min-h-14 border-t')}
            disabled={busy}
            maxLength={MAX_REVIEW_TEXT}
            onChange={e => onText(comment.id, e.target.value)}
            value={text}
          />
        </>
      )}
    </div>
  )
}

export function ReviewDraft(p: ReviewDraftProps): React.JSX.Element {
  const { draft } = p
  // A changed PR allows only a discard. A locked panel allows nothing.
  const stopped = p.busy || p.locked
  const blocked = stopped || draft.changed
  return (
    <div className='flex h-full min-h-0 flex-col text-xs' data-review-draft={draft.key}>
      <div className='min-h-0 flex-1 overflow-auto px-3 py-2'>
        <p className='break-words text-text'>
          {'Claude suggests: '}
          <span className={cx(TONE[draft.recommendation])}>
            {RECOMMENDATION_TEXT[draft.recommendation]}
          </span>
          {draft.why === '' ? '.' : `. ${draft.why}`}
        </p>
        {draft.changed && <p className='mt-1.5 text-text-dim'>{CHANGED_TEXT}</p>}
        <p className={LABEL}>Summary</p>
        <textarea
          aria-label='Summary'
          className={cx(BOX, 'min-h-16 border')}
          data-draft-summary={true}
          disabled={p.busy}
          maxLength={MAX_REVIEW_TEXT}
          onChange={e => p.onBody(e.target.value)}
          placeholder='Write a summary'
          value={p.body}
        />
        <p className={LABEL}>{`Comments (${draft.comments.length})`}</p>
        {draft.comments.length === 0 && <p className='text-text-dim'>No comments in this draft.</p>}
        {draft.comments.map(c => (
          <CommentBox
            busy={p.busy}
            comment={c}
            key={c.id}
            onRemove={p.onRemove}
            onText={p.onText}
            removed={p.removed[c.id] === true}
            text={p.texts[c.id] ?? c.body}
          />
        ))}
      </div>
      {p.confirm !== null && (
        <div className={STRIP} data-draft-confirm={p.confirm}>
          <p className='min-w-0 flex-1 text-text'>{confirmText(p.confirm, yoursCount(draft))}</p>
          <button className={cx(BUTTON, PLAIN)} disabled={p.busy} onClick={p.onKeep} type='button'>
            Keep draft
          </button>
          <button
            className={cx(BUTTON, PLAIN)}
            data-draft-confirm-ok={true}
            disabled={stopped}
            onClick={p.confirm === 'discard' ? p.onDiscard : p.onApprove}
            type='button'
          >
            {p.confirm === 'discard' ? 'Discard draft' : 'Approve instead'}
          </button>
        </div>
      )}
      {p.locked && (
        <p className={cx(STRIP, 'text-text-dim')} data-draft-locked={true}>
          {LOCKED_TEXT}
        </p>
      )}
      <div className={cx(STRIP, 'justify-between')}>
        <div className='flex flex-wrap items-center gap-1.5'>
          <button
            className={cx(BUTTON, PLAIN)}
            data-draft-discard={true}
            disabled={stopped}
            onClick={p.onDiscard}
            type='button'
          >
            Discard draft
          </button>
          <button
            className={cx(BUTTON, 'border-review-approve text-review-approve')}
            data-draft-approve={true}
            disabled={blocked}
            onClick={p.onApprove}
            type='button'
          >
            Approve instead
          </button>
        </div>
        <div className='flex flex-wrap items-center gap-1.5'>
          <span className='text-text-dim'>Send as</span>
          <div className='flex border border-panel-edge'>
            {SEND_VERDICTS.map(v => (
              <button
                aria-pressed={v === p.verdict}
                className={cx(
                  'px-2 leading-5 disabled:opacity-40',
                  v === p.verdict ? VERDICT_TONE[v].on : 'text-text-dim hover:text-text',
                )}
                data-draft-verdict={v}
                disabled={p.busy}
                key={v}
                onClick={() => p.onVerdict(v)}
                type='button'
              >
                {VERDICT_TEXT[v]}
              </button>
            ))}
          </div>
          <button
            className={cx(BUTTON, VERDICT_TONE[p.verdict].send)}
            data-draft-send={true}
            disabled={blocked}
            onClick={p.onSend}
            type='button'
          >
            Send review
          </button>
        </div>
      </div>
    </div>
  )
}
