import { expect, test, vi } from 'vitest'
import { healthReasons } from '../../../src/main/performance/health'
import {
  createHealthLog,
  HEALTH_WINDOW_MS,
  NO_HEALTH,
  reportSave,
} from '../../../src/main/performance/health-log'

const START = 1_000_000

// A log with a clock that the test sets.
function setup() {
  let time = START
  const log = createHealthLog(() => time)
  return {
    log,
    setTime: (t: number) => {
      time = t
    },
  }
}

test('a new log has no failures, no crashes and no start error', () => {
  const { log } = setup()
  expect(log.view(START)).toEqual({
    crashes: [],
    failsInARow: { 'account-usage': 0, reviews: 0, 'service-status': 0, sessions: 0, updates: 0 },
    liveStartFailedAt: null,
    saveFailedAt: {},
  })
})

test('each failed poll adds 1 to the failures in a row of its part only', () => {
  const { log } = setup()
  log.poll('reviews', 'failed')
  log.poll('reviews', 'failed')
  log.poll('reviews', 'failed')
  log.poll('sessions', 'failed')
  expect(log.view(START).failsInARow).toEqual({
    'account-usage': 0,
    reviews: 3,
    'service-status': 0,
    sessions: 1,
    updates: 0,
  })
})

test('a good poll sets the failures in a row of its part to 0', () => {
  const { log } = setup()
  log.poll('account-usage', 'failed')
  log.poll('account-usage', 'failed')
  log.poll('service-status', 'failed')
  log.poll('account-usage', 'ok')
  expect(log.view(START).failsInARow['account-usage']).toBe(0)
  expect(log.view(START).failsInARow['service-status']).toBe(1)
  log.poll('account-usage', 'failed')
  expect(log.view(START).failsInARow['account-usage']).toBe(1)
})

test('a poll with no data keeps the failures in a row', () => {
  const { log } = setup()
  log.poll('reviews', 'failed')
  log.poll('reviews', 'failed')
  log.poll('reviews', 'no-data')
  expect(log.view(START).failsInARow.reviews).toBe(2)
  log.poll('reviews', 'failed')
  expect(log.view(START).failsInARow.reviews).toBe(3)
  log.poll('sessions', 'no-data')
  expect(log.view(START).failsInARow.sessions).toBe(0)
})

test('while offline, a failed network poll counts as no data, a failed session poll counts', () => {
  let online = true
  const log = createHealthLog(
    () => START,
    () => online,
  )
  log.poll('reviews', 'failed')
  online = false
  for (let i = 0; i < 12; i++) {
    log.poll('reviews', 'failed')
    log.poll('account-usage', 'failed')
    log.poll('service-status', 'failed')
    log.poll('sessions', 'failed')
  }
  expect(log.view(START).failsInARow).toEqual({
    'account-usage': 0,
    reviews: 1,
    'service-status': 0,
    sessions: 12,
    updates: 0,
  })
  // A good poll while offline still sets the count to 0.
  log.poll('reviews', 'ok')
  expect(log.view(START).failsInARow.reviews).toBe(0)
  online = true
  log.poll('service-status', 'failed')
  expect(log.view(START).failsInARow['service-status']).toBe(1)
})

test('the updates part starts at 0 failures in a row', () => {
  const { log } = setup()
  expect(log.view(START).failsInARow.updates).toBe(0)
})

test('while offline, a failed update check counts as no data', () => {
  let online = false
  const log = createHealthLog(
    () => START,
    () => online,
  )
  log.poll('updates', 'failed')
  log.poll('updates', 'failed')
  expect(log.view(START).failsInARow.updates).toBe(0)
  online = true
  log.poll('updates', 'failed')
  expect(log.view(START).failsInARow.updates).toBe(1)
})

test('failures while offline give no reason at the reconnect', () => {
  let online = false
  const log = createHealthLog(
    () => START,
    () => online,
  )
  // 10 minutes offline: 10 rounds of each network poll fail.
  for (let i = 0; i < 10; i++) {
    log.poll('reviews', 'failed')
    log.poll('account-usage', 'failed')
    log.poll('service-status', 'failed')
  }
  online = true
  const input = {
    delayMs: null,
    fpsLow10s: false,
    log: log.view(START),
    now: START,
    online,
    orphans: 0,
    samples: [],
  }
  expect(healthReasons(input)).toEqual([])
})

test('a stopped part has 0 failures in a row, the other parts keep their count', () => {
  const { log } = setup()
  for (let i = 0; i < 3; i++) log.poll('reviews', 'failed')
  log.poll('sessions', 'failed')
  log.stopped('reviews')
  expect(log.view(START).failsInARow).toEqual({
    'account-usage': 0,
    reviews: 0,
    'service-status': 0,
    sessions: 1,
    updates: 0,
  })
})

test('a crash stays in the view for 60 minutes, then it drops', () => {
  const { log, setTime } = setup()
  log.crash('window', 'crashed')
  setTime(START + 10 * 60_000)
  log.crash('gpu', 'killed')
  expect(log.view(START + HEALTH_WINDOW_MS - 1).crashes).toEqual([
    { at: START, kind: 'window', reason: 'crashed' },
    { at: START + 10 * 60_000, kind: 'gpu', reason: 'killed' },
  ])
  expect(log.view(START + HEALTH_WINDOW_MS).crashes).toEqual([
    { at: START + 10 * 60_000, kind: 'gpu', reason: 'killed' },
  ])
  expect(log.view(START + 10 * 60_000 + HEALTH_WINDOW_MS).crashes).toEqual([])
})

test('a save failure stays for 60 minutes after the last failure, also after a good save', () => {
  const { log, setTime } = setup()
  log.save('settings', false)
  log.save('registry', true)
  setTime(START + 5 * 60_000)
  // A later good save of the same store does not clear the failure early (P6).
  log.save('settings', true)
  expect(log.view(START + 5 * 60_000).saveFailedAt).toEqual({ settings: START })
  setTime(START + 20 * 60_000)
  log.save('ui-state', false)
  expect(log.view(START + HEALTH_WINDOW_MS - 1).saveFailedAt).toEqual({
    settings: START,
    'ui-state': START + 20 * 60_000,
  })
  expect(log.view(START + HEALTH_WINDOW_MS).saveFailedAt).toEqual({
    'ui-state': START + 20 * 60_000,
  })
})

test('a new save failure of the same store gives the newest time', () => {
  const { log, setTime } = setup()
  log.save('reviews-state', false)
  setTime(START + 30 * 60_000)
  log.save('reviews-state', false)
  expect(log.view(START + HEALTH_WINDOW_MS).saveFailedAt).toEqual({
    'reviews-state': START + 30 * 60_000,
  })
})

test('a failed Live details start gives the time of the last failure', () => {
  const { log, setTime } = setup()
  log.liveStartFailed('Another program listens on /x.')
  expect(log.view(START).liveStartFailedAt).toBe(START)
  setTime(START + 60_000)
  log.liveStartFailed('Another program listens on /x.')
  expect(log.view(START + 60_000).liveStartFailedAt).toBe(START + 60_000)
})

test('a good Live details start or a stop clears the start error', () => {
  const { log } = setup()
  log.liveStartCleared()
  expect(log.view(START).liveStartFailedAt).toBeNull()
  log.liveStartFailed('Another program listens on /x.')
  expect(log.view(START).liveStartFailedAt).toBe(START)
  log.liveStartCleared()
  expect(log.view(START).liveStartFailedAt).toBeNull()
})

test('a change to a view does not change the log', () => {
  const { log } = setup()
  log.crash('window', 'oom')
  const view = log.view(START)
  view.failsInARow.sessions = 99
  view.crashes.length = 0
  view.saveFailedAt['window-state'] = 1
  expect(log.view(START)).toEqual({
    crashes: [{ at: START, kind: 'window', reason: 'oom' }],
    failsInARow: { 'account-usage': 0, reviews: 0, 'service-status': 0, sessions: 0, updates: 0 },
    liveStartFailedAt: null,
    saveFailedAt: {},
  })
})

test('NO_HEALTH accepts each event and does nothing', () => {
  expect(() => {
    NO_HEALTH.poll('sessions', 'failed')
    NO_HEALTH.save('settings', false)
    NO_HEALTH.crash('gpu', 'crashed')
    NO_HEALTH.liveStartFailed('x')
    NO_HEALTH.liveStartCleared()
    NO_HEALTH.stopped('reviews')
  }).not.toThrow()
})

test('reportSave gives the result of each write and keeps the error of a failed write', async () => {
  const save = vi.fn()
  const error = new Error('disk full')
  await expect(
    reportSave({ save }, 'settings', async () => {
      throw error
    }),
  ).rejects.toBe(error)
  await reportSave({ save }, 'settings', async () => {})
  expect(save.mock.calls).toEqual([
    ['settings', false],
    ['settings', true],
  ])
})

// A log with a line writer that the test reads.
function withLines(online: () => boolean = () => true) {
  const lines: string[] = []
  const log = createHealthLog(
    () => START,
    online,
    line => lines.push(line),
  )
  return { lines, log }
}

test('clear removes the crashes, the failed saves and the Live start error', () => {
  const { log } = withLines()
  log.crash('window', 'killed')
  log.save('settings', false)
  log.liveStartFailed('port in use')
  log.clear()
  const view = log.view(START)
  expect(view.crashes).toEqual([])
  expect(view.saveFailedAt).toEqual({})
  expect(view.liveStartFailedAt).toBeNull()
})

test('clear sets every failure in a row to 0, so a new failure counts from 0', () => {
  const { log } = withLines()
  log.poll('reviews', 'failed')
  log.poll('reviews', 'failed')
  log.poll('sessions', 'failed')
  log.clear()
  expect(Object.values(log.view(START).failsInARow)).toEqual([0, 0, 0, 0, 0])
  log.poll('reviews', 'failed')
  expect(log.view(START).failsInARow.reviews).toBe(1)
})

test('each event writes its line', () => {
  const { log, lines } = withLines()
  log.crash('gpu', 'killed')
  log.crash('window', 'oom')
  log.save('ui-state', false)
  log.liveStartFailed('port in use')
  log.poll('reviews', 'failed')
  log.poll('reviews', 'failed')
  log.clear()
  expect(lines).toEqual([
    'crash gpu: killed',
    'crash window: oom',
    'save failed: ui-state',
    'live details did not start: port in use',
    'poll failed: reviews (1 in a row)',
    'poll failed: reviews (2 in a row)',
    'cleared by the user',
  ])
})

test('a good save, a good poll and a no-data poll write nothing', () => {
  const { log, lines } = withLines()
  log.save('settings', true)
  log.poll('reviews', 'ok')
  log.poll('reviews', 'no-data')
  log.liveStartCleared()
  log.stopped('reviews')
  expect(lines).toEqual([])
})

test('a failed network poll while offline writes nothing, a failed sessions poll writes', () => {
  const { log, lines } = withLines(() => false)
  log.poll('reviews', 'failed')
  log.poll('sessions', 'failed')
  expect(lines).toEqual(['poll failed: sessions (1 in a row)'])
})

test('a log with no writer works', () => {
  const log = createHealthLog(() => START)
  log.crash('gpu', 'x')
  log.clear()
  expect(log.view(START).crashes).toEqual([])
})

test('a line holds no line break, so one event is one line in the file', () => {
  const { log, lines } = withLines()
  log.liveStartFailed('first\nsecond\r\nthird')
  log.crash('gpu', 'a\rb')
  expect(lines).toEqual(['live details did not start: first second third', 'crash gpu: a b'])
})
