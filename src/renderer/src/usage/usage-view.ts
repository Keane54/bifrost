// The texts and numbers of the Usage HUD (spec 8.8). Pure functions, no React.
import type { AccountUsage, RateWindow, UsageSnapshot } from '../../../shared/types'
import { formatClock, formatDayClock, formatDuration, sameDay } from '../lib/time'
import { formatAge } from '../overview/format'

// From this percent, the bar uses the usage-high colour.
export const HIGH_PERCENT = 90

// Account values older than this fall back to the session values.
export const ACCOUNT_MAX_AGE_MS = 15 * 60_000

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

// HH:MM on the day of now, else Ddd HH:MM.
function clockText(ms: number, now: number, timeZone?: string): string {
  return sameDay(ms, now, timeZone) ? formatClock(ms, timeZone) : formatDayClock(ms, timeZone)
}

// "45 min (12:45)", "2 h 05 min (14:05)", "1 d 1 h (Fri 13:00)".
export function formatReset(resetsAt: number, now: number, timeZone?: string): string {
  return `${formatDuration(resetsAt - now)} (${clockText(resetsAt, now, timeZone)})`
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
      detail: `Reset at ${clockText(window.resetsAt, now, timeZone)}.`,
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
// they come from the usage lines of the sessions.
export function usageView(
  snapshot: UsageSnapshot | null,
  now: number,
  timeZone?: string,
  account: AccountUsage | null = null,
): { bars: [UsageBar, UsageBar]; source: string } {
  if (account && now - account.fetchedAt <= ACCOUNT_MAX_AGE_MS) {
    const { fiveHour, sevenDay } = account.limits
    return {
      bars: [
        bar('5-hour limit', fiveHour, now, timeZone, NO_FIVE_HOUR),
        bar('7-day limit', sevenDay, now, timeZone),
      ],
      source: `From your Anthropic account, updated ${formatAge(account.fetchedAt, now)} ago.`,
    }
  }
  if (!snapshot) {
    return {
      bars: [
        { detail: NO_DATA, high: false, label: '5-hour limit', percent: null },
        { detail: NO_DATA, high: false, label: '7-day limit', percent: null },
      ],
      source: 'No usage data yet.',
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
