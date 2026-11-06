// BUSY_MESSAGE is the message of the Error for a call that comes while another call runs.
// The renderer shows it.
import { BUSY_MESSAGE } from '../../shared/live'

export interface SerialRunner {
  run<T>(fn: () => Promise<T>): Promise<T>
  // Run fn now with the lock. Each call of run that comes before fn ends waits for fn, also
  // when fn fails. Then that call runs with the usual rule.
  runFirst(fn: () => Promise<void>): Promise<void>
}

// Run one integration action at a time.
// Two actions at the same time could both change the settings file of the user.
// They could also get the same backup name. So a call that comes during a call rejects.
// The start of Live details goes through runFirst. An action that comes during the start waits
// for it and does not reject.
export function createSerialRunner(): SerialRunner {
  let busy = false
  // The call of runFirst. It never rejects.
  let first: Promise<unknown> = Promise.resolve()
  async function lock<T>(fn: () => Promise<T>): Promise<T> {
    if (busy) throw new Error(BUSY_MESSAGE)
    busy = true
    try {
      return await fn()
    } finally {
      busy = false
    }
  }
  return {
    async run<T>(fn: () => Promise<T>): Promise<T> {
      await first
      return lock(fn)
    },
    runFirst(fn) {
      const running = lock(fn)
      first = running.catch(() => {})
      return running
    },
  }
}
