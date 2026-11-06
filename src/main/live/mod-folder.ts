import { randomUUID } from 'node:crypto'
import { mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'

// The mod folder holds exactly these files. Bifrost copies no other file.
export const MOD_FILES = [
  '.claude-plugin/plugin.json',
  '.claude-plugin/marketplace.json',
  'hooks/hooks.json',
  'hooks/register.ts',
] as const

// In the packaged app, electron-builder unpacks resources/** next to app.asar.
export function modSourceDir(appPath: string): string {
  return join(appPath.replace(/app\.asar$/, 'app.asar.unpacked'), 'resources', 'live-mod')
}

// True only when each of the four files of dest has the same bytes as in source.
export async function modFolderCurrent(source: string, dest: string): Promise<boolean> {
  try {
    for (const file of MOD_FILES) {
      const [a, b] = await Promise.all([readFile(join(source, file)), readFile(join(dest, file))])
      if (!a.equals(b)) return false
    }
    return true
  } catch {
    return false
  }
}

// Copy the four files to a temporary folder. Then swap it with dest.
// A failure removes the temporary folder and leaves dest as it was.
export async function syncModFolder(source: string, dest: string): Promise<void> {
  if (await modFolderCurrent(source, dest)) return
  // Read all source files first. A missing file rejects before any change.
  const contents = await Promise.all(MOD_FILES.map(file => readFile(join(source, file))))
  const id = randomUUID()
  const tmp = `${dest}.${id}.tmp`
  const old = `${dest}.${id}.old`
  let moved = false
  try {
    await mkdir(dirname(dest), { mode: 0o700, recursive: true })
    await mkdir(tmp, { mode: 0o700 })
    for (const [i, file] of MOD_FILES.entries()) {
      const target = join(tmp, file)
      await mkdir(dirname(target), { mode: 0o700, recursive: true })
      await writeFile(target, contents[i], { mode: 0o600 })
    }
    try {
      await rename(dest, old)
      moved = true
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== 'ENOENT') throw e
    }
    await rename(tmp, dest)
  } catch (e) {
    // Put the old folder back when the last rename failed.
    if (moved) await rename(old, dest).catch(() => undefined)
    await rm(tmp, { force: true, recursive: true })
    throw e
  }
  if (moved) await rm(old, { force: true, recursive: true })
}

// A missing folder is not an error.
export async function removeModFolder(dest: string): Promise<void> {
  await rm(dest, { force: true, recursive: true })
}
