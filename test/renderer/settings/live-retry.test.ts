// The re-read of the Live details status while a warning shows. The first read can give a short
// failure, for example before the main process listens. The warning dot must then go away by
// itself.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { hasWarning } from '../../../src/renderer/src/settings/live-notice'
import {
  createLiveRetry,
  FOCUS_GAP_MS,
  RETRY_EVERY_MS,
  type RetryClock,
} from '../../../src/renderer/src/settings/live-retry'
import { LIVE_MIN_CLAUDE_VERSION } from '../../../src/shared/live'
import type { ClaudeVersion, LiveStatus } from '../../../src/shared/types'

const CONTEXT = readFileSync(
  join(__dirname, '../../../src/renderer/src/settings/live-context.tsx'),
  'utf8',
)

// The fake timers of Vitest replace setInterval and Date.now.
const CLOCK: RetryClock = {
  every(ms, fn) {
    const id = setInterval(fn, ms)
    return () => clearInterval(id)
  },
  now: () => Date.now(),
}

const ON: LiveStatus = {
  claudeVersion: '2.1.318',
  listening: true,
  liveSessions: 0,
  modCurrent: true,
  oldInstall: false,
  plugin: 'enabled',
  versionOk: true,
}
// The status of a read before the main process listens.
const NOT_RECEIVING: LiveStatus = { ...ON, listening: false }
const VERSION: ClaudeVersion = { minimum: LIVE_MIN_CLAUDE_VERSION, ok: true, version: '2.1.318' }

interface WorldOptions {
  status: LiveStatus
  // The status that each re-read gives. The default is the first status.
  next?: LiveStatus
  version?: ClaudeVersion | null
  versionFailed?: boolean
  // The number of version re-reads that fail before one works.
  versionFails?: number
  // A status re-read waits for this promise when it is set.
  statusGate?: Promise<void>
}

// A fake LiveProvider. The warning follows the state after each read, like the effect of the
// provider.
function world(opts: WorldOptions) {
  const state = {
    busy: false,
    status: opts.status,
    version: opts.version === undefined ? VERSION : opts.version,
    versionFailed: opts.versionFailed ?? false,
  }
  const reads = { status: 0, version: 0 }
  let versionFails = opts.versionFails ?? 0
  const warning = (): boolean => hasWarning(state.status, state.version, state.versionFailed)
  const retry = createLiveRetry({
    busy: () => state.busy,
    clock: CLOCK,
    async readStatus() {
      reads.status += 1
      if (opts.statusGate) await opts.statusGate
      state.status = opts.next ?? opts.status
      retry.warn(warning())
    },
    async readVersion() {
      reads.version += 1
      if (versionFails > 0) {
        versionFails -= 1
        return
      }
      state.version = VERSION
      state.versionFailed = false
      retry.warn(warning())
    },
    versionFailed: () => state.versionFailed,
  })
  retry.warn(warning())
  return { reads, retry, state, warning }
}

beforeEach(() => {
  vi.useFakeTimers()
})
afterEach(() => {
  vi.useRealTimers()
})

describe('createLiveRetry', () => {
  it('reads again after 60 s, and a good status clears the warning and the timer', async () => {
    const w = world({ next: ON, status: NOT_RECEIVING })
    expect(w.warning()).toBe(true)
    await vi.advanceTimersByTimeAsync(RETRY_EVERY_MS - 1)
    expect(w.reads.status).toBe(0)
    await vi.advanceTimersByTimeAsync(1)
    expect(w.reads.status).toBe(1)
    expect(w.warning()).toBe(false)
    expect(vi.getTimerCount()).toBe(0)
    await vi.advanceTimersByTimeAsync(10 * RETRY_EVERY_MS)
    expect(w.reads.status).toBe(1)
  })

  it('reads again each 60 s while the warning stays', async () => {
    const w = world({ status: NOT_RECEIVING })
    await vi.advanceTimersByTimeAsync(3 * RETRY_EVERY_MS)
    expect(w.reads.status).toBe(3)
    expect(w.warning()).toBe(true)
  })

  it('has no timer and reads nothing while there is no warning', async () => {
    const w = world({ status: ON })
    expect(w.warning()).toBe(false)
    expect(vi.getTimerCount()).toBe(0)
    await vi.advanceTimersByTimeAsync(10 * RETRY_EVERY_MS)
    w.retry.focus()
    await vi.advanceTimersByTimeAsync(0)
    expect(w.reads).toEqual({ status: 0, version: 0 })
  })

  it('reads at a focus only when the last read is 10 s old or older', async () => {
    const w = world({ status: NOT_RECEIVING })
    // The read that gave the warning counts as the last read.
    await vi.advanceTimersByTimeAsync(FOCUS_GAP_MS - 1)
    w.retry.focus()
    await vi.advanceTimersByTimeAsync(0)
    expect(w.reads.status).toBe(0)
    await vi.advanceTimersByTimeAsync(1)
    w.retry.focus()
    await vi.advanceTimersByTimeAsync(0)
    expect(w.reads.status).toBe(1)
    // A second focus soon after that read does not read again.
    await vi.advanceTimersByTimeAsync(FOCUS_GAP_MS - 1)
    w.retry.focus()
    await vi.advanceTimersByTimeAsync(0)
    expect(w.reads.status).toBe(1)
  })

  it('does not read at a focus within 10 s of a timer read', async () => {
    const w = world({ status: NOT_RECEIVING })
    await vi.advanceTimersByTimeAsync(RETRY_EVERY_MS)
    expect(w.reads.status).toBe(1)
    await vi.advanceTimersByTimeAsync(FOCUS_GAP_MS - 1)
    w.retry.focus()
    await vi.advanceTimersByTimeAsync(0)
    expect(w.reads.status).toBe(1)
  })

  it('does not read while an action runs', async () => {
    const w = world({ status: NOT_RECEIVING })
    w.state.busy = true
    await vi.advanceTimersByTimeAsync(RETRY_EVERY_MS + FOCUS_GAP_MS)
    w.retry.focus()
    await vi.advanceTimersByTimeAsync(0)
    expect(w.reads.status).toBe(0)
    w.state.busy = false
    await vi.advanceTimersByTimeAsync(RETRY_EVERY_MS - FOCUS_GAP_MS)
    expect(w.reads.status).toBe(1)
  })

  it('does not start a second read while a read runs', async () => {
    let open = (): void => {}
    const statusGate = new Promise<void>(resolve => {
      open = resolve
    })
    const w = world({ next: ON, status: NOT_RECEIVING, statusGate })
    await vi.advanceTimersByTimeAsync(3 * RETRY_EVERY_MS)
    w.retry.focus()
    expect(w.reads.status).toBe(1)
    open()
    await vi.advanceTimersByTimeAsync(0)
    expect(w.warning()).toBe(false)
  })

  it('reads a failed version again until it works, and then clears the warning', async () => {
    const w = world({ status: ON, version: null, versionFailed: true, versionFails: 1 })
    expect(w.warning()).toBe(true)
    await vi.advanceTimersByTimeAsync(RETRY_EVERY_MS)
    expect(w.reads).toEqual({ status: 1, version: 1 })
    expect(w.state.versionFailed).toBe(true)
    await vi.advanceTimersByTimeAsync(RETRY_EVERY_MS)
    expect(w.reads).toEqual({ status: 2, version: 2 })
    expect(w.state).toMatchObject({ version: VERSION, versionFailed: false })
    expect(w.warning()).toBe(false)
    expect(vi.getTimerCount()).toBe(0)
  })

  it('does not read the version again when the version check did not fail', async () => {
    const w = world({ status: NOT_RECEIVING })
    await vi.advanceTimersByTimeAsync(RETRY_EVERY_MS)
    expect(w.reads).toEqual({ status: 1, version: 0 })
  })

  it('starts the timer again for a new warning', async () => {
    const w = world({ status: ON })
    w.retry.warn(true)
    w.retry.warn(true)
    expect(vi.getTimerCount()).toBe(1)
    w.retry.warn(false)
    expect(vi.getTimerCount()).toBe(0)
  })
})

// The repository has no DOM test. So these checks read the source text of the provider.
describe('LiveProvider wiring', () => {
  it('gives the warning to the retry, and stops the timer when the provider goes', () => {
    expect(CONTEXT).toMatch(/retry\.warn\(warning\)\s+return \(\) => retry\.warn\(false\)/)
  })

  it('reads again at a window focus', () => {
    expect(CONTEXT).toContain("window.addEventListener('focus', onFocus)")
    expect(CONTEXT).toContain("window.removeEventListener('focus', onFocus)")
  })

  it('uses the running ref as the busy test of the retry', () => {
    expect(CONTEXT).toContain('busy: () => running.current')
  })
})
