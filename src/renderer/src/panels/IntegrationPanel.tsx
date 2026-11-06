import { useEffect, useRef, useState } from 'react'
import type {
  ClaudeVersion,
  InstallPreview,
  IntegrationStatus,
  LiveStatus,
} from '../../../shared/types'
import { errorMessage } from '../lib/error-message'

// A copy of RELOAD_NOTE in src/main/live/live-control.ts. The renderer does not import main code.
const RELOAD_NOTE = 'Sessions that run now get the change after /reload-plugins or a restart.'

const PLUGIN_TEXT: Record<LiveStatus['plugin'], string> = {
  disabled: 'installed, off',
  enabled: 'installed, on',
  'not-installed': 'not installed',
  unknown: 'unknown',
}

const yesNo = (value: boolean): string => (value ? 'yes' : 'no')

// One line for each field of the Live details status.
function LiveLines({ live }: { live: LiveStatus }): React.JSX.Element {
  return (
    <>
      <div>Plugin: {PLUGIN_TEXT[live.plugin]}</div>
      <div>Mod folder up to date: {yesNo(live.modCurrent)}</div>
      <div>Old hook install found: {yesNo(live.oldInstall)}</div>
      <div>Listening: {yesNo(live.listening)}</div>
      <div>Live sessions: {live.liveSessions}</div>
      <div>Claude Code version: {live.claudeVersion ?? 'not found'}</div>
      <div>Version is new enough: {yesNo(live.versionOk)}</div>
      {live.error && <div className='whitespace-pre-wrap text-box-red'>{live.error}</div>}
    </>
  )
}

function describe(status: IntegrationStatus): string {
  if (status.installed) return 'Installed.'
  const missing: string[] = []
  if (status.missingHooks.length > 0) missing.push(`hooks: ${status.missingHooks.join(', ')}`)
  if (!status.statusLineInstalled) missing.push('status line wrapper')
  if (!status.scriptsPresent) missing.push('scripts')
  else if (!status.scriptsCurrent) missing.push('current scripts (install again to repair)')
  return `Not installed. Missing: ${missing.join('; ') || 'unknown'}.`
}

// A press gives a short cyan tint. A disabled button gets no tint.
const BUTTON =
  'mt-1 mr-2 mb-1 border border-panel-edge px-2 py-0.5 hover:bg-title enabled:active:bg-accent/12 disabled:opacity-40'

// The version of Claude Code, and a warning when it is below the minimum.
function VersionLine(): React.JSX.Element {
  const [version, setVersion] = useState<ClaudeVersion | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let active = true
    window.bifrost
      .claudeVersion()
      .then(v => active && setVersion(v))
      .catch(err => active && setError(errorMessage(err)))
    return () => {
      active = false
    }
  }, [])

  return (
    <div className='mb-2'>
      Claude Code version:{' '}
      {version ? (version.version ?? 'unknown') : error ? `error (${error})` : 'loading'}
      {version && !version.ok && (
        <span className='text-box-yellow'>
          {' '}
          Warning: this version is below the minimum {version.minimum}.
        </span>
      )}
    </div>
  )
}

// The controls for the Claude Code integration.
export default function IntegrationPanel(): React.JSX.Element {
  const [status, setStatus] = useState<IntegrationStatus | null>(null)
  const [preview, setPreview] = useState<InstallPreview | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [live, setLive] = useState<LiveStatus | null>(null)
  const [liveError, setLiveError] = useState<string | null>(null)
  const [note, setNote] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const running = useRef(false)

  useEffect(() => {
    window.bifrost.integration
      .status()
      .then(setStatus)
      .catch(err => setError(errorMessage(err)))
    window.bifrost.live
      .status()
      .then(setLive)
      .catch(err => setLiveError(errorMessage(err)))
  }, [])

  // Run one action. All buttons stay off until it ends.
  // The ref stops a second action before the next render disables the buttons.
  // Each action clears the old preview. Install needs a new preview each time.
  // onError shows the failure in the block of the button.
  async function run(
    action: () => Promise<void>,
    onError: (text: string) => void = setError,
  ): Promise<void> {
    if (running.current) return
    running.current = true
    setBusy(true)
    setError(null)
    setLiveError(null)
    setNote(null)
    setPreview(null)
    try {
      await action()
    } catch (err) {
      onError(errorMessage(err))
    } finally {
      running.current = false
      setBusy(false)
    }
  }

  // Run one Live details action. Then read both statuses again, also after a failure:
  // an action can remove the old hook install before it fails.
  const onLive = (action: () => Promise<LiveStatus>, reload: boolean) => (): Promise<void> =>
    run(async () => {
      try {
        setLive(await action())
        if (reload) setNote(RELOAD_NOTE)
      } catch (err) {
        await window.bifrost.live.status().then(setLive, () => {})
        throw err
      } finally {
        await window.bifrost.integration.status().then(setStatus, () => {})
      }
    }, setLiveError)

  const onPreview = (): Promise<void> =>
    run(async () => setPreview(await window.bifrost.integration.preview()))

  const onInstall = (): Promise<void> =>
    run(async () => {
      const next = await window.bifrost.integration.install()
      setStatus(next)
      setPreview(null)
    })

  const onUninstall = (): Promise<void> =>
    run(async () => {
      const next = await window.bifrost.integration.uninstall()
      setStatus(next)
      setPreview(null)
    })

  return (
    <div className='select-text p-3 font-mono text-[13px] leading-[1.4]'>
      <div className='mb-3'>
        <div>Live details</div>
        {live ? <LiveLines live={live} /> : <div>Status: loading.</div>}
        <div>
          <button
            className={BUTTON}
            disabled={busy}
            onClick={onLive(() => window.bifrost.live.install(), true)}
            type='button'
          >
            Install
          </button>
          <button
            className={BUTTON}
            disabled={busy}
            onClick={onLive(() => window.bifrost.live.enable(), true)}
            type='button'
          >
            Turn on
          </button>
          <button
            className={BUTTON}
            disabled={busy}
            onClick={onLive(() => window.bifrost.live.disable(), false)}
            type='button'
          >
            Turn off
          </button>
          <button
            className={BUTTON}
            disabled={busy}
            onClick={onLive(() => window.bifrost.live.uninstall(), false)}
            type='button'
          >
            Remove
          </button>
        </div>
        {liveError && <div className='whitespace-pre-wrap text-box-red'>{liveError}</div>}
        {note && <div>{note}</div>}
      </div>
      <VersionLine />
      <div>{status ? describe(status) : 'Status: loading.'}</div>
      {status?.error && <div className='whitespace-pre-wrap text-box-red'>{status.error}</div>}
      <div>
        <button className={BUTTON} disabled={busy} onClick={onPreview} type='button'>
          Preview install
        </button>
        <button
          className={BUTTON}
          disabled={busy || preview === null}
          onClick={onInstall}
          type='button'
        >
          Install
        </button>
        <button className={BUTTON} disabled={busy} onClick={onUninstall} type='button'>
          Uninstall
        </button>
      </div>
      {error && <div className='whitespace-pre-wrap text-box-red'>{error}</div>}
      {preview && (
        <div>
          <div>Changes:</div>
          <ul>
            {preview.changes.map(change => (
              <li key={change}>{change}</li>
            ))}
          </ul>
          <div>Backup path: {preview.backupPath ?? 'none'}</div>
          <div>Original command:</div>
          <pre className='my-1 whitespace-pre-wrap'>{preview.originalCommand ?? 'none'}</pre>
        </div>
      )}
    </div>
  )
}
