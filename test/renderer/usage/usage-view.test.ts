import { describe, expect, test } from 'vitest'
import { formatReset, usageView } from '../../../src/renderer/src/usage/usage-view'
import type { AccountUsage, UsageSnapshot } from '../../../src/shared/types'

const NOW = Date.UTC(2026, 10, 5, 12, 0)
const MIN = 60_000
const HOUR = 60 * MIN
const DAY = 24 * HOUR
const ZONE = 'UTC'

const snap = (limits: UsageSnapshot['limits'], updatedAt = NOW - 2 * MIN): UsageSnapshot => ({
  limits,
  name: 'bifrost-test-a',
  sessionId: 'abcdef12-0000',
  updatedAt,
})

describe('usageView', () => {
  test('usageView gives No data for each bar without a snapshot', () => {
    const v = usageView(null, NOW, ZONE)
    expect(v.bars[0]).toEqual({
      detail: 'No data',
      high: false,
      label: '5-hour limit',
      percent: null,
    })
    expect(v.bars[1]).toEqual({
      detail: 'No data',
      high: false,
      label: '7-day limit',
      percent: null,
    })
    expect(v.source).toBe('No usage data yet.')
  })

  test('usageView shows the 7-day bar of a plan with no 5-hour window', () => {
    const v = usageView(snap({ sevenDay: { resetsAt: NOW + 3 * DAY, usedPercent: 10 } }), NOW, ZONE)
    expect(v.bars[0]).toMatchObject({ detail: 'No data for this limit yet.', percent: null })
    expect(v.bars[1]).toMatchObject({
      detail: 'Resets in 3 d 0 h (Sun 12:00)',
      high: false,
      percent: 10,
    })
  })

  test('a window whose reset time passed shows - and the reset time (final wave item 8)', () => {
    const v = usageView(snap({ fiveHour: { resetsAt: NOW - HOUR, usedPercent: 95 } }), NOW, ZONE)
    expect(v.bars[0]).toEqual({
      detail: 'Reset at 11:00.',
      high: false,
      label: '5-hour limit',
      percent: null,
    })
    // A reset time at this minute has passed too.
    const at = usageView(snap({ fiveHour: { resetsAt: NOW, usedPercent: 95 } }), NOW, ZONE)
    expect(at.bars[0]).toMatchObject({ detail: 'Reset at 12:00.', percent: null })
    // A reset on another day shows the day.
    const old = usageView(snap({ sevenDay: { resetsAt: NOW - DAY, usedPercent: 40 } }), NOW, ZONE)
    expect(old.bars[1]).toMatchObject({ detail: 'Reset at Wed 12:00.', percent: null })
  })

  test('a usedPercent that is not a finite number shows -, not 0%', () => {
    for (const usedPercent of [Number.NaN, Number.POSITIVE_INFINITY]) {
      const v = usageView(snap({ fiveHour: { resetsAt: NOW + HOUR, usedPercent } }), NOW, ZONE)
      expect(v.bars[0]).toEqual({
        detail: 'Resets in 1 h 00 min (13:00)',
        high: false,
        label: '5-hour limit',
        percent: null,
      })
    }
  })

  test('a reset under 1 minute from now shows less than 1 min', () => {
    expect(formatReset(NOW + 30_000, NOW, ZONE)).toBe('less than 1 min (12:00)')
    const v = usageView(snap({ fiveHour: { resetsAt: NOW + 59_999, usedPercent: 97 } }), NOW, ZONE)
    expect(v.bars[0]).toMatchObject({
      detail: 'Resets in less than 1 min (12:00)',
      high: true,
      percent: 97,
    })
  })

  test('usageView rounds and clamps the percent and marks 90% as high', () => {
    const at = (usedPercent: number) =>
      usageView(snap({ fiveHour: { resetsAt: NOW + HOUR, usedPercent } }), NOW, ZONE).bars[0]
    expect(at(89.6)).toMatchObject({ high: true, percent: 90 })
    expect(at(89.4)).toMatchObject({ high: false, percent: 89 })
    expect(at(120)).toMatchObject({ high: true, percent: 100 })
    expect(at(-3)).toMatchObject({ high: false, percent: 0 })
  })

  test('formatReset gives minutes, hours and days', () => {
    expect(formatReset(NOW + 45 * MIN, NOW, ZONE)).toBe('45 min (12:45)')
    expect(formatReset(NOW + 125 * MIN, NOW, ZONE)).toBe('2 h 05 min (14:05)')
    expect(formatReset(NOW + 25 * HOUR, NOW, ZONE)).toBe('1 d 1 h (Fri 13:00)')
  })

  test('the source names the session and the age', () => {
    const v = usageView(snap({ fiveHour: { resetsAt: NOW + HOUR, usedPercent: 5 } }), NOW, ZONE)
    expect(v.source).toBe('From bifrost-test-a, 2 min ago.')
  })
})

describe('usageView with account values', () => {
  const account = (ageMs: number, limits: AccountUsage['limits']): AccountUsage => ({
    fetchedAt: NOW - ageMs,
    limits,
  })
  const session = snap({
    fiveHour: { resetsAt: NOW + HOUR, usedPercent: 91 },
    sevenDay: { resetsAt: NOW + DAY, usedPercent: 70 },
  })
  const sevenOnly = { sevenDay: { resetsAt: NOW + 3 * DAY, usedPercent: 36 } }

  test('fresh account values win over the session values', () => {
    const v = usageView(session, NOW, ZONE, account(3 * MIN, sevenOnly))
    expect(v.bars[1]).toMatchObject({
      detail: 'Resets in 3 d 0 h (Sun 12:00)',
      high: false,
      percent: 36,
    })
    expect(v.source).toBe('From your Anthropic account, updated 3 min ago.')
  })

  test('a plan with no 5-hour window shows a dash and the reason', () => {
    const v = usageView(session, NOW, ZONE, account(0, sevenOnly))
    expect(v.bars[0]).toEqual({
      detail: 'No 5-hour limit right now.',
      high: false,
      label: '5-hour limit',
      percent: null,
    })
    expect(v.source).toBe('From your Anthropic account, updated 0 s ago.')
  })

  test('the bar rules stay the same: high at 90 percent', () => {
    const v = usageView(
      null,
      NOW,
      ZONE,
      account(MIN, {
        fiveHour: { resetsAt: NOW + HOUR, usedPercent: 90 },
        sevenDay: { resetsAt: NOW + DAY, usedPercent: 89.4 },
      }),
    )
    expect(v.bars[0]).toMatchObject({ high: true, percent: 90 })
    expect(v.bars[1]).toMatchObject({ high: false, percent: 89 })
  })

  test('account values of exactly 15 minutes still win', () => {
    const v = usageView(session, NOW, ZONE, account(15 * MIN, sevenOnly))
    expect(v.source).toBe('From your Anthropic account, updated 15 min ago.')
  })

  test('account values older than 15 minutes fall back to the session values', () => {
    const v = usageView(session, NOW, ZONE, account(15 * MIN + 1, sevenOnly))
    expect(v.bars[0]).toMatchObject({ percent: 91 })
    expect(v.source).toBe('From bifrost-test-a, 2 min ago.')
  })

  test('old account values with no session values give No usage data', () => {
    const v = usageView(null, NOW, ZONE, account(20 * MIN, sevenOnly))
    expect(v.source).toBe('No usage data yet.')
  })

  test('no account values give the session values as before', () => {
    expect(usageView(session, NOW, ZONE, null)).toEqual(usageView(session, NOW, ZONE))
  })
})
