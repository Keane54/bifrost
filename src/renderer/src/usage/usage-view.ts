// The texts and numbers of the Usage HUD (spec 8.8). Pure functions, no React.
import { formatClockOrDay, formatDuration } from '../../../shared/time'
import type { AccountUsage, RateLimits, RateWindow, UsageSnapshot } from '../../../shared/types'
import { HIGH_PERCENT, usageSource } from '../../../shared/usage'
import { formatAge } from '../overview/format'

export interface UsageBar {
  label: '5-hour limit' | '7-day limit'
  // null means that no value is known.
  percent: number | null
  high: boolean
  detail: string
}

const NO_DATA = 'No data'
const NO_WINDOW = 'No data for this limit yet.'
const NO_FIVE_HOUR = 'No 5-hour limit right now.'

// "45 min (12:45)", "2 h 05 min (14:05)", "1 d 1 h (Fri 13:00)".
export function formatReset(resetsAt: number, now: number, timeZone?: string): string {
  return `${formatDuration(resetsAt - now)} (${formatClockOrDay(resetsAt, now, timeZone)})`
}

function bar(
  label: UsageBar['label'],
  window: RateWindow | undefined,
  now: number,
  timeZone?: string,
  noWindow: string = NO_WINDOW,
): UsageBar {
  if (!window) return { detail: noWindow, high: false, label, percent: null }
  // After the reset time, the use of the new window is not known until the next message. The
  // old value is wrong, and 0% is only a guess. So the bar shows "-" and the reset time, the same
  // as Show Info (final wave item 8).
  if (window.resetsAt <= now) {
    return {
      detail: `Reset at ${formatClockOrDay(window.resetsAt, now, timeZone)}.`,
      high: false,
      label,
      percent: null,
    }
  }
  const detail = `Resets in ${formatReset(window.resetsAt, now, timeZone)}`
  // A value that is not a finite number is not known. It shows "-", not 0%.
  if (!Number.isFinite(window.usedPercent)) return { detail, high: false, label, percent: null }
  const percent = Math.min(100, Math.max(0, Math.round(window.usedPercent)))
  return { detail, high: percent >= HIGH_PERCENT, label, percent }
}

// The bars come from the account values when they are 15 minutes old or less (spec 8.8). Else
// they come from the usage lines of the sessions. usageSource makes this choice, and the usage
// notification uses the same function.
// A source with a 7-day window and no 5-hour window gives the 7-day bar only. A plan can have no
// 5-hour window (user decision, 2026-11-10). A source with no window gives both bars.
function barsOf(
  limits: RateLimits,
  now: number,
  timeZone: string | undefined,
  noFiveHour: string,
): UsageBar[] {
  const seven = bar('7-day limit', limits.sevenDay, now, timeZone)
  if (!limits.fiveHour && limits.sevenDay) return [seven]
  return [bar('5-hour limit', limits.fiveHour, now, timeZone, noFiveHour), seven]
}

export function usageView(
  snapshot: UsageSnapshot | null,
  now: number,
  timeZone?: string,
  account: AccountUsage | null = null,
): { bars: UsageBar[]; source: string } {
  const source = usageSource(snapshot, now, account)
  if (source?.kind === 'account') {
    return {
      bars: barsOf(source.limits, now, timeZone, NO_FIVE_HOUR),
      source: `From your Anthropic account, updated ${formatAge(source.account.fetchedAt, now)} ago.`,
    }
  }
  if (!source) {
    return {
      bars: [
        { detail: NO_DATA, high: false, label: '5-hour limit', percent: null },
        { detail: NO_DATA, high: false, label: '7-day limit', percent: null },
      ],
      source: 'No usage data yet.',
    }
  }
  return {
    bars: barsOf(source.limits, now, timeZone, NO_WINDOW),
    source: `From ${source.snapshot.name}, ${formatAge(source.snapshot.updatedAt, now)} ago.`,
  }
}
