// The Usage HUD panel (spec 8.8): the 5-hour and the 7-day limit, each with the use and the
// reset time.
import { useEffect, useState } from 'react'
import type { UsageSnapshot } from '../../../shared/types'
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
  const now = useNow(30_000)

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

  const view = usageView(snapshot, now)
  return (
    <div className='flex h-full flex-col gap-3 p-3 text-text' data-usage-hud={true}>
      <Bar bar={view.bars[0]} />
      <Bar bar={view.bars[1]} />
      <div className='mt-auto text-[11px] text-text-dim'>{view.source}</div>
    </div>
  )
}
