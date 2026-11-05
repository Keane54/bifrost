import { useEffect, useState } from 'react'
import type { ClaudeVersion, SessionRow } from '../../../shared/types'
import { cx } from '../lib/cx'
import IntegrationPanel from './IntegrationPanel'

const H2 = 'mt-4 mb-2 text-sm font-bold'
const CELL = 'border-panel-edge border-b px-2 py-1 text-left whitespace-nowrap'

function age(since: number, now: number): string {
  const s = Math.max(0, Math.floor((now - since) / 1000))
  if (s < 60) return `${s} s`
  if (s < 3600) return `${Math.floor(s / 60)} min`
  if (s < 86400) return `${Math.floor(s / 3600)} h`
  return `${Math.floor(s / 86400)} d`
}

function boxClass(row: SessionRow): string {
  return cx(
    'size-2.5 rounded-sm border-2 border-panel-edge',
    row.box === 'yellow' && 'border-box-yellow bg-box-yellow',
    row.box === 'red' && 'border-box-red bg-box-red',
    row.flashing && 'animate-box-flash',
  )
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
    <div className='h-full select-text overflow-auto p-4 font-mono text-[13px] leading-[1.4]'>
      <div>
        Claude Code version:{' '}
        {version
          ? (version.version ?? 'unknown')
          : versionError
            ? `error (${versionError})`
            : 'loading'}
        {version && !version.ok && (
          <span className='text-box-yellow'>
            {' '}
            Warning: this version is below the minimum {version.minimum}.
          </span>
        )}
      </div>
      <h2 className={H2}>Integration</h2>
      <IntegrationPanel />
      <h2 className={H2}>Sessions</h2>
      {error && <div className='whitespace-pre-wrap text-box-red'>{error}</div>}
      <table className='w-full border-collapse'>
        <thead>
          <tr>
            <th className={CELL}>Box</th>
            <th className={CELL}>Name</th>
            <th className={CELL}>Kind</th>
            <th className={CELL}>State</th>
            <th className={CELL}>Status</th>
            <th className={CELL}>Waiting for</th>
            <th className={CELL}>Model</th>
            <th className={CELL}>Context</th>
            <th className={CELL}>Cost</th>
            <th className={CELL}>Branch</th>
            <th className={CELL}>Age</th>
            <th className={CELL}>Last message</th>
          </tr>
        </thead>
        <tbody>
          {rows.map(row => (
            <tr
              className='cursor-pointer hover:bg-panel'
              key={row.sessionId}
              onClick={() =>
                window.bifrost.registry
                  .acknowledge(row.sessionId)
                  .catch(err => setError(message(err)))
              }
            >
              <td className={CELL}>
                <div className={boxClass(row)} />
              </td>
              <td className={CELL}>{row.name}</td>
              <td className={CELL}>{row.kind}</td>
              <td className={CELL}>{row.state}</td>
              <td className={CELL}>{row.status}</td>
              <td className={CELL}>{row.waitingFor ?? ''}</td>
              <td className={CELL}>{row.model ?? ''}</td>
              <td className={CELL}>{row.contextPercent != null ? `${row.contextPercent}%` : ''}</td>
              <td className={CELL}>{row.costUsd != null ? `$${row.costUsd.toFixed(2)}` : ''}</td>
              <td className={CELL}>{row.branch ?? ''}</td>
              <td className={CELL}>{age(row.lastActivity, now)}</td>
              <td className={cx(CELL, 'whitespace-normal')}>{firstLine(row.lastMessage)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
