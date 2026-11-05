import { readJsonFile, writeJsonAtomic } from './json-file'

export const MAX_UI_BYTES = 1_000_000

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

// Open ui-state.json. The data is null when the file is missing or damaged.
// The renderer checks all values and then saves a good file.
// If the file cannot be read, saving is off.
// Then Bifrost cannot write over a file that it did not read.
export async function openUiStore(
  file: string,
  log: (message: string, error: unknown) => void = console.error,
): Promise<{ data: unknown; save(data: unknown): Promise<void> }> {
  try {
    const result = await readJsonFile(file)
    return {
      data: result.ok ? result.data : null,
      save: async data => {
        if (!isPlainObject(data)) throw new Error('refused: the UI state must be an object')
        if (JSON.stringify(data).length > MAX_UI_BYTES) {
          throw new Error('refused: the UI state is too large')
        }
        await writeJsonAtomic(file, data)
      },
    }
  } catch (error) {
    log(`Bifrost cannot read ${file}. Bifrost uses the default layout and does not save.`, error)
    return { data: null, save: async () => {} }
  }
}
