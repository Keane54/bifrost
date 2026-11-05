import { randomUUID } from 'node:crypto'
import { mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises'
import { dirname } from 'node:path'

// Write the data to a temporary name in the same directory. Then rename the file.
// So a crash during the write cannot leave a part of a file.
export async function writeJsonAtomic(file: string, data: unknown): Promise<void> {
  await mkdir(dirname(file), { recursive: true })
  const temporary = `${file}.${randomUUID()}.tmp`
  try {
    await writeFile(temporary, `${JSON.stringify(data, null, 2)}\n`, { flag: 'wx', mode: 0o600 })
    await rename(temporary, file)
  } catch (error) {
    await rm(temporary, { force: true })
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
