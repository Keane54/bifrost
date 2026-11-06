import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'
import {
  APPEND_GAP_MS,
  createBatcher,
  EVENT_LOG_MAX,
  EventLog,
  NOTIFICATION_REFUSED,
} from '../../../src/main/events/event-log'
import type { HookEvent } from '../../../src/main/registry/hook-event'
import type { LogEntry } from '../../../src/shared/types'

const ev = (i: number, o: Partial<HookEvent> = {}): HookEvent => ({
  at: 1000 + i,
  name: 'Stop',
  sessionId: 's1',
  ...o,
})

const entry = (seq: number): LogEntry => ({ at: seq, name: 'Stop', seq, sessionId: 's1' })

describe('EventLog', () => {
  test('append gives each event a seq and a detail', () => {
    const log = new EventLog()
    const out = log.append([
      ev(1, { name: 'PreToolUse', toolName: 'AskUserQuestion' }),
      ev(2, { name: 'PermissionRequest', sessionId: 's2', toolName: 'Bash' }),
      ev(3, { name: 'TurnAborted' }),
    ])
    expect(out).toEqual([
      { at: 1001, detail: 'AskUserQuestion', name: 'PreToolUse', seq: 1, sessionId: 's1' },
      { at: 1002, detail: 'Bash', name: 'PermissionRequest', seq: 2, sessionId: 's2' },
      { at: 1003, name: 'TurnAborted', seq: 3, sessionId: 's1' },
    ])
    expect(out[2]).not.toHaveProperty('detail')
  })

  test('the seq of the log is its own number, not the seq of the mod', () => {
    const out = new EventLog().append([ev(1, { seq: 77 })])
    expect(out[0]?.seq).toBe(1)
  })

  test('EventLog keeps the 5,000 newest', () => {
    expect(EVENT_LOG_MAX).toBe(5000)
    const log = new EventLog()
    log.append(Array.from({ length: 4900 }, (_, i) => ev(i)))
    const burst = log.append(Array.from({ length: 300 }, (_, i) => ev(i)))
    expect(burst).toHaveLength(300)
    const all = log.list()
    expect(all).toHaveLength(5000)
    expect(all[0]?.seq).toBe(201)
    expect(all.at(-1)?.seq).toBe(5200)
  })

  test('list gives a copy', () => {
    const log = new EventLog()
    log.append([ev(1)])
    const copy = log.list()
    copy.pop()
    expect(log.list()).toHaveLength(1)
  })

  test('a notice entry has the kind notice, and the same text shows one time', () => {
    const log = new EventLog()
    log.append([ev(1)])
    const first = log.notice(NOTIFICATION_REFUSED, 5000)
    expect(first).toEqual({
      at: 5000,
      kind: 'notice',
      name: NOTIFICATION_REFUSED,
      seq: 2,
      sessionId: '',
    })
    expect(log.notice(NOTIFICATION_REFUSED, 6000)).toBeNull()
    expect(log.list()).toHaveLength(2)
  })

  test('the notice text is plain and friendly', () => {
    expect(NOTIFICATION_REFUSED).toBe(
      "macOS didn't show a notification. Allow notifications for Bifrost in System Settings.",
    )
  })
})

describe('createBatcher', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(0)
  })
  afterEach(() => vi.useRealTimers())

  test('the batcher sends at once, then at most once each 250 ms', () => {
    expect(APPEND_GAP_MS).toBe(250)
    const send = vi.fn()
    const batcher = createBatcher(send)
    batcher.push([entry(1)])
    expect(send).toHaveBeenCalledTimes(1)
    expect(send).toHaveBeenLastCalledWith([entry(1)])
    vi.advanceTimersByTime(100)
    batcher.push([entry(2)])
    vi.advanceTimersByTime(100)
    batcher.push([entry(3)])
    expect(send).toHaveBeenCalledTimes(1)
    vi.advanceTimersByTime(49)
    expect(send).toHaveBeenCalledTimes(1)
    vi.advanceTimersByTime(1)
    expect(send).toHaveBeenCalledTimes(2)
    expect(send).toHaveBeenLastCalledWith([entry(2), entry(3)])
  })

  test('a push after a quiet gap sends at once again', () => {
    const send = vi.fn()
    const batcher = createBatcher(send)
    batcher.push([entry(1)])
    vi.advanceTimersByTime(300)
    batcher.push([entry(2)])
    expect(send).toHaveBeenCalledTimes(2)
  })

  test('stop drops the waiting entries', () => {
    const send = vi.fn()
    const batcher = createBatcher(send)
    batcher.push([entry(1)])
    batcher.push([entry(2)])
    batcher.stop()
    vi.advanceTimersByTime(1000)
    expect(send).toHaveBeenCalledTimes(1)
  })
})
