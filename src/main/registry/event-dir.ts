import { readdir, readFile, stat, unlink } from 'node:fs/promises'
import { join } from 'node:path'
import { type HookEvent, parseHookEvent } from './hook-event'

// Read all event files, oldest first, and delete them.
// The hook names a file with PIDs and no time, so the order comes from mtimeMs.
// A file that is empty or not valid is deleted and counts as one error.
// A missing directory gives no events and no errors.
export async function drainEventDir(dir: string): Promise<{ events: HookEvent[]; errors: number }> {
  let names: string[]
  try {
    names = await readdir(dir)
  } catch {
    return { errors: 0, events: [] }
  }
  const files: { name: string; mtimeMs: number }[] = []
  for (const name of names) {
    if (name.startsWith('.') || !name.endsWith('.json')) continue
    try {
      files.push({ mtimeMs: (await stat(join(dir, name))).mtimeMs, name })
    } catch {
      // Another process removed the file. Skip it.
    }
  }
  files.sort((a, b) => a.mtimeMs - b.mtimeMs || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))
  const events: HookEvent[] = []
  let errors = 0
  for (const file of files) {
    const path = join(dir, file.name)
    let event: HookEvent | null = null
    try {
      event = parseHookEvent(await readFile(path, 'utf8'), file.mtimeMs)
    } catch {
      event = null
    }
    if (event) events.push(event)
    else errors++
    await unlink(path).catch(() => {})
  }
  return { errors, events }
}
