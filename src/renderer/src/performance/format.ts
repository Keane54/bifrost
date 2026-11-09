// The texts and the trend line points of the Performance panel (design section 5.2).
import type { PerformanceSnapshot } from '../../../shared/performance'
import { formatClock } from '../lib/time'

const MB_PER_GB = 1024
const NET_STEP = 1000

// A RAM value. Below 1024 MB it is a whole number of MB. From 1024 MB it is GB with two
// decimals. The nearest whole MB value decides, so 1023.6 MB gives "1.00 GB" and not "1024 MB".
export function mb(value: number): string {
  const whole = Math.round(value)
  return whole < MB_PER_GB ? `${whole} MB` : `${(value / MB_PER_GB).toFixed(2)} GB`
}

// A whole number of GB, for the free disk. A decimal adds no use there.
export function gb(value: number | null): string {
  return value === null ? '-' : `${Math.round(value)} GB`
}

// A CPU value as a whole percent of one core.
export function percent(value: number): string {
  return `${Math.round(value)}%`
}

// A network rate. The steps are 1000, as for the network. The nearest whole value decides the
// unit.
export function rate(bytesPerSecond: number): string {
  const bytes = Math.round(bytesPerSecond)
  if (bytes < NET_STEP) return `${bytes} B/s`
  const kb = Math.round(bytesPerSecond / NET_STEP)
  if (kb < NET_STEP) return `${kb} KB/s`
  return `${(bytesPerSecond / NET_STEP ** 2).toFixed(1)} MB/s`
}

// A time in ms, or the word for a request with no answer or no connection.
export function ms(value: number | 'no-answer' | 'unreachable' | null): string {
  if (value === null) return '-'
  if (value === 'no-answer') return 'No answer'
  if (value === 'unreachable') return "Can't reach"
  return `${Math.round(value)} ms`
}

const THERMAL: Record<string, string> = {
  critical: 'Critical',
  fair: 'Fair',
  nominal: 'Normal',
  serious: 'Serious',
}

// The thermal state of macOS as a word. An unknown state gives a dash.
export function thermalText(state: string | null): string {
  return (state !== null && THERMAL[state]) || '-'
}

type Battery = NonNullable<PerformanceSnapshot['mac']>['battery']

// The battery level and the power state. A full battery on a power adapter is "charged", and macOS
// can also hold the charge below 100%. Both are on power and not charging, so the text says
// "plugged in" and not "not charging".
export function batteryText(battery: Battery): string {
  if (battery === null) return '-'
  const state = battery.charging ? 'charging' : battery.onBattery ? 'on battery' : 'plugged in'
  return `${Math.round(battery.percent)}%, ${state}`
}

type Pressure = NonNullable<PerformanceSnapshot['mac']>['pressure']

const PRESSURE: Record<NonNullable<Pressure>, string> = {
  critical: 'High',
  normal: 'Normal',
  warn: 'Medium',
}

// The memory pressure of macOS as a word.
export function pressureText(p: Pressure): string {
  return p === null ? '-' : PRESSURE[p]
}

// The GitHub GraphQL points: what is left of the limit and the reset time, or the reason when
// Bifrost cannot read them (design section 7). The time zone argument is for tests.
export function pointsText(
  github: PerformanceSnapshot['limits']['github'],
  timeZone?: string,
): string {
  if (github === null) return '-'
  if ('unavailable' in github) return `Not available - ${github.unavailable}`
  const left = github.remaining.toLocaleString('en-US')
  const limit = github.limit.toLocaleString('en-US')
  return `${left} of ${limit} left · resets ${formatClock(github.resetAt, timeZone)}`
}

// The size of the trend line in SVG units, and the time that it shows.
export const TREND_W = 500
export const TREND_H = 34
const TREND_PAD = 2
const TREND_MS = 600_000
const MINUTE_MS = 60_000
// The RAM line shows at least this range, so a small change does not fill the height.
const MIN_RAM_SPAN_MB = 64
// The CPU line shows at least 0 to 100% of one core.
const MIN_CPU_TOP = 100

type TrendPoint = NonNullable<PerformanceSnapshot['bifrost']>['trend'][number]

function coord(n: number): string {
  return String(Math.round(n * 10) / 10)
}

// The y position of a value in the range from low (bottom) to high (top).
function yOf(value: number, low: number, high: number): number {
  const inner = TREND_H - 2 * TREND_PAD
  return TREND_H - TREND_PAD - ((value - low) / (high - low)) * inner
}

// The points of the 10 minutes before the newest point, and the time from the oldest of them to
// the newest.
function trendWindow(trend: readonly TrendPoint[]): { points: TrendPoint[]; spanMs: number } {
  const last = trend.at(-1)
  if (last === undefined) return { points: [], spanMs: 0 }
  const points = trend.filter(p => p.at >= last.at - TREND_MS)
  return { points, spanMs: last.at - (points[0]?.at ?? last.at) }
}

// The polyline points of the RAM line and the CPU line. The x axis goes from the oldest point of
// the 10-minute window at the left edge to the newest point at the right edge. So a short trend
// also fills the width. One point is at the right edge. The RAM line uses its own range. The
// CPU line starts at 0.
export function trendLines(trend: readonly TrendPoint[]): { ram: string; cpu: string } {
  const { points, spanMs } = trendWindow(trend)
  const first = points[0]
  if (first === undefined) return { cpu: '', ram: '' }
  const xOf = (at: number): number =>
    spanMs === 0 ? TREND_W : ((at - first.at) / spanMs) * TREND_W
  const rams = points.map(p => p.ramMb)
  let low = Math.min(...rams)
  let high = Math.max(...rams)
  if (high - low < MIN_RAM_SPAN_MB) {
    const middle = (low + high) / 2
    low = middle - MIN_RAM_SPAN_MB / 2
    high = middle + MIN_RAM_SPAN_MB / 2
  }
  const cpuTop = Math.max(MIN_CPU_TOP, ...points.map(p => p.cpu))
  const line = (y: (p: TrendPoint) => number): string =>
    points.map(p => `${coord(xOf(p.at))},${coord(y(p))}`).join(' ')
  return {
    cpu: line(p => yOf(p.cpu, 0, cpuTop)),
    ram: line(p => yOf(p.ramMb, low, high)),
  }
}

// The time of the trend key. Until the trend fills its 10 minutes, it gives the minutes up to the
// next whole minute, from 1. For example, 2 minutes and 10 s give "Last 3 min". Then it gives
// "Last 10 minutes".
export function trendLabel(trend: readonly TrendPoint[]): string {
  const minutes = Math.max(1, Math.ceil(trendWindow(trend).spanMs / MINUTE_MS))
  return minutes >= TREND_MS / MINUTE_MS ? 'Last 10 minutes' : `Last ${minutes} min`
}
