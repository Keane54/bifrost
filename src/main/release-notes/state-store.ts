// The last seen version of What's new, in userData/release-notes.json. The file keeps it across
// restarts. So What's new opens only one time for each version.
import { join } from 'node:path'
import { readJsonFile, writeJsonAtomic } from '../store/json-file'

export interface ReleaseNotesState {
  lastSeenVersion: string | null
}

export interface ReleaseNotesStore {
  // The newest value.
  get(): ReleaseNotesState
  // Set the value at once and write the file. This promise never rejects. A failed write goes to
  // the log, and the new value stays in memory.
  set(next: ReleaseNotesState): Promise<void>
}

export function releaseNotesFile(userData: string): string {
  return join(userData, 'release-notes.json')
}

// A value that is not a text gives null ("no version stored").
export function parseReleaseNotesState(data: unknown): ReleaseNotesState {
  if (typeof data !== 'object' || data === null || Array.isArray(data)) {
    return { lastSeenVersion: null }
  }
  const value = (data as Record<string, unknown>).lastSeenVersion
  return { lastSeenVersion: typeof value === 'string' ? value : null }
}

// Open the state file.
// A missing file or a file that is not valid JSON gives no stored version.
// A file that cannot be read gives no stored version, and the store does not save. So it cannot
// write over a file that it did not read.
export async function openReleaseNotesStore(
  file: string,
  log: (message: string, error: unknown) => void = console.error,
): Promise<ReleaseNotesStore> {
  let current: ReleaseNotesState = { lastSeenVersion: null }
  let canSave = true
  try {
    const read = await readJsonFile(file)
    if (read.ok) current = parseReleaseNotesState(read.data)
  } catch (error) {
    canSave = false
    log(`Bifrost cannot read ${file}. What's new uses an empty state and does not save.`, error)
  }
  // Each write waits for the write before it, so the last set wins on disk.
  let queue: Promise<void> = Promise.resolve()
  return {
    get: () => current,
    set(next) {
      current = { ...next }
      const value = current
      queue = queue.then(async () => {
        if (!canSave) return
        try {
          await writeJsonAtomic(file, value)
        } catch (error) {
          log(`Bifrost cannot save ${file}.`, error)
        }
      })
      return queue
    },
  }
}
