// The poller of the account usage (spec 8.8). It runs only while the setting is on.
// SECURITY: the token lives in memory for one request. The poller never logs it, never sends it
// to the renderer, and never sends it to another URL. It never refreshes a token. After an
// expired token or a 401 or 403, it waits and reads the Keychain again at the next poll, because
// Claude Code refreshes the token itself.
import type { AccountUsage } from '../../shared/types'
import { parseAccountUsage } from './parse'

// Hard-coded. The token goes only to this URL.
export const ACCOUNT_USAGE_URL = 'https://api.anthropic.com/api/oauth/usage'
export const POLL_INTERVAL_MS = 5 * 60_000
export const HUD_GAP_MS = 60_000
export const RATE_LIMIT_WAIT_MS = 15 * 60_000
export const REQUEST_TIMEOUT_MS = 10_000
const MAX_BODY_CHARS = 1_000_000

export interface PollerDeps {
  // The access token, or null for "no token".
  readToken(): Promise<string | null>
  fetch(url: string, init: RequestInit): Promise<Response>
  now(): number
  // The new values, or null when there are none.
  emit(value: AccountUsage | null): void
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
  let running = false
  let busy = false
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
  async function request(): Promise<AccountUsage | null | undefined> {
    const token = await deps.readToken()
    if (token === null) return undefined
    let res: Response
    try {
      res = await deps.fetch(ACCOUNT_USAGE_URL, {
        headers: {
          Authorization: `Bearer ${token}`,
          'anthropic-beta': 'oauth-2025-04-20',
          'User-Agent': 'Bifrost',
        },
        method: 'GET',
        redirect: 'error',
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      })
    } catch {
      // The error text can hold request data, so it goes nowhere.
      return undefined
    }
    if (res.status === 401 || res.status === 403) return null
    if (res.status === 429) {
      waitUntil = deps.now() + RATE_LIMIT_WAIT_MS
      return undefined
    }
    if (!res.ok) return undefined
    try {
      const text = await res.text()
      if (text.length > MAX_BODY_CHARS) return null
      const limits = parseAccountUsage(JSON.parse(text))
      return limits ? { fetchedAt: deps.now(), limits } : null
    } catch {
      return null
    }
  }

  async function poll(): Promise<void> {
    if (!running || busy) return
    busy = true
    lastPollAt = deps.now()
    try {
      const result = await request()
      if (!running) return
      if (result !== undefined && (result !== null || value !== null)) set(result)
    } finally {
      busy = false
      if (running) schedule()
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
      void poll()
    },
    stop() {
      running = false
      if (timer) clearTimeout(timer)
      timer = null
      waitUntil = Number.NEGATIVE_INFINITY
      lastPollAt = Number.NEGATIVE_INFINITY
      if (value !== null) set(null)
    },
  }
}
