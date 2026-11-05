import { readJsonFile, writeJsonAtomic } from './json-file'

export const MAX_UI_BYTES = 1_000_000

function isPlainObject(value: unknown): value is Record<string, unknown> {
  if (typeof value !== 'object' || value === null) return false
  const proto = Object.getPrototypeOf(value)
  return proto === Object.prototype || proto === null
}

// Open ui-state.json. load() gives null when the file is missing or damaged.
// After a good save, load() gives the saved value.
// The renderer checks all values and then saves a good file.
// Saves run one after the other, in the order of the calls.
// If the file cannot be read, saving is off.
// Then Bifrost cannot write over a file that it did not read.
export async function openUiStore(
  file: string,
  log: (message: string, error: unknown) => void = console.error,
): Promise<{ load(): unknown; save(data: unknown): Promise<void> }> {
  try {
    const result = await readJsonFile(file)
    let current: unknown = result.ok ? result.data : null
    let queue: Promise<void> = Promise.resolve()
    return {
      load: () => current,
      save: data => {
        if (!isPlainObject(data))
          return Promise.reject(new Error('refused: the UI state must be an object'))
        if (Buffer.byteLength(JSON.stringify(data)) > MAX_UI_BYTES) {
          return Promise.reject(new Error('refused: the UI state is too large'))
        }
        const run = queue.then(async () => {
          await writeJsonAtomic(file, data)
          current = data
        })
        queue = run.catch(() => {})
        return run
      },
    }
  } catch (error) {
    log(`Bifrost cannot read ${file}. Bifrost uses the default layout and does not save.`, error)
    return { load: () => null, save: async () => {} }
  }
}
