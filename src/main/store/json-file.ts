import { randomUUID } from 'node:crypto'
import { closeSync, fsyncSync, openSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import { mkdir, open, readFile, rename, rm } from 'node:fs/promises'
import { dirname } from 'node:path'

// Write the data to a temporary name in the same directory. Then rename the file.
// So a crash during the write cannot leave a part of a file.
// Sync the data to disk before the rename. So a power cut cannot leave an empty file.
export async function writeJsonAtomic(file: string, data: unknown): Promise<void> {
  await writeTextAtomic(file, `${JSON.stringify(data, null, 2)}\n`)
}

// Write the text as writeJsonAtomic does. The file gets the mode 0600.
export async function writeTextAtomic(file: string, text: string): Promise<void> {
  await mkdir(dirname(file), { recursive: true })
  const temporary = `${file}.${randomUUID()}.tmp`
  try {
    const handle = await open(temporary, 'wx', 0o600)
    try {
      await handle.writeFile(text)
      await handle.sync()
    } finally {
      await handle.close()
    }
    await rename(temporary, file)
  } catch (error) {
    // A failed clean-up must not hide the first error.
    await rm(temporary, { force: true }).catch(() => {})
    throw error
  }
}

// The same write with no wait, for the quit of the app. The folder must exist.
export function writeTextAtomicSync(file: string, text: string): void {
  const temporary = `${file}.${randomUUID()}.tmp`
  try {
    const fd = openSync(temporary, 'wx', 0o600)
    try {
      writeFileSync(fd, text)
      fsyncSync(fd)
    } finally {
      closeSync(fd)
    }
    renameSync(temporary, file)
  } catch (error) {
    rmSync(temporary, { force: true })
    throw error
  }
}

// Read and parse a JSON file.
// A missing file and a file that is not valid JSON give a result with ok false.
// Other read errors, for example EACCES or EISDIR, reject.
export async function readJsonFile(
  file: string,
): Promise<{ ok: true; data: unknown } | { ok: false; missing: boolean }> {
  let text: string
  try {
    text = await readFile(file, 'utf8')
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return { missing: true, ok: false }
    throw error
  }
  try {
    return { data: JSON.parse(text), ok: true }
  } catch {
    return { missing: false, ok: false }
  }
}
