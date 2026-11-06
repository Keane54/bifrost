// The pure logic of the Event log panel (spec 8.7).
import type { LogEntry, SessionRow } from '../../../shared/types'

// The clock of a log row: HH:MM:SS.mmm (R8, one time module).
export { formatClockMs as formatClock } from '../lib/time'

export const LOG_MAX = 5000
// The height of a row, in px.
export const ROW_HEIGHT = 18
const OVERSCAN = 8
const SHORT_ID = 8

// Add the incoming entries to the current ones. Drop an entry whose seq is in the list already.
// Sort by seq and keep the max newest. With no new entry, return the same array.
export function mergeLog(
  current: LogEntry[],
  incoming: LogEntry[],
  max: number = LOG_MAX,
): LogEntry[] {
  const known = new Set(current.map(entry => entry.seq))
  const fresh = incoming.filter(entry => {
    if (known.has(entry.seq)) return false
    known.add(entry.seq)
    return true
  })
  if (fresh.length === 0) return current
  const all = [...current, ...fresh].sort((a, b) => a.seq - b.seq)
  return all.length > max ? all.slice(all.length - max) : all
}

// null gives all entries.
export function filterLog(entries: LogEntry[], sessionId: string | null): LogEntry[] {
  return sessionId === null ? entries : entries.filter(entry => entry.sessionId === sessionId)
}

// The rows to put in the DOM, with the overscan above and below the viewport.
export function visibleRange(
  scrollTop: number,
  viewport: number,
  rowHeight: number,
  count: number,
  overscan: number = OVERSCAN,
): { start: number; end: number } {
  const start = Math.max(0, Math.floor(scrollTop / rowHeight) - overscan)
  const end = Math.min(count, Math.ceil((scrollTop + viewport) / rowHeight) + overscan)
  return { end, start }
}

// The name, then the detail in brackets. A notice gives its own text.
export function eventText(entry: LogEntry): string {
  if (entry.kind === 'notice') return entry.name
  return entry.detail === undefined ? entry.name : `${entry.name} (${entry.detail})`
}

// The label of a session: the row name, else the first 8 characters of the ID.
export function sessionLabel(sessionId: string, rows: SessionRow[]): string {
  const name = rows.find(row => row.sessionId === sessionId)?.name
  return name ? name : sessionId.slice(0, SHORT_ID)
}

// Each session of the log one time, sorted by label. A notice has no session.
export function sessionOptions(
  entries: LogEntry[],
  rows: SessionRow[],
): { id: string; label: string }[] {
  const ids = new Set<string>()
  for (const entry of entries) if (entry.sessionId !== '') ids.add(entry.sessionId)
  return [...ids]
    .map(id => ({ id, label: sessionLabel(id, rows) }))
    .sort((a, b) => a.label.localeCompare(b.label))
}
