import { readFileSync } from 'node:fs'
import { describe, expect, test } from 'vitest'
import { parseAccountUsage } from '../../../src/main/account-usage/parse'

const sample: unknown = JSON.parse(
  readFileSync(new URL('../../fixtures/oauth-usage-sample.json', import.meta.url), 'utf8'),
)

describe('parseAccountUsage', () => {
  test('the real answer gives the 7-day window and no 5-hour window', () => {
    expect(parseAccountUsage(sample)).toEqual({
      sevenDay: { resetsAt: Date.parse('2026-11-07T01:59:59.702828+00:00'), usedPercent: 36 },
    })
  })

  test('both windows are read', () => {
    const data = {
      five_hour: { resets_at: '2026-11-06T15:00:00+00:00', utilization: 12.5 },
      seven_day: { resets_at: '2026-11-09T00:00:00+00:00', utilization: 40 },
    }
    expect(parseAccountUsage(data)).toEqual({
      fiveHour: { resetsAt: Date.parse('2026-11-06T15:00:00Z'), usedPercent: 12.5 },
      sevenDay: { resetsAt: Date.parse('2026-11-09T00:00:00Z'), usedPercent: 40 },
    })
  })

  test('a null seven_day uses the weekly_all entry of limits', () => {
    const data = {
      five_hour: null,
      limits: [
        { kind: 'weekly_scoped', percent: 90, resets_at: '2026-11-09T00:00:00+00:00' },
        { kind: 'weekly_all', percent: 22, resets_at: '2026-11-08T00:00:00+00:00' },
      ],
      seven_day: null,
    }
    expect(parseAccountUsage(data)).toEqual({
      sevenDay: { resetsAt: Date.parse('2026-11-08T00:00:00Z'), usedPercent: 22 },
    })
    const { seven_day: _gone, ...missing } = data
    expect(parseAccountUsage(missing)).toEqual(parseAccountUsage(data))
  })

  test('seven_day wins over limits', () => {
    const data = {
      limits: [{ kind: 'weekly_all', percent: 99, resets_at: '2026-11-08T00:00:00+00:00' }],
      seven_day: { resets_at: '2026-11-09T00:00:00+00:00', utilization: 5 },
    }
    expect(parseAccountUsage(data)?.sevenDay?.usedPercent).toBe(5)
  })

  test('a percent above 100 is capped and a negative percent is dropped', () => {
    const over = { seven_day: { resets_at: '2026-11-09T00:00:00+00:00', utilization: 130 } }
    expect(parseAccountUsage(over)?.sevenDay?.usedPercent).toBe(100)
    const under = { seven_day: { resets_at: '2026-11-09T00:00:00+00:00', utilization: -3 } }
    expect(parseAccountUsage(under)).toBeNull()
  })

  test('bad data gives null', () => {
    const bad: unknown[] = [
      null,
      undefined,
      7,
      'x',
      [],
      {},
      { five_hour: null, seven_day: null },
      { seven_day: 'x' },
      { seven_day: { resets_at: '2026-11-09T00:00:00+00:00', utilization: '36' } },
      { seven_day: { resets_at: '2026-11-09T00:00:00+00:00', utilization: Number.NaN } },
      { seven_day: { resets_at: 'tomorrow', utilization: 36 } },
      { seven_day: { resets_at: 5, utilization: 36 } },
      { seven_day: { utilization: 36 } },
      { limits: 'x' },
      { limits: [null, 7, { kind: 'weekly_all' }, { kind: 'weekly_all', percent: 'x' }] },
    ]
    for (const data of bad) expect(parseAccountUsage(data)).toBeNull()
  })

  test('a bad five_hour does not hide a good seven_day', () => {
    const data = {
      five_hour: { resets_at: 'x', utilization: 'y' },
      seven_day: { resets_at: '2026-11-09T00:00:00+00:00', utilization: 8 },
    }
    expect(parseAccountUsage(data)).toEqual({
      sevenDay: { resetsAt: Date.parse('2026-11-09T00:00:00Z'), usedPercent: 8 },
    })
  })
})
