// The Usage HUD panel (spec 8.8): the 5-hour and the 7-day limit, each with the use and the
// reset time. A plan with no 5-hour window shows the 7-day limit only.
import { useEffect, useRef, useState } from 'react'
import type { AccountUsage, UsageSnapshot } from '../../../shared/types'
import { cx } from '../lib/cx'
import { useNow } from '../lib/use-now'
import { type UsageBar, usageView } from './usage-view'

function Bar({ bar }: { bar: UsageBar }): React.JSX.Element {
  return (
    <div data-usage-bar={bar.label}>
      <div className='flex items-baseline justify-between text-xs'>
        <span>{bar.label}</span>
        <span className='text-text-strong'>{bar.percent === null ? '-' : `${bar.percent}%`}</span>
      </div>
      <div className='my-1 h-1.5 bg-panel-edge'>
        <div
          className={cx('h-full', bar.high ? 'bg-usage-high' : 'bg-usage')}
          style={{ width: `${bar.percent ?? 0}%` }}
        />
      </div>
      <div className='text-[11px] text-text-dim'>{bar.detail}</div>
    </div>
  )
}

export default function UsagePanel(): React.JSX.Element {
  const [snapshot, setSnapshot] = useState<UsageSnapshot | null>(null)
  const [account, setAccount] = useState<AccountUsage | null>(null)
  const now = useNow(30_000)

  // The account usage from Anthropic. The panel opening asks the main process to poll. The main
  // process polls at most one time in 60 seconds, and only when the setting is on.
  useEffect(() => {
    let active = true
    let updated = false
    const off = window.bifrost.usage.onAccountUpdate(next => {
      updated = true
      if (active) setAccount(next)
    })
    window.bifrost.usage.getAccount().then(
      first => {
        if (active && !updated) setAccount(first)
      },
      () => {},
    )
    return () => {
      active = false
      off()
    }
  }, [])

  // The HUD opens when it mounts and when it becomes visible again (a minimised or hidden frame
  // stays mounted). Then the main process polls. It polls at most one time in 60 seconds.
  const root = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const ask = (): void => {
      window.bifrost.usage.hudOpened().catch(() => {})
    }
    const element = root.current
    if (!element || typeof IntersectionObserver === 'undefined') {
      ask()
      return
    }
    const observer = new IntersectionObserver(entries => {
      if (entries.some(entry => entry.isIntersecting)) ask()
    })
    observer.observe(element)
    return () => observer.disconnect()
  }, [])

  // Subscribe first, then load the value. An update that comes before the first answer wins.
  useEffect(() => {
    let active = true
    let updated = false
    const off = window.bifrost.usage.onUpdate(next => {
      updated = true
      if (active) setSnapshot(next)
    })
    window.bifrost.usage.get().then(
      first => {
        if (active && !updated) setSnapshot(first)
      },
      () => {},
    )
    return () => {
      active = false
      off()
    }
  }, [])

  const view = usageView(snapshot, now, undefined, account)
  return (
    <div className='flex h-full flex-col gap-3 p-3 text-text' data-usage-hud={true} ref={root}>
      {view.bars.map(bar => (
        <Bar bar={bar} key={bar.label} />
      ))}
      <div className='mt-auto text-[11px] text-text-dim'>{view.source}</div>
    </div>
  )
}
