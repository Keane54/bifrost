import { chmod, mkdir } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { type HealthEvents, NO_HEALTH, reportSave } from '../performance/health-log'
import { readJsonFile, writeJsonAtomic } from '../store/json-file'
import { EMPTY_STATE, parseState, type ReviewsState } from './state'

export interface ReviewsStateStore {
  // The newest value.
  get(): ReviewsState
  // Run the function in a queue. Each call sees the result of the call before it.
  change(fn: (s: ReviewsState) => ReviewsState): Promise<ReviewsState>
}

export function reviewsStateFile(bifrostHome: string): string {
  return join(bifrostHome, 'reviews', 'state.json')
}

// Open the Reviews state file.
// A missing file or a file that is not valid JSON gives EMPTY_STATE.
// A file that cannot be read gives EMPTY_STATE and Bifrost does not save,
// so it cannot write over a file that it did not read.
// The health log gets the result of each write (P6).
export async function openReviewsStateStore(
  file: string,
  log: (message: string) => void = console.error,
  health: Pick<HealthEvents, 'save'> = NO_HEALTH,
): Promise<ReviewsStateStore> {
  let current: ReviewsState = structuredClone(EMPTY_STATE)
  let canSave = true
  try {
    const read = await readJsonFile(file)
    if (read.ok) current = parseState(read.data)
  } catch (error) {
    canSave = false
    log(`Bifrost cannot read ${file}. Reviews uses an empty state and does not save. ${error}`)
  }
  // The queue never rejects, so one failed call does not stop the next call.
  let queue: Promise<unknown> = Promise.resolve()
  return {
    change(fn) {
      const run = queue.then(async () => {
        const next = fn(current)
        if (canSave) {
          await reportSave(health, 'reviews-state', async () => {
            const folder = dirname(file)
            await mkdir(folder, { mode: 0o700, recursive: true })
            await chmod(folder, 0o700)
            await writeJsonAtomic(file, next)
          })
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
