// A rotating text log. It writes one line for each call to a file in a folder.
// When the file reaches ROTATING_LOG_MAX_BYTES, it moves to <name>.old.log and a new file starts.
// A write error never reaches the caller, because a log must not stop the code that writes it.
import { join } from 'node:path'

export const ROTATING_LOG_MAX_BYTES = 1_000_000

export interface RotatingLog {
  line(text: string): Promise<void>
  path: string
}

// The file functions of node:fs/promises that the log uses. Tests pass fakes.
export interface RotatingLogDeps {
  // Milliseconds since the epoch (Date.now in the app).
  now(): number
  appendFile(path: string, text: string): Promise<void>
  // stat throws when the file does not exist.
  stat(path: string): Promise<{ size: number }>
  rename(from: string, to: string): Promise<void>
  mkdir(path: string, options: { recursive: true }): Promise<unknown>
}

// The name of the old file. "health.log" gives "health.old.log".
function oldName(name: string): string {
  return name.endsWith('.log') ? `${name.slice(0, -4)}.old.log` : `${name}.old`
}

export function createRotatingLog(dir: string, name: string, deps: RotatingLogDeps): RotatingLog {
  const path = join(dir, name)
  let queue: Promise<void> = Promise.resolve()
  let reported = false

  async function write(text: string): Promise<void> {
    try {
      await deps.mkdir(dir, { recursive: true })
      const size = await deps.stat(path).then(
        s => s.size,
        () => 0,
      )
      if (size >= ROTATING_LOG_MAX_BYTES) await deps.rename(path, join(dir, oldName(name)))
      await deps.appendFile(path, `${new Date(deps.now()).toISOString()} ${text}\n`)
    } catch (error) {
      // Report the first error only. The same fault would repeat on each line.
      if (!reported) {
        reported = true
        console.error(`The log ${name} cannot write.`, error)
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
