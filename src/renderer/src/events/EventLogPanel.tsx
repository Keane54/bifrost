// The Event log panel (spec 8.7): the newest live state events, newest first, in a virtual list.
import { useEffect, useMemo, useRef, useState } from 'react'
import type { LogEntry } from '../../../shared/types'
import { useRegistry } from '../data/registry'
import { cx } from '../lib/cx'
import { useLive } from '../settings/live-context'
import {
  filterLog,
  formatLogTime,
  logRow,
  mergeLog,
  ROW_HEIGHT,
  sessionOptions,
  visibleRange,
} from './log-view'

const EMPTY = 'No events yet.'
const LIVE_HINT = 'Events come from Live details. Turn it on in Settings to see them here.'
const ALL = ''

export default function EventLogPanel(): React.JSX.Element {
  const { rows } = useRegistry()
  const { notice } = useLive()
  const [entries, setEntries] = useState<LogEntry[]>([])
  const [session, setSession] = useState(ALL)
  const [scrollTop, setScrollTop] = useState(0)
  const [viewport, setViewport] = useState(360)
  const box = useRef<HTMLDivElement>(null)

  // Subscribe first, then load the list. mergeLog drops the copies. The entries stay while the
  // panel is open.
  useEffect(() => {
    let active = true
    const off = window.bifrost.events.onAppend(added => {
      if (active) setEntries(current => mergeLog(current, added))
    })
    window.bifrost.events.list().then(
      list => {
        if (active) setEntries(current => mergeLog(current, list))
      },
      () => {},
    )
    return () => {
      active = false
      off()
    }
  }, [])

  // Follow the height of the list area.
  useEffect(() => {
    const el = box.current
    if (!el) return
    const observer = new ResizeObserver(() => setViewport(el.clientHeight))
    observer.observe(el)
    setViewport(el.clientHeight)
    return () => observer.disconnect()
  }, [])

  const options = useMemo(() => sessionOptions(entries, rows), [entries, rows])
  const filtered = useMemo(
    () => filterLog(entries, session === ALL ? null : session),
    [entries, session],
  )
  // The newest first.
  const count = filtered.length
  const { start, end } = visibleRange(scrollTop, viewport, ROW_HEIGHT, count)
  const shown: LogEntry[] = []
  for (let i = start; i < end; i++) {
    const entry = filtered[count - 1 - i]
    if (entry) shown.push(entry)
  }

  return (
    <div className='flex h-full min-w-0 flex-col text-xs' data-event-log={true}>
      <div className='flex shrink-0 items-center gap-3 border-panel-edge border-b px-2 py-1.5'>
        <select
          aria-label='Session'
          className='min-w-0 max-w-[60%] truncate border border-panel-edge bg-transparent px-1 py-0.5 text-text'
          onChange={e => {
            setSession(e.target.value)
            setScrollTop(0)
            if (box.current) box.current.scrollTop = 0
          }}
          value={session}
        >
          <option value={ALL}>All sessions</option>
          {options.map(o => (
            <option key={o.id} value={o.id}>
              {o.label}
            </option>
          ))}
        </select>
        <span className='shrink-0 text-text-dim'>
          {count} {count === 1 ? 'event' : 'events'}
        </span>
      </div>
      <div
        className='min-h-0 flex-1 overflow-y-auto'
        onScroll={e => setScrollTop(e.currentTarget.scrollTop)}
        ref={box}
      >
        {count === 0 ? (
          <div className='p-3 text-[13px] text-text-dim'>
            <p>{EMPTY}</p>
            {notice.kind !== 'on' && <p className='mt-1'>{LIVE_HINT}</p>}
          </div>
        ) : (
          <div className='relative' style={{ height: count * ROW_HEIGHT }}>
            {shown.map((entry, i) => {
              const row = logRow(entry, rows)
              return (
                <div
                  className={cx(
                    'absolute right-0 left-0 flex items-center gap-2 px-2',
                    entry.kind === 'notice' && 'text-text-strong',
                  )}
                  data-log-row={entry.seq}
                  key={entry.seq}
                  style={{ height: ROW_HEIGHT, top: (start + i) * ROW_HEIGHT }}
                >
                  <span className='w-24 shrink-0 font-mono text-text-dim'>
                    {formatLogTime(entry.at)}
                  </span>
                  {/* A notice has no session. Its text uses the session column too. */}
                  {row.session !== null && (
                    <span className='w-[150px] shrink-0 truncate text-text-dim'>{row.session}</span>
                  )}
                  <span className='min-w-0 flex-1 truncate' title={row.title}>
                    {row.text}
                  </span>
                </div>
              )
            })}
          </div>
        )}
      </div>
    </div>
  )
}
