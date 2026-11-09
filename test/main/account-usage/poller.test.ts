import { readFileSync } from 'node:fs'
import { afterEach, beforeEach, describe, expect, expectTypeOf, test, vi } from 'vitest'
import {
  ACCOUNT_USAGE_URL,
  createAccountUsagePoller,
  HUD_GAP_MS,
  MAX_BODY_BYTES,
  POLL_DEADLINE_MS,
  POLL_INTERVAL_MS,
  RATE_LIMIT_WAIT_MS,
} from '../../../src/main/account-usage/poller'
import type { HealthEvents } from '../../../src/main/performance/health-log'
import type { AccountUsage } from '../../../src/shared/types'

const sample = readFileSync(
  new URL('../../fixtures/oauth-usage-sample.json', import.meta.url),
  'utf8',
)
const SEVEN_DAY = Date.parse('2026-11-07T01:59:59.702828+00:00')
// A fake secret. It is not a real token.
const FAKE = 'fake-access-token-for-tests'
const MIN = 60_000

type Reply = { status: number; body: string } | Error

function setup(token: string | null = FAKE, health?: Pick<HealthEvents, 'poll'>) {
  const replies: Reply[] = []
  const fetch = vi.fn(async (_url: string, _init: RequestInit) => {
    const reply = replies.shift() ?? { body: sample, status: 200 }
    if (reply instanceof Error) throw reply
    return new Response(reply.body, { status: reply.status })
  })
  const readToken = vi.fn(async () => token)
  const emitted: (AccountUsage | null)[] = []
  const poller = createAccountUsagePoller({
    emit: value => emitted.push(value),
    fetch,
    health,
    now: () => Date.now(),
    readToken,
  })
  return { emitted, fetch, poller, readToken, replies }
}

beforeEach(() => {
  vi.useFakeTimers()
  vi.setSystemTime(new Date('2026-11-06T10:00:00Z'))
})
afterEach(() => {
  vi.useRealTimers()
})

describe('createAccountUsagePoller', () => {
  test('the poller does nothing before start', async () => {
    const { fetch, poller, readToken } = setup()
    poller.requestPoll()
    await vi.advanceTimersByTimeAsync(10 * MIN)
    expect(readToken).not.toHaveBeenCalled()
    expect(fetch).not.toHaveBeenCalled()
    expect(poller.current()).toBeNull()
  })

  test('start polls at once and every 5 minutes', async () => {
    const { emitted, fetch, poller } = setup()
    poller.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(poller.current()).toEqual({
      fetchedAt: Date.now(),
      limits: { sevenDay: { resetsAt: SEVEN_DAY, usedPercent: 36 } },
    })
    expect(emitted).toHaveLength(1)
    await vi.advanceTimersByTimeAsync(POLL_INTERVAL_MS - 1)
    expect(fetch).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(1)
    expect(fetch).toHaveBeenCalledTimes(2)
    await vi.advanceTimersByTimeAsync(POLL_INTERVAL_MS)
    expect(fetch).toHaveBeenCalledTimes(3)
    poller.stop()
  })

  test('the request goes to the fixed URL with the three headers', async () => {
    const { fetch, poller } = setup()
    poller.start()
    await vi.advanceTimersByTimeAsync(0)
    const [url, init] = fetch.mock.calls[0] ?? []
    expect(url).toBe('https://api.anthropic.com/api/oauth/usage')
    expect(ACCOUNT_USAGE_URL).toBe(url)
    expect(init?.method).toBe('GET')
    expect(init?.headers).toEqual({
      Authorization: `Bearer ${FAKE}`,
      'anthropic-beta': 'oauth-2025-04-20',
      'User-Agent': 'Bifrost',
    })
    expect(init?.redirect).toBe('error')
    expect(init?.credentials).toBe('omit')
    expect(init?.cache).toBe('no-store')
    expect(init?.signal).toBeInstanceOf(AbortSignal)
    poller.stop()
  })

  test('the poller never calls another URL, so it never refreshes a token', async () => {
    const { fetch, poller, replies } = setup()
    replies.push(
      { body: '{}', status: 401 },
      { body: '{}', status: 403 },
      { body: '', status: 429 },
    )
    poller.start()
    for (let i = 0; i < 8; i++) await vi.advanceTimersByTimeAsync(RATE_LIMIT_WAIT_MS)
    expect(fetch.mock.calls.length).toBeGreaterThan(3)
    for (const call of fetch.mock.calls) expect(call[0]).toBe(ACCOUNT_USAGE_URL)
    poller.stop()
  })

  test('no token means no request, and the poller reads the Keychain again later', async () => {
    const { fetch, poller, readToken } = setup(null)
    poller.start()
    await vi.advanceTimersByTimeAsync(POLL_INTERVAL_MS)
    expect(fetch).not.toHaveBeenCalled()
    expect(readToken).toHaveBeenCalledTimes(2)
    poller.stop()
  })

  test('the HUD opening polls at most one time in 60 seconds', async () => {
    const { fetch, poller } = setup()
    poller.start()
    await vi.advanceTimersByTimeAsync(0)
    poller.requestPoll()
    await vi.advanceTimersByTimeAsync(0)
    expect(fetch).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(HUD_GAP_MS - 1)
    poller.requestPoll()
    await vi.advanceTimersByTimeAsync(0)
    expect(fetch).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(1)
    poller.requestPoll()
    await vi.advanceTimersByTimeAsync(0)
    expect(fetch).toHaveBeenCalledTimes(2)
    // The timer starts again after a poll, so the next timed poll is 5 minutes later.
    await vi.advanceTimersByTimeAsync(POLL_INTERVAL_MS - 1)
    expect(fetch).toHaveBeenCalledTimes(2)
    await vi.advanceTimersByTimeAsync(1)
    expect(fetch).toHaveBeenCalledTimes(3)
    poller.stop()
  })

  // The deadline is shorter than each gap between polls (HUD_GAP_MS and POLL_INTERVAL_MS), so two
  // polls cannot overlap. A Keychain read that ends after the deadline must still send nothing.
  test('a Keychain read that ends after the poll deadline sends no request', async () => {
    const { fetch, poller, readToken } = setup()
    let release: (token: string) => void = () => {}
    readToken.mockImplementationOnce(
      () =>
        new Promise<string | null>(resolve => {
          release = resolve
        }),
    )
    poller.start()
    await vi.advanceTimersByTimeAsync(POLL_DEADLINE_MS + 1)
    release(FAKE)
    await vi.advanceTimersByTimeAsync(0)
    expect(fetch).not.toHaveBeenCalled()
    poller.stop()
  })

  test('a 401 or a 403 clears the values', async () => {
    for (const status of [401, 403]) {
      const { emitted, poller, replies } = setup()
      poller.start()
      await vi.advanceTimersByTimeAsync(0)
      expect(poller.current()).not.toBeNull()
      replies.push({ body: '{"error":"x"}', status })
      await vi.advanceTimersByTimeAsync(POLL_INTERVAL_MS)
      expect(poller.current()).toBeNull()
      expect(emitted.at(-1)).toBeNull()
      // A later good poll brings the values back.
      await vi.advanceTimersByTimeAsync(POLL_INTERVAL_MS)
      expect(poller.current()).not.toBeNull()
      poller.stop()
    }
  })

  test('a 429 waits 15 minutes and keeps the values', async () => {
    const { fetch, poller, replies } = setup()
    poller.start()
    await vi.advanceTimersByTimeAsync(0)
    replies.push({ body: '', status: 429 })
    await vi.advanceTimersByTimeAsync(POLL_INTERVAL_MS)
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(poller.current()).not.toBeNull()
    await vi.advanceTimersByTimeAsync(RATE_LIMIT_WAIT_MS - 1)
    expect(fetch).toHaveBeenCalledTimes(2)
    // A HUD open does not break the wait.
    poller.requestPoll()
    await vi.advanceTimersByTimeAsync(0)
    expect(fetch).toHaveBeenCalledTimes(2)
    await vi.advanceTimersByTimeAsync(1)
    expect(fetch).toHaveBeenCalledTimes(3)
    poller.stop()
  })

  test('another error keeps the last good values', async () => {
    const { fetch, poller, replies } = setup()
    poller.start()
    await vi.advanceTimersByTimeAsync(0)
    const first = poller.current()
    replies.push({ body: '', status: 500 }, new Error(`network ${FAKE}`))
    await vi.advanceTimersByTimeAsync(POLL_INTERVAL_MS)
    expect(poller.current()).toEqual(first)
    await vi.advanceTimersByTimeAsync(POLL_INTERVAL_MS)
    expect(fetch).toHaveBeenCalledTimes(3)
    expect(poller.current()).toEqual(first)
    poller.stop()
  })

  test('a bad answer gives no values', async () => {
    const { emitted, poller, replies } = setup()
    poller.start()
    await vi.advanceTimersByTimeAsync(0)
    replies.push({ body: 'not json', status: 200 })
    await vi.advanceTimersByTimeAsync(POLL_INTERVAL_MS)
    expect(poller.current()).toBeNull()
    expect(emitted.at(-1)).toBeNull()
    poller.stop()
  })

  test('stop ends the timer and clears the values', async () => {
    const { emitted, fetch, poller } = setup()
    poller.start()
    await vi.advanceTimersByTimeAsync(0)
    poller.stop()
    expect(poller.current()).toBeNull()
    expect(emitted.at(-1)).toBeNull()
    await vi.advanceTimersByTimeAsync(10 * POLL_INTERVAL_MS)
    poller.requestPoll()
    await vi.advanceTimersByTimeAsync(0)
    expect(fetch).toHaveBeenCalledTimes(1)
  })

  test('stop during a poll drops the answer', async () => {
    const { emitted, fetch, poller } = setup()
    let release: () => void = () => {}
    fetch.mockImplementationOnce(
      () =>
        new Promise<Response>(resolve => {
          release = () => resolve(new Response(sample, { status: 200 }))
        }),
    )
    poller.start()
    await vi.advanceTimersByTimeAsync(0)
    poller.stop()
    release()
    await vi.advanceTimersByTimeAsync(0)
    expect(poller.current()).toBeNull()
    expect(emitted.every(value => value === null)).toBe(true)
  })

  test('the token never reaches the console or the emitted values', async () => {
    const spies = (['log', 'error', 'warn', 'info', 'debug'] as const).map(m =>
      vi.spyOn(console, m).mockImplementation(() => {}),
    )
    const { emitted, poller, replies } = setup()
    replies.push({ body: 'x', status: 500 }, new Error(`network ${FAKE}`))
    poller.start()
    await vi.advanceTimersByTimeAsync(3 * POLL_INTERVAL_MS)
    poller.stop()
    expect(JSON.stringify(emitted)).not.toContain(FAKE)
    for (const spy of spies) {
      expect(spy).not.toHaveBeenCalled()
      spy.mockRestore()
    }
  })

  test('stop while the Keychain read waits: no request is sent', async () => {
    const { emitted, fetch, poller, readToken } = setup()
    let release: (token: string | null) => void = () => {}
    readToken.mockImplementationOnce(
      () =>
        new Promise<string | null>(resolve => {
          release = resolve
        }),
    )
    poller.start()
    await vi.advanceTimersByTimeAsync(0)
    poller.stop()
    release(FAKE)
    await vi.advanceTimersByTimeAsync(0)
    expect(fetch).not.toHaveBeenCalled()
    expect(emitted.every(value => value === null)).toBe(true)
    await vi.advanceTimersByTimeAsync(3 * POLL_INTERVAL_MS)
    expect(fetch).not.toHaveBeenCalled()
  })

  test('stop aborts a request in progress', async () => {
    const { fetch, poller } = setup()
    let signal: AbortSignal | undefined
    fetch.mockImplementationOnce(
      (_url, init) =>
        new Promise<Response>((_resolve, reject) => {
          signal = init.signal ?? undefined
          signal?.addEventListener('abort', () => reject(new Error('aborted')))
        }),
    )
    poller.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(signal?.aborted).toBe(false)
    poller.stop()
    expect(signal?.aborted).toBe(true)
  })

  test('stop then start while a poll waits: the old poll gives nothing, a new poll runs', async () => {
    const { emitted, fetch, poller, readToken } = setup()
    let release: (token: string | null) => void = () => {}
    readToken.mockImplementationOnce(
      () =>
        new Promise<string | null>(resolve => {
          release = resolve
        }),
    )
    poller.start()
    await vi.advanceTimersByTimeAsync(0)
    poller.stop()
    poller.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(fetch).toHaveBeenCalledTimes(1)
    release(FAKE)
    await vi.advanceTimersByTimeAsync(0)
    // The old poll sent no request and set no timer. One timer remains.
    expect(fetch).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(POLL_INTERVAL_MS)
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(emitted.filter(value => value !== null)).toHaveLength(2)
    poller.stop()
  })

  test('a poll that never ends does not stop the later polls', async () => {
    const { fetch, poller } = setup()
    fetch.mockImplementationOnce(() => new Promise<Response>(() => {}))
    poller.start()
    await vi.advanceTimersByTimeAsync(POLL_DEADLINE_MS + 1)
    await vi.advanceTimersByTimeAsync(POLL_INTERVAL_MS)
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(poller.current()).not.toBeNull()
    poller.stop()
  })

  test('a failed body read keeps the last good values', async () => {
    const { fetch, poller } = setup()
    poller.start()
    await vi.advanceTimersByTimeAsync(0)
    const first = poller.current()
    const broken = new Response(sample, { status: 200 })
    vi.spyOn(broken, 'text').mockRejectedValue(new Error(`read ${FAKE}`))
    fetch.mockResolvedValueOnce(broken)
    await vi.advanceTimersByTimeAsync(POLL_INTERVAL_MS)
    expect(poller.current()).toEqual(first)
    poller.stop()
  })

  test('a body over the limit is not read', async () => {
    const { poller, fetch } = setup()
    const big = new Response('{}', {
      headers: { 'content-length': String(MAX_BODY_BYTES + 1) },
      status: 200,
    })
    const text = vi.spyOn(big, 'text')
    fetch.mockResolvedValueOnce(big)
    poller.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(text).not.toHaveBeenCalled()
    expect(poller.current()).toBeNull()
    poller.stop()
  })

  test('off then on keeps the 15 minute wait after a 429', async () => {
    const { fetch, poller, replies } = setup()
    replies.push({ body: '', status: 429 })
    poller.start()
    await vi.advanceTimersByTimeAsync(0)
    poller.stop()
    poller.start()
    await vi.advanceTimersByTimeAsync(RATE_LIMIT_WAIT_MS - 1)
    expect(fetch).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(1)
    expect(fetch).toHaveBeenCalledTimes(2)
    poller.stop()
  })

  test('the health log gets each poll: 401, 403, 429 and no token give no data (P7)', async () => {
    const poll = vi.fn()
    const { fetch, poller, readToken, replies } = setup(FAKE, { poll })
    replies.push(
      { body: sample, status: 200 },
      { body: '', status: 401 },
      { body: '', status: 403 },
      { body: '', status: 500 },
      new Error('network down'),
      // Task 2 decision: another 4xx and an answer that Bifrost cannot read are failures too.
      { body: '', status: 404 },
      { body: 'not json', status: 200 },
    )
    poller.start()
    await vi.advanceTimersByTimeAsync(0)
    for (let i = 0; i < 6; i++) await vi.advanceTimersByTimeAsync(POLL_INTERVAL_MS)
    readToken.mockResolvedValueOnce(null)
    await vi.advanceTimersByTimeAsync(POLL_INTERVAL_MS)
    // A request that never ends fails at the poll deadline.
    fetch.mockImplementationOnce(() => new Promise<Response>(() => {}))
    await vi.advanceTimersByTimeAsync(POLL_INTERVAL_MS + POLL_DEADLINE_MS)
    replies.push({ body: '', status: 429 })
    await vi.advanceTimersByTimeAsync(POLL_INTERVAL_MS)
    expect(poll.mock.calls).toEqual([
      ['account-usage', 'ok'],
      ['account-usage', 'no-data'],
      ['account-usage', 'no-data'],
      ['account-usage', 'failed'],
      ['account-usage', 'failed'],
      ['account-usage', 'failed'],
      ['account-usage', 'failed'],
      ['account-usage', 'no-data'],
      ['account-usage', 'failed'],
      ['account-usage', 'no-data'],
    ])
    poller.stop()
  })

  test('start twice does not start two timers', async () => {
    const { fetch, poller } = setup()
    poller.start()
    poller.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(fetch).toHaveBeenCalledTimes(1)
    poller.stop()
  })
})

describe('AccountUsage', () => {
  test('the type that goes to the renderer has no token field', () => {
    expectTypeOf<keyof AccountUsage>().toEqualTypeOf<'fetchedAt' | 'limits'>()
    expectTypeOf<keyof AccountUsage['limits']>().toEqualTypeOf<'fiveHour' | 'sevenDay'>()
  })
})
