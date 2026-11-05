// The New session dialog (spec 8.9). It runs "claude --bg" with the values of the form.
import { Dialog } from '@base-ui/react/dialog'
import { useEffect, useId, useReducer, useRef, useState } from 'react'
import { isSendKey } from '../../../shared/input'
import {
  type DirInfo,
  MAX_NAME,
  MODEL_CHOICES,
  type ModelChoice,
  PERMISSION_MODES,
} from '../../../shared/new-session'
import { actionLabel } from '../actions/action-model'
import { useActions } from '../actions/actions-context'
import { DIALOG_BACKDROP, DIALOG_BUTTON, DIALOG_POPUP_WIDE } from '../actions/ConfirmDialog'
import { friendlyError } from '../actions/errors'
import { chatPanelId } from '../chat/views'
import { useRegistry } from '../data/registry'
import { cx } from '../lib/cx'
import { errorMessage } from '../lib/error-message'
import { useWmControls } from '../wm/context'
import { recentDirectories, rememberSession } from './history'
import { useHistory } from './history-context'
import { formReducer, initialForm, toSpec, worktreeState } from './new-session-form'

// The folder check starts this long after the last change of the folder.
const DIR_CHECK_MS = 300
const STARTING = 'Starting the session...'

const FIELD =
  'min-w-0 border border-panel-edge bg-bg px-2 py-1 text-text outline-none focus:border-text-strong/30 disabled:opacity-40'
const LABEL = 'flex flex-col gap-1 text-text-dim text-xs'

// 4 hex characters for the default name.
function newSuffix(): string {
  return Array.from(crypto.getRandomValues(new Uint8Array(2)), b =>
    b.toString(16).padStart(2, '0'),
  ).join('')
}

function Form({ onClose }: { onClose(): void }): React.JSX.Element {
  const { history, update } = useHistory()
  const { rows, select } = useRegistry()
  const { globalContext } = useActions()
  const { dispatch: wmDispatch } = useWmControls()
  const [form, dispatch] = useReducer(formReducer, undefined, () =>
    initialForm(history, newSuffix()),
  )
  const [info, setInfo] = useState<DirInfo | null>(null)
  const [reason, setReason] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [checkFailed, setCheckFailed] = useState(false)
  // True from the first submit at once, before the next render.
  const startingRef = useRef(false)
  const listId = useId()
  const cwdRef = useRef<HTMLInputElement>(null)
  // True after a failed start. The Folder field is off while the form is busy. So the focus
  // moves when the busy state ends.
  const refocusRef = useRef(false)
  const dirs = recentDirectories(history, rows)

  useEffect(() => {
    if (busy || !refocusRef.current) return
    refocusRef.current = false
    cwdRef.current?.focus()
  }, [busy])

  // Check the folder 300 ms after the last change. A change clears the old result first.
  useEffect(() => {
    setInfo(null)
    setCheckFailed(false)
    if (!form.cwd.startsWith('/')) return
    let active = true
    const timer = window.setTimeout(() => {
      window.bifrost.sessions.dirInfo(form.cwd).then(
        result => {
          if (active) setInfo(result)
        },
        () => {
          if (active) setCheckFailed(true)
        },
      )
    }, DIR_CHECK_MS)
    return () => {
      active = false
      window.clearTimeout(timer)
    }
  }, [form.cwd])

  const worktree = worktreeState(info, undefined, checkFailed, form.cwd)

  async function submit(): Promise<void> {
    if (busy || startingRef.current) return
    const result = toSpec(form)
    if (!result.ok) {
      setReason(result.reason)
      return
    }
    startingRef.current = true
    setBusy(true)
    setReason(null)
    let sessionId: string
    try {
      sessionId = (await window.bifrost.sessions.create(result.spec)).sessionId
    } catch (err) {
      setReason(friendlyError(errorMessage(err)))
      startingRef.current = false
      refocusRef.current = true
      setBusy(false)
      return
    }
    // The session exists now. A second submit would start a copy, so the fields stay off.
    update(h => rememberSession(h, result.spec))
    onClose()
    select(sessionId)
    wmDispatch({ panelId: chatPanelId(sessionId), type: 'open' })
  }

  async function browse(): Promise<void> {
    try {
      const dir = await window.bifrost.sessions.pickDirectory(form.cwd || null)
      if (dir !== null) dispatch({ cwd: dir, type: 'cwd' })
    } catch (err) {
      setReason(friendlyError(errorMessage(err)))
    }
  }

  const title = actionLabel('new-session', globalContext().labels)
  return (
    <Dialog.Root
      onOpenChange={open => {
        if (!open && !busy) onClose()
      }}
      open={true}
    >
      <Dialog.Portal>
        <Dialog.Backdrop className={DIALOG_BACKDROP} />
        <Dialog.Popup
          className={DIALOG_POPUP_WIDE}
          data-new-session-dialog={true}
          initialFocus={cwdRef}
        >
          <Dialog.Title className='font-semibold text-text-strong'>{title}</Dialog.Title>
          <form
            className='flex flex-col gap-3'
            onSubmit={e => {
              e.preventDefault()
              void submit()
            }}
          >
            <div className={LABEL}>
              <label htmlFor={`${listId}-cwd`}>Folder</label>
              <div className='flex gap-2'>
                <input
                  className={cx(FIELD, 'flex-1')}
                  disabled={busy}
                  id={`${listId}-cwd`}
                  list={listId}
                  onChange={e => {
                    dispatch({ cwd: e.target.value, type: 'cwd' })
                    setReason(null)
                  }}
                  ref={cwdRef}
                  spellCheck={false}
                  value={form.cwd}
                />
                <datalist id={listId}>
                  {dirs.map(dir => (
                    <option key={dir} value={dir} />
                  ))}
                </datalist>
                <button
                  className={DIALOG_BUTTON}
                  disabled={busy}
                  onClick={() => void browse()}
                  type='button'
                >
                  Choose...
                </button>
              </div>
            </div>
            <label className={LABEL}>
              Name
              <input
                className={FIELD}
                disabled={busy}
                maxLength={MAX_NAME}
                onChange={e => {
                  dispatch({ name: e.target.value, type: 'name' })
                  setReason(null)
                }}
                spellCheck={false}
                value={form.name}
              />
            </label>
            <div className='flex gap-2'>
              <label className={cx(LABEL, 'flex-1')}>
                Model
                <select
                  className={FIELD}
                  disabled={busy}
                  onChange={e => dispatch({ model: e.target.value as ModelChoice, type: 'model' })}
                  value={form.model}
                >
                  {MODEL_CHOICES.map(m => (
                    <option key={m.value} value={m.value}>
                      {m.label}
                    </option>
                  ))}
                </select>
              </label>
              <label className={cx(LABEL, 'flex-1')}>
                Permission mode
                <select
                  className={FIELD}
                  disabled={busy}
                  onChange={e => dispatch({ mode: e.target.value, type: 'mode' })}
                  value={form.permissionMode}
                >
                  <option value=''>Default</option>
                  {PERMISSION_MODES.map(mode => (
                    <option key={mode} value={mode}>
                      {mode}
                    </option>
                  ))}
                </select>
              </label>
            </div>
            <label className={LABEL}>
              First prompt
              <textarea
                className={cx(FIELD, 'resize-none')}
                disabled={busy}
                onChange={e => {
                  dispatch({ prompt: e.target.value, type: 'prompt' })
                  setReason(null)
                }}
                onKeyDown={e => {
                  const key = {
                    isComposing: e.nativeEvent.isComposing,
                    key: e.key,
                    shiftKey: e.shiftKey,
                  }
                  if (!isSendKey(key)) return
                  e.preventDefault()
                  void submit()
                }}
                placeholder='Optional'
                rows={3}
                spellCheck={false}
                value={form.prompt}
              />
            </label>
            <label
              className={cx(
                'flex items-center gap-2 text-text text-xs',
                (!worktree.enabled || busy) && 'opacity-40',
              )}
              title={worktree.reason ?? undefined}
            >
              <input
                checked={form.worktree}
                disabled={!worktree.enabled || busy}
                onChange={e => dispatch({ on: e.target.checked, type: 'worktree' })}
                type='checkbox'
              />
              Use a worktree
            </label>
            {busy && (
              <p className='text-text-dim text-xs' data-new-session-starting={true}>
                {STARTING}
              </p>
            )}
            {reason !== null && (
              <p className='text-text text-xs' data-new-session-reason={true}>
                {reason}
              </p>
            )}
            <div className='flex items-center justify-end gap-2'>
              <Dialog.Close className={DIALOG_BUTTON} disabled={busy}>
                Cancel
              </Dialog.Close>
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

// The form mounts at each open. So each open starts with fresh values.
export default function NewSessionDialog({
  open,
  onClose,
}: {
  open: boolean
  onClose(): void
}): React.JSX.Element | null {
  return open ? <Form onClose={onClose} /> : null
}
