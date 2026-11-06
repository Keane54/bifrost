// The Rename dialog (spec 9.1). It sets the local name of the session in Bifrost.
// It can also send "/rename <name>" to an owned session.
import { Dialog } from '@base-ui/react/dialog'
import { useRef, useState } from 'react'
import { MAX_RENAME } from '../../../shared/input'
import { useRegistry } from '../data/registry'
import { focusOverviewRows } from '../keys/focus-rows'
import { overviewRowsOf } from '../keys/focus-zone'
import { CheckBox } from '../lib/CheckBox'
import { errorMessage } from '../lib/error-message'
import { ACTIONS, actionStateFor } from './action-model'
import { useActions } from './actions-context'
import { DIALOG_BACKDROP, DIALOG_BUTTON, DIALOG_POPUP } from './ConfirmDialog'
import { friendlyError } from './errors'
import {
  CLAUDE_BOX_LABEL,
  NAME_FIELD_LABEL,
  planRename,
  RESET_LABEL,
  renameControls,
} from './rename-model'

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
  const [alsoClaude, setAlsoClaude] = useState(false)
  const [busy, setBusy] = useState(false)
  const inputRef = useRef<HTMLInputElement>(null)
  // The Overview whose rows had the focus when the dialog opened (M5a carry-over 1). Base UI gives
  // the focus back to the first tabbable child of an element that is not tabbable. The rows area
  // has tabIndex -1, so the focus went to a column header button. So the dialog focuses the rows
  // itself.
  const [rowsPanel] = useState(() => overviewRowsOf(document.activeElement))

  async function onSubmit(e: React.FormEvent<HTMLFormElement>): Promise<void> {
    e.preventDefault()
    if (busy) return
    // The row can change while the dialog is open, for example it goes away.
    const state = actionStateFor('rename', row, contextFor(sessionId))
    if (!state.enabled || row === undefined) {
      setReason(state.reason)
      return
    }
    const plan = planRename(row, { alsoClaude, name })
    if (!plan.ok) {
      setReason(plan.reason)
      return
    }
    setBusy(true)
    setReason(null)
    try {
      // Send first. If the send fails, the local name stays as it is.
      if (plan.send !== null) await send(sessionId, plan.send)
      await window.bifrost.registry.setAlias(sessionId, plan.alias)
      onClose()
    } catch (err) {
      setReason(friendlyError(errorMessage(err)))
      setBusy(false)
    }
  }

  async function onReset(): Promise<void> {
    if (busy) return
    setBusy(true)
    setReason(null)
    try {
      await window.bifrost.registry.setAlias(sessionId, null)
      onClose()
    } catch (err) {
      setReason(friendlyError(errorMessage(err)))
      setBusy(false)
    }
  }

  const controls = row === undefined ? null : renameControls(row)
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
          finalFocus={() => {
            if (rowsPanel === null) return true
            focusOverviewRows(rowsPanel)
            return false
          }}
          initialFocus={inputRef}
        >
          <Dialog.Title className='font-semibold text-text-strong'>{title}</Dialog.Title>
          <form className='flex flex-col gap-2' onSubmit={onSubmit}>
            <label className='text-text-dim text-xs' htmlFor={`rename-name-${sessionId}`}>
              {NAME_FIELD_LABEL}
            </label>
            <input
              aria-label={NAME_FIELD_LABEL}
              className='min-w-0 border border-panel-edge bg-bg px-2 py-1 text-text focus:border-text-strong/30'
              id={`rename-name-${sessionId}`}
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
            {controls !== null && controls.claudeBox !== 'hidden' && (
              <div
                className={controls.claudeBox === 'disabled' ? 'opacity-70' : undefined}
                data-rename-claude-box={true}
                title={controls.claudeBoxReason ?? undefined}
              >
                <CheckBox
                  checked={alsoClaude && controls.claudeBox === 'enabled'}
                  disabled={busy || controls.claudeBox === 'disabled'}
                  label={CLAUDE_BOX_LABEL}
                  onChange={on => {
                    setAlsoClaude(on)
                    setReason(null)
                  }}
                />
              </div>
            )}
            {controls !== null && controls.claudeBoxReason !== null && (
              <p className='text-text-dim text-xs'>{controls.claudeBoxReason}</p>
            )}
            {reason !== null && (
              <p className='text-text text-xs' data-rename-reason={true}>
                {reason}
              </p>
            )}
            <div className='flex items-center justify-end gap-2'>
              {controls?.showReset && (
                <button
                  className={DIALOG_BUTTON}
                  data-rename-reset={true}
                  disabled={busy}
                  onClick={onReset}
                  type='button'
                >
                  {RESET_LABEL}
                </button>
              )}
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
