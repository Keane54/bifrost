// The choice of the usage values (spec 8.8). The Usage HUD and the usage notification of the main
// process both use it, so they cannot disagree.
import type { AccountUsage, RateLimits, UsageSnapshot } from './types'

// From this percent, a limit is high. The HUD and the usage notification compare the rounded
// percent with it. The HUD bar then uses the usage-high colour, and Bifrost shows the usage
// notification.
export const HIGH_PERCENT = 90

// Account values older than this fall back to the session values.
export const ACCOUNT_MAX_AGE_MS = 15 * 60_000

export type UsageSource =
  | { kind: 'account'; account: AccountUsage; limits: RateLimits }
  | { kind: 'session'; snapshot: UsageSnapshot; limits: RateLimits }

// The account values when they are 15 minutes old or less. Else the newest session values from
// the usage lines. null when neither is available.
export function usageSource(
  snapshot: UsageSnapshot | null,
  now: number,
  account: AccountUsage | null,
): UsageSource | null {
  if (account && now - account.fetchedAt <= ACCOUNT_MAX_AGE_MS) {
    return { account, kind: 'account', limits: account.limits }
  }
  return snapshot ? { kind: 'session', limits: snapshot.limits, snapshot } : null
}
