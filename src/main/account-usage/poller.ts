// The poller of the account usage (spec 8.8). It runs only while the setting is on.
// SECURITY: the token lives in memory for one request. The poller never logs it, never sends it
// to the renderer, and never sends it to another URL. It never refreshes a token. After an
// expired token or a 401 or 403, it waits and reads the Keychain again at the next poll, because
// Claude Code refreshes the token itself.
import type { AccountUsage } from '../../shared/types'
import { type HealthEvents, NO_HEALTH, type PollResult } from '../performance/health-log'
import { parseAccountUsage } from './parse'

// Hard-coded. The token goes only to this URL.
export const ACCOUNT_USAGE_URL = 'https://api.anthropic.com/api/oauth/usage'
export const POLL_INTERVAL_MS = 5 * 60_000
export const HUD_GAP_MS = 60_000
export const RATE_LIMIT_WAIT_MS = 15 * 60_000
export const REQUEST_TIMEOUT_MS = 10_000
// A poll ends at this time, even when the request does not.
export const POLL_DEADLINE_MS = 25_000
export const MAX_BODY_BYTES = 1_000_000

export interface PollerDeps {
  // The access token, or null for "no token".
  readToken(): Promise<string | null>
  fetch(url: string, init: RequestInit): Promise<Response>
  now(): number
  // The new values, or null when there are none.
  emit(value: AccountUsage | null): void
  // The health log gets the result of each poll (P5, P7). The default does nothing.
  health?: Pick<HealthEvents, 'poll'>
}

export interface AccountUsagePoller {
  // Poll now and then every 5 minutes. A second call does nothing.
  start(): void
  // End the polling and clear the values.
  stop(): void
  // The HUD opened. Poll, but not more than one time in 60 seconds.
  requestPoll(): void
  current(): AccountUsage | null
}

export function createAccountUsagePoller(deps: PollerDeps): AccountUsagePoller {
  const health = deps.health ?? NO_HEALTH
  let running = false
  let busy = false
  // Each start and each stop makes a new generation. A poll of an old generation sends nothing,
  // changes nothing and sets no timer.
  let generation = 0
  let controller: AbortController | null = null
  let timer: ReturnType<typeof setTimeout> | null = null
  let lastPollAt = Number.NEGATIVE_INFINITY
  let waitUntil = Number.NEGATIVE_INFINITY
  let value: AccountUsage | null = null

  function set(next: AccountUsage | null): void {
    value = next
    deps.emit(next)
  }

  function schedule(): void {
    if (timer) clearTimeout(timer)
    const wait = Math.max(POLL_INTERVAL_MS, waitUntil - deps.now())
    timer = setTimeout(() => void poll(), wait)
  }

  // One request. Return the new values, null for "no data", or undefined to keep the old values.
  // The request sets the health result of the poll in outcome. When it sets no result, the
  // result stays 'failed'. This applies to a fetch error, a 5xx or other bad status, a bad answer
  // and a timeout (P7).
  async function request(
    gen: number,
    abort: AbortController,
    outcome: { result: PollResult },
  ): Promise<AccountUsage | null | undefined> {
    const token = await deps.readToken()
    if (token === null) outcome.result = 'no-data'
    // The setting can go off during the Keychain read, or the poll deadline can pass. Then drop
    // the token and send nothing.
    if (token === null || !running || gen !== generation || abort.signal.aborted) return undefined
    let res: Response
    try {
      res = await deps.fetch(ACCOUNT_USAGE_URL, {
        cache: 'no-store',
        credentials: 'omit',
        headers: {
          Authorization: `Bearer ${token}`,
          'anthropic-beta': 'oauth-2025-04-20',
          'User-Agent': 'Bifrost',
        },
        method: 'GET',
        redirect: 'error',
        signal: AbortSignal.any([abort.signal, AbortSignal.timeout(REQUEST_TIMEOUT_MS)]),
      })
    } catch {
      // The error text can hold request data, so it goes nowhere.
      return undefined
    }
    // An expired login and the rate limit give no data. They are not failures.
    if (res.status === 401 || res.status === 403) {
      outcome.result = 'no-data'
      return null
    }
    if (res.status === 429) {
      outcome.result = 'no-data'
      waitUntil = deps.now() + RATE_LIMIT_WAIT_MS
      return undefined
    }
    if (!res.ok) return undefined
    // An answer that is too large is a bad answer.
    const length = Number(res.headers.get('content-length'))
    if (Number.isFinite(length) && length > MAX_BODY_BYTES) {
      await res.body?.cancel().catch(() => {})
      return null
    }
    let text: string
    try {
      text = await res.text()
    } catch {
      // A read error is not a bad answer, so the old values stay.
      return undefined
    }
    try {
      if (text.length > MAX_BODY_BYTES) return null
      const limits = parseAccountUsage(JSON.parse(text))
      if (!limits) return null
      outcome.result = 'ok'
      return { fetchedAt: deps.now(), limits }
    } catch {
      return null
    }
  }

  // A poll never lasts longer than the deadline, so a hung request cannot stop all later polls.
  async function poll(): Promise<void> {
    if (!running || busy) return
    busy = true
    const gen = generation
    const abort = new AbortController()
    controller = abort
    lastPollAt = deps.now()
    let deadline: ReturnType<typeof setTimeout> | undefined
    // Each poll has its own outcome, so a late request of an old poll cannot change it.
    const outcome: { result: PollResult } = { result: 'failed' }
    try {
      const result = await Promise.race([
        request(gen, abort, outcome),
        new Promise<undefined>(resolve => {
          deadline = setTimeout(() => resolve(undefined), POLL_DEADLINE_MS)
        }),
      ])
      if (!running || gen !== generation) return
      health.poll('account-usage', outcome.result)
      if (result !== undefined && (result !== null || value !== null)) set(result)
    } catch {
      // request() does not throw. A throw here keeps the old values.
    } finally {
      clearTimeout(deadline)
      if (gen === generation) {
        abort.abort()
        controller = null
        busy = false
        if (running) schedule()
      }
    }
  }

  return {
    current: () => value,
    requestPoll() {
      if (!running || busy) return
      const now = deps.now()
      if (now - lastPollAt < HUD_GAP_MS || now < waitUntil) return
      void poll()
    },
    start() {
      if (running) return
      running = true
      generation += 1
      // A 429 wait from before a stop still holds.
      if (deps.now() < waitUntil) schedule()
      else void poll()
    },
    stop() {
      running = false
      generation += 1
      controller?.abort()
      controller = null
      busy = false
      if (timer) clearTimeout(timer)
      timer = null
      lastPollAt = Number.NEGATIVE_INFINITY
      if (value !== null) set(null)
    },
  }
}
