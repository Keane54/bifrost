// The re-read of the Live details status while a warning shows. The first read at the start of
// the app can give a short failure. Without a re-read, the side bar then shows a warning dot
// until Settings opens. Each read runs claude plugin list. So the re-reads follow a back-off
// (user decision, 2026-11-10):
// - A new warning starts the steps. The re-reads come 1, 2, 5 and 10 minutes after that start.
//   No timer runs after the last step, and no timer runs while there is no warning.
// - A read that ended less than 30 s before a step counts as that step. The step then does not
//   read.
// - A window focus reads again only when the last read ended 5 minutes or more ago.
// - Reads of each kind count: the mount read, a refresh, an action read and a re-read. Each read
//   counts from its end.
// After the last step, the warning stays until a focus read, a Settings read or an action clears
// it.

// The times of the re-reads from the start of a warning.
export const RETRY_STEPS_MS: readonly number[] = [60_000, 120_000, 300_000, 600_000]
// The minimum time from the end of the last read to a re-read at a window focus.
export const FOCUS_GAP_MS = 300_000
// A read that ended less than this time before a step counts as the step.
export const RECENT_READ_MS = 30_000

// The clock of the page. A test gives the fake timers.
export interface RetryClock {
  now(): number
  // Call fn one time after ms milliseconds. The result stops the timer.
  after(ms: number, fn: () => void): () => void
}

export interface LiveRetryDeps {
  // True while a Live details action or a refresh runs. Then a re-read does nothing.
  busy(): boolean
  // Read the status again and set it. It never rejects.
  readStatus(): Promise<void>
  // True when the last claudeVersion() call failed.
  versionFailed(): boolean
  // Call claudeVersion() again and set the result. It never rejects.
  readVersion(): Promise<void>
  clock: RetryClock
}

export interface LiveRetry {
  // Give the warning state. A new warning starts the steps. No warning stops them.
  warn(on: boolean): void
  // The window got the focus.
  focus(): void
  // A read of the provider ended: the mount read, a refresh or an action read.
  readEnded(): void
}

export function createLiveRetry(deps: LiveRetryDeps): LiveRetry {
  const { clock } = deps
  let warning = false
  // The start of the steps, and the index of the next step.
  let startedAt = 0
  let step = 0
  // The function that stops the timer of the next step, or null.
  let cancel: (() => void) | null = null
  // The end of the last read, or null before the first read ends.
  let lastEnd: number | null = null
  // True while a re-read runs. Then a second re-read does not start.
  let reading = false

  const endedWithin = (ms: number): boolean => lastEnd !== null && clock.now() - lastEnd < ms

  async function read(): Promise<void> {
    if (reading || deps.busy()) return
    reading = true
    try {
      await Promise.all([deps.readStatus(), deps.versionFailed() ? deps.readVersion() : null])
    } finally {
      reading = false
      lastEnd = clock.now()
    }
  }

  // Set the timer of the next step. The timer callback sets the next timer before it reads,
  // because the read can end the warning and stop the timer.
  function schedule(): void {
    cancel = null
    const at = RETRY_STEPS_MS[step]
    if (!warning || at === undefined) return
    cancel = clock.after(Math.max(0, startedAt + at - clock.now()), () => {
      step += 1
      schedule()
      if (!endedWithin(RECENT_READ_MS)) void read()
    })
  }

  return {
    focus() {
      if (!warning || lastEnd === null || endedWithin(FOCUS_GAP_MS)) return
      void read()
    },
    readEnded() {
      lastEnd = clock.now()
    },
    warn(on) {
      if (on === warning) return
      warning = on
      cancel?.()
      cancel = null
      if (!on) return
      startedAt = clock.now()
      step = 0
      schedule()
    },
  }
}
