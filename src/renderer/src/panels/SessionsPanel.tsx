import { useEffect, useState } from 'react'
import type { SessionRow } from '../../../shared/types'
import { useRegistry } from '../data/registry'
import { cx } from '../lib/cx'

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
    'size-2.5 rounded-sm border-2',
    row.box === 'none' && 'border-panel-edge',
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

// The M1 table of sessions. The Overview of M3 replaces it.
export default function SessionsPanel(): React.JSX.Element {
  const { rows, error, selectedId, select } = useRegistry()
  const [now, setNow] = useState(() => Date.now())

  // One timer for all age cells of this panel.
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(id)
  }, [])

  return (
    <div className='select-text p-2 font-mono text-[13px] leading-[1.4]'>
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
              className={cx(
                'cursor-pointer',
                row.sessionId === selectedId ? 'bg-accent/25' : 'hover:bg-title',
              )}
              key={row.sessionId}
              onClick={() => select(row.sessionId)}
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
