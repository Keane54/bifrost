import { randomUUID } from 'node:crypto'
import { mkdir, open, readFile, rename, rm } from 'node:fs/promises'
import { dirname } from 'node:path'

// Write the data to a temporary name in the same directory. Then rename the file.
// So a crash during the write cannot leave a part of a file.
// Sync the data to disk before the rename. So a power cut cannot leave an empty file.
export async function writeJsonAtomic(file: string, data: unknown): Promise<void> {
  await mkdir(dirname(file), { recursive: true })
  const temporary = `${file}.${randomUUID()}.tmp`
  try {
    const handle = await open(temporary, 'wx', 0o600)
    try {
      await handle.writeFile(`${JSON.stringify(data, null, 2)}\n`)
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
