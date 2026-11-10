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
  await syncWith(source, dest, { rename, rm })
}

// Internal. The tests give fake file operations to this function.
export interface SyncOps {
  rename: (from: string, to: string) => Promise<void>
  rm: (path: string, opts: { force: true; recursive: true }) => Promise<void>
}

export async function syncWith(source: string, dest: string, ops: SyncOps): Promise<void> {
  if (await modFolderCurrent(source, dest)) return
  // Read all source files first. A missing file rejects before any change.
  const entries = await Promise.all(
    MOD_FILES.map(async file => ({ bytes: await readFile(join(source, file)), file })),
  )
  await writeFolder(dest, entries, ops)
}

// Write the files to a temporary folder. Then swap it with dest.
// A failure removes the temporary folder and leaves dest as it was.
export async function writeFolder(
  dest: string,
  entries: readonly { file: string; bytes: Buffer }[],
  ops: SyncOps,
): Promise<void> {
  const id = randomUUID()
  const tmp = `${dest}.${id}.tmp`
  const old = `${dest}.${id}.old`
  let moved = false
  try {
    await mkdir(dirname(dest), { mode: 0o700, recursive: true })
    await mkdir(tmp, { mode: 0o700 })
    for (const { bytes, file } of entries) {
      const target = join(tmp, file)
      await mkdir(dirname(target), { mode: 0o700, recursive: true })
      await writeFile(target, bytes, { mode: 0o600 })
    }
    try {
      await ops.rename(dest, old)
      moved = true
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== 'ENOENT') throw e
    }
    await ops.rename(tmp, dest)
  } catch (e) {
    // Put the old folder back when the last rename failed.
    let failure = e
    if (moved) {
      try {
        await ops.rename(old, dest)
      } catch {
        failure = new Error(
          `${(e as Error).message} The old folder is at ${old}. Move it back to ${dest}.`,
        )
      }
    }
    await ops.rm(tmp, { force: true, recursive: true }).catch(() => undefined)
    throw failure
  }
  // dest is current now. A failed removal of the old folder is not an error.
  if (moved) await ops.rm(old, { force: true, recursive: true }).catch(() => undefined)
}

// A missing folder is not an error.
export async function removeModFolder(dest: string): Promise<void> {
  await rm(dest, { force: true, recursive: true })
}
