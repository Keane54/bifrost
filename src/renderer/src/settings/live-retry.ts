// The re-read of the Live details status while a warning shows. The first read at the start of
// the app can give a short failure. Without a re-read, the side bar then shows a warning dot
// until Settings opens. Each read runs claude plugin list. So the re-read runs only while a
// warning shows, and no timer runs while there is no warning.

// The time between two re-reads while a warning shows.
export const RETRY_EVERY_MS = 60_000
// The minimum time from the last read to a re-read at a window focus.
export const FOCUS_GAP_MS = 10_000

// The clock of the page. A test gives the fake timers.
export interface RetryClock {
  now(): number
  // Call fn each ms milliseconds. The result stops the timer.
  every(ms: number, fn: () => void): () => void
}

export interface LiveRetryDeps {
  // True while a Live details action runs. Then a re-read does nothing.
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
  // Give the warning state. A new warning starts the timer. No warning stops it.
  warn(on: boolean): void
  // The window got the focus. Read again when a warning shows and the last read is 10 s old or
  // older.
  focus(): void
}

export function createLiveRetry(deps: LiveRetryDeps): LiveRetry {
  const { clock } = deps
  // The function that stops the timer, or null while there is no warning.
  let stop: (() => void) | null = null
  // The time of the last read. A read gives each new warning, so a new warning sets it too.
  let last = 0
  // True while a re-read runs. Then a second re-read does not start.
  let reading = false

  async function read(): Promise<void> {
    if (reading || deps.busy()) return
    reading = true
    last = clock.now()
    try {
      await Promise.all([deps.readStatus(), deps.versionFailed() ? deps.readVersion() : null])
    } finally {
      reading = false
    }
  }

  return {
    focus() {
      if (stop === null || clock.now() - last < FOCUS_GAP_MS) return
      void read()
    },
    warn(on) {
      if (on === (stop !== null)) return
      if (stop !== null) {
        stop()
        stop = null
        return
      }
      last = clock.now()
      stop = clock.every(RETRY_EVERY_MS, () => void read())
    },
  }
}
