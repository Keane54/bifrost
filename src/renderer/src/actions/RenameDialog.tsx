// The Rename dialog (spec 9.1). It sends "/rename <name>" to the session.
import { Dialog } from '@base-ui/react/dialog'
import { useRef, useState } from 'react'
import { MAX_RENAME, renameText } from '../../../shared/input'
import { useRegistry } from '../data/registry'
import { errorMessage } from '../lib/error-message'
import { ACTIONS, actionStateFor } from './action-model'
import { useActions } from './actions-context'
import { DIALOG_BACKDROP, DIALOG_BUTTON, DIALOG_POPUP } from './ConfirmDialog'
import { friendlyError } from './errors'

export default function RenameDialog({
  sessionId,
  onClose,
}: {
  sessionId: string
  onClose(): void
}): React.JSX.Element {
  const { rows } = useRegistry()
  const { contextFor, send } = useActions()
  const row = rows.find(r => r.sessionId === sessionId)
  const labels = contextFor(sessionId).labels
  const [name, setName] = useState(() => row?.name ?? '')
  const [reason, setReason] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const inputRef = useRef<HTMLInputElement>(null)

  async function onSubmit(e: React.FormEvent<HTMLFormElement>): Promise<void> {
    e.preventDefault()
    if (busy) return
    const result = renameText(name)
    if (!result.ok) {
      setReason(result.reason)
      return
    }
    // The row can change while the dialog is open, for example a prompt opens.
    const state = actionStateFor('rename', row, contextFor(sessionId))
    if (!state.enabled) {
      setReason(state.reason)
      return
    }
    setBusy(true)
    setReason(null)
    try {
      await send(sessionId, result.text)
      onClose()
    } catch (err) {
      setReason(friendlyError(errorMessage(err)))
      setBusy(false)
    }
  }

  const title = ACTIONS.rename[labels]
  return (
    <Dialog.Root
      onOpenChange={open => {
        if (!open) onClose()
      }}
      open={true}
    >
      <Dialog.Portal>
        <Dialog.Backdrop className={DIALOG_BACKDROP} />
        <Dialog.Popup
          className={DIALOG_POPUP}
          data-rename-dialog={sessionId}
          initialFocus={inputRef}
        >
          <Dialog.Title className='font-semibold text-text-strong'>{title}</Dialog.Title>
          <form className='flex flex-col gap-2' onSubmit={onSubmit}>
            <input
              aria-label='Session name'
              className='min-w-0 border border-panel-edge bg-bg px-2 py-1 text-text outline-none focus:border-text-strong/30'
              maxLength={MAX_RENAME}
              onChange={e => {
                setName(e.target.value)
                setReason(null)
              }}
              onFocus={e => e.currentTarget.select()}
              readOnly={busy}
              ref={inputRef}
              spellCheck={false}
              value={name}
            />
            {reason !== null && (
              <p className='text-text text-xs' data-rename-reason={true}>
                {reason}
              </p>
            )}
            <div className='flex items-center justify-end gap-2'>
              <Dialog.Close className={DIALOG_BUTTON}>Cancel</Dialog.Close>
              <button className={DIALOG_BUTTON} disabled={busy} type='submit'>
                {title}
              </button>
            </div>
          </form>
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  )
}
