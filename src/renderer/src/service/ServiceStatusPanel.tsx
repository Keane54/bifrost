// The Service status panel (spec 8.11): the state of the public status pages of Claude, GitHub
// and Sentry. The main process checks them one time each minute.
import { ExternalLink } from 'lucide-react'
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
import { flushSync } from 'react-dom'
import type { ServiceLevel, ServiceStatus } from '../../../shared/types'
import { cx } from '../lib/cx'
import { useNow } from '../lib/use-now'
import {
  checkedText,
  incidentLine,
  levelText,
  type ServiceView,
  serviceView,
  sinceText,
} from './service-view'

// The class of the text colour and the dot colour of each level. "No data" has no dot. The texts
// of the levels are LEVEL_TEXT in service-view.ts.
const LEVEL_CLASS: Record<Exclude<ServiceLevel, 'unknown'>, string> = {
  critical: 'text-svc-critical',
  maintenance: 'text-svc-maint',
  major: 'text-svc-major',
  minor: 'text-svc-minor',
  none: 'text-svc-ok',
}

// The head line of a service: the level, the since text, the name and the status page button.
// The view hides the text of the button (1), and also the level text (2) (spec 8.11). A measure
// copy shows the full view at its natural width, so the panel can measure the widths that the
// row needs.
const SQUARE = 'size-2 shrink-0 bg-current'

function Head({
  service,
  now,
  view,
  measure = false,
}: {
  service: ServiceStatus
  now: number
  view: ServiceView
  measure?: boolean
}): React.JSX.Element {
  const since = sinceText(service.level, service.since, now)
  const level = levelText(service.level)
  const pageLabel = `Open status page of ${service.name}`
  const squareOnly = view === 2
  return (
    <div
      className={cx('flex items-center gap-2 text-xs', measure && 'w-max')}
      data-service-measure={measure ? service.id : undefined}
      data-service-row={measure ? undefined : service.id}
    >
      {service.level === 'unknown' ? (
        // "No data" has no square, so it keeps its text in each view.
        <span className='shrink-0 text-text italic'>{level}</span>
      ) : (
        <>
          {squareOnly ? (
            // The square alone gives the level to a screen reader and in its tooltip.
            <span
              aria-label={level}
              className={cx(SQUARE, LEVEL_CLASS[service.level])}
              data-service-square={true}
              role='img'
              title={level}
            />
          ) : (
            <>
              <span className={cx(SQUARE, LEVEL_CLASS[service.level])} data-service-square={true} />
              <span
                className={cx('shrink-0', LEVEL_CLASS[service.level])}
                data-service-level-text={true}
              >
                {level}
              </span>
            </>
          )}
          {since !== null && <span className='shrink-0 text-text-dim'>{since}</span>}
        </>
      )}
      <span
        className={cx('text-text-strong', measure ? 'shrink-0' : 'min-w-0 flex-1 truncate')}
        data-service-name={true}
      >
        {service.name}
      </span>
      <button
        aria-label={pageLabel}
        className='flex shrink-0 items-center gap-1 px-1 text-[11px] text-text-dim hover:bg-hover hover:text-text enabled:active:bg-accent/12'
        onClick={() => {
          window.bifrost.service.openPage(service.id).catch(() => {})
        }}
        tabIndex={measure ? -1 : undefined}
        title={view === 0 ? undefined : pageLabel}
        type='button'
      >
        <ExternalLink aria-hidden={true} data-service-icon={true} size={11} />
        {view === 0 && <span data-service-button-text={true}>Open status page</span>}
      </button>
    </div>
  )
}

function Block({
  service,
  now,
  view,
}: {
  service: ServiceStatus
  now: number
  view: ServiceView
}): React.JSX.Element {
  return (
    <div data-service={service.id} data-service-level={service.level}>
      <Head now={now} service={service} view={view} />
      {service.incidents.map((incident, i) => (
        <div
          className='mt-1 pl-4 text-[11px] text-text'
          // biome-ignore lint/suspicious/noArrayIndexKey: the list has no stable ID
          key={i}
        >
          {incidentLine(incident, now)}
        </div>
      ))}
      {service.error !== undefined && (
        <div className='mt-1 pl-4 text-[11px] text-text-dim'>{service.error}</div>
      )}
    </div>
  )
}

// The widths that the widest row needs: in the full view, and without the text of the status
// page button. The measure copies give them.
function measureNeeds(panel: HTMLElement): [number, number] {
  let full = 0
  let compact = 0
  for (const row of panel.querySelectorAll<HTMLElement>('[data-service-measure]')) {
    const width = row.getBoundingClientRect().width
    const icon = row.querySelector('[data-service-icon]')?.getBoundingClientRect()
    const text = row.querySelector('[data-service-button-text]')?.getBoundingClientRect()
    full = Math.max(full, width)
    compact = Math.max(compact, icon && text ? width - (text.right - icon.right) : width)
  }
  return [full, compact]
}

export default function ServiceStatusPanel(): React.JSX.Element {
  const [list, setList] = useState<ServiceStatus[]>([])
  const now = useNow(30_000)

  // Subscribe first, then load the value. An update that comes before the first answer wins.
  useEffect(() => {
    let active = true
    let updated = false
    const off = window.bifrost.service.onUpdate(next => {
      updated = true
      if (active) setList(next)
    })
    window.bifrost.service.status().then(
      first => {
        if (active && !updated) setList(first)
      },
      () => {},
    )
    return () => {
      active = false
      off()
    }
  }, [])

  // The view of the rows (spec 8.11). The panel measures the full rows and chooses the view
  // before the paint: after each render, and at each resize of the panel. The measure does not
  // depend on the view, so the view cannot change in a loop.
  const panel = useRef<HTMLDivElement>(null)
  const [view, setView] = useState<ServiceView>(0)
  const choose = useCallback(() => {
    const el = panel.current
    const row = el?.querySelector<HTMLElement>('[data-service-row]')
    if (!el || !row) return
    setView(serviceView(row.clientWidth, measureNeeds(el)))
  }, [])
  useLayoutEffect(() => choose())
  useLayoutEffect(() => {
    const el = panel.current
    if (!el) return
    // flushSync renders the new view at once, so a resize shows no frame of the old view.
    const observer = new ResizeObserver(() => flushSync(choose))
    observer.observe(el)
    return () => observer.disconnect()
  }, [choose])

  const newest = list.reduce((max, s) => Math.max(max, s.checkedAt), 0)
  return (
    <div
      className='relative flex h-full flex-col gap-3 p-3 text-text'
      data-service-status={true}
      data-service-view={view}
      ref={panel}
    >
      {list.map(service => (
        <Block key={service.id} now={now} service={service} view={view} />
      ))}
      <div className='mt-auto text-[11px] text-text-dim'>{checkedText(newest, now)}</div>
      {/* The measure copies: the full rows at their natural width. They are invisible, and the
          box of size 0 clips them, so they add no scroll width. */}
      <div
        aria-hidden={true}
        className='pointer-events-none invisible absolute top-0 left-0 h-0 w-0 overflow-hidden'
      >
        {list.map(service => (
          <Head key={service.id} measure={true} now={now} service={service} view={0} />
        ))}
      </div>
    </div>
  )
}
