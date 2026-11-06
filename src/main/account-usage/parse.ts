// Read the answer of GET /api/oauth/usage. The endpoint is not documented, so every step is
// defensive. A bad answer gives null ("no data"), never a throw. Other keys are ignored.
import type { RateLimits, RateWindow } from '../../shared/types'

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

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
