import { randomUUID } from 'node:crypto'
import { mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises'
import { dirname } from 'node:path'
import type { RegistryStore } from './registry'

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

// Read the registry store.
// A missing file or a file that is not valid JSON gives an empty store.
// The function removes each value that has the wrong type.
// Other read errors, for example EACCES or EISDIR, reject.
export async function loadStore(file: string): Promise<RegistryStore> {
  let text: string
  try {
    text = await readFile(file, 'utf8')
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return { names: {}, started: [] }
    throw error
  }
  let data: unknown
  try {
    data = JSON.parse(text)
  } catch {
    return { names: {}, started: [] }
  }
  if (!isObject(data)) return { names: {}, started: [] }
  const names = isObject(data.names)
    ? Object.fromEntries(
        Object.entries(data.names).filter((pair): pair is [string, string] => {
          return typeof pair[1] === 'string'
        }),
      )
    : {}
  const started = Array.isArray(data.started)
    ? data.started.filter((id): id is string => typeof id === 'string')
    : []
  return { names, started }
}

// Write the store to a temporary name in the same directory. Then rename the file.
// So a crash during the write cannot leave a part of a file.
export async function saveStore(file: string, store: RegistryStore): Promise<void> {
  await mkdir(dirname(file), { recursive: true })
  const temporary = `${file}.${randomUUID()}.tmp`
  try {
    await writeFile(temporary, `${JSON.stringify(store, null, 2)}\n`, { flag: 'wx', mode: 0o600 })
    await rename(temporary, file)
  } catch (error) {
    await rm(temporary, { force: true })
    throw error
  }
}

// Load the store for the registry service. Give the save function for the same file.
// If the store cannot be read, use an empty store and turn saving off.
// Then the service cannot write over a file that it did not read.
export async function openStore(
  file: string,
  log: (message: string, error: unknown) => void = console.error,
): Promise<{ store: RegistryStore; save: (store: RegistryStore) => Promise<void> }> {
  try {
    return { save: store => saveStore(file, store), store: await loadStore(file) }
  } catch (error) {
    log(`Bifrost cannot read ${file}. The registry uses an empty store and does not save.`, error)
    return { save: async () => {}, store: { names: {}, started: [] } }
  }
}
