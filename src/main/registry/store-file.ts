import { readFile } from 'node:fs/promises'
import { cleanAlias } from '../../shared/alias'
import { isRecord } from '../../shared/plain-object'
import { isPriority } from '../../shared/priority'
import type { DeferredDelete, Priority } from '../../shared/types'
import { isUuid } from '../../shared/uuid'
import { isWatchColour, OLD_WATCH_COLOURS } from '../../shared/watch'
import { worktreeRoot } from '../../shared/worktree'
import { SHORT_ID } from '../actions/claude-output'
import { writeJsonAtomic } from '../store/json-file'
import type { RegistryStore } from './registry'

function emptyStore(): RegistryStore {
  return {
    aliases: {},
    current: {},
    jobs: {},
    lastActive: [],
    names: {},
    priorities: {},
    started: [],
    watch: [],
    worktrees: [],
  }
}

// Read the registry store.
// A missing file or a file that is not valid JSON gives an empty store.
// A file without priorities (from M1) gives no priorities.
// A file without aliases (from before the local name) gives no local names.
// A local name that is not a valid, non-empty string is dropped. A valid name is trimmed.
// A file without current or jobs (from before the row ID) gives no current IDs and no short IDs.
// A current ID must be a UUID that is not its row ID. Two rows can have one current ID, because
// two processes can run one conversation.
// A short ID must have the form of a short ID.
// A file without lastActive (from M3) gives an empty list.
// A file without prSessions (from before the review sessions) gives no PR sessions.
// A file without watch (from M3) gives an empty watchlist.
// A watch entry with a bad colour, a bad ID or a repeated ID is dropped.
// A file without worktrees (from M3 or an early M4) gives no worktrees.
// A worktree entry needs a string ID and an absolute path that worktreeRoot accepts.
// An entry with a repeated ID is dropped.
// A file without deferred (from before the deferred delete) gives no deferred deletes. A deferred
// delete needs a non-empty ID, a short ID and a worktree root. An entry with a repeated ID is
// dropped. The job value is optional. A job value that is not a short ID is dropped.
// The function removes each value that has the wrong type.
// Other read errors, for example EACCES or EISDIR, reject.
export async function loadStore(file: string): Promise<RegistryStore> {
  let text: string
  try {
    text = await readFile(file, 'utf8')
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return emptyStore()
    throw error
  }
  let data: unknown
  try {
    data = JSON.parse(text)
  } catch {
    return emptyStore()
  }
  if (!isRecord(data)) return emptyStore()
  const names = isRecord(data.names)
    ? Object.fromEntries(
        Object.entries(data.names).filter((pair): pair is [string, string] => {
          return typeof pair[1] === 'string'
        }),
      )
    : {}
  const aliases: Record<string, string> = {}
  if (isRecord(data.aliases)) {
    for (const [id, value] of Object.entries(data.aliases)) {
      if (typeof value !== 'string') continue
      const clean = cleanAlias(value)
      if (clean.ok && clean.name !== '') aliases[id] = clean.name
    }
  }
  const current: Record<string, string> = {}
  if (isRecord(data.current)) {
    for (const [rowId, id] of Object.entries(data.current)) {
      if (isUuid(id) && id !== rowId) current[rowId] = id
    }
  }
  const jobs: Record<string, string> = {}
  if (isRecord(data.jobs)) {
    for (const [rowId, id] of Object.entries(data.jobs)) {
      if (typeof id === 'string' && SHORT_ID.test(id)) jobs[rowId] = id
    }
  }
  const started = Array.isArray(data.started)
    ? data.started.filter((id): id is string => typeof id === 'string')
    : []
  const priorities = isRecord(data.priorities)
    ? Object.fromEntries(
        Object.entries(data.priorities).filter((pair): pair is [string, Priority] => {
          return isPriority(pair[1])
        }),
      )
    : {}
  const lastActive = Array.isArray(data.lastActive)
    ? [...new Set(data.lastActive.filter((id): id is string => typeof id === 'string'))]
    : []
  const prSessions = Array.isArray(data.prSessions)
    ? [...new Set(data.prSessions.filter((id): id is string => typeof id === 'string'))]
    : []
  const prNames = Array.isArray(data.prNames)
    ? [...new Set(data.prNames.filter((id): id is string => typeof id === 'string'))]
    : []
  const seen = new Set<string>()
  const watch: RegistryStore['watch'] = []
  if (Array.isArray(data.watch)) {
    for (const entry of data.watch) {
      if (!isRecord(entry)) continue
      const { sessionId } = entry
      // An old colour name maps to a new colour before the check.
      const old =
        typeof entry.colour === 'string' && Object.hasOwn(OLD_WATCH_COLOURS, entry.colour)
          ? OLD_WATCH_COLOURS[entry.colour]
          : undefined
      const colour = isWatchColour(entry.colour) ? entry.colour : old
      if (typeof sessionId !== 'string' || colour === undefined || seen.has(sessionId)) continue
      seen.add(sessionId)
      watch.push({ colour, sessionId })
    }
  }
  const withWorktree = new Set<string>()
  const worktrees: RegistryStore['worktrees'] = []
  if (Array.isArray(data.worktrees)) {
    for (const entry of data.worktrees) {
      if (!isRecord(entry)) continue
      const { path, sessionId } = entry
      if (typeof sessionId !== 'string' || withWorktree.has(sessionId)) continue
      if (typeof path !== 'string' || worktreeRoot(path) === null) continue
      withWorktree.add(sessionId)
      worktrees.push({ path, sessionId })
    }
  }
  const deferred = deferredOf(data.deferred)
  const store: RegistryStore = {
    aliases,
    current,
    jobs,
    lastActive,
    names,
    priorities,
    started,
    watch,
    worktrees,
  }
  if (prSessions.length > 0) store.prSessions = prSessions
  if (prNames.length > 0) store.prNames = prNames
  if (deferred.length > 0) store.deferred = deferred
  return store
}

// The valid deferred deletes of the file, in the file order.
function deferredOf(value: unknown): DeferredDelete[] {
  if (!Array.isArray(value)) return []
  const ids = new Set<string>()
  const deferred: DeferredDelete[] = []
  for (const entry of value) {
    if (!isRecord(entry)) continue
    const { job, sessionId, shortId, worktree } = entry
    if (typeof sessionId !== 'string' || sessionId === '' || ids.has(sessionId)) continue
    if (typeof shortId !== 'string' || !SHORT_ID.test(shortId)) continue
    if (typeof worktree !== 'string' || worktreeRoot(worktree)?.worktree !== worktree) continue
    ids.add(sessionId)
    const kept: DeferredDelete = { sessionId, shortId, worktree }
    if (typeof job === 'string' && SHORT_ID.test(job)) kept.job = job
    deferred.push(kept)
  }
  return deferred
}

// Write the store to a temporary name in the same directory. Then rename the file.
// So a crash during the write cannot leave a part of a file.
// writeJsonAtomic does the work.
export async function saveStore(file: string, store: RegistryStore): Promise<void> {
  await writeJsonAtomic(file, store)
}

// Load the store for the registry service. Give the save function for the same file.
// If the store cannot be read, use an empty store and turn saving off.
// Then the service cannot write over a file that it did not read.
export async function openStore(
  file: string,
  log: (message: string, error: unknown) => void = console.error,
): Promise<{ store: RegistryStore; save: (store: RegistryStore) => Promise<void> }> {
  try {
    return { save: store => saveStore(file, store), store: await loadStore(file) }
  } catch (error) {
    log(`Bifrost cannot read ${file}. The registry uses an empty store and does not save.`, error)
    return { save: async () => {}, store: emptyStore() }
  }
}
