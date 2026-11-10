// The state of Live details and the version of Claude Code for the renderer (spec 11, D11).
// The setup dialog, Settings > Live details, Settings > General and the side bar read it.
// While a warning shows, the provider reads the status again on a back-off (live-retry.ts). So a
// short failure at the first read does not keep the warning dot.
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react'
import { BUSY_MESSAGE } from '../../../shared/live'
import type { ClaudeVersion, LiveStatus } from '../../../shared/types'
import { friendlyError } from '../actions/errors'
import { errorMessage } from '../lib/error-message'
import { hasWarning, type LiveNotice, liveNotice, unknownStatus } from './live-notice'
import { createLiveRetry, type RetryClock } from './live-retry'

export interface LiveValue {
  // null until the first live.status() resolves.
  status: LiveStatus | null
  // null until the first claudeVersion() resolves.
  version: ClaudeVersion | null
  // True when the last claudeVersion() call failed. The version then keeps its last answer.
  versionFailed: boolean
  notice: LiveNotice
  // True for a problem, an old hook install or a version notice (D11).
  warning: boolean
  // True while a call runs. One call runs at a time.
  busy: boolean
  // True after a good install or enable, until the next action.
  changed: boolean
  // Load the status again. It never rejects: a failure gives an unknown status with the reason.
  refresh(): Promise<void>
  // Each action rejects with the friendly message of the live.* call.
  install(): Promise<void>
  enable(): Promise<void>
  disable(): Promise<void>
  uninstall(): Promise<void>
}

const LiveContext = createContext<LiveValue | null>(null)

// Read the status. A failure gives an unknown status with the reason.
function loadStatus(): Promise<LiveStatus> {
  return window.bifrost.live.status().catch(err => unknownStatus(friendlyError(errorMessage(err))))
}

const PAGE_CLOCK: RetryClock = {
  after(ms, fn) {
    const id = window.setTimeout(fn, ms)
    return () => window.clearTimeout(id)
  },
  now: () => Date.now(),
}

export function LiveProvider({ children }: { children: React.ReactNode }): React.JSX.Element {
  const [status, setStatus] = useState<LiveStatus | null>(null)
  const [version, setVersion] = useState<ClaudeVersion | null>(null)
  const [versionFailed, setVersionFailed] = useState(false)
  const [busy, setBusy] = useState(false)
  const [changed, setChanged] = useState(false)
  // The ref stops a second call before the next render shows busy.
  const running = useRef(false)
  // The number of calls with the lock. A re-read drops its answer when a call starts during it.
  const lockedCalls = useRef(0)
  // Copies of version and versionFailed for the re-read.
  const versionNow = useRef<ClaudeVersion | null>(null)
  const versionFailedNow = useRef(false)
  const mounted = useRef(true)

  // Call claudeVersion(). An answer sets the version and clears a failed check.
  const readVersion = useCallback(async (): Promise<void> => {
    try {
      const next = await window.bifrost.claudeVersion()
      if (!mounted.current) return
      versionNow.current = next
      versionFailedNow.current = false
      setVersion(next)
      setVersionFailed(false)
    } catch (err) {
      console.error('Bifrost cannot read the version of Claude Code.', err)
      if (!mounted.current) return
      versionFailedNow.current = true
      setVersionFailed(true)
    }
  }, [])

  // The re-read while a warning shows. It does not lock, so the buttons do not show busy. An
  // action or a refresh that starts during the read gives a newer status. Then the read drops its
  // answer.
  const [retry] = useState(() =>
    createLiveRetry({
      busy: () => running.current,
      clock: PAGE_CLOCK,
      async readStatus() {
        const calls = lockedCalls.current
        const next = await loadStatus()
        if (mounted.current && lockedCalls.current === calls) setStatus(next)
      },
      readVersion,
      version: () => versionNow.current,
      versionFailed: () => versionFailedNow.current,
    }),
  )

  // Load the status and the version one time at mount.
  useEffect(() => {
    mounted.current = true
    loadStatus().then(next => {
      retry.readEnded()
      if (mounted.current) setStatus(next)
    })
    void readVersion()
    return () => {
      mounted.current = false
    }
  }, [readVersion, retry])

  const warning = hasWarning(status, version, versionFailed)

  // Read again on the back-off while a warning shows. The cleanup stops the timer.
  useEffect(() => {
    retry.warn(warning)
    return () => retry.warn(false)
  }, [retry, warning])

  // A window focus can read again too, when the last read ended 5 minutes or more ago. The window
  // focus event follows the key window of macOS in Electron.
  useEffect(() => {
    const onFocus = (): void => retry.focus()
    window.addEventListener('focus', onFocus)
    return () => window.removeEventListener('focus', onFocus)
  }, [retry])

  // Run one call with the lock. A call that comes while another call runs rejects.
  // Each call with the lock ends with a status read: a refresh, or the status of an action. So
  // its end is the end of a read for the back-off.
  const locked = useCallback(
    async (fn: () => Promise<void>): Promise<void> => {
      if (running.current) throw new Error(BUSY_MESSAGE)
      running.current = true
      lockedCalls.current += 1
      setBusy(true)
      try {
        await fn()
      } finally {
        running.current = false
        retry.readEnded()
        if (mounted.current) setBusy(false)
      }
    },
    [retry],
  )

  const refresh = useCallback(async (): Promise<void> => {
    // A refresh during an action does nothing. The action sets the status when it ends.
    if (running.current) return
    await locked(async () => {
      const next = await loadStatus()
      if (mounted.current) setStatus(next)
    })
  }, [locked])

  // Run an action. A good install or enable sets changed, so the reload note shows.
  // An action can remove the old hook install before it fails. So a failure reads the status
  // again, and then rejects with the message of the call.
  const action = useCallback(
    (call: () => Promise<LiveStatus>, marksChange: boolean) => (): Promise<void> =>
      locked(async () => {
        setChanged(false)
        try {
          const next = await call()
          if (!mounted.current) return
          setStatus(next)
          if (marksChange) setChanged(true)
        } catch (err) {
          const next = await loadStatus()
          if (mounted.current) setStatus(next)
          throw new Error(friendlyError(errorMessage(err)))
        }
      }),
    [locked],
  )

  const value = useMemo<LiveValue>(
    () => ({
      busy,
      changed,
      disable: action(() => window.bifrost.live.disable(), false),
      enable: action(() => window.bifrost.live.enable(), true),
      install: action(() => window.bifrost.live.install(), true),
      notice: liveNotice(status),
      refresh,
      status,
      uninstall: action(() => window.bifrost.live.uninstall(), false),
      version,
      versionFailed,
      warning,
    }),
    [action, busy, changed, refresh, status, version, versionFailed, warning],
  )

  return <LiveContext value={value}>{children}</LiveContext>
}

export function useLive(): LiveValue {
  const value = useContext(LiveContext)
  if (!value) throw new Error('useLive needs a LiveProvider.')
  return value
}
