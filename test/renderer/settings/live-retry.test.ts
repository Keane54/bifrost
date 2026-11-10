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
  RECENT_READ_MS,
  RETRY_STEPS_MS,
  type RetryClock,
} from '../../../src/renderer/src/settings/live-retry'
import { LIVE_MIN_CLAUDE_VERSION } from '../../../src/shared/live'
import type { ClaudeVersion, LiveStatus } from '../../../src/shared/types'

const CONTEXT = readFileSync(
  join(__dirname, '../../../src/renderer/src/settings/live-context.tsx'),
  'utf8',
)

// The fake timers of Vitest replace setTimeout and Date.now.
const CLOCK: RetryClock = {
  after(ms, fn) {
    const id = setTimeout(fn, ms)
    return () => clearTimeout(id)
  },
  now: () => Date.now(),
}

const SECOND = 1000
const MINUTE = 60 * SECOND

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
}

// A fake LiveProvider. The first read (the mount read) ends at the start. The warning follows the
// state after each read, like the effect of the provider.
function world(opts: WorldOptions) {
  const t0 = Date.now()
  const state = {
    busy: false,
    // A status re-read waits for this promise when it is set.
    hold: null as Promise<void> | null,
    // The status that the next re-read gives, or null for the first status.
    next: opts.next ?? null,
    status: opts.status,
    version: opts.version === undefined ? VERSION : opts.version,
    versionFailed: opts.versionFailed ?? false,
  }
  const reads = { status: 0, version: 0 }
  // The time of each status re-read from the start, in seconds.
  const at: number[] = []
  let versionFails = opts.versionFails ?? 0
  const warning = (): boolean => hasWarning(state.status, state.version, state.versionFailed)
  const retry = createLiveRetry({
    busy: () => state.busy,
    clock: CLOCK,
    async readStatus() {
      reads.status += 1
      at.push((Date.now() - t0) / SECOND)
      if (state.hold) await state.hold
      state.status = state.next ?? opts.status
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
    version: () => state.version,
    versionFailed: () => state.versionFailed,
  })
  retry.readEnded()
  retry.warn(warning())
  return { at, reads, retry, state, warning }
}

// A promise and the function that resolves it.
function gate(): { open: () => void; promise: Promise<void> } {
  let open = (): void => {}
  const promise = new Promise<void>(resolve => {
    open = resolve
  })
  return { open, promise }
}

// Move the fake time on by ms, and then give a window focus.
async function focusAfter(w: ReturnType<typeof world>, ms: number): Promise<void> {
  await vi.advanceTimersByTimeAsync(ms)
  w.retry.focus()
  await vi.advanceTimersByTimeAsync(0)
}

beforeEach(() => {
  vi.useFakeTimers()
})
afterEach(() => {
  vi.useRealTimers()
})

describe('createLiveRetry', () => {
  it('has the steps of the back-off and the two gaps', () => {
    expect(RETRY_STEPS_MS).toEqual([MINUTE, 2 * MINUTE, 5 * MINUTE, 10 * MINUTE])
    expect(FOCUS_GAP_MS).toBe(5 * MINUTE)
    expect(RECENT_READ_MS).toBe(30 * SECOND)
  })

  it('reads again after 1 minute, and a good status clears the warning and the timer', async () => {
    const w = world({ next: ON, status: NOT_RECEIVING })
    expect(w.warning()).toBe(true)
    await vi.advanceTimersByTimeAsync(MINUTE - 1)
    expect(w.reads.status).toBe(0)
    await vi.advanceTimersByTimeAsync(1)
    expect(w.reads.status).toBe(1)
    expect(w.warning()).toBe(false)
    expect(vi.getTimerCount()).toBe(0)
    await vi.advanceTimersByTimeAsync(30 * MINUTE)
    expect(w.reads.status).toBe(1)
  })

  it('reads at 1, 2, 5 and 10 minutes while the warning stays, and then stops', async () => {
    const w = world({ status: NOT_RECEIVING })
    await vi.advanceTimersByTimeAsync(10 * MINUTE)
    expect(w.at).toEqual([60, 120, 300, 600])
    expect(vi.getTimerCount()).toBe(0)
    await vi.advanceTimersByTimeAsync(60 * MINUTE)
    expect(w.at).toEqual([60, 120, 300, 600])
    expect(w.warning()).toBe(true)
  })

  it('starts the steps again only at a new warning', async () => {
    const w = world({ status: NOT_RECEIVING })
    await vi.advanceTimersByTimeAsync(2 * MINUTE)
    // The warning stays. The steps go on from the first warning.
    w.retry.warn(true)
    await vi.advanceTimersByTimeAsync(3 * MINUTE)
    expect(w.at).toEqual([60, 120, 300])
    // The warning goes away and comes back at 5 minutes. The steps start again.
    w.retry.warn(false)
    expect(vi.getTimerCount()).toBe(0)
    w.retry.warn(true)
    await vi.advanceTimersByTimeAsync(2 * MINUTE)
    expect(w.at).toEqual([60, 120, 300, 360, 420])
  })

  it('has no timer and reads nothing while there is no warning', async () => {
    const w = world({ status: ON })
    expect(w.warning()).toBe(false)
    expect(vi.getTimerCount()).toBe(0)
    await focusAfter(w, 30 * MINUTE)
    expect(w.reads).toEqual({ status: 0, version: 0 })
  })

  it('skips a step when a read ended less than 30 s before it', async () => {
    const w = world({ status: NOT_RECEIVING })
    // A Settings read ends at 40 s. It counts as the step at 1 minute.
    await vi.advanceTimersByTimeAsync(40 * SECOND)
    w.retry.readEnded()
    await vi.advanceTimersByTimeAsync(20 * SECOND)
    expect(w.reads.status).toBe(0)
    // A read that ended 30 s before the step does not count as the step.
    await vi.advanceTimersByTimeAsync(30 * SECOND)
    w.retry.readEnded()
    await vi.advanceTimersByTimeAsync(30 * SECOND)
    expect(w.at).toEqual([120])
  })

  it('reads at a focus only when the last read ended 5 minutes or more ago', async () => {
    const w = world({ status: NOT_RECEIVING })
    // The last step reads at 10 minutes.
    await vi.advanceTimersByTimeAsync(10 * MINUTE)
    await focusAfter(w, FOCUS_GAP_MS - 1)
    expect(w.reads.status).toBe(4)
    await focusAfter(w, 1)
    expect(w.reads.status).toBe(5)
    await focusAfter(w, 0)
    expect(w.reads.status).toBe(5)
    // A Settings read or an action read counts too.
    await vi.advanceTimersByTimeAsync(FOCUS_GAP_MS)
    w.retry.readEnded()
    await focusAfter(w, FOCUS_GAP_MS - 1)
    expect(w.reads.status).toBe(5)
  })

  it('counts a read from its end, not from its start', async () => {
    const w = world({ status: NOT_RECEIVING })
    await vi.advanceTimersByTimeAsync(15 * MINUTE)
    const slow = gate()
    w.state.hold = slow.promise
    await focusAfter(w, 0)
    expect(w.reads.status).toBe(5)
    // The read takes 2 minutes.
    await vi.advanceTimersByTimeAsync(2 * MINUTE)
    w.state.hold = null
    slow.open()
    await vi.advanceTimersByTimeAsync(0)
    await focusAfter(w, FOCUS_GAP_MS - 1)
    expect(w.reads.status).toBe(5)
    await focusAfter(w, 1)
    expect(w.reads.status).toBe(6)
  })

  it('keeps the warning after the last step until a focus read clears it', async () => {
    const w = world({ status: NOT_RECEIVING })
    await vi.advanceTimersByTimeAsync(10 * MINUTE)
    // The problem ends after the last step. No timer reads it.
    w.state.next = ON
    await vi.advanceTimersByTimeAsync(20 * MINUTE)
    expect(w.reads.status).toBe(4)
    expect(w.warning()).toBe(true)
    await focusAfter(w, 0)
    expect(w.reads.status).toBe(5)
    expect(w.warning()).toBe(false)
  })

  it('does not read while an action runs', async () => {
    const w = world({ status: NOT_RECEIVING })
    w.state.busy = true
    await vi.advanceTimersByTimeAsync(MINUTE)
    expect(w.reads.status).toBe(0)
    w.state.busy = false
    await vi.advanceTimersByTimeAsync(MINUTE)
    expect(w.at).toEqual([120])
    // A focus while an action runs does not read either.
    await vi.advanceTimersByTimeAsync(8 * MINUTE)
    w.state.busy = true
    await focusAfter(w, FOCUS_GAP_MS)
    expect(w.reads.status).toBe(3)
  })

  it('does not start a second read while a read runs', async () => {
    const slow = gate()
    const w = world({ next: ON, status: NOT_RECEIVING })
    w.state.hold = slow.promise
    await vi.advanceTimersByTimeAsync(10 * MINUTE)
    expect(w.reads.status).toBe(1)
    slow.open()
    await vi.advanceTimersByTimeAsync(0)
    expect(w.warning()).toBe(false)
  })

  it('reads a failed version again until it works, and then clears the warning', async () => {
    const w = world({ status: ON, version: null, versionFailed: true, versionFails: 1 })
    expect(w.warning()).toBe(true)
    await vi.advanceTimersByTimeAsync(MINUTE)
    expect(w.reads).toEqual({ status: 1, version: 1 })
    expect(w.state.versionFailed).toBe(true)
    await vi.advanceTimersByTimeAsync(MINUTE)
    expect(w.reads).toEqual({ status: 2, version: 2 })
    expect(w.state).toMatchObject({ version: VERSION, versionFailed: false })
    expect(w.warning()).toBe(false)
    expect(vi.getTimerCount()).toBe(0)
  })

  it('reads again after an answer with no version, and a good answer clears it', async () => {
    // A timeout of claude --version gives an answer with no version. The call does not reject.
    const missing: ClaudeVersion = { minimum: LIVE_MIN_CLAUDE_VERSION, ok: false, version: null }
    const w = world({ status: ON, version: missing })
    expect(w.warning()).toBe(true)
    await vi.advanceTimersByTimeAsync(MINUTE)
    expect(w.reads).toEqual({ status: 1, version: 1 })
    expect(w.state).toMatchObject({ version: VERSION, versionFailed: false })
    expect(w.warning()).toBe(false)
    expect(vi.getTimerCount()).toBe(0)
  })

  it('does not read the version again when the version is good', async () => {
    const w = world({ status: NOT_RECEIVING })
    await vi.advanceTimersByTimeAsync(MINUTE)
    expect(w.reads).toEqual({ status: 1, version: 0 })
  })
})

// The text of the provider from the start text up to the first end text after it.
function between(from: string, to: string): string {
  const start = CONTEXT.indexOf(from)
  expect(start, from).toBeGreaterThan(-1)
  const end = CONTEXT.indexOf(to, start)
  expect(end, to).toBeGreaterThan(start)
  return CONTEXT.slice(start, end)
}

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

  it('gives the newest version and the failed check to the retry', () => {
    expect(CONTEXT).toContain('version: () => versionNow.current')
    expect(CONTEXT).toContain('versionFailed: () => versionFailedNow.current')
  })

  it('gives the end of the mount read, a refresh and an action read to the retry', () => {
    const mount = between('// Load the status and the version one time at mount.', 'return () =>')
    expect(mount).toContain('retry.readEnded()')
    const locked = between('const locked = useCallback(', 'const refresh =')
    expect(locked).toMatch(/finally \{[^}]*retry\.readEnded\(\)/)
  })
})
