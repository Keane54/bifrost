// The trend line of the Bifrost section (design section 5.2): the RAM and the CPU of Bifrost in
// the last 10 minutes. An inline SVG. Each line takes its colour from a token class.
import type { PerformanceSnapshot } from '../../../shared/performance'
import { cx } from '../lib/cx'
import { TREND_H, TREND_W, trendLines } from './format'

type Trend = NonNullable<PerformanceSnapshot['bifrost']>['trend']

// The RAM line is the stronger line. The CPU line is thin and dim.
const RAM_LINE = 'text-usage'
const CPU_LINE = 'text-text-dim'

function Key({ label, line }: { label: string; line: string }): React.JSX.Element {
  return (
    <span className='inline-flex items-center gap-1'>
      <span aria-hidden={true} className={cx('inline-block h-0.5 w-3 bg-current', line)} />
      {label}
    </span>
  )
}

export default function TrendLine({ trend }: { trend: Trend }): React.JSX.Element {
  const { cpu, ram } = trendLines(trend)
  return (
    <div data-perf-trend={true}>
      {/* The SVG stretches to the width of the panel. The strokes keep their width. */}
      <svg
        aria-hidden={true}
        className='mt-0.5 mb-1 block h-[34px] w-full'
        preserveAspectRatio='none'
        viewBox={`0 0 ${TREND_W} ${TREND_H}`}
      >
        <polyline
          className={CPU_LINE}
          fill='none'
          points={cpu}
          stroke='currentColor'
          strokeWidth={1}
          vectorEffect='non-scaling-stroke'
        />
        <polyline
          className={RAM_LINE}
          fill='none'
          points={ram}
          stroke='currentColor'
          strokeWidth={1.5}
          vectorEffect='non-scaling-stroke'
        />
      </svg>
      <div className='mb-1 flex gap-3 text-[10px] text-text-dim'>
        <Key label='Memory' line={RAM_LINE} />
        <Key label='CPU' line={CPU_LINE} />
        <span>Last 10 minutes</span>
      </div>
    </div>
  )
}
