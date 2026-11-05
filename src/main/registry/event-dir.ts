import { readdir, readFile, stat, unlink } from 'node:fs/promises'
import { join } from 'node:path'
import { type HookEvent, parseHookEvent } from './hook-event'

// The hook writes the final file name with one cat. So a drain can find a file that is not complete.
// A file that does not parse and is younger than this time stays for the next drain.
export const PARTIAL_GRACE_MS = 5000

// Return true for the name of an event file. A name that starts with a dot is not an event file.
function isEventName(name: string): boolean {
  return !name.startsWith('.') && name.endsWith('.json')
}

// Read all event files, oldest first, and delete them.
// The hook names a file with PIDs and no time, so the order comes from mtimeMs.
// A file that does not parse and is younger than PARTIAL_GRACE_MS stays. It can be partial.
// An older file that does not parse is deleted and counts as one error. An empty file is the same.
// A missing directory gives no events and no errors.
// now must come from the same clock as the caller.
export async function drainEventDir(
  dir: string,
  now = Date.now(),
): Promise<{ events: HookEvent[]; errors: number }> {
  let names: string[]
  try {
    names = await readdir(dir)
  } catch {
    return { errors: 0, events: [] }
  }
  const files: { name: string; mtimeMs: number }[] = []
  for (const name of names) {
    if (!isEventName(name)) continue
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
    if (event) {
      events.push(event)
    } else if (now - file.mtimeMs < PARTIAL_GRACE_MS) {
      // The hook can still write this file. Read it again at the next drain.
      continue
    } else {
      errors++
    }
    await unlink(path).catch(() => {})
  }
  return { errors, events }
}

// Delete the event files that are older than maxAgeMs, without a parse.
// Also delete each temporary file (.tmp.*) of an older hook script.
// Bifrost runs this at start. The registry drops an event that is this old, so the read gives nothing.
// Return the number of deleted files. A missing directory gives 0.
export async function cleanEventDir(dir: string, now: number, maxAgeMs: number): Promise<number> {
  let names: string[]
  try {
    names = await readdir(dir)
  } catch {
    return 0
  }
  let deleted = 0
  for (const name of names) {
    const path = join(dir, name)
    if (!name.startsWith('.tmp.')) {
      if (!isEventName(name)) continue
      try {
        if (now - (await stat(path)).mtimeMs <= maxAgeMs) continue
      } catch {
        // Another process removed the file. Skip it.
        continue
      }
    }
    try {
      await unlink(path)
      deleted++
    } catch {
      // Another process removed the file, or it is a directory. Skip it.
    }
  }
  return deleted
}
