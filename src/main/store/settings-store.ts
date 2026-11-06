import { applyPatch, parseSettings, type Settings, type SettingsPatch } from '../../shared/settings'
import { readJsonFile, writeJsonAtomic } from './json-file'

type ChangeListener = (settings: Settings, prev: Settings) => void

export interface SettingsStore {
  // The current settings. Do not change the object.
  get(): Settings
  // Apply a patch. This rejects with the reason of applyPatch, or with a write error.
  // A patch that changes nothing resolves with the same object and does not write.
  update(patch: unknown): Promise<Settings>
  // Apply the patch that fn gives for the newest settings. fn runs in the queue, after the
  // earlier updates. So two quick changes never start from the same old value.
  change(fn: (settings: Settings) => SettingsPatch): Promise<Settings>
  // The returned function removes only this listener.
  onChange(cb: (settings: Settings, prev: Settings) => void): () => void
}

// Open settings.json (the M2 pattern of openUiStore).
// A missing file or bad JSON gives the defaults, and a save works.
// A bad value in the file gives its default. The other values stay.
// If the file cannot be read, the store uses the defaults and does not save.
// Then Bifrost cannot write over a file that it did not read.
// Updates run one after the other, in the order of the calls.
export async function openSettingsStore(
  file: string,
  log: (message: string, error?: unknown) => void = console.error,
): Promise<SettingsStore> {
  let current: Settings
  let canSave = true
  try {
    const result = await readJsonFile(file)
    current = parseSettings(result.ok ? result.data : null)
  } catch (error) {
    log(`Bifrost cannot read ${file}. Bifrost uses the default settings and does not save.`, error)
    current = parseSettings(null)
    canSave = false
  }
  const listeners = new Set<ChangeListener>()
  let queue: Promise<unknown> = Promise.resolve()

  // Apply the patch to the newest settings. Write, then tell each listener.
  const run = async (patch: unknown): Promise<Settings> => {
    const result = applyPatch(current, patch)
    if (!result.ok) throw new Error(result.reason)
    if (result.settings === current) return current
    if (canSave) await writeJsonAtomic(file, result.settings)
    const prev = current
    current = result.settings
    for (const cb of [...listeners]) {
      // A failed listener must not stop the other listeners.
      try {
        cb(current, prev)
      } catch (error) {
        log('A settings listener failed.', error)
      }
    }
    return current
  }

  return {
    change: fn => {
      const next = queue.then(() => run(fn(current)))
      queue = next.catch(() => {})
      return next
    },
    get: () => current,
    onChange: cb => {
      // Each call adds its own entry. So two calls with the same function stay separate.
      const entry: ChangeListener = (settings, prev) => cb(settings, prev)
      listeners.add(entry)
      return () => {
        listeners.delete(entry)
      }
    },
    update: patch => {
      const next = queue.then(() => run(patch))
      queue = next.catch(() => {})
      return next
    },
  }
}
