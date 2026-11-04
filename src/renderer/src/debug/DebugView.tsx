import { useEffect, useState } from 'react'
import type { ClaudeVersion, SessionRow } from '../../../shared/types'
import IntegrationPanel from './IntegrationPanel'
import './debug.css'

function age(since: number, now: number): string {
  const s = Math.max(0, Math.floor((now - since) / 1000))
  if (s < 60) return `${s} s`
  if (s < 3600) return `${Math.floor(s / 60)} min`
  if (s < 86400) return `${Math.floor(s / 3600)} h`
  return `${Math.floor(s / 86400)} d`
}

function boxClass(row: SessionRow): string {
  const classes = ['box']
  if (row.box !== 'none') classes.push(row.box)
  if (row.flashing) classes.push('flashing')
  return classes.join(' ')
}

// The first line that has text. Trim spaces and carriage returns.
function firstLine(text: string | null | undefined): string {
  if (text == null) return ''
  return (
    text
      .split('\n')
      .map(line => line.trim())
      .find(line => line !== '') ?? ''
  )
}

function message(err: unknown): string {
  return err instanceof Error ? err.message : String(err)
}

// A plain view of the session rows and the integration controls.
export default function DebugView(): React.JSX.Element {
  const [version, setVersion] = useState<ClaudeVersion | null>(null)
  const [rows, setRows] = useState<SessionRow[]>([])
  const [versionError, setVersionError] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [now, setNow] = useState(() => Date.now())

  useEffect(() => {
    let active = true
    let updated = false
    window.bifrost
      .claudeVersion()
      .then(v => active && setVersion(v))
      .catch(err => active && setVersionError(message(err)))
    // One call at mount. An update that arrived first is newer, so keep it.
    window.bifrost.registry
      .rows()
      .then(r => active && !updated && setRows(r))
      .catch(() => {})
    const unsubscribe = window.bifrost.registry.onUpdate((r, e) => {
      updated = true
      setRows(r)
      setError(e)
    })
    return () => {
      active = false
      unsubscribe()
    }
  }, [])

  // One timer for all age cells.
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(id)
  }, [])

  return (
    <div className='debug'>
      <div>
        Claude Code version:{' '}
        {version
          ? (version.version ?? 'unknown')
          : versionError
            ? `error (${versionError})`
            : 'loading'}
        {version && !version.ok && (
          <span className='debug-warn'>
            {' '}
            Warning: this version is below the minimum {version.minimum}.
          </span>
        )}
      </div>
      <h2>Integration</h2>
      <IntegrationPanel />
      <h2>Sessions</h2>
      {error && <div className='debug-error'>{error}</div>}
      <table className='debug-table'>
        <thead>
          <tr>
            <th>Box</th>
            <th>Name</th>
            <th>Kind</th>
            <th>State</th>
            <th>Status</th>
            <th>Waiting for</th>
            <th>Model</th>
            <th>Context</th>
            <th>Cost</th>
            <th>Branch</th>
            <th>Age</th>
            <th>Last message</th>
          </tr>
        </thead>
        <tbody>
          {rows.map(row => (
            <tr
              key={row.sessionId}
              onClick={() =>
                window.bifrost.registry
                  .acknowledge(row.sessionId)
                  .catch(err => setError(message(err)))
              }
            >
              <td>
                <div className={boxClass(row)} />
              </td>
              <td>{row.name}</td>
              <td>{row.kind}</td>
              <td>{row.state}</td>
              <td>{row.status}</td>
              <td>{row.waitingFor ?? ''}</td>
              <td>{row.model ?? ''}</td>
              <td>{row.contextPercent != null ? `${row.contextPercent}%` : ''}</td>
              <td>{row.costUsd != null ? `$${row.costUsd.toFixed(2)}` : ''}</td>
              <td>{row.branch ?? ''}</td>
              <td>{age(row.lastActivity, now)}</td>
              <td className='msg'>{firstLine(row.lastMessage)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
