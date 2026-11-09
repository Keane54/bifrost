import { expect, test, vi } from 'vitest'
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
    failsInARow: { 'account-usage': 0, reviews: 0, 'service-status': 0, sessions: 0 },
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

test('a change to a view does not change the log', () => {
  const { log } = setup()
  log.crash('window', 'oom')
  const view = log.view(START)
  view.failsInARow.sessions = 99
  view.crashes.length = 0
  view.saveFailedAt['window-state'] = 1
  expect(log.view(START)).toEqual({
    crashes: [{ at: START, kind: 'window', reason: 'oom' }],
    failsInARow: { 'account-usage': 0, reviews: 0, 'service-status': 0, sessions: 0 },
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
