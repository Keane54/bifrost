import { describe, expect, test } from 'vitest'
import type { AccountUsage, UsageSnapshot } from '../../src/shared/types'
import { ACCOUNT_MAX_AGE_MS, HIGH_PERCENT, usageSource } from '../../src/shared/usage'

const NOW = Date.UTC(2026, 10, 10, 12, 0)
const MIN = 60_000

const snapshot: UsageSnapshot = {
  limits: { fiveHour: { resetsAt: NOW + 60 * MIN, usedPercent: 40 } },
  name: 'bifrost-test-a',
  sessionId: 'abcdef12-0000',
  updatedAt: NOW - 2 * MIN,
}

const account = (age: number): AccountUsage => ({
  fetchedAt: NOW - age,
  limits: { sevenDay: { resetsAt: NOW + 3 * 24 * 60 * MIN, usedPercent: 91 } },
})

describe('usageSource', () => {
  test('the constants are 90 percent and 15 minutes', () => {
    expect(HIGH_PERCENT).toBe(90)
    expect(ACCOUNT_MAX_AGE_MS).toBe(15 * MIN)
  })

  test('the account values win while they are 15 minutes old or less', () => {
    const fresh = account(15 * MIN)
    expect(usageSource(snapshot, NOW, fresh)).toEqual({
      account: fresh,
      kind: 'account',
      limits: fresh.limits,
    })
    // The account values win also when they lack a window that the session values have.
    expect(usageSource(snapshot, NOW, account(0))?.limits.fiveHour).toBeUndefined()
  })

  test('older account values fall back to the session values', () => {
    expect(usageSource(snapshot, NOW, account(15 * MIN + 1))).toEqual({
      kind: 'session',
      limits: snapshot.limits,
      snapshot,
    })
    expect(usageSource(snapshot, NOW, null)?.kind).toBe('session')
  })

  test('no values give null', () => {
    expect(usageSource(null, NOW, null)).toBeNull()
    expect(usageSource(null, NOW, account(16 * MIN))).toBeNull()
  })
})
