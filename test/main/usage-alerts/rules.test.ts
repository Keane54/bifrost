import { describe, expect, test } from 'vitest'
import {
  afterAlerts,
  alertText,
  dueAlerts,
  extraUsageOfClaudeJson,
  isNewPeriod,
  NO_PERIODS,
  SAME_PERIOD_MS,
  type UsageAlert,
} from '../../../src/main/usage-alerts/rules'
import type { RateLimits } from '../../../src/shared/types'

const NOW = Date.UTC(2026, 10, 10, 12, 0)
const MIN = 60_000
const HOUR = 60 * MIN
const DAY = 24 * HOUR
const ZONE = 'UTC'
const FIVE_RESET = NOW + 2 * HOUR + 5 * MIN
const SEVEN_RESET = NOW + 3 * DAY + HOUR

const five = (usedPercent: number, resetsAt = FIVE_RESET): RateLimits => ({
  fiveHour: { resetsAt, usedPercent },
})

describe('isNewPeriod', () => {
  test('a limit with no notified period has a new period', () => {
    expect(isNewPeriod(FIVE_RESET, null)).toBe(true)
  })

  test('a reset time up to 15 minutes after the kept value is the same period', () => {
    expect(SAME_PERIOD_MS).toBe(15 * MIN)
    expect(isNewPeriod(FIVE_RESET, FIVE_RESET)).toBe(false)
    expect(isNewPeriod(FIVE_RESET + 15 * MIN, FIVE_RESET)).toBe(false)
    expect(isNewPeriod(FIVE_RESET + 15 * MIN + 1, FIVE_RESET)).toBe(true)
    expect(isNewPeriod(FIVE_RESET + 5 * HOUR, FIVE_RESET)).toBe(true)
  })

  test('a reset time before the kept value is not a new period', () => {
    expect(isNewPeriod(FIVE_RESET - MIN, FIVE_RESET)).toBe(false)
    expect(isNewPeriod(FIVE_RESET - 5 * HOUR, FIVE_RESET)).toBe(false)
  })
})

describe('dueAlerts', () => {
  test('a limit at 90% or more notifies', () => {
    expect(dueAlerts(five(90), NO_PERIODS, NOW)).toEqual([
      { limit: 'fiveHour', resetsAt: FIVE_RESET, usedPercent: 90 },
    ])
    expect(dueAlerts(five(100), NO_PERIODS, NOW)).toHaveLength(1)
  })

  test('a limit below 90% does not notify', () => {
    expect(dueAlerts(five(89.9), NO_PERIODS, NOW)).toEqual([])
    expect(dueAlerts(five(0), NO_PERIODS, NOW)).toEqual([])
    expect(dueAlerts({}, NO_PERIODS, NOW)).toEqual([])
  })

  test('both limits can notify at the same time, the 5-hour limit first', () => {
    const limits: RateLimits = {
      fiveHour: { resetsAt: FIVE_RESET, usedPercent: 91 },
      sevenDay: { resetsAt: SEVEN_RESET, usedPercent: 95 },
    }
    expect(dueAlerts(limits, NO_PERIODS, NOW)).toEqual([
      { limit: 'fiveHour', resetsAt: FIVE_RESET, usedPercent: 91 },
      { limit: 'sevenDay', resetsAt: SEVEN_RESET, usedPercent: 95 },
    ])
  })

  test('a window whose reset time passed does not notify', () => {
    expect(dueAlerts(five(95, NOW), NO_PERIODS, NOW)).toEqual([])
    expect(dueAlerts(five(95, NOW - HOUR), NO_PERIODS, NOW)).toEqual([])
    expect(dueAlerts(five(95, NOW + 1), NO_PERIODS, NOW)).toHaveLength(1)
  })

  test('a value that is not a finite number does not notify', () => {
    expect(dueAlerts(five(Number.NaN), NO_PERIODS, NOW)).toEqual([])
    expect(dueAlerts(five(95, Number.NaN), NO_PERIODS, NOW)).toEqual([])
    expect(dueAlerts(five(95, Number.POSITIVE_INFINITY), NO_PERIODS, NOW)).toEqual([])
  })

  test('a limit notifies one time in each period', () => {
    const notified = { ...NO_PERIODS, fiveHour: FIVE_RESET }
    expect(dueAlerts(five(95), notified, NOW)).toEqual([])
    // The other source can give a reset time that is a little later for the same period.
    expect(dueAlerts(five(95, FIVE_RESET + 10 * MIN), notified, NOW)).toEqual([])
    // The next period notifies again.
    const next = FIVE_RESET + 5 * HOUR
    expect(dueAlerts(five(92, next), notified, NOW)).toEqual([
      { limit: 'fiveHour', resetsAt: next, usedPercent: 92 },
    ])
  })

  test('each limit keeps its own period', () => {
    const limits: RateLimits = {
      fiveHour: { resetsAt: FIVE_RESET, usedPercent: 91 },
      sevenDay: { resetsAt: SEVEN_RESET, usedPercent: 95 },
    }
    const notified = { fiveHour: FIVE_RESET, sevenDay: null }
    expect(dueAlerts(limits, notified, NOW).map(a => a.limit)).toEqual(['sevenDay'])
  })
})

describe('afterAlerts', () => {
  test('keeps the reset time of each alert and the other values', () => {
    const alerts: UsageAlert[] = [{ limit: 'sevenDay', resetsAt: SEVEN_RESET, usedPercent: 90 }]
    expect(afterAlerts({ fiveHour: FIVE_RESET, sevenDay: null }, alerts)).toEqual({
      fiveHour: FIVE_RESET,
      sevenDay: SEVEN_RESET,
    })
    expect(afterAlerts(NO_PERIODS, [])).toEqual(NO_PERIODS)
  })
})

describe('alertText', () => {
  const fiveAlert: UsageAlert = { limit: 'fiveHour', resetsAt: FIVE_RESET, usedPercent: 91.6 }
  const sevenAlert: UsageAlert = {
    limit: 'sevenDay',
    resetsAt: Date.UTC(2026, 10, 13, 13, 0),
    usedPercent: 95,
  }

  test('extra usage off gives the limit and the reset time', () => {
    expect(alertText(fiveAlert, false, NOW, ZONE)).toEqual({
      body: 'Claude Code stops at 100% until the limit resets at 14:05.',
      title: '5-hour limit at 92%',
    })
    expect(alertText(sevenAlert, false, NOW, ZONE)).toEqual({
      body: 'Claude Code stops at 100% until the limit resets at Fri 13:00.',
      title: '7-day limit at 95%',
    })
  })

  test('extra usage on gives a clear warning about real money', () => {
    expect(alertText(fiveAlert, true, NOW, ZONE)).toEqual({
      body:
        'Your 5-hour limit is at 92%. After 100%, Claude Code spends your extra usage credits, ' +
        'which costs real money. It resets at 14:05.',
      title: 'Warning: extra usage is on',
    })
    expect(alertText(sevenAlert, true, NOW, ZONE)).toEqual({
      body:
        'Your 7-day limit is at 95%. After 100%, Claude Code spends your extra usage credits, ' +
        'which costs real money. It resets at Fri 13:00.',
      title: 'Warning: extra usage is on',
    })
  })

  test('the percent is the rounded value, capped at 100', () => {
    const at = (usedPercent: number): string =>
      alertText({ ...fiveAlert, usedPercent }, false, NOW, ZONE).title
    expect(at(90)).toBe('5-hour limit at 90%')
    expect(at(99.5)).toBe('5-hour limit at 100%')
    expect(at(130)).toBe('5-hour limit at 100%')
  })

  test('no text has an em dash', () => {
    // The code point, so the source file has no em dash.
    const EM_DASH = String.fromCharCode(0x2014)
    for (const extra of [false, true]) {
      for (const alert of [fiveAlert, sevenAlert]) {
        const { body, title } = alertText(alert, extra, NOW, ZONE)
        expect(`${title} ${body}`).not.toContain(EM_DASH)
      }
    }
  })
})

describe('extraUsageOfClaudeJson', () => {
  test('only oauthAccount.hasExtraUsageEnabled true counts as on', () => {
    expect(extraUsageOfClaudeJson({ oauthAccount: { hasExtraUsageEnabled: true } })).toBe(true)
  })

  test('a value that is not known counts as off', () => {
    const off: unknown[] = [
      null,
      undefined,
      7,
      'x',
      [],
      {},
      { oauthAccount: null },
      { oauthAccount: [] },
      { oauthAccount: {} },
      { oauthAccount: { hasExtraUsageEnabled: false } },
      { oauthAccount: { hasExtraUsageEnabled: 'true' } },
      { oauthAccount: { hasExtraUsageEnabled: 1 } },
      { hasExtraUsageEnabled: true },
    ]
    for (const data of off) expect(extraUsageOfClaudeJson(data)).toBe(false)
  })
})
