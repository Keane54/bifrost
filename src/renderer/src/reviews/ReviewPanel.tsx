// The Review panel (user decision, 2026-11-13): the user checks the draft review of Claude for one
// To review row, edits it, and sends it, discards it or approves instead. The edits stay in this
// panel until Send review (ruling B5). The main process reads the draft from GitHub when the
// panel opens, and again before each write.
import { useEffect, useState } from 'react'
import type { DraftResult, DraftView, SendVerdict } from '../../../shared/reviews'
import { friendlyError } from '../actions/errors'
import { ErrorLine } from '../lib/ErrorLine'
import { errorMessage } from '../lib/error-message'
import { useWmControls } from '../wm/context'
import { setDraftKey, useDraftKey } from './draft-key'
import { draftTitle, editsOf, firstVerdict, yoursCount } from './draft-text'
import { ReviewDraft } from './ReviewDraft'
import { useReviews } from './use-reviews'

// The title of the panel, with the PR of the panel.
export function ReviewTitle(): React.JSX.Element {
  return <>{draftTitle(useDraftKey())}</>
}

export default function ReviewPanel(): React.JSX.Element {
  const { dispatch } = useWmControls()
  const key = useDraftKey()
  const snapshot = useReviews()
  const [draft, setDraft] = useState<DraftView | null>(null)
  const [body, setBody] = useState('')
  const [texts, setTexts] = useState<Record<string, string>>({})
  const [removed, setRemoved] = useState<Record<string, boolean>>({})
  const [verdict, setVerdict] = useState<SendVerdict>('comment')
  const [confirm, setConfirm] = useState<'discard' | 'approve' | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  // The store holds the key only while the panel is open.
  useEffect(() => () => setDraftKey(null), [])

  // Each PR reads its draft from GitHub, and starts with no edits. An answer for an older key
  // does not count.
  useEffect(() => {
    setDraft(null)
    setTexts({})
    setRemoved({})
    setConfirm(null)
    setError(null)
    if (key === null) return
    let live = true
    window.bifrost.reviews.draft(key).then(
      result => {
        if (!live) return
        if (!result.ok) {
          setError(result.message)
          return
        }
        setDraft(result.draft)
        setBody(result.draft.body)
        setVerdict(firstVerdict(result.draft.recommendation))
      },
      (err: unknown) => {
        if (live) setError(friendlyError(errorMessage(err)))
      },
    )
    return () => {
      live = false
    }
  }, [key])

  const close = (): void => dispatch({ panelId: 'review-draft', type: 'close' })

  if (key === null) {
    return <p className='px-3 py-2 text-xs text-text-dim'>Nothing to review right now.</p>
  }
  if (draft === null) {
    return (
      <div className='flex h-full min-h-0 flex-col text-xs'>
        <p className='min-h-0 flex-1 px-3 py-2 text-text-dim'>
          {error === null ? 'Loading the draft from GitHub…' : "Bifrost couldn't open the draft."}
        </p>
        <ErrorLine message={error} />
      </div>
    )
  }

  // Run one action. After a result that worked, the panel closes. After a failure, the edits stay,
  // so the user can try again.
  const run = (job: () => Promise<DraftResult>): void => {
    setError(null)
    setBusy(true)
    job().then(
      result => {
        setBusy(false)
        setConfirm(null)
        if (result.ok) close()
        else setError(result.message)
      },
      (err: unknown) => {
        setBusy(false)
        setConfirm(null)
        setError(friendlyError(errorMessage(err)))
      },
    )
  }

  // The panel allows an action only while the row offers the draft. After Approve instead, Discard
  // draft or an unknown result, the row does not. The action of this panel itself does not lock it.
  const row = snapshot.toReview.find(r => r.key === key)
  const locked = !busy && row?.draft !== 'ready'

  // A delete of the draft also deletes the comments that the user added on GitHub. The panel says
  // so first (ruling B8).
  const asks = yoursCount(draft) > 0
  const onDiscard = (): void => {
    if (asks && confirm !== 'discard') setConfirm('discard')
    else run(() => window.bifrost.reviews.discardDraft(key))
  }
  const onApprove = (): void => {
    if (asks && confirm !== 'approve') setConfirm('approve')
    else run(() => window.bifrost.reviews.approveInstead(key))
  }
  const onSend = (): void =>
    run(() => window.bifrost.reviews.sendDraft(key, editsOf(draft, body, texts, removed, verdict)))

  return (
    <div className='flex h-full min-h-0 flex-col'>
      <div className='min-h-0 flex-1'>
        <ReviewDraft
          body={body}
          busy={busy}
          confirm={confirm}
          draft={draft}
          locked={locked}
          onApprove={onApprove}
          onBody={setBody}
          onDiscard={onDiscard}
          onKeep={() => setConfirm(null)}
          onRemove={(id, on) => setRemoved(r => ({ ...r, [id]: on }))}
          onSend={onSend}
          onText={(id, text) => setTexts(t => ({ ...t, [id]: text }))}
          onVerdict={setVerdict}
          removed={removed}
          texts={texts}
          verdict={verdict}
        />
      </div>
      <ErrorLine message={error} onClose={() => setError(null)} />
    </div>
  )
}
