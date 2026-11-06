// The texts and numbers of the Usage HUD (spec 8.8). Pure functions, no React.
import type { RateWindow, UsageSnapshot } from '../../../shared/types'
import { formatClock, formatDayClock, formatDuration, timeParts } from '../lib/time'
import { formatAge } from '../overview/format'

// From this percent, the bar uses the usage-high colour.
export const HIGH_PERCENT = 90

export interface UsageBar {
  label: '5-hour limit' | '7-day limit'
  // null means that no value is known.
  percent: number | null
  high: boolean
  detail: string
}

const NO_DATA = 'No data'
const NO_WINDOW = 'No data for this limit yet.'

function sameDay(a: number, b: number, timeZone?: string): boolean {
  const x = timeParts(a, timeZone)
  const y = timeParts(b, timeZone)
  return x.day === y.day && x.month === y.month && x.year === y.year
}

// "45 min (12:45)", "2 h 05 min (14:05)", "1 d 1 h (Fri 13:00)".
export function formatReset(resetsAt: number, now: number, timeZone?: string): string {
  const clock = sameDay(resetsAt, now, timeZone)
    ? formatClock(resetsAt, timeZone)
    : formatDayClock(resetsAt, timeZone)
  return `${formatDuration(resetsAt - now)} (${clock})`
}

function bar(
  label: UsageBar['label'],
  window: RateWindow | undefined,
  now: number,
  timeZone?: string,
): UsageBar {
  if (!window) return { detail: NO_WINDOW, high: false, label, percent: null }
  if (window.resetsAt <= now) {
    return {
      detail: `Reset at ${formatClock(window.resetsAt, timeZone)}.`,
      high: false,
      label,
      percent: 0,
    }
  }
  const raw = Number.isFinite(window.usedPercent) ? window.usedPercent : 0
  const percent = Math.min(100, Math.max(0, Math.round(raw)))
  return {
    detail: `Resets in ${formatReset(window.resetsAt, now, timeZone)}`,
    high: percent >= HIGH_PERCENT,
    label,
    percent,
  }
}

export function usageView(
  snapshot: UsageSnapshot | null,
  now: number,
  timeZone?: string,
): { bars: [UsageBar, UsageBar]; source: string } {
  if (!snapshot) {
    return {
      bars: [
        { detail: NO_DATA, high: false, label: '5-hour limit', percent: null },
        { detail: NO_DATA, high: false, label: '7-day limit', percent: null },
      ],
      source: 'No usage data yet. Live details sends it.',
    }
  }
  return {
    bars: [
      bar('5-hour limit', snapshot.limits.fiveHour, now, timeZone),
      bar('7-day limit', snapshot.limits.sevenDay, now, timeZone),
    ],
    source: `From ${snapshot.name}, ${formatAge(snapshot.updatedAt, now)} ago.`,
  }
}
