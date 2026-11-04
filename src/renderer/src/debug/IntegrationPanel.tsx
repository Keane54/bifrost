import { useEffect, useRef, useState } from 'react'
import type { InstallPreview, IntegrationStatus } from '../../../shared/types'

function describe(status: IntegrationStatus): string {
  if (status.installed) return 'Installed.'
  const missing: string[] = []
  if (status.missingHooks.length > 0) missing.push(`hooks: ${status.missingHooks.join(', ')}`)
  if (!status.statusLineInstalled) missing.push('status line wrapper')
  if (!status.scriptsPresent) missing.push('scripts')
  return `Not installed. Missing: ${missing.join('; ') || 'unknown'}.`
}

function message(err: unknown): string {
  return err instanceof Error ? err.message : String(err)
}

// The controls for the Claude Code integration.
export default function IntegrationPanel(): React.JSX.Element {
  const [status, setStatus] = useState<IntegrationStatus | null>(null)
  const [preview, setPreview] = useState<InstallPreview | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const running = useRef(false)

  useEffect(() => {
    window.bifrost.integration
      .status()
      .then(setStatus)
      .catch(err => setError(message(err)))
  }, [])

  // Run one action. The three buttons stay off until it ends.
  // The ref stops a second action before the next render disables the buttons.
  // Each action clears the old preview. Install needs a new preview each time.
  async function run(action: () => Promise<void>): Promise<void> {
    if (running.current) return
    running.current = true
    setBusy(true)
    setError(null)
    setPreview(null)
    try {
      await action()
    } catch (err) {
      setError(message(err))
    } finally {
      running.current = false
      setBusy(false)
    }
  }

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
    <div className='debug-panel'>
      <div>{status ? describe(status) : 'Status: loading.'}</div>
      {status?.error && <div className='debug-error'>{status.error}</div>}
      <div>
        <button disabled={busy} onClick={onPreview} type='button'>
          Preview install
        </button>
        <button disabled={busy || preview === null} onClick={onInstall} type='button'>
          Install
        </button>
        <button disabled={busy} onClick={onUninstall} type='button'>
          Uninstall
        </button>
      </div>
      {error && <div className='debug-error'>{error}</div>}
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
          <pre>{preview.originalCommand ?? 'none'}</pre>
        </div>
      )}
    </div>
  )
}
