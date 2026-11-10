// The update log. The updater writes one line for each step to updater.log in the logs folder.
// When the file reaches LOG_MAX_BYTES, it moves to updater.old.log and a new file starts.
// A write error never reaches the caller, because the log must not stop an update.
import { join } from 'node:path'

export const LOG_NAME = 'updater.log'
export const OLD_LOG_NAME = 'updater.old.log'
export const LOG_MAX_BYTES = 1_000_000

export interface UpdateLog {
  line(text: string): Promise<void>
  path: string
}

// The file functions of node:fs/promises that the log uses. Tests pass fakes.
export interface UpdateLogDeps {
  // Milliseconds since the epoch (Date.now in the app).
  now(): number
  appendFile(path: string, text: string): Promise<void>
  // stat throws when the file does not exist.
  stat(path: string): Promise<{ size: number }>
  rename(from: string, to: string): Promise<void>
  mkdir(path: string, options: { recursive: true }): Promise<unknown>
}

export function createUpdateLog(dir: string, deps: UpdateLogDeps): UpdateLog {
  const path = join(dir, LOG_NAME)
  let queue: Promise<void> = Promise.resolve()
  let reported = false

  async function write(text: string): Promise<void> {
    try {
      await deps.mkdir(dir, { recursive: true })
      const size = await deps.stat(path).then(
        s => s.size,
        () => 0,
      )
      if (size >= LOG_MAX_BYTES) await deps.rename(path, join(dir, OLD_LOG_NAME))
      await deps.appendFile(path, `${new Date(deps.now()).toISOString()} ${text}\n`)
    } catch (error) {
      // Report the first error only. The same fault would repeat on each line.
      if (!reported) {
        reported = true
        console.error('The update log cannot write.', error)
      }
    }
  }

  return {
    line(text) {
      // Each write waits for the write before it. write never rejects.
      queue = queue.then(() => write(text))
      return queue
    },
    path,
  }
}
