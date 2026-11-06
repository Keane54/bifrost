// The Service status panel (spec 8.11): the state of the public status pages of Claude, GitHub
// and Sentry. The main process checks them one time each minute.
import { ExternalLink } from 'lucide-react'
import { useEffect, useState } from 'react'
import type { ServiceLevel, ServiceStatus } from '../../../shared/types'
import { cx } from '../lib/cx'
import { useNow } from '../lib/use-now'
import { checkedText, incidentLine, levelText } from './service-view'

// Text colour and dot colour of each level. "No data" has no dot.
const LEVEL_TEXT: Record<Exclude<ServiceLevel, 'unknown'>, string> = {
  critical: 'text-svc-critical',
  maintenance: 'text-svc-maint',
  major: 'text-svc-major',
  minor: 'text-svc-minor',
  none: 'text-svc-ok',
}

function Block({ service, now }: { service: ServiceStatus; now: number }): React.JSX.Element {
  const known = service.level !== 'unknown'
  return (
    <div data-service={service.id} data-service-level={service.level}>
      <div className='flex items-center gap-2 text-xs'>
        {known ? (
          <>
            <span className={cx('size-2 shrink-0 bg-current', LEVEL_TEXT[service.level])} />
            <span className={LEVEL_TEXT[service.level]}>{levelText(service.level)}</span>
          </>
        ) : (
          <span className='text-text italic'>{levelText(service.level)}</span>
        )}
        <span className='min-w-0 flex-1 truncate text-text-strong'>{service.name}</span>
        <button
          aria-label={`Open status page of ${service.name}`}
          className='flex shrink-0 items-center gap-1 px-1 text-[11px] text-text-dim hover:bg-hover hover:text-text enabled:active:bg-accent/12'
          onClick={() => {
            window.bifrost.service.openPage(service.id).catch(() => {})
          }}
          type='button'
        >
          <ExternalLink aria-hidden={true} size={11} />
          Open status page
        </button>
      </div>
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

  const newest = list.reduce((max, s) => Math.max(max, s.checkedAt), 0)
  return (
    <div className='flex h-full flex-col gap-3 p-3 text-text' data-service-status={true}>
      {list.map(service => (
        <Block key={service.id} now={now} service={service} />
      ))}
      <div className='mt-auto text-[11px] text-text-dim'>{checkedText(newest, now)}</div>
    </div>
  )
}
