// The helpers that ipc.ts uses to bind the Performance monitor (Performance design section 7). The
// module never imports electron. ipc.ts gives each Electron and Node function.
import { CHAT_VIEW } from '../../shared/view-id'
import { type Gh, ghFailure } from '../reviews/gh'
import type { GithubLimit, PanelView, ProbeResult } from './monitor'

// The window of the main process delay.
export const DELAY_WINDOW_MS = 60_000
// A response time request ends after this time with 'no-answer'.
export const PROBE_TIMEOUT_MS = 5000

// gh api rate_limit costs no points (P11).
export const RATE_LIMIT_ARGS = ['api', 'rate_limit']
const RATE_LIMIT_TIMEOUT_MS = 15_000
// The texts of the GitHub limit row when gh cannot give the limit.
export const GH_LIMIT_MISSING = "GitHub CLI isn't installed"
export const GH_LIMIT_LOGGED_OUT = "GitHub CLI isn't signed in"
export const GH_LIMIT_FAILED = "Couldn't read the GitHub limit"

// The renderer sent a chat panel ID that is not a chat view ID.
export const REFUSED_BAD_CHAT_PANEL = 'refused: bad chat panel'
const REFUSED_BAD_INPUT = 'refused: bad input'
// More chat panels than this in one report is not a real window.
const MAX_CHAT_PANELS = 500
const MAX_FPS = 1000
const NS_PER_MS = 1e6

// Read the GraphQL limit from the REST answer of gh api rate_limit. reset is in seconds.
export function parseGhRateLimit(stdout: string): GithubLimit | null {
  let root: unknown
  try {
    root = JSON.parse(stdout)
  } catch {
    return null
  }
  type Answer = { resources?: { graphql?: Record<string, unknown> } } | null
  const graphql = (root as Answer)?.resources?.graphql
  const value = (v: unknown): number | null =>
    typeof v === 'number' && Number.isFinite(v) && v >= 0 ? v : null
  const limit = value(graphql?.limit)
  const remaining = value(graphql?.remaining)
  const reset = value(graphql?.reset)
  if (limit === null || remaining === null || reset === null) return null
  return { limit, remaining, resetAt: reset * 1000 }
}

// The GitHub limit with Reviews off (ruling 6). A failure gives a friendly reason.
export async function readGhRateLimit(
  gh: Pick<Gh, 'run'>,
): Promise<GithubLimit | { unavailable: string }> {
  try {
    const result = await gh.run(RATE_LIMIT_ARGS, { timeoutMs: RATE_LIMIT_TIMEOUT_MS })
    const failed = ghFailure(result)
    if (failed?.availability === 'no-gh') return { unavailable: GH_LIMIT_MISSING }
    if (failed?.availability === 'logged-out') return { unavailable: GH_LIMIT_LOGGED_OUT }
    if (failed !== null) return { unavailable: GH_LIMIT_FAILED }
    return parseGhRateLimit(result.stdout) ?? { unavailable: GH_LIMIT_FAILED }
  } catch {
    return { unavailable: GH_LIMIT_FAILED }
  }
}

// One HEAD request with no login, no token and no cookie (ruling 9). Any HTTP status is an answer.
// The time is until the response headers. The timeout gives 'no-answer'. A DNS or connection
// error gives 'unreachable'.
export async function probeUrl(
  fetch: (url: string, init: RequestInit) => Promise<Response>,
  url: string,
  clock: () => number,
): Promise<ProbeResult> {
  const signal = AbortSignal.timeout(PROBE_TIMEOUT_MS)
  const start = clock()
  try {
    const res = await fetch(url, {
      cache: 'no-store',
      credentials: 'omit',
      method: 'HEAD',
      signal,
    })
    const ms = Math.max(0, Math.round(clock() - start))
    res.body?.cancel().catch(() => {})
    return ms
  } catch (error) {
    const timedOut = signal.aborted || (error instanceof Error && error.name === 'TimeoutError')
    return timedOut ? 'no-answer' : 'unreachable'
  }
}

// The part of the Node event loop delay histogram that the monitor uses. Its values are in ns.
// Each value is the time between two runs of its timer: the resolution plus the delay.
export interface DelayHistogram {
  readonly count: number
  readonly max: number
  reset(): void
  enable(): unknown
  disable(): unknown
}

// The timer interval of the histogram. A longer interval costs less CPU. A delay check of 200 ms
// does not need a finer value.
export const DELAY_RESOLUTION_MS = 50

// The main process delay (design section 6).
export interface LoopDelay {
  // The longest delay of the last full window in ms, without the timer interval. null before
  // the end of the first window, and for a window with no data.
  longestMs(): number | null
  stop(): void
}

// Make and enable the histogram with a 50 ms resolution. At the end of each 60 s window, keep
// its longest delay and reset it. The longest delay shows a repeated freeze that a percentile
// can hide. stop clears the timer and disables the histogram.
export function createLoopDelay(
  make: (options: { resolution: number }) => DelayHistogram,
): LoopDelay {
  const h = make({ resolution: DELAY_RESOLUTION_MS })
  let last: number | null = null
  let timer: ReturnType<typeof setTimeout> | null = null
  h.enable()
  const roll = (): void => {
    last = h.count > 0 ? Math.max(0, h.max / NS_PER_MS - DELAY_RESOLUTION_MS) : null
    h.reset()
    timer = setTimeout(roll, DELAY_WINDOW_MS)
  }
  timer = setTimeout(roll, DELAY_WINDOW_MS)
  return {
    longestMs: () => last,
    stop() {
      if (timer === null) return
      clearTimeout(timer)
      timer = null
      h.disable()
    },
  }
}

// Check the view report of the renderer. It has two booleans and the chat panel IDs only.
export function checkView(v: unknown): PanelView {
  if (typeof v !== 'object' || v === null) throw new Error(REFUSED_BAD_INPUT)
  const { chatPanels, focused, showing } = v as Record<string, unknown>
  if (typeof showing !== 'boolean' || typeof focused !== 'boolean') {
    throw new Error(REFUSED_BAD_INPUT)
  }
  if (!Array.isArray(chatPanels) || chatPanels.length > MAX_CHAT_PANELS) {
    throw new Error(REFUSED_BAD_INPUT)
  }
  for (const id of chatPanels) {
    if (typeof id !== 'string' || !CHAT_VIEW.test(id)) throw new Error(REFUSED_BAD_CHAT_PANEL)
  }
  return { chatPanels: [...chatPanels] as string[], focused, showing }
}

// Check the frame rate of the renderer: a finite number from 0 to 1000.
export function checkFps(v: unknown): number {
  if (typeof v !== 'number' || !Number.isFinite(v) || v < 0 || v > MAX_FPS) {
    throw new Error(REFUSED_BAD_INPUT)
  }
  return v
}
