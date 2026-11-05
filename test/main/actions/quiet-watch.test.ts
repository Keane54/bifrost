import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { QuietWatch } from '../../../src/main/actions/quiet-watch'

beforeEach(() => {
  vi.useFakeTimers({ now: 0 })
})

afterEach(() => {
  vi.useRealTimers()
})

// Record the result of a wait and the time when it came.
function track(p: Promise<boolean>): { result: boolean | undefined; at: number | undefined } {
  const t: { result: boolean | undefined; at: number | undefined } = {
    at: undefined,
    result: undefined,
  }
  void p.then(v => {
    t.result = v
    t.at = Date.now()
  })
  return t
}

test('the watch settles 1500 ms after the last chunk', async () => {
  const w = new QuietWatch(1500)
  const waited = track(w.wait(15_000))
  w.data()
  await vi.advanceTimersByTimeAsync(1000)
  w.data()
  await vi.advanceTimersByTimeAsync(1499)
  expect(w.settled).toBe(false)
  expect(waited.result).toBeUndefined()
  await vi.advanceTimersByTimeAsync(1)
  expect(w.settled).toBe(true)
  expect(waited).toEqual({ at: 2500, result: true })
})

test('data after the watch settled has no effect', async () => {
  const w = new QuietWatch(1500)
  w.data()
  await vi.advanceTimersByTimeAsync(1500)
  expect(w.settled).toBe(true)
  w.data()
  expect(w.settled).toBe(true)
  expect(vi.getTimerCount()).toBe(0)
})

test('the watch does not settle without output', async () => {
  const w = new QuietWatch(1500)
  const waited = track(w.wait(15_000))
  await vi.advanceTimersByTimeAsync(14_999)
  expect(waited.result).toBeUndefined()
  await vi.advanceTimersByTimeAsync(1)
  expect(waited).toEqual({ at: 15_000, result: false })
  expect(w.settled).toBe(false)
})

test('wait resolves at once when the watch settled', async () => {
  const w = new QuietWatch(1500)
  w.data()
  await vi.advanceTimersByTimeAsync(1500)
  const waited = track(w.wait(15_000))
  await vi.advanceTimersByTimeAsync(0)
  expect(waited).toEqual({ at: 1500, result: true })
})

test('dispose resolves a wait with false', async () => {
  const w = new QuietWatch(1500)
  const waited = track(w.wait(15_000))
  w.data()
  await vi.advanceTimersByTimeAsync(500)
  w.dispose()
  await vi.advanceTimersByTimeAsync(0)
  expect(waited).toEqual({ at: 500, result: false })
  expect(vi.getTimerCount()).toBe(0)
  await vi.advanceTimersByTimeAsync(5000)
  expect(w.settled).toBe(false)
  expect(await w.wait(15_000)).toBe(false)
})
