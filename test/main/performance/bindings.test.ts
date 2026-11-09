import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ExecResult } from '../../../src/main/claude/cli'
import {
  checkFps,
  checkView,
  createLoopDelay,
  DELAY_RESOLUTION_MS,
  DELAY_WINDOW_MS,
  GH_LIMIT_FAILED,
  GH_LIMIT_LOGGED_OUT,
  GH_LIMIT_MISSING,
  probeUrl,
  RATE_LIMIT_ARGS,
  REFUSED_BAD_CHAT_PANEL,
  readGhRateLimit,
} from '../../../src/main/performance/bindings'
import { PROBE_URLS } from '../../../src/main/performance/monitor'
import type { Gh } from '../../../src/main/reviews/gh'

// A session ID. n is one digit.
const uuid = (n: number): string => `0000000${n}-0000-4000-8000-000000000000`
const chat = (id: string): string => `chat:${id}`
const send = (id: string): string => `send:${id}`

function ok(stdout: string): ExecResult {
  return { code: 0, stderr: '', stdout }
}

beforeEach(() => {
  vi.useFakeTimers()
})
afterEach(() => {
  vi.useRealTimers()
})

describe('readGhRateLimit', () => {
  it('reads the GraphQL limit of gh api rate_limit, with the reset in ms', async () => {
    const run = vi.fn<Gh['run']>(async () =>
      ok(
        JSON.stringify({
          rate: { limit: 5000, remaining: 4990, reset: 1794229000, used: 10 },
          resources: {
            core: { limit: 5000, remaining: 4990, reset: 1794229000, used: 10 },
            graphql: { limit: 5000, remaining: 4321, reset: 1794229200, used: 679 },
          },
        }),
      ),
    )
    expect(await readGhRateLimit({ run })).toEqual({
      limit: 5000,
      remaining: 4321,
      resetAt: 1794229200 * 1000,
    })
    expect(RATE_LIMIT_ARGS).toEqual(['api', 'rate_limit'])
    expect(run).toHaveBeenCalledWith(RATE_LIMIT_ARGS, { timeoutMs: expect.any(Number) })
  })

  it('gives a friendly reason when gh cannot answer', async () => {
    expect(GH_LIMIT_MISSING).toBe("GitHub CLI isn't installed")
    expect(GH_LIMIT_LOGGED_OUT).toBe("GitHub CLI isn't signed in")
    expect(GH_LIMIT_FAILED).toBe("Couldn't read the GitHub limit")
    const cases: Array<[ExecResult, string]> = [
      [{ code: -2, stderr: 'spawn gh ENOENT', stdout: '' }, GH_LIMIT_MISSING],
      [{ code: 4, stderr: 'please run:  gh auth login', stdout: '' }, GH_LIMIT_LOGGED_OUT],
      [{ code: 1, stderr: 'gh: HTTP 502', stdout: '' }, GH_LIMIT_FAILED],
      [{ code: 1, stderr: '', stdout: '', timedOut: true }, GH_LIMIT_FAILED],
      [ok('not json'), GH_LIMIT_FAILED],
      [ok('{"resources":{"graphql":{"limit":5000}}}'), GH_LIMIT_FAILED],
    ]
    for (const [result, reason] of cases) {
      expect(await readGhRateLimit({ run: async () => result })).toEqual({ unavailable: reason })
    }
    const thrown = async (): Promise<ExecResult> => {
      throw new Error('spawn failed')
    }
    expect(await readGhRateLimit({ run: thrown })).toEqual({ unavailable: GH_LIMIT_FAILED })
  })
})

describe('probeUrl', () => {
  it('times a HEAD request with no login and counts any status as an answer', async () => {
    let clock = 1000
    const fetch = vi.fn(async (_url: string, _init: RequestInit) => {
      clock += 87
      return new Response(null, { status: 404 })
    })
    expect(await probeUrl(fetch, PROBE_URLS.anthropic, () => clock)).toBe(87)
    const [url, init] = fetch.mock.calls[0] ?? []
    expect(url).toBe('https://api.anthropic.com')
    expect(init).toMatchObject({ cache: 'no-store', credentials: 'omit', method: 'HEAD' })
    expect(init?.signal).toBeInstanceOf(AbortSignal)
    expect(init?.headers).toBeUndefined()
  })

  it('gives no-answer after the timeout and unreachable for a connection error', async () => {
    const timeout = async (): Promise<Response> => {
      throw new DOMException('The operation timed out.', 'TimeoutError')
    }
    expect(await probeUrl(timeout, PROBE_URLS.github, () => 0)).toBe('no-answer')
    const refused = async (): Promise<Response> => {
      throw new TypeError('net::ERR_NAME_NOT_RESOLVED')
    }
    expect(await probeUrl(refused, PROBE_URLS.github, () => 0)).toBe('unreachable')
  })
})

describe('createLoopDelay', () => {
  // A fake of the Node event loop delay histogram. Its values are in ns. Each value is the time
  // between two runs of the timer: the resolution plus the delay.
  function fakeHistogram() {
    const h = {
      count: 0,
      disable: vi.fn(),
      enable: vi.fn(),
      max: 0,
      // A 1 s freeze every 4 s at a 10 ms resolution gave this 99th percentile: 11.1 ms.
      percentile: vi.fn((_p: number) => 11.1e6),
      reset: vi.fn(() => {
        h.count = 0
        h.max = 0
      }),
    }
    return h
  }

  it('makes the histogram with a 50 ms resolution', () => {
    const h = fakeHistogram()
    const make = vi.fn((_options: { resolution: number }) => h)
    const delay = createLoopDelay(make)
    expect(DELAY_RESOLUTION_MS).toBe(50)
    expect(make).toHaveBeenCalledWith({ resolution: DELAY_RESOLUTION_MS })
    expect(h.enable).toHaveBeenCalledTimes(1)
    delay.stop()
  })

  it('gives the longest delay of the last full 60 s window, without the resolution', async () => {
    const h = fakeHistogram()
    const delay = createLoopDelay(() => h)
    // Repeated 1 s freezes. The longest time between two timer runs is 1050 ms.
    h.count = 1000
    h.max = 1050e6
    // The first window has not ended.
    expect(delay.longestMs()).toBeNull()
    await vi.advanceTimersByTimeAsync(DELAY_WINDOW_MS)
    expect(delay.longestMs()).toBe(1000)
    expect(h.percentile).not.toHaveBeenCalled()
    expect(h.reset).toHaveBeenCalledTimes(1)
    // A quiet window. A value below the resolution gives 0, never less.
    h.count = 1200
    h.max = 49e6
    await vi.advanceTimersByTimeAsync(DELAY_WINDOW_MS)
    expect(delay.longestMs()).toBe(0)
    h.count = 1200
    h.max = 62e6
    await vi.advanceTimersByTimeAsync(DELAY_WINDOW_MS)
    expect(delay.longestMs()).toBe(12)
    // A window with no data gives null.
    await vi.advanceTimersByTimeAsync(DELAY_WINDOW_MS)
    expect(delay.longestMs()).toBeNull()
    expect(h.reset).toHaveBeenCalledTimes(4)
    delay.stop()
    expect(h.disable).toHaveBeenCalledTimes(1)
    expect(vi.getTimerCount()).toBe(0)
  })
})

describe('checkView and checkFps', () => {
  it('checkView takes two booleans and chat panel IDs only', () => {
    const good = { chatPanels: [chat(uuid(1))], focused: false, showing: true }
    expect(checkView(good)).toEqual(good)
    const base = { focused: false, showing: true }
    expect(() => checkView({ ...base, chatPanels: ['/etc/passwd'] })).toThrow(
      REFUSED_BAD_CHAT_PANEL,
    )
    expect(() => checkView({ ...base, chatPanels: [send(uuid(1))] })).toThrow(
      REFUSED_BAD_CHAT_PANEL,
    )
    expect(() => checkView({ ...base, chatPanels: [7] })).toThrow(REFUSED_BAD_CHAT_PANEL)
    expect(REFUSED_BAD_CHAT_PANEL).toBe('refused: bad chat panel')
    const bad: unknown[] = [
      null,
      'showing',
      { ...base, chatPanels: 'chat:x' },
      { ...base },
      { chatPanels: [], focused: 1, showing: true },
      { chatPanels: [], focused: true, showing: 'yes' },
      { ...base, chatPanels: Array.from({ length: 501 }, () => chat(uuid(1))) },
    ]
    for (const v of bad) expect(() => checkView(v)).toThrow('refused: bad input')
  })

  it('checkFps takes a finite number from 0 to 1000', () => {
    expect(checkFps(0)).toBe(0)
    expect(checkFps(59.5)).toBe(59.5)
    expect(checkFps(1000)).toBe(1000)
    for (const v of [-1, 1001, Number.NaN, Number.POSITIVE_INFINITY, '60', null]) {
      expect(() => checkFps(v)).toThrow('refused: bad input')
    }
  })
})
