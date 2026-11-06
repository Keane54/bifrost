import { describe, expect, test } from 'vitest'
import { formatReset, usageView } from '../../../src/renderer/src/usage/usage-view'
import type { UsageSnapshot } from '../../../src/shared/types'

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
    expect(v.source).toBe('No usage data yet. Live details sends it.')
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

  test('a window whose reset time passed shows 0%', () => {
    const v = usageView(snap({ fiveHour: { resetsAt: NOW - HOUR, usedPercent: 95 } }), NOW, ZONE)
    expect(v.bars[0]).toMatchObject({ detail: 'Reset at 11:00.', high: false, percent: 0 })
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
