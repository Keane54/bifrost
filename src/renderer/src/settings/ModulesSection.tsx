// Settings > Modules (Modules design 7, the approved mock). Each module has a row with its name,
// version, source, tier badge, "Permissions" and an on/off switch. "Permissions" opens a view with
// each requested permission, its reason and a switch, the model and the daily cap of its module
// jobs, and the jobs of today. The buttons install a module from a folder or a GitHub repository,
// load a folder in place in a development build, and check for updates. An install opens
// Heimdall's panel with the approval. The rows come from the main process through
// modules:changed, so each change shows at once.
import { useEffect, useState } from 'react'
import type { PermissionId } from '../../../shared/module-manifest'
import type { ModuleApproval, ModuleRow } from '../../../shared/modules'
import { type ModelChoice, modelOptions } from '../../../shared/new-session'
import { DIALOG_BUTTON, useConfirm } from '../actions/ConfirmDialog'
import { friendlyError } from '../actions/errors'
import { CheckBox } from '../lib/CheckBox'
import { cx } from '../lib/cx'
import { ErrorLine, NoticeLine } from '../lib/ErrorLine'
import { errorMessage } from '../lib/error-message'
import { showApproval } from '../modules/HeimdallPanel'
import { TierBadge } from '../modules/TierBadge'
import { useModules, useModulesLoaded } from '../modules/use-modules'
import { useWmControls } from '../wm/context'
import {
  type CheckUpdateNote,
  checkUpdateNotes,
  jobsTodayText,
  MODULES_EMPTY,
  MODULES_ROWS,
  PERMISSION_LABELS,
  pendingUpdateLine,
  sourceLabel,
} from './modules-rows'
import { DraftField } from './rows'
import { ROW_FIELD } from './SettingRow'

const MODEL_LABEL = 'Model for module jobs'
const CAP_LABEL = 'Daily cap of module jobs'
const MAX_CAP = 500
const GIT_HINT = 'Only GitHub repositories. Bifrost uses your gh login, so a private repo works.'
// The button of an update that waits uses the amber of the update line.
const UPDATE_BUTTON = cx(
  'shrink-0 border border-module-update px-2 py-0.5 text-module-update hover:bg-panel',
  'enabled:active:bg-accent/12 disabled:opacity-40',
)

export interface ModuleRowViewProps {
  row: ModuleRow
  // True while the Permissions view of the row shows.
  open: boolean
  onToggle(): void
  onEnabled(on: boolean): void
  onPermission(id: PermissionId, on: boolean): void
  onModel(model: ModelChoice): void
  // Resolves true when the cap saved.
  onCap(cap: number): Promise<boolean>
  onRemove(): void
  onReviewUpdate(): void
}

function PermissionsView(props: ModuleRowViewProps): React.JSX.Element {
  const { row } = props
  return (
    <div className={cx('mt-2 border-t border-panel-edge pt-1')} data-module-permissions={row.id}>
      {row.requested.length === 0 && (
        <p className={cx('py-1 text-text-dim')}>This module doesn't ask for any permissions.</p>
      )}
      {row.requested.map(p => {
        const granted = row.granted.includes(p.id)
        return (
          <div
            className={cx('flex items-start gap-3 py-1')}
            data-module-permission={p.id}
            key={p.id}
          >
            <div className={cx('min-w-0 flex-1')}>
              <p className={cx('text-text')}>{PERMISSION_LABELS[p.id]}</p>
              <p className={cx('break-words text-text-dim')}>{p.reason}</p>
            </div>
            <div className={cx('w-12 shrink-0')}>
              <CheckBox
                ariaLabel={PERMISSION_LABELS[p.id]}
                checked={granted}
                label={granted ? 'On' : 'Off'}
                onChange={on => props.onPermission(p.id, on)}
              />
            </div>
          </div>
        )
      })}
      <div className={cx('flex min-h-7 items-center gap-2')}>
        <span className={cx('min-w-0 flex-1 text-text')}>{MODEL_LABEL}</span>
        <select
          aria-label={MODEL_LABEL}
          className={cx(ROW_FIELD)}
          onChange={e => props.onModel(e.target.value as ModelChoice)}
          value={row.model}
        >
          {modelOptions().map(option => (
            <option key={option.value} value={option.value}>
              {option.label}
            </option>
          ))}
        </select>
      </div>
      <div className={cx('flex min-h-7 items-center gap-2')}>
        <span className={cx('min-w-0 flex-1 text-text')}>{CAP_LABEL}</span>
        <DraftField
          label={CAP_LABEL}
          max={MAX_CAP}
          min={1}
          onCommit={async text => {
            const n = Number(text)
            return props.onCap(text.trim() === '' ? Number.NaN : n)
          }}
          type='number'
          value={String(row.dailyCap)}
          width='w-16'
        />
        <span className={cx('text-text-dim')} data-module-jobs-today={true}>
          {jobsTodayText(row.jobsToday)}
        </span>
      </div>
      <div className={cx('flex justify-end py-1')}>
        <button
          className={cx(DIALOG_BUTTON)}
          data-module-remove={row.id}
          onClick={props.onRemove}
          type='button'
        >
          Remove
        </button>
      </div>
    </div>
  )
}

export function ModuleRowView(props: ModuleRowViewProps): React.JSX.Element {
  const { open, row } = props
  const pending = pendingUpdateLine(row)
  return (
    <div className={cx('border-b border-panel-edge px-3 py-2')} data-module-row={row.id}>
      <div className={cx('flex items-center gap-2.5')}>
        <div className={cx('min-w-0 flex-1')}>
          <p className={cx('truncate text-text-strong')}>
            {row.name}
            <span className={cx('text-text-dim')}>{` v${row.version} · ${sourceLabel(row)}`}</span>
          </p>
          <p className={cx('break-words text-text-dim')}>{row.description}</p>
        </div>
        <TierBadge tier={row.tier} />
        <button
          aria-expanded={open}
          className={cx(DIALOG_BUTTON)}
          data-module-open-permissions={row.id}
          onClick={props.onToggle}
          type='button'
        >
          Permissions
        </button>
        <span className={cx('flex w-12 shrink-0')} data-module-switch={row.id}>
          <CheckBox
            ariaLabel={`${row.name} on`}
            checked={row.enabled}
            disabled={row.offReason !== null}
            label={row.enabled ? 'On' : 'Off'}
            onChange={props.onEnabled}
          />
        </span>
      </div>
      {row.offReason !== null && <p className={cx('mt-1 text-text-dim')}>{row.offReason}</p>}
      {pending !== null && (
        <div className={cx('mt-1 flex items-center gap-2')}>
          <p className={cx('min-w-0 flex-1 text-module-update')}>{pending}</p>
          <button
            className={cx(UPDATE_BUTTON)}
            data-module-review-update={row.id}
            onClick={props.onReviewUpdate}
            type='button'
          >
            Check update
          </button>
        </div>
      )}
      {open && <PermissionsView {...props} />}
    </div>
  )
}

export interface ModulesActionsViewProps {
  // False in a development build. Only then does Load from folder (developer) show.
  packaged: boolean
  busy: boolean
  onFolder(): void
  // Resolves true when Heimdall shows the approval.
  onGit(url: string): Promise<boolean>
  onDev(): void
  onCheck(): void
}

export function ModulesActionsView(props: ModulesActionsViewProps): React.JSX.Element {
  const [gitOpen, setGitOpen] = useState(false)
  const [url, setUrl] = useState('')
  const { busy, onGit } = props
  return (
    <div className={cx('flex flex-col gap-2 px-3 py-2')}>
      <div className={cx('flex flex-wrap items-center gap-2')}>
        <button
          className={cx(DIALOG_BUTTON)}
          data-modules-action='check'
          disabled={busy}
          onClick={props.onCheck}
          type='button'
        >
          {MODULES_ROWS.checkUpdates}
        </button>
        <span className={cx('flex-1')} />
        <button
          className={cx(DIALOG_BUTTON)}
          data-modules-action='folder'
          disabled={busy}
          onClick={props.onFolder}
          type='button'
        >
          {MODULES_ROWS.installFolder}
        </button>
        <button
          aria-expanded={gitOpen}
          className={cx(DIALOG_BUTTON)}
          data-modules-action='git'
          disabled={busy}
          onClick={() => setGitOpen(was => !was)}
          type='button'
        >
          {MODULES_ROWS.installGit}
        </button>
        {!props.packaged && (
          <button
            className={cx(DIALOG_BUTTON)}
            data-modules-action='dev'
            disabled={busy}
            onClick={props.onDev}
            type='button'
          >
            {MODULES_ROWS.installDev}
          </button>
        )}
      </div>
      {gitOpen && (
        <form
          className={cx('flex flex-col gap-1')}
          onSubmit={e => {
            e.preventDefault()
            onGit(url.trim()).then(ok => {
              if (!ok) return
              setUrl('')
              setGitOpen(false)
            })
          }}
        >
          <div className={cx('flex items-center gap-2')}>
            <input
              aria-label='GitHub repository address'
              className={cx(ROW_FIELD, 'h-6 flex-1')}
              data-modules-git-url={true}
              onChange={e => setUrl(e.target.value)}
              placeholder='https://github.com/owner/repo'
              spellCheck={false}
              value={url}
            />
            <button
              className={cx(DIALOG_BUTTON)}
              disabled={busy || url.trim() === ''}
              type='submit'
            >
              Install
            </button>
          </div>
          <p className={cx('text-text-dim')}>{GIT_HINT}</p>
        </form>
      )}
    </div>
  )
}

export default function ModulesSection(): React.JSX.Element {
  const { modules } = useModules()
  const loaded = useModulesLoaded()
  const { dispatch } = useWmControls()
  const confirm = useConfirm()
  // Until the answer comes, act as a packaged app, so the developer button does not flash.
  const [packaged, setPackaged] = useState(true)
  const [openId, setOpenId] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [notes, setNotes] = useState<CheckUpdateNote[] | null>(null)

  useEffect(() => {
    let live = true
    window.bifrost.system.info().then(
      info => {
        if (live) setPackaged(info.packaged)
      },
      () => {},
    )
    return () => {
      live = false
    }
  }, [])

  const api = window.bifrost.modules
  const fail = (err: unknown): void => setError(friendlyError(errorMessage(err)))

  // Run an action of a row. A refusal shows in the error line.
  const act = (call: () => Promise<void>): void => {
    setError(null)
    call().catch(fail)
  }

  // An install shows its approval in Heimdall's panel. null: the user closed the folder dialog.
  const install = async (start: () => Promise<ModuleApproval | null>): Promise<boolean> => {
    setError(null)
    setNotes(null)
    setBusy(true)
    try {
      const approval = await start()
      if (approval === null) return false
      showApproval(approval, dispatch)
      return true
    } catch (err) {
      fail(err)
      return false
    } finally {
      setBusy(false)
    }
  }

  const check = async (): Promise<void> => {
    setError(null)
    setNotes(null)
    setBusy(true)
    try {
      setNotes(checkUpdateNotes(await api.checkUpdates()))
    } catch (err) {
      fail(err)
    } finally {
      setBusy(false)
    }
  }

  const removeModule = async (row: ModuleRow): Promise<void> => {
    const ok = await confirm({
      body: 'Bifrost deletes its files and its saved data. You can install it again later.',
      confirm: 'Remove',
      title: `Remove ${row.name}?`,
    })
    if (ok) act(() => api.remove(row.id))
  }

  return (
    <div className={cx('flex flex-col text-xs')} data-modules-section={true}>
      {loaded && modules.length === 0 && (
        <p className={cx('border-b border-panel-edge px-3 py-2 text-text-dim')}>{MODULES_EMPTY}</p>
      )}
      {modules.map(row => (
        <ModuleRowView
          key={row.id}
          onCap={async cap => {
            setError(null)
            try {
              await api.setCap(row.id, cap)
              return true
            } catch (err) {
              fail(err)
              return false
            }
          }}
          onEnabled={on => act(() => api.setEnabled(row.id, on))}
          onModel={model => act(() => api.setModel(row.id, model))}
          onPermission={(id, on) =>
            act(() => (on ? api.grant(row.id, id) : api.revoke(row.id, id)))
          }
          onRemove={() => void removeModule(row)}
          onReviewUpdate={() =>
            act(async () => showApproval(await api.reviewUpdate(row.id), dispatch))
          }
          onToggle={() => setOpenId(id => (id === row.id ? null : row.id))}
          open={openId === row.id}
          row={row}
        />
      ))}
      <ModulesActionsView
        busy={busy}
        onCheck={() => void check()}
        onDev={() => void install(() => api.installDev())}
        onFolder={() => void install(() => api.installFolder())}
        onGit={url => install(() => api.installGit(url))}
        packaged={packaged}
      />
      {notes?.map(note => (
        <NoticeLine key={note.key} message={note.text} />
      ))}
      <ErrorLine message={error} onClose={() => setError(null)} />
    </div>
  )
}
