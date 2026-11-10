// The state of the updater that must stay across restarts, in userData/updates.json.
// notifiedVersion is the last version that had its notification (sent or held back).
// attemptedVersion is the version that "Restart to update" tried to install.
import { readJsonFile, writeJsonAtomic } from '../store/json-file'

export interface UpdateStateData {
  notifiedVersion: string | null
  attemptedVersion: string | null
}

export const EMPTY_UPDATE_STATE: UpdateStateData = {
  attemptedVersion: null,
  notifiedVersion: null,
}

export interface UpdateStateStore {
  // The newest value.
  get(): UpdateStateData
  // Change the fields of the patch and write the file. This promise never rejects. A failed
  // write goes to the log, and the new value stays in memory.
  set(patch: Partial<UpdateStateData>): Promise<void>
}

function stringOrNull(value: unknown): string | null {
  return typeof value === 'string' ? value : null
}

function parse(data: unknown): UpdateStateData {
  if (typeof data !== 'object' || data === null || Array.isArray(data)) return EMPTY_UPDATE_STATE
  const record = data as Record<string, unknown>
  return {
    attemptedVersion: stringOrNull(record.attemptedVersion),
    notifiedVersion: stringOrNull(record.notifiedVersion),
  }
}

// Open the state file.
// A missing file or a file that is not valid JSON gives the empty state.
// A file that cannot be read gives the empty state, and the store does not save. So it cannot
// write over a file that it did not read.
export async function openUpdateStateStore(
  file: string,
  log: (message: string, error: unknown) => void = console.error,
): Promise<UpdateStateStore> {
  let current: UpdateStateData = { ...EMPTY_UPDATE_STATE }
  let canSave = true
  try {
    const read = await readJsonFile(file)
    if (read.ok) current = parse(read.data)
  } catch (error) {
    canSave = false
    log(`Bifrost cannot read ${file}. The updater uses an empty state and does not save.`, error)
  }
  // Each write waits for the write before it, so the last set wins on disk.
  let queue: Promise<void> = Promise.resolve()
  return {
    get: () => current,
    set(patch) {
      current = { ...current, ...patch }
      const next = current
      queue = queue.then(async () => {
        if (!canSave) return
        try {
          await writeJsonAtomic(file, next)
        } catch (error) {
          log(`Bifrost cannot save ${file}.`, error)
        }
      })
      return queue
    },
  }
}
