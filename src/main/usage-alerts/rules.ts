// The rules of the usage notification (spec 8.8). When the 5-hour limit or the 7-day limit gets to
// 90% or more, Bifrost shows one notification. Each limit notifies one time in each reset period.
// Pure functions, no Electron.
import { formatClockOrDay } from '../../shared/time'
import type { RateLimits } from '../../shared/types'
import { HIGH_PERCENT } from '../../shared/usage'

export type LimitId = 'fiveHour' | 'sevenDay'

const LIMITS: readonly LimitId[] = ['fiveHour', 'sevenDay']

const LIMIT_NAMES: Record<LimitId, string> = {
  fiveHour: '5-hour limit',
  sevenDay: '7-day limit',
}

// The reset time of the last period that notified, for each limit, in milliseconds. null means
// that no period notified.
export interface NotifiedPeriods {
  fiveHour: number | null
  sevenDay: number | null
}

export const NO_PERIODS: NotifiedPeriods = { fiveHour: null, sevenDay: null }

// The account values and the session values can give a slightly different reset time for the
// same period. A reset time that is this much later or less is the same period.
export const SAME_PERIOD_MS = 15 * 60_000

export interface UsageAlert {
  limit: LimitId
  usedPercent: number
  resetsAt: number
}

// True when the reset time is more than 15 minutes after the kept reset time.
export function isNewPeriod(resetsAt: number, kept: number | null): boolean {
  return kept === null || resetsAt > kept + SAME_PERIOD_MS
}

// The limits that must notify now: the rounded value is 90% or more, the reset time is in the
// future, and the period did not notify yet. The rounded value agrees with the HUD colour. The
// 5-hour limit comes first.
export function dueAlerts(
  limits: RateLimits,
  notified: NotifiedPeriods,
  now: number,
): UsageAlert[] {
  const alerts: UsageAlert[] = []
  for (const limit of LIMITS) {
    const window = limits[limit]
    if (!window) continue
    const { resetsAt, usedPercent } = window
    if (!Number.isFinite(resetsAt) || resetsAt <= now) continue
    if (!(Math.round(usedPercent) >= HIGH_PERCENT)) continue
    if (!isNewPeriod(resetsAt, notified[limit])) continue
    alerts.push({ limit, resetsAt, usedPercent })
  }
  return alerts
}

// Follow the reset time of each kept period. A value in the same period with a later reset time
// raises the kept value to that reset time. So small steps of the reset time cannot add up to more
// than 15 minutes and make a new period. The percent does not matter here.
export function followPeriods(
  limits: RateLimits,
  notified: NotifiedPeriods,
  now: number,
): NotifiedPeriods {
  const next = { ...notified }
  for (const limit of LIMITS) {
    const window = limits[limit]
    const kept = notified[limit]
    if (!window || kept === null) continue
    const { resetsAt } = window
    if (!Number.isFinite(resetsAt) || resetsAt <= now) continue
    if (resetsAt > kept && !isNewPeriod(resetsAt, kept)) next[limit] = resetsAt
  }
  return next
}

// The notified periods after the alerts show.
export function afterAlerts(notified: NotifiedPeriods, alerts: UsageAlert[]): NotifiedPeriods {
  const next = { ...notified }
  for (const alert of alerts) next[alert.limit] = alert.resetsAt
  return next
}

// The title and the body of the notification. extraUsage true gives a warning that real money
// can be spent. The percent is the rounded value, capped at 100. The reset time is HH:MM on the
// day of now, else Ddd HH:MM.
export function alertText(
  alert: UsageAlert,
  extraUsage: boolean,
  now: number,
  timeZone?: string,
): { title: string; body: string } {
  const name = LIMIT_NAMES[alert.limit]
  const percent = Math.min(100, Math.round(alert.usedPercent))
  const clock = formatClockOrDay(alert.resetsAt, now, timeZone)
  if (extraUsage) {
    return {
      body:
        `Your ${name} is at ${percent}%. After 100%, Claude Code spends your extra usage ` +
        `credits, which costs real money. It resets at ${clock}.`,
      title: 'Warning: extra usage is on',
    }
  }
  return {
    body: `Claude Code stops at 100% until the limit resets at ${clock}.`,
    title: `${name} at ${percent}%`,
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

// The extra usage flag of ~/.claude.json. Only oauthAccount.hasExtraUsageEnabled true counts as
// on. A value that is not known counts as off.
export function extraUsageOfClaudeJson(data: unknown): boolean {
  return isRecord(data) && isRecord(data.oauthAccount)
    ? data.oauthAccount.hasExtraUsageEnabled === true
    : false
}
