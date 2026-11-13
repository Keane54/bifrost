// Read the answer of GET /api/oauth/usage. The endpoint is not documented, so every step is
// defensive. A bad answer gives null ("no data"), never a throw. Other keys are ignored.

import { isRecord } from '../../shared/plain-object'
import type { AccountUsage, RateLimits, RateWindow } from '../../shared/types'

// A window from a percent and an ISO 8601 reset time. A percent above 100 becomes 100.
function windowOf(percent: unknown, resetsAt: unknown): RateWindow | null {
  if (typeof percent !== 'number' || !Number.isFinite(percent) || percent < 0) return null
  if (typeof resetsAt !== 'string') return null
  const time = Date.parse(resetsAt)
  if (!Number.isFinite(time)) return null
  return { resetsAt: time, usedPercent: Math.min(100, percent) }
}

function fromObject(value: unknown): RateWindow | null {
  return isRecord(value) ? windowOf(value.utilization, value.resets_at) : null
}

// The weekly_all entry of the list limits.
function fromLimits(value: unknown): RateWindow | null {
  if (!Array.isArray(value)) return null
  for (const entry of value) {
    if (isRecord(entry) && entry.kind === 'weekly_all') {
      const found = windowOf(entry.percent, entry.resets_at)
      if (found) return found
    }
  }
  return null
}

// Return the windows of the answer, or null when it has no good window.
export function parseAccountUsage(data: unknown): RateLimits | null {
  if (!isRecord(data)) return null
  const limits: RateLimits = {}
  const fiveHour = fromObject(data.five_hour)
  if (fiveHour) limits.fiveHour = fiveHour
  const sevenDay = fromObject(data.seven_day) ?? fromLimits(data.limits)
  if (sevenDay) limits.sevenDay = sevenDay
  return limits.fiveHour || limits.sevenDay ? limits : null
}

// The extra usage flag of the answer: extra_usage.is_enabled. Extra usage is the pay-as-you-go
// spend above the plan. A missing value or a value that is not a boolean gives undefined.
function parseExtraUsage(data: Record<string, unknown>): boolean | undefined {
  const extra = data.extra_usage
  if (!isRecord(extra)) return undefined
  return typeof extra.is_enabled === 'boolean' ? extra.is_enabled : undefined
}

// The account usage of the answer, or null when it has no good window. fetchedAt is the time of
// the answer. The value has extraUsage only when the answer gives a boolean for it.
export function parseAccountAnswer(data: unknown, fetchedAt: number): AccountUsage | null {
  const limits = parseAccountUsage(data)
  if (!limits || !isRecord(data)) return null
  const extraUsage = parseExtraUsage(data)
  return extraUsage === undefined ? { fetchedAt, limits } : { extraUsage, fetchedAt, limits }
}
