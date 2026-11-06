import { describe, expect, it } from 'vitest'
import {
  formatClock,
  formatClockMs,
  formatDayClock,
  formatDuration,
  sameDay,
} from '../../../src/renderer/src/lib/time'

describe('time formats', () => {
  it('formatClock gives HH:MM with a 24-hour clock', () => {
    expect(formatClock(Date.UTC(2026, 10, 5, 9, 7), 'UTC')).toBe('09:07')
    expect(formatClock(Date.UTC(2026, 10, 5, 0, 5), 'UTC')).toBe('00:05')
    expect(formatClock(Date.UTC(2026, 10, 5, 23, 59), 'UTC')).toBe('23:59')
  })

  it('formatClock uses the time zone', () => {
    expect(formatClock(Date.UTC(2026, 10, 5, 9, 7), 'Asia/Tokyo')).toBe('18:07')
  })

  it('sameDay compares the date in the time zone', () => {
    const a = Date.UTC(2026, 10, 5, 0, 0)
    expect(sameDay(a, Date.UTC(2026, 10, 5, 23, 59), 'UTC')).toBe(true)
    expect(sameDay(a, Date.UTC(2026, 10, 4, 23, 59), 'UTC')).toBe(false)
    expect(sameDay(a, Date.UTC(2025, 10, 5, 0, 0), 'UTC')).toBe(false)
    // 23:30 UTC on 4 Nov is 08:30 on 5 Nov in Tokyo.
    expect(sameDay(a, Date.UTC(2026, 10, 4, 23, 30), 'Asia/Tokyo')).toBe(true)
  })

  it('formatDayClock gives Ddd HH:MM', () => {
    expect(formatDayClock(Date.UTC(2026, 10, 5, 14, 3), 'UTC')).toBe('Thu 14:03')
  })

  it('formatClockMs gives HH:MM:SS.mmm', () => {
    expect(formatClockMs(Date.UTC(2026, 10, 5, 9, 7, 3, 45), 'UTC')).toBe('09:07:03.045')
    expect(formatClockMs(Date.UTC(2026, 10, 5, 23, 0, 59, 999), 'UTC')).toBe('23:00:59.999')
  })

  it('formatDuration gives the units', () => {
    expect(formatDuration(0)).toBe('less than 1 min')
    expect(formatDuration(59_000)).toBe('less than 1 min')
    expect(formatDuration(60_000)).toBe('1 min')
    expect(formatDuration(3_599_000)).toBe('59 min')
    expect(formatDuration(3_720_000)).toBe('1 h 02 min')
    expect(formatDuration(86_399_000)).toBe('23 h 59 min')
    expect(formatDuration(86_400_000)).toBe('1 d 0 h')
    expect(formatDuration(90_000_000)).toBe('1 d 1 h')
    expect(formatDuration(-5)).toBe('less than 1 min')
  })
})
