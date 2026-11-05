// The send box of the Selected Item panel (spec 8.4 item 6). Enter sends. Shift+Enter adds a line.
import { useEffect, useRef, useState } from 'react'
import { isSendKey } from '../../../shared/input'
import type { SessionRow } from '../../../shared/types'
import { actionLabel, actionStateFor } from '../actions/action-model'
import { useActions } from '../actions/actions-context'
import { friendlyError } from '../actions/errors'
import { cx } from '../lib/cx'
import { errorMessage } from '../lib/error-message'

const SENDING = 'Sending...'
const SLASH_HINT = 'This runs as a slash command.'

// The number of the last focus request that a send box used.
// So a new mount of the panel does not use an old request again.
let usedFocus = 0

interface Failure {
  sessionId: string
  message: string
}

export default function SendBox({ row }: { row: SessionRow }): React.JSX.Element {
  const { contextFor, focusRequest, send } = useActions()
  const sessionId = row.sessionId
  const ctx = contextFor(sessionId)
  const state = actionStateFor('send-message', row, ctx)
  // The draft of each session. A draft stays when the selection changes.
  const drafts = useRef(new Map<string, string>())
  // The map holds the drafts. A change of a draft renders the box again.
  const [, setVersion] = useState(0)
  const [sending, setSending] = useState<ReadonlySet<string>>(() => new Set())
  const [failure, setFailure] = useState<Failure | null>(null)
  const field = useRef<HTMLTextAreaElement>(null)
  const draft = drafts.current.get(sessionId) ?? ''
  const isSending = sending.has(sessionId)

  function setDraft(id: string, text: string): void {
    if (text === '') drafts.current.delete(id)
    else drafts.current.set(id, text)
    setVersion(v => v + 1)
  }

  function setSendingFor(id: string, on: boolean): void {
    setSending(prev => {
      const next = new Set(prev)
      if (on) next.add(id)
      else next.delete(id)
      return next
    })
  }

  async function submit(): Promise<void> {
    if (!state.enabled || isSending) return
    const id = sessionId
    const text = draft
    if (text.trim() === '') return
    setFailure(null)
    setSendingFor(id, true)
    try {
      await send(id, text)
      // A success clears the draft. The field is read-only during the send.
      setDraft(id, '')
    } catch (err) {
      // A failed send keeps the text.
      setFailure({ message: friendlyError(errorMessage(err)), sessionId: id })
    } finally {
      setSendingFor(id, false)
    }
  }

  // A focus request from Send message or Run slash command (Other...).
  useEffect(() => {
    const request = focusRequest
    if (!request || request.n <= usedFocus || request.sessionId !== sessionId) return
    usedFocus = request.n
    // A disabled field gets no text and no focus.
    if (field.current?.disabled) return
    if (request.text === '/' && (drafts.current.get(sessionId) ?? '') === '') {
      drafts.current.set(sessionId, '/')
      setVersion(v => v + 1)
    }
    // Wait one frame. The menu that started the request closes first.
    const frame = requestAnimationFrame(() => {
      const el = field.current
      if (!el) return
      el.focus()
      el.setSelectionRange(el.value.length, el.value.length)
    })
    return () => cancelAnimationFrame(frame)
  }, [focusRequest, sessionId])

  // One line under the field. The disabled reason comes first.
  let line: { text: string; dim: boolean } | null = null
  if (!state.enabled && state.reason !== null) line = { dim: true, text: state.reason }
  else if (isSending) line = { dim: true, text: SENDING }
  else if (failure?.sessionId === sessionId) line = { dim: false, text: failure.message }
  else if (draft.trimStart().startsWith('/')) line = { dim: true, text: SLASH_HINT }

  return (
    <div className='flex flex-col gap-1' data-send-box={true}>
      <textarea
        aria-label={actionLabel('send-message', ctx.labels)}
        className='min-w-0 resize-none border border-panel-edge bg-bg px-2 py-1 text-text outline-none focus:border-text-strong/30 disabled:opacity-40'
        disabled={!state.enabled}
        onChange={e => {
          setDraft(sessionId, e.target.value)
          if (failure?.sessionId === sessionId) setFailure(null)
        }}
        onKeyDown={e => {
          const key = { isComposing: e.nativeEvent.isComposing, key: e.key, shiftKey: e.shiftKey }
          if (!isSendKey(key)) return
          e.preventDefault()
          void submit()
        }}
        placeholder={actionLabel('send-message', ctx.labels)}
        readOnly={isSending}
        ref={field}
        rows={3}
        spellCheck={false}
        value={draft}
      />
      {line !== null && (
        <p
          className={cx('min-w-0 whitespace-pre-line', line.dim ? 'text-text-dim' : 'text-text')}
          data-send-line={true}
        >
          {line.text}
        </p>
      )}
    </div>
  )
}
