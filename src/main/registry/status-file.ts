import { readdir, readFile, stat, unlink } from 'node:fs/promises'
import { join } from 'node:path'
import { UUID_PATTERN } from '../integration/scripts'

export interface StatusData {
  model?: string
  contextPercent?: number
  costUsd?: number
  sessionName?: string
  updatedAt: number
}

const UUID = new RegExp(UUID_PATTERN)

function obj(value: unknown): Record<string, unknown> {
  return typeof value === 'object' && value !== null ? (value as Record<string, unknown>) : {}
}

// Read the JSON that the status line wrapper saves for one session.
// Return null for bad JSON. A missing value stays out of the result.
export function parseStatusJson(input: string, updatedAt: number): StatusData | null {
  let data: unknown
  try {
    data = JSON.parse(input)
  } catch {
    return null
  }
  if (typeof data !== 'object' || data === null) return null
  const raw = data as Record<string, unknown>
  const model = obj(raw.model).display_name
  const percent = obj(raw.context_window).used_percentage
  const cost = obj(raw.cost).total_cost_usd
  const result: StatusData = { updatedAt }
  if (typeof model === 'string') result.model = model
  if (typeof percent === 'number') result.contextPercent = percent
  if (typeof cost === 'number') result.costUsd = cost
  if (typeof raw.session_name === 'string') result.sessionName = raw.session_name
  return result
}

// Read <sessionsDir>/<uuid>/status.json for each directory that has a UUID name.
// updatedAt is the mtime of the file. A file that cannot be read is skipped.
export async function readStatusFiles(sessionsDir: string): Promise<Map<string, StatusData>> {
  const map = new Map<string, StatusData>()
  let names: string[]
  try {
    names = await readdir(sessionsDir)
  } catch {
    return map
  }
  for (const name of names) {
    if (!UUID.test(name)) continue
    const path = join(sessionsDir, name, 'status.json')
    try {
      const [text, info] = await Promise.all([readFile(path, 'utf8'), stat(path)])
      const data = parseStatusJson(text, info.mtimeMs)
      if (data) map.set(name, data)
    } catch {
      // No file yet, or the file is not readable. Skip it.
    }
  }
  return map
}

// A temporary status file of the wrapper is this old only after a hard stop of the wrapper.
export const STATUS_TEMP_MAX_AGE_MS = 60_000

// Delete the temporary files (.status.*) of the wrapper that are older than maxAgeMs.
// A hard stop of the wrapper between the write and the move can leave such a file.
// Bifrost runs this at start. Return the number of deleted files. A missing directory gives 0.
export async function cleanStatusTemps(
  sessionsDir: string,
  now: number,
  maxAgeMs: number,
): Promise<number> {
  let sessions: string[]
  try {
    sessions = await readdir(sessionsDir)
  } catch {
    return 0
  }
  let deleted = 0
  for (const session of sessions) {
    if (!UUID.test(session)) continue
    const dir = join(sessionsDir, session)
    let names: string[]
    try {
      names = await readdir(dir)
    } catch {
      continue
    }
    for (const name of names) {
      if (!name.startsWith('.status.')) continue
      const path = join(dir, name)
      try {
        if (now - (await stat(path)).mtimeMs <= maxAgeMs) continue
        await unlink(path)
        deleted++
      } catch {
        // Another process removed the file. Skip it.
      }
    }
  }
  return deleted
}
