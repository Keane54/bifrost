process.env.TZ = 'Europe/London'

import { describe, expect, test } from 'vitest'
import {
  allDone,
  type DayMarks,
  freshMarks,
  isDueDay,
  localDate,
  nextAction,
  showMarker,
  sinceTime,
} from '../../src/shared/daily-schedule'
import {
  type DailyUpdateSettings,
  DEFAULT_DAILY_UPDATE,
  type WorkArea,
} from '../../src/shared/daily-update'

const area = (id: string, on = true): WorkArea => ({
  channel: '',
  description: '',
  id,
  name: id,
  on,
  takesRest: false,
})

const settings = (areas: WorkArea[] = [area('a')]): DailyUpdateSettings => ({
  ...DEFAULT_DAILY_UPDATE,
  areas,
})

// Tuesday 2026-11-10 is a due day. Months are 0-based in the Date form.
const at = (h: number, min: number, d = 10, m = 10) => new Date(2026, m, d, h, min)
const marks = (patch: Partial<DayMarks> = {}): DayMarks => ({
  ...freshMarks('2026-11-10'),
  ...patch,
})

describe('basics', () => {
  test('localDate gives the local date', () => {
    expect(localDate(new Date(2026, 0, 5, 23, 59))).toBe('2026-01-05')
  })
  test('isDueDay uses the day numbers', () => {
    expect(isDueDay(at(9, 0), [1, 2, 3, 4, 5])).toBe(true)
    expect(isDueDay(at(9, 0, 14), [1, 2, 3, 4, 5])).toBe(false)
  })
})

describe('nextAction', () => {
  test('nothing happens before the draft time', () => {
    expect(nextAction(at(9, 29), settings(), marks())).toEqual({ kind: 'none' })
  })
  test('the first reminder runs at the draft time', () => {
    expect(nextAction(at(9, 30), settings(), marks())).toEqual({ kind: 'run', reminder: 'first' })
  })
  test('the first reminder does not run twice', () => {
    expect(nextAction(at(9, 31), settings(), marks({ firstShown: true }))).toEqual({ kind: 'none' })
  })
  test('the second reminder only notifies when the first was shown', () => {
    expect(nextAction(at(9, 50), settings(), marks({ firstShown: true }))).toEqual({
      kind: 'notify',
      reminder: 'second',
    })
  })
  test('the second reminder does nothing when it was shown', () => {
    const m = marks({ firstShown: true, secondShown: true })
    expect(nextAction(at(9, 55), settings(), m)).toEqual({ kind: 'none' })
  })
  test('a start at 09:55 with nothing shown runs once with the second reminder', () => {
    expect(nextAction(at(9, 55), settings(), marks())).toEqual({ kind: 'run', reminder: 'second' })
  })
  test('a start after the deadline runs once with the late reminder', () => {
    expect(nextAction(at(10, 0), settings(), marks())).toEqual({ kind: 'run', reminder: 'late' })
  })
  test('after the deadline with a reminder shown nothing happens', () => {
    expect(nextAction(at(10, 5), settings(), marks({ firstShown: true }))).toEqual({ kind: 'none' })
    expect(nextAction(at(10, 5), settings(), marks({ secondShown: true }))).toEqual({
      kind: 'none',
    })
  })
  test('a weekend day gives none', () => {
    const m = freshMarks('2026-11-14')
    expect(nextAction(at(9, 40, 14), settings(), m)).toEqual({ kind: 'none' })
  })
  test('skipped gives none', () => {
    expect(nextAction(at(9, 40), settings(), marks({ skipped: true }))).toEqual({ kind: 'none' })
  })
  test('all areas sent gives none', () => {
    expect(nextAction(at(9, 40), settings(), marks({ sent: { a: 1 } }))).toEqual({ kind: 'none' })
  })
  test('no area on gives none', () => {
    expect(nextAction(at(9, 40), settings([]), marks())).toEqual({ kind: 'none' })
  })
  test('an area that is off does not count', () => {
    const s = settings([area('a'), area('b', false)])
    expect(nextAction(at(9, 40), s, marks({ sent: { a: 1 } }))).toEqual({ kind: 'none' })
    expect(nextAction(at(9, 40), s, marks())).toEqual({ kind: 'run', reminder: 'first' })
  })
  test('a new day starts with fresh marks', () => {
    const old = freshMarks('2026-11-09')
    old.firstShown = true
    expect(nextAction(at(9, 30), settings(), old)).toEqual({ kind: 'run', reminder: 'first' })
  })
  test('a daylight saving change keeps 09:30', () => {
    const all = { ...settings(), days: [0, 1, 2, 3, 4, 5, 6] }
    for (const [m, d] of [
      [2, 29],
      [9, 25],
    ] as const) {
      const now = at(9, 30, d, m)
      expect(nextAction(now, all, freshMarks(localDate(now)))).toEqual({
        kind: 'run',
        reminder: 'first',
      })
    }
  })
})

describe('allDone', () => {
  test('is true when skipped, sent or no area is on', () => {
    expect(allDone(marks({ skipped: true }), [area('a')])).toBe(true)
    expect(allDone(marks({ sent: { a: 1 } }), [area('a')])).toBe(true)
    expect(allDone(marks(), [area('a', false)])).toBe(true)
    expect(allDone(marks(), [area('a')])).toBe(false)
  })

  test('uses own keys only, so an area with the ID constructor is not done', () => {
    expect(allDone(marks(), [area('constructor')])).toBe(false)
  })
})

describe('showMarker', () => {
  test('is true from the draft time until all areas are done', () => {
    expect(showMarker(at(9, 29), settings(), marks())).toBe(false)
    expect(showMarker(at(9, 30), settings(), marks())).toBe(true)
    expect(showMarker(at(12, 0), settings(), marks())).toBe(true)
    expect(showMarker(at(12, 0), settings(), marks({ sent: { a: 1 } }))).toBe(false)
    expect(showMarker(at(12, 0, 14), settings(), freshMarks('2026-11-14'))).toBe(false)
    expect(showMarker(at(12, 0), settings([]), marks())).toBe(false)
  })
})

describe('sinceTime', () => {
  const days = [1, 2, 3, 4, 5]
  test('the start on Monday with no mark is Friday', () => {
    expect(sinceTime(at(9, 30, 16), days, undefined)).toBe(new Date(2026, 10, 13).getTime())
  })
  test('the start is the last mark when there is one', () => {
    expect(sinceTime(at(9, 30, 16), days, 12345)).toBe(12345)
  })
  test('with no due day in the week it is 24 hours before now', () => {
    const now = at(9, 30, 16)
    expect(sinceTime(now, [], undefined)).toBe(now.getTime() - 24 * 3600 * 1000)
  })
})
