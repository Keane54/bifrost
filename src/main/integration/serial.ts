// The message of the Error for a call that comes while another call runs.
export const BUSY_MESSAGE = 'Another integration action runs now.'

export interface SerialRunner {
  run<T>(fn: () => Promise<T>): Promise<T>
}

// Run one integration action at a time.
// Two actions at the same time could both change the settings file of the user.
// They could also get the same backup name. So a call that comes during a call rejects.
export function createSerialRunner(): SerialRunner {
  let busy = false
  return {
    async run<T>(fn: () => Promise<T>): Promise<T> {
      if (busy) throw new Error(BUSY_MESSAGE)
      busy = true
      try {
        return await fn()
      } finally {
        busy = false
      }
    },
  }
}
