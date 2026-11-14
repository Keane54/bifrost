import { chmod, mkdir } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import {
  type ModuleManifest,
  PERMISSION_IDS,
  type PermissionId,
  parseManifest,
} from '../../shared/module-manifest'
import { MODEL_VALUES, type ModelChoice } from '../../shared/new-session'
import { isPlainObject } from '../../shared/plain-object'
import { readJsonFile, writeJsonAtomic } from '../store/json-file'

export type ModuleSource =
  | { kind: 'folder'; path: string }
  | { kind: 'git'; url: string }
  | { kind: 'dev'; path: string }

export interface ModuleEntry {
  source: ModuleSource
  // The approved manifest.
  manifest: ModuleManifest
  granted: PermissionId[]
  enabled: boolean
  model: ModelChoice
  dailyCap: number
  jobs: { day: string; count: number }
  hash: string
  pendingUpdate: { manifest: ModuleManifest; hash: string } | null
}

export interface ModulesState {
  modules: Record<string, ModuleEntry>
  // The ids of the sessions that Discuss with Claude started, the oldest first (ruling P12).
  // Heimdall hides these sessions from every module. Only Bifrost reads and changes this list.
  // No call of a module gives it or changes it.
  discussSessions?: string[]
}

// The most ids in discussSessions. Above it, the oldest id goes.
export const MAX_DISCUSS_SESSIONS = 200
const SESSION_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/

// The state with the id at the end of discussSessions. An id that is there already moves to the
// end. Above the cap, the oldest ids go.
export function withDiscussSession(state: ModulesState, sessionId: string): ModulesState {
  if (!SESSION_ID.test(sessionId)) return state
  const list = (state.discussSessions ?? []).filter(id => id !== sessionId)
  list.push(sessionId)
  return { ...state, discussSessions: list.slice(-MAX_DISCUSS_SESSIONS) }
}

// A hand-over gave a saved session a new id. The new id is saved too.
export function carriedDiscussSession(state: ModulesState, from: string, to: string): ModulesState {
  return state.discussSessions?.includes(from) ? withDiscussSession(state, to) : state
}

// The state without the id of a session that Bifrost forgot for good, so the list stays small.
// An id that is not in the list gives the same object, and the store does not need to write.
export function withoutDiscussSession(state: ModulesState, sessionId: string): ModulesState {
  const list = state.discussSessions ?? []
  if (!list.includes(sessionId)) return state
  return { ...state, discussSessions: list.filter(id => id !== sessionId) }
}

function parseDiscussSessions(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  const ids = value.filter((id): id is string => typeof id === 'string' && SESSION_ID.test(id))
  return [...new Set(ids)].slice(-MAX_DISCUSS_SESSIONS)
}

export function modulesStateFile(bifrostHome: string): string {
  return join(bifrostHome, 'modules', 'state.json')
}

export function moduleCodeDir(bifrostHome: string, id: string, slot: 'current' | 'next'): string {
  return join(bifrostHome, 'modules', id, slot)
}

export function moduleDataFile(bifrostHome: string, id: string): string {
  return join(bifrostHome, 'modules-data', `${id}.json`)
}

const HASH_PATTERN = /^[0-9a-f]{64}$/
const DAY_PATTERN = /^\d{4}-\d{2}-\d{2}$/

function parseSource(value: unknown): ModuleSource | null {
  if (!isPlainObject(value)) return null
  if (value.kind === 'git') {
    return typeof value.url === 'string' && value.url !== ''
      ? { kind: 'git', url: value.url }
      : null
  }
  if (value.kind === 'folder' || value.kind === 'dev') {
    return typeof value.path === 'string' && value.path !== ''
      ? { kind: value.kind, path: value.path }
      : null
  }
  return null
}

function manifestOf(value: unknown): ModuleManifest | null {
  const result = parseManifest(value)
  return result.ok ? result.manifest : null
}

function parseEntry(id: string, value: unknown): ModuleEntry | null {
  if (!isPlainObject(value)) return null
  const manifest = manifestOf(value.manifest)
  if (!manifest || manifest.id !== id) return null
  const source = parseSource(value.source)
  if (!source) return null
  if (typeof value.enabled !== 'boolean') return null
  if (typeof value.hash !== 'string' || !HASH_PATTERN.test(value.hash)) return null
  if (typeof value.model !== 'string' || !MODEL_VALUES.includes(value.model as ModelChoice)) {
    return null
  }
  const cap = value.dailyCap
  if (typeof cap !== 'number' || !Number.isInteger(cap) || cap < 1 || cap > 500) return null
  const jobs = value.jobs
  if (
    !isPlainObject(jobs) ||
    typeof jobs.day !== 'string' ||
    typeof jobs.count !== 'number' ||
    !Number.isInteger(jobs.count) ||
    jobs.count < 0
  ) {
    return null
  }
  const validDay = DAY_PATTERN.test(jobs.day)
  if (!Array.isArray(value.granted)) return null
  const requested = new Set<string>(manifest.permissions.map(p => p.id))
  const granted = value.granted.filter(
    (g): g is PermissionId =>
      typeof g === 'string' &&
      (PERMISSION_IDS as readonly string[]).includes(g) &&
      requested.has(g),
  )
  let pendingUpdate: ModuleEntry['pendingUpdate'] = null
  if (
    isPlainObject(value.pendingUpdate) &&
    typeof value.pendingUpdate.hash === 'string' &&
    HASH_PATTERN.test(value.pendingUpdate.hash)
  ) {
    const next = manifestOf(value.pendingUpdate.manifest)
    if (next && next.id === id) pendingUpdate = { hash: value.pendingUpdate.hash, manifest: next }
  }
  return {
    dailyCap: cap,
    enabled: value.enabled,
    granted: [...new Set(granted)],
    hash: value.hash,
    jobs: validDay ? { count: jobs.count, day: jobs.day } : { count: 0, day: '' },
    manifest,
    model: value.model as ModelChoice,
    pendingUpdate,
    source,
  }
}

// Keep each good entry and drop each bad entry.
// The packaged-app check for a dev source is not here.
export function parseModulesState(data: unknown): ModulesState {
  const modules: Record<string, ModuleEntry> = {}
  if (isPlainObject(data) && isPlainObject(data.modules)) {
    for (const [id, raw] of Object.entries(data.modules)) {
      const entry = parseEntry(id, raw)
      if (entry) modules[id] = entry
    }
  }
  const sessions = isPlainObject(data) ? parseDiscussSessions(data.discussSessions) : []
  return sessions.length > 0 ? { discussSessions: sessions, modules } : { modules }
}

export interface ModulesStateStore {
  // The newest value.
  get(): ModulesState
  // Run the function in a queue. Each call sees the result of the call before it.
  change(fn: (s: ModulesState) => ModulesState): Promise<ModulesState>
  // Call the listener after each change that completes. The returned function removes it.
  onChange(listener: (s: ModulesState) => void): () => void
}

// Open the modules state file.
// A missing file or a file that is not valid JSON gives the empty state.
// A file that cannot be read gives the empty state and Bifrost does not save,
// so it cannot write over a file that it did not read.
export async function openModulesStateStore(
  file: string,
  log: (message: string) => void = console.error,
): Promise<ModulesStateStore> {
  let current: ModulesState = { modules: {} }
  let canSave = true
  try {
    const read = await readJsonFile(file)
    if (read.ok) current = parseModulesState(read.data)
  } catch (error) {
    canSave = false
    log(`Bifrost cannot read ${file}. Modules use an empty state and do not save. ${error}`)
  }
  // The queue never rejects, so one failed call does not stop the next call.
  let queue: Promise<unknown> = Promise.resolve()
  const listeners = new Set<(s: ModulesState) => void>()
  // A listener that fails does not stop the change or the next listener.
  const tell = (next: ModulesState): void => {
    for (const listener of [...listeners]) {
      try {
        listener(next)
      } catch (error) {
        log(`A listener of the modules state failed. ${error}`)
      }
    }
  }
  return {
    change(fn) {
      const run = queue.then(async () => {
        const next = fn(current)
        if (canSave) {
          const folder = dirname(file)
          await mkdir(folder, { mode: 0o700, recursive: true })
          await chmod(folder, 0o700)
          await writeJsonAtomic(file, next)
        }
        current = next
        tell(next)
        return next
      })
      queue = run.catch(() => {})
      return run
    },
    get: () => current,
    onChange(listener) {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
  }
}
