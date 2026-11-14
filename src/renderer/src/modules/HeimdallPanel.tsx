// Heimdall's panel (Modules design 7 and 8.4). It is Bifrost's own UI in the purple Heimdall
// frame, and a module can never draw it. It has two views. The approval view shows the approval
// of an install or of an update that asks for more permissions. The Discuss view shows the
// request of a module for Discuss with Claude. Of the module, only its approved name, its texts
// (as plain text) and an icon of the fixed set show here.
import { type Dispatch, useEffect, useId, useRef, useState } from 'react'
import { stripInvisible } from '../../../shared/invisible'
import type { ModuleApproval, ModuleDiscuss } from '../../../shared/modules'
import { DIALOG_BUTTON } from '../actions/ConfirmDialog'
import { friendlyError } from '../actions/errors'
import { chatPanelId } from '../chat/views'
import { useRegistry } from '../data/registry'
import { cx } from '../lib/cx'
import { ErrorLine } from '../lib/ErrorLine'
import { errorMessage } from '../lib/error-message'
import { recentDirectories } from '../sessions/history'
import { useHistory } from '../sessions/history-context'
import { newPermissionsText, PERMISSION_LABELS } from '../settings/modules-rows'
import { useWmControls } from '../wm/context'
import type { WmAction } from '../wm/state'
import {
  getHeimdallRequest,
  type HeimdallRequest,
  setHeimdallRequest,
  useHeimdallRequest,
} from './heimdall-key'
import { MODULE_ICON_COMPONENTS } from './module-icons'
import { TierBadge } from './TierBadge'

// The fixed list of what a module can never do (the approved mock).
export const NEVER_ITEMS: readonly string[] = Object.freeze([
  'See your tokens, keys or logins',
  'Read files on your Mac (it sees only a file that you pick or drop on it)',
  'Type into a Claude session',
  'Change Bifrost',
])

// Each module gets this, with no permission.
export const OWN_PANELS = 'Show its own panels and keep a little data of its own'

export const HEIMDALL_IDLE = 'Heimdall has nothing for you right now.'

const LABEL = 'mt-3 mb-1 text-[10px] tracking-wider text-text-dim uppercase'
// The main button of Heimdall is purple. A press gives a short cyan tint (spec 8.10).
const ALLOW_BUTTON = cx(
  'shrink-0 border border-heimdall px-2 py-0.5 text-heimdall hover:bg-panel',
  'enabled:active:bg-accent/12 disabled:opacity-40',
)

// "Hello v1.0.0", or "Hello v1.2.0 → v1.3.0" for an update.
export function approvalTitle(a: ModuleApproval): string {
  if (a.kind === 'update' && a.fromVersion !== null) {
    return `${a.name} v${a.fromVersion} → v${a.version}`
  }
  return `${a.name} v${a.version}`
}

export function approvalIntro(a: ModuleApproval): string {
  if (a.kind === 'install') {
    return 'Check what this module asks for. It runs only after you allow it.'
  }
  const added = a.permissions.filter(p => p.added).length
  return `This update asks for ${newPermissionsText(added)}. Everything else stays the same.`
}

export function approvalButtons(a: ModuleApproval): { allow: string; cancel: string } {
  if (a.kind === 'update') {
    return { allow: 'Allow and update', cancel: `Stay on v${a.fromVersion ?? a.version}` }
  }
  return { allow: 'Allow', cancel: 'Cancel' }
}

function sourceLine(a: ModuleApproval): string {
  switch (a.sourceKind) {
    case 'git':
      return `From ${a.source}`
    case 'dev':
      return `Developer folder ${a.source}. Bifrost uses it in place.`
    default:
      return `From the folder ${a.source}`
  }
}

// Show an approval in Heimdall's panel.
export function showApproval(approval: ModuleApproval, dispatch: Dispatch<WmAction>): void {
  setHeimdallRequest({ approval, kind: 'approval' })
  dispatch({ panelId: 'heimdall', type: 'open' })
}

export interface ApprovalViewProps {
  approval: ModuleApproval
  busy: boolean
  error: string | null
  onAllow(): void
  onCancel(): void
  onCloseError(): void
}

// The texts of the module go in as React text, so they never become markup.
export function ApprovalView({
  approval,
  busy,
  error,
  onAllow,
  onCancel,
  onCloseError,
}: ApprovalViewProps): React.JSX.Element {
  const Icon = MODULE_ICON_COMPONENTS[approval.icon]
  const buttons = approvalButtons(approval)
  return (
    <div
      className={cx('flex h-full min-h-0 flex-col text-xs')}
      data-heimdall-approval={approval.requestId}
    >
      <div className={cx('min-h-0 flex-1 overflow-auto px-3 py-2')}>
        <div className={cx('flex items-start gap-2')}>
          <Icon aria-hidden={true} className={cx('mt-0.5 size-4 shrink-0 text-heimdall')} />
          <div className={cx('min-w-0 flex-1')}>
            <p className={cx('break-words text-text-strong')}>{approvalTitle(approval)}</p>
            <p className={cx('break-words text-text-dim')}>{approval.description}</p>
          </div>
          <TierBadge tier={approval.tier} />
        </div>
        <p className={cx('mt-2 text-text')}>{approvalIntro(approval)}</p>
        <p className={cx('mt-1 break-words text-text-dim')}>{sourceLine(approval)}</p>
        <h3 className={cx(LABEL)}>What it can do</h3>
        <ul>
          <li className={cx('flex gap-2 py-0.5')}>
            <span className={cx('w-4 shrink-0 text-center text-text-dim')}>·</span>
            <span className={cx('text-text')}>{OWN_PANELS}</span>
          </li>
          {approval.permissions.map(p => (
            <li
              className={cx('flex gap-2 py-0.5', p.added && '-mx-1.5 bg-module-update/8 px-1.5')}
              data-approval-new={p.added ? 'true' : 'false'}
              data-approval-permission={p.id}
              key={p.id}
            >
              <span
                className={cx(
                  'w-4 shrink-0 text-center',
                  p.added ? 'text-module-update' : 'text-text-dim',
                )}
              >
                {p.added ? '+' : '·'}
              </span>
              <span className={cx('min-w-0 flex-1')}>
                <span className={cx('block text-text')}>
                  {p.added && <b className={cx('font-semibold text-text-strong')}>New: </b>}
                  {PERMISSION_LABELS[p.id]}
                </span>
                <span className={cx('block break-words text-text-dim')}>{p.reason}</span>
              </span>
            </li>
          ))}
        </ul>
        <h3 className={cx(LABEL)}>What it can never do</h3>
        <p className={cx('text-text-dim')}>{NEVER_ITEMS.join(' · ')}</p>
      </div>
      <ErrorLine message={error} onClose={onCloseError} />
      <div
        className={cx(
          'flex shrink-0 items-center justify-end gap-2 border-t border-panel-edge px-3 py-1.5',
        )}
      >
        <button className={cx(DIALOG_BUTTON)} disabled={busy} onClick={onCancel} type='button'>
          {buttons.cancel}
        </button>
        <button
          className={cx(ALLOW_BUTTON)}
          data-heimdall-allow={true}
          disabled={busy}
          onClick={onAllow}
          type='button'
        >
          {buttons.allow}
        </button>
      </div>
    </div>
  )
}

// The approval of one request. A new request gets a new key, so its state starts again.
function ApprovalPanel({ approval }: { approval: ModuleApproval }): React.JSX.Element {
  const { dispatch } = useWmControls()
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const close = (): void => {
    setHeimdallRequest(null)
    dispatch({ panelId: 'heimdall', type: 'close' })
  }
  // Allow and Cancel go to the main process, which checks the request again.
  const act = (call: () => Promise<void>): void => {
    setBusy(true)
    setError(null)
    call().then(close, (err: unknown) => {
      setError(friendlyError(errorMessage(err)))
      setBusy(false)
    })
  }
  return (
    <ApprovalView
      approval={approval}
      busy={busy}
      error={error}
      onAllow={() => act(() => window.bifrost.modules.approve(approval.requestId))}
      onCancel={() => act(() => window.bifrost.modules.decline(approval.requestId))}
      onCloseError={() => setError(null)}
    />
  )
}

// The texts of the Discuss view.
export const DISCUSS_INTRO = 'Write your own prompt. Claude sees only what you write here.'
export const DISCUSS_CARDS = 'From the module'
export const DISCUSS_CARDS_NOTE = "Claude doesn't see these. Copy what you need into your prompt."
export const DISCUSS_SETUP = 'Your normal Claude setup'
export const DISCUSS_SETUP_DETAIL =
  'Your own model, permission mode and MCP servers, as if you started the session yourself.'
const DISCUSS_STARTING = 'Starting the session...'
// The time that a Copy button shows "Copied".
const COPIED_MS = 1500

const FIELD = cx(
  'min-w-0 border border-panel-edge bg-bg px-2 py-1 text-text focus:border-text-strong/30',
  'disabled:opacity-40',
)
const FIELD_LABEL = 'mt-3 mb-1 block text-text-dim'

// The title of Heimdall's panel after its name.
export function heimdallTitle(request: HeimdallRequest): string {
  if (request.kind === 'discuss') return `Discuss with Claude · ${request.discuss.moduleName}`
  return approvalTitle(request.approval)
}

function cancelDiscuss(requestId: string): void {
  window.bifrost.modules.discussCancel(requestId).catch(() => {})
}

// Show the request of a module for Discuss with Claude in Heimdall's panel. An approval that
// shows stays, and the request of the module ends at once. So a module never interrupts an
// approval.
export function showDiscuss(
  discuss: ModuleDiscuss,
  dispatch: Dispatch<WmAction>,
  cancel: (requestId: string) => void = cancelDiscuss,
): void {
  if (getHeimdallRequest()?.kind === 'approval') {
    cancel(discuss.requestId)
    return
  }
  setHeimdallRequest({ discuss, kind: 'discuss' })
  dispatch({ panelId: 'heimdall', type: 'open' })
}

// Close Heimdall's panel only while it still shows this request. So an install approval that
// opened during a start stays open.
export function closeDiscussView(requestId: string, dispatch: Dispatch<WmAction>): void {
  const shown = getHeimdallRequest()
  if (shown?.kind !== 'discuss' || shown.discuss.requestId !== requestId) return
  setHeimdallRequest(null)
  dispatch({ panelId: 'heimdall', type: 'close' })
}

export interface DiscussForm {
  cwd: string
  prompt: string
}

// The prompt box always starts empty, and the user picks the folder.
export function initialDiscussForm(): DiscussForm {
  return { cwd: '', prompt: '' }
}

export function canStartDiscuss(form: DiscussForm): boolean {
  return form.prompt.trim() !== '' && form.cwd.trim() !== ''
}

// The prompt after a paste at the selection. The pasted text loses its invisible characters.
export function pastePrompt(
  value: string,
  start: number,
  end: number,
  pasted: string,
): { value: string; caret: number } {
  const clean = stripInvisible(pasted)
  return { caret: start + clean.length, value: value.slice(0, start) + clean + value.slice(end) }
}

export interface DiscussViewProps {
  discuss: ModuleDiscuss
  form: DiscussForm
  // The recent folders for the folder field.
  dirs: string[]
  busy: boolean
  // The card that shows "Copied", or null.
  copied: number | null
  error: string | null
  onCopy(index: number): void
  onCwd(cwd: string): void
  onChoose(): void
  // The new text of the prompt box. The view removed its invisible characters.
  onPrompt(prompt: string): void
  onStart(): void
  onCancel(): void
  onCloseError(): void
}

// The texts of the module go in as React text, so they never become markup.
export function DiscussView({
  busy,
  copied,
  dirs,
  discuss,
  error,
  form,
  onCancel,
  onChoose,
  onCloseError,
  onCopy,
  onCwd,
  onPrompt,
  onStart,
}: DiscussViewProps): React.JSX.Element {
  const id = useId()
  return (
    <div
      className={cx('flex h-full min-h-0 flex-col text-xs')}
      data-heimdall-discuss={discuss.requestId}
    >
      <div className={cx('min-h-0 flex-1 overflow-auto px-3 py-2')}>
        <p className={cx('break-words text-text-strong')}>{discuss.title}</p>
        <p className={cx('break-words text-text-dim')}>{`Asked by ${discuss.moduleName}`}</p>
        <p className={cx('mt-2 text-text')}>{DISCUSS_INTRO}</p>
        {discuss.cards.length > 0 && (
          <>
            <h3 className={cx(LABEL)}>{DISCUSS_CARDS}</h3>
            <p className={cx('text-text-dim')}>{DISCUSS_CARDS_NOTE}</p>
            <ul className={cx('mt-1 flex flex-col gap-1.5')}>
              {discuss.cards.map((card, index) => (
                <li
                  className={cx('border border-panel-edge px-2 py-1')}
                  data-discuss-card={index}
                  // biome-ignore lint/suspicious/noArrayIndexKey: the card order is fixed
                  key={index}
                >
                  <div className={cx('flex items-start gap-2')}>
                    <span className={cx('min-w-0 flex-1 break-words text-text-strong')}>
                      {card.label}
                    </span>
                    <button
                      className={cx(DIALOG_BUTTON)}
                      data-discuss-copy={index}
                      onClick={() => onCopy(index)}
                      type='button'
                    >
                      {copied === index ? 'Copied' : 'Copy'}
                    </button>
                  </div>
                  <p className={cx('mt-1 break-words whitespace-pre-wrap text-text-dim')}>
                    {card.text}
                  </p>
                </li>
              ))}
            </ul>
          </>
        )}
        <label className={cx(FIELD_LABEL)} htmlFor={`${id}-cwd`}>
          Folder
        </label>
        <div className={cx('flex gap-2')}>
          <input
            className={cx(FIELD, 'flex-1')}
            data-discuss-folder={true}
            disabled={busy}
            id={`${id}-cwd`}
            list={`${id}-dirs`}
            onChange={e => onCwd(e.target.value)}
            spellCheck={false}
            value={form.cwd}
          />
          <datalist id={`${id}-dirs`}>
            {dirs.map(dir => (
              <option key={dir} value={dir} />
            ))}
          </datalist>
          <button className={cx(DIALOG_BUTTON)} disabled={busy} onClick={onChoose} type='button'>
            Choose...
          </button>
        </div>
        <label className={cx(FIELD_LABEL)} htmlFor={`${id}-prompt`}>
          Your prompt
        </label>
        <textarea
          className={cx(FIELD, 'block w-full resize-y')}
          data-discuss-prompt={true}
          disabled={busy}
          id={`${id}-prompt`}
          onChange={e => onPrompt(stripInvisible(e.target.value))}
          onPaste={e => {
            e.preventDefault()
            const box = e.currentTarget
            const pasted = e.clipboardData.getData('text/plain')
            const next = pastePrompt(box.value, box.selectionStart, box.selectionEnd, pasted)
            onPrompt(next.value)
            requestAnimationFrame(() => box.setSelectionRange(next.caret, next.caret))
          }}
          rows={5}
          spellCheck={false}
          value={form.prompt}
        />
        <p className={cx('mt-3 text-text')}>{DISCUSS_SETUP}</p>
        <p className={cx('text-text-dim')}>{DISCUSS_SETUP_DETAIL}</p>
        {busy && (
          <p className={cx('mt-2 text-text-dim')} data-discuss-starting={true}>
            {DISCUSS_STARTING}
          </p>
        )}
      </div>
      <ErrorLine message={error} onClose={onCloseError} />
      <div
        className={cx(
          'flex shrink-0 items-center justify-end gap-2 border-t border-panel-edge px-3 py-1.5',
        )}
      >
        <button className={cx(DIALOG_BUTTON)} disabled={busy} onClick={onCancel} type='button'>
          Cancel
        </button>
        <button
          className={cx(ALLOW_BUTTON)}
          data-discuss-start={true}
          disabled={busy || !canStartDiscuss(form)}
          onClick={onStart}
          type='button'
        >
          Start session
        </button>
      </div>
    </div>
  )
}

// The Discuss view of one request. A new request gets a new key, so its state starts again.
// Start, Copy and Cancel go to the main process, which checks the request again.
function DiscussPanel({ discuss }: { discuss: ModuleDiscuss }): React.JSX.Element {
  const { dispatch } = useWmControls()
  const { history } = useHistory()
  const { rows, select } = useRegistry()
  const [form, setForm] = useState(initialDiscussForm)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [copied, setCopied] = useState<number | null>(null)
  // True after a start or a Cancel. Then the main process has no open request to cancel.
  const done = useRef(false)

  // A close of the panel, or a new request in it, cancels this request.
  useEffect(
    () => () => {
      if (!done.current) cancelDiscuss(discuss.requestId)
    },
    [discuss.requestId],
  )

  useEffect(() => {
    if (copied === null) return
    const timer = window.setTimeout(() => setCopied(null), COPIED_MS)
    return () => window.clearTimeout(timer)
  }, [copied])

  const fail = (err: unknown): void => setError(friendlyError(errorMessage(err)))
  const close = (): void => closeDiscussView(discuss.requestId, dispatch)

  const copy = (index: number): void => {
    setError(null)
    const call = window.bifrost.modules.discussCopy(discuss.requestId, index)
    call.then(() => setCopied(index), fail)
  }

  const choose = (): void => {
    const from = form.cwd.trim()
    window.bifrost.sessions.pickDirectory(from === '' ? null : from).then(dir => {
      if (dir !== null) setForm(f => ({ ...f, cwd: dir }))
    }, fail)
  }

  // The session opens in its chat window, as after New session. The module never gets it.
  const start = (): void => {
    if (busy || !canStartDiscuss(form)) return
    setBusy(true)
    setError(null)
    const input = { cwd: form.cwd.trim(), prompt: form.prompt }
    const call = window.bifrost.modules.discussStart(discuss.requestId, input)
    call.then(
      ({ sessionId }) => {
        done.current = true
        close()
        select(sessionId)
        dispatch({ panelId: chatPanelId(sessionId), type: 'open' })
      },
      (err: unknown) => {
        fail(err)
        setBusy(false)
      },
    )
  }

  const cancel = (): void => {
    done.current = true
    cancelDiscuss(discuss.requestId)
    close()
  }

  return (
    <DiscussView
      busy={busy}
      copied={copied}
      dirs={recentDirectories(history, rows)}
      discuss={discuss}
      error={error}
      form={form}
      onCancel={cancel}
      onChoose={choose}
      onCloseError={() => setError(null)}
      onCopy={copy}
      onCwd={cwd => {
        setForm(f => ({ ...f, cwd }))
        setError(null)
      }}
      onPrompt={prompt => {
        setForm(f => ({ ...f, prompt }))
        setError(null)
      }}
      onStart={start}
    />
  )
}

export default function HeimdallPanel(): React.JSX.Element {
  const request = useHeimdallRequest()

  // The store holds the request only while the panel is open.
  useEffect(() => () => setHeimdallRequest(null), [])

  if (request === null) {
    return <p className={cx('p-3 text-[13px] text-text-dim')}>{HEIMDALL_IDLE}</p>
  }
  if (request.kind === 'discuss') {
    return <DiscussPanel discuss={request.discuss} key={request.discuss.requestId} />
  }
  return <ApprovalPanel approval={request.approval} key={request.approval.requestId} />
}
