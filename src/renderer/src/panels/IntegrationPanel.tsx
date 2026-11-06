import { useEffect, useRef, useState } from 'react'
import type { ClaudeVersion, LiveStatus } from '../../../shared/types'
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

// The controls for Live details.
export default function IntegrationPanel(): React.JSX.Element {
  const [live, setLive] = useState<LiveStatus | null>(null)
  const [liveError, setLiveError] = useState<string | null>(null)
  const [note, setNote] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const running = useRef(false)

  useEffect(() => {
    window.bifrost.live
      .status()
      .then(setLive)
      .catch(err => setLiveError(errorMessage(err)))
  }, [])

  // Run one Live details action. All buttons stay off until it ends.
  // The ref stops a second action before the next render disables the buttons.
  // Read the status again also after a failure: an action can remove the old hook install
  // before it fails.
  const onLive =
    (action: () => Promise<LiveStatus>, reload: boolean) => async (): Promise<void> => {
      if (running.current) return
      running.current = true
      setBusy(true)
      setLiveError(null)
      setNote(null)
      try {
        setLive(await action())
        if (reload) setNote(RELOAD_NOTE)
      } catch (err) {
        await window.bifrost.live.status().then(setLive, () => {})
        setLiveError(errorMessage(err))
      } finally {
        running.current = false
        setBusy(false)
      }
    }

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
    </div>
  )
}
