import { chmod, mkdir } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { type DailyState, EMPTY_DAILY_STATE, parseDailyState } from '../../shared/daily-state'
import { readJsonFile, writeJsonAtomic } from '../store/json-file'

export interface DailyStateStore {
  // The newest value.
  get(): DailyState
  // Run the function in a queue. Each call sees the result of the call before it.
  change(fn: (s: DailyState) => DailyState): Promise<DailyState>
}

export function dailyStateFile(bifrostHome: string): string {
  return join(bifrostHome, 'daily-update', 'state.json')
}

// Open the day state file.
// A missing file or a file that is not valid JSON gives the empty state.
// A file that cannot be read gives the empty state and Bifrost does not save,
// so it cannot write over a file that it did not read.
export async function openDailyStateStore(
  file: string,
  log: (message: string) => void = console.error,
): Promise<DailyStateStore> {
  let current: DailyState = structuredClone(EMPTY_DAILY_STATE)
  let canSave = true
  try {
    const read = await readJsonFile(file)
    if (read.ok) current = parseDailyState(read.data)
  } catch (error) {
    canSave = false
    log(
      `Bifrost cannot read ${file}. The Daily update uses an empty state and does not save. ` +
        `${error}`,
    )
  }
  // The queue never rejects, so one failed call does not stop the next call.
  let queue: Promise<unknown> = Promise.resolve()
  return {
    change(fn) {
      const run = queue.then(async () => {
        const next = fn(current)
        if (canSave) {
          const folder = dirname(file)
          await mkdir(folder, { mode: 0o700, recursive: true })
          await chmod(folder, 0o700)
          await writeJsonAtomic(file, next)
        }
        current = next
        return next
      })
      queue = run.catch(() => {})
      return run
    },
    get: () => current,
  }
}
