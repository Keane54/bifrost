import { describe, expect, test } from 'vitest'
import {
  eventText,
  filterLog,
  formatClock,
  mergeLog,
  sessionOptions,
  visibleRange,
} from '../../../src/renderer/src/events/log-view'
import type { LogEntry, SessionRow } from '../../../src/shared/types'

const e = (seq: number, sessionId = 's1', o: Partial<LogEntry> = {}): LogEntry => ({
  at: seq,
  name: 'Stop',
  seq,
  sessionId,
  ...o,
})
const seqs = (list: LogEntry[]): number[] => list.map(x => x.seq)

describe('mergeLog', () => {
  test('mergeLog drops copies after a reload', () => {
    const merged = mergeLog([e(1), e(2), e(3)], [e(3), e(4)])
    expect(seqs(merged)).toEqual([1, 2, 3, 4])
  })

  test('mergeLog sorts by seq when the append came before the list', () => {
    expect(seqs(mergeLog([e(4)], [e(1), e(2), e(4)]))).toEqual([1, 2, 4])
  })

  test('mergeLog keeps the max newest and returns the same array with no new entry', () => {
    const current = [e(1), e(2), e(3)]
    expect(mergeLog(current, [e(2)])).toBe(current)
    expect(mergeLog(current, [])).toBe(current)
    expect(seqs(mergeLog(current, [e(4), e(5)], 3))).toEqual([3, 4, 5])
  })
})

describe('filterLog', () => {
  test('filterLog keeps one session', () => {
    const all = [e(1, 'a'), e(2, 'b'), e(3, 'a')]
    expect(seqs(filterLog(all, 'a'))).toEqual([1, 3])
    expect(filterLog(all, null)).toBe(all)
  })
})

describe('visibleRange', () => {
  test('visibleRange gives the rows in the viewport with the overscan', () => {
    expect(visibleRange(180, 360, 18, 5000)).toEqual({ end: 38, start: 2 })
    expect(visibleRange(0, 360, 18, 5000)).toEqual({ end: 28, start: 0 })
    expect(visibleRange(90_000, 360, 18, 5000)).toEqual({ end: 5000, start: 4992 })
    expect(visibleRange(0, 360, 18, 0)).toEqual({ end: 0, start: 0 })
  })
})

describe('texts', () => {
  test('eventText and formatClock give the texts', () => {
    expect(eventText(e(1, 's1', { detail: 'AskUserQuestion', name: 'PreToolUse' }))).toBe(
      'PreToolUse (AskUserQuestion)',
    )
    expect(eventText(e(1))).toBe('Stop')
    expect(formatClock(Date.UTC(2026, 10, 5, 14, 3, 7, 45), 'UTC')).toBe('14:03:07.045')
  })

  test('eventText gives a notice as its plain text', () => {
    expect(eventText(e(1, '', { kind: 'notice', name: 'Allow it.' }))).toBe('Allow it.')
  })
})

describe('sessionOptions', () => {
  test('sessionOptions uses the row name and the short form of a gone session', () => {
    const rows = [{ name: 'zeta', sessionId: 'aaaaaaaa-1111' }] as SessionRow[]
    const out = sessionOptions(
      [
        e(1, 'aaaaaaaa-1111'),
        e(2, 'gone1234-5678'),
        e(3, 'aaaaaaaa-1111'),
        e(4, '', { kind: 'notice' }),
      ],
      rows,
    )
    expect(out).toEqual([
      { id: 'gone1234-5678', label: 'gone1234' },
      { id: 'aaaaaaaa-1111', label: 'zeta' },
    ])
  })
})
