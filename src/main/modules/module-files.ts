import { createHash } from 'node:crypto'
import { constants } from 'node:fs'
import { lstat, mkdir, open, readdir, readFile, realpath, rm, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { parseManifest } from '../../shared/module-manifest'

export const MAX_FILE_BYTES = 5_000_000
export const MAX_MODULE_BYTES = 50_000_000
export const MAX_FILES = 2000

const MANIFEST_FILE = 'bifrost-module.json'

type Failure = { ok: false; reason: string }

interface Entry {
  relative: string
  size: number
}

class Refusal extends Error {}

// List the files of a folder. Skip names that start with a dot.
// Refuse a symbolic link and every other entry that is not a file or a folder.
async function listFiles(root: string, enforceLimits: boolean): Promise<Entry[]> {
  const files: Entry[] = []
  let total = 0
  let count = 0
  const rootInfo = await lstat(root)
  if (rootInfo.isSymbolicLink()) throw new Refusal('The module folder is a symbolic link.')
  async function walk(relative: string): Promise<void> {
    const names = await readdir(join(root, relative))
    for (const name of names.sort()) {
      if (name.startsWith('.')) continue
      const path = relative === '' ? name : `${relative}/${name}`
      const info = await lstat(join(root, path))
      if (info.isSymbolicLink()) throw new Refusal(`The module has a symbolic link: ${path}.`)
      if (enforceLimits) {
        count += 1
        if (count > MAX_FILES) throw new Refusal('The module has too many files.')
      }
      if (info.isDirectory()) {
        await walk(path)
        continue
      }
      if (!info.isFile()) {
        throw new Refusal(`The module has a file of a type that is not allowed: ${path}.`)
      }
      if (enforceLimits) {
        if (info.size > MAX_FILE_BYTES) throw new Refusal(`A file is too big: ${path}.`)
        total += info.size
        if (total > MAX_MODULE_BYTES) throw new Refusal('The module is too big.')
      }
      files.push({ relative: path, size: info.size })
    }
  }
  await walk('')
  return files
}

async function readManifest(dir: string): Promise<Failure | null> {
  let text: string
  try {
    text = await readFile(join(dir, MANIFEST_FILE), 'utf8')
  } catch {
    return { ok: false, reason: `The module has no ${MANIFEST_FILE} file.` }
  }
  let data: unknown
  try {
    data = JSON.parse(text)
  } catch {
    return { ok: false, reason: `The ${MANIFEST_FILE} file is not valid JSON.` }
  }
  const result = parseManifest(data)
  return result.ok ? null : result
}

// Hash the relative paths and the contents of all files in sorted order.
// Each part has a length in front, so two different trees cannot give the same input.
function addToHash(hash: ReturnType<typeof createHash>, relative: string, content: Buffer): void {
  const path = Buffer.from(relative)
  hash.update(`${path.length}:`).update(path).update(`${content.length}:`).update(content)
}

export async function hashModule(dir: string): Promise<string> {
  const hash = createHash('sha256')
  for (const file of await listFiles(dir, false)) {
    addToHash(hash, file.relative, await readFile(join(dir, file.relative)))
  }
  return hash.digest('hex')
}

// Read a source file. Refuse a symbolic link in the file or in a parent folder.
// O_NOFOLLOW makes the open fail for a link, so a swap after the walk is not followed.
async function readSource(from: string, realFrom: string, relative: string): Promise<Buffer> {
  const source = join(from, relative)
  const realParent = await realpath(dirname(source))
  if (realParent !== join(realFrom, dirname(relative)).replace(/\/\.$/, '')) {
    throw new Refusal(`The module has a symbolic link: ${relative}.`)
  }
  let handle: Awaited<ReturnType<typeof open>>
  try {
    handle = await open(source, constants.O_RDONLY | constants.O_NOFOLLOW)
  } catch {
    throw new Refusal(`The module has a symbolic link: ${relative}.`)
  }
  try {
    const info = await handle.stat()
    if (!info.isFile() || info.size > MAX_FILE_BYTES) {
      throw new Refusal(`A file is not allowed: ${relative}.`)
    }
    return await handle.readFile()
  } finally {
    await handle.close()
  }
}

// Copy a module folder. Check all limits before the first copy.
// The target folder must not exist. A failed copy removes the target folder.
export async function copyModule(
  from: string,
  to: string,
  // A step that runs after the walk and before the copy. Tests use it to change the source.
  options: { beforeCopy?: () => Promise<void> } = {},
): Promise<{ ok: true; hash: string } | Failure> {
  try {
    const files = await listFiles(from, true)
    const bad = await readManifest(from)
    if (bad) return bad
    try {
      await lstat(to)
      return { ok: false, reason: 'The target folder exists.' }
    } catch {
      // The target folder does not exist. This is the expected case.
    }
    await options.beforeCopy?.()
    const expected = createHash('sha256')
    try {
      await mkdir(to, { recursive: true })
      const realFrom = await realpath(from)
      for (const file of files) {
        const content = await readSource(from, realFrom, file.relative)
        addToHash(expected, file.relative, content)
        const target = join(to, file.relative)
        await mkdir(dirname(target), { recursive: true })
        await writeFile(target, content)
      }
      const actual = await hashModule(to)
      if (actual !== expected.digest('hex')) {
        throw new Refusal('The module changed while Bifrost copied it.')
      }
    } catch (error) {
      await rm(to, { force: true, recursive: true }).catch(() => {})
      throw error
    }
    return { hash: await hashModule(to), ok: true }
  } catch (error) {
    if (error instanceof Refusal) return { ok: false, reason: error.message }
    return { ok: false, reason: `Bifrost cannot copy the module: ${error}` }
  }
}
