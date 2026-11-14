// Heimdall's call check (Modules design 8). A module frame sends a call through the bridge of the
// renderer. Heimdall checks each call in the main process: the module must be on, under the caps,
// and have the permission of the call. The input must have the right form. Each value that goes
// back to a module passes the secret filter.

import type { PermissionId } from '../../shared/module-manifest'
import {
  jsonBytes,
  MODULE_IN_FLIGHT,
  MODULE_MESSAGE_BYTES,
  MODULE_RATE,
  REFUSED_BAD_MODULE_INPUT,
  REFUSED_CALL_FAILED,
  REFUSED_MESSAGE_TOO_LARGE,
  REFUSED_MODULE_OFF,
  REFUSED_NOT_ALLOWED,
  REFUSED_STORAGE_FULL,
  REFUSED_TOO_MANY_CALLS,
  REFUSED_UNKNOWN_CALL,
} from '../../shared/modules'
import { isPlainObject } from '../../shared/plain-object'
import type {
  AccountUsage,
  PrInfo,
  RateWindow,
  ServiceStatus,
  SessionRow,
  UsageSnapshot,
} from '../../shared/types'
import { usageSource } from '../../shared/usage'
import type { ModuleDataStore } from './module-data'
import type { ModuleEntry, ModulesState } from './module-state'
import { filterSecrets, filterSecretValue } from './secret-filter'

export { MODULE_IN_FLIGHT, MODULE_MESSAGE_BYTES, MODULE_RATE } from '../../shared/modules'

// The most notifications of one module in one minute.
export const NOTIFY_PER_MINUTE = 10
// The most storage sets of one module in one second. The file write of the store is slow work,
// so this cap is lower than the cap of all calls.
export const STORAGE_SETS_PER_SECOND = 10
// The most PR lookups at the same time for module calls. Each lookup can run gh.
export const PR_LOOKUPS = 4
// After an unavailable result, module calls look up the PR of that branch again only after this
// time.
export const PR_RETRY_MS = 5 * 60_000
const RATE_WINDOW_MS = 1000
const NOTIFY_WINDOW_MS = 60_000
// The deepest nesting of objects and arrays in the input of a call.
const MAX_DEPTH = 32
const STORAGE_KEY = /^[a-z0-9._-]{1,64}$/
const EVENT_NAME = /^[a-z][a-z0-9.-]{0,39}$/
const MAX_TITLE = 80
const MAX_BODY = 300

// The usage values that usage.get chooses from.
export interface UsageParts {
  snapshot: UsageSnapshot | null
  account: AccountUsage | null
}

// A Bifrost notification for a module.
export interface ModuleNotice {
  moduleId: string
  moduleName: string
  title: string
  body: string
}

export interface HeimdallDeps {
  // The newest modules state. Heimdall reads it at each call.
  state(): ModulesState
  // False in a packaged app. Then a dev module counts as off.
  devAllowed: boolean
  store: ModuleDataStore
  notify(notice: ModuleNotice): void
  sessions: {
    rows(): readonly SessionRow[]
    // The PR of the branch of the session (the PR lookup of the Info panel, with its cache).
    pr(row: SessionRow): Promise<PrInfo>
  }
  usage(): UsageParts | Promise<UsageParts>
  serviceStatus(): readonly ServiceStatus[] | Promise<readonly ServiceStatus[]>
  // The module jobs (plan Task 7, jobs.ts). Without it, claude.job is an unknown call.
  jobs?: { run(moduleId: string, req: unknown): Promise<unknown> }
  // Discuss with Claude (plan Task 10). Without it, discuss.request is an unknown call.
  // sessions.list hides each session that Discuss started, from every module (ruling P12). The
  // modules state also saves these sessions.
  discuss?: {
    request(moduleId: string, req: unknown): Promise<unknown>
    isDiscussSession?(sessionId: string): boolean
  }
  // Send an event to the frames of the module.
  emit(moduleId: string, event: string, data: unknown): void
  now(): number
  // The log of the main process. An error of a part goes here, never to the module.
  log?: (message: string) => void
}

export interface Heimdall {
  // Run a call of a module. This rejects with a "refused: ..." code.
  call(moduleId: string, name: string, args: unknown): Promise<unknown>
  // Send an event to a module that is on. Data that is not JSON or is too large is not sent.
  event(moduleId: string, name: string, data: unknown): void
}

interface CallContext {
  moduleId: string
  entry: ModuleEntry
}

interface CallDef {
  // null: the call needs no permission.
  permission: PermissionId | null
  run(ctx: CallContext, args: unknown): Promise<unknown> | unknown
}

function refuse(code: string): never {
  throw new Error(code)
}

// The arguments as an object with only the given keys and each required key.
function argsObject(
  args: unknown,
  keys: readonly string[],
  required: readonly string[],
): Record<string, unknown> {
  if (!isPlainObject(args)) refuse(REFUSED_BAD_MODULE_INPUT)
  const own = Object.keys(args)
  if (own.some(k => !keys.includes(k)) || required.some(k => !own.includes(k))) {
    refuse(REFUSED_BAD_MODULE_INPUT)
  }
  return args
}

// A call that takes no arguments accepts nothing, null or an empty object.
function noArgs(args: unknown): void {
  if (args === undefined || args === null) return
  if (isPlainObject(args) && Object.keys(args).length === 0) return
  refuse(REFUSED_BAD_MODULE_INPUT)
}

function storageKey(value: unknown): string {
  if (typeof value !== 'string' || !STORAGE_KEY.test(value)) refuse(REFUSED_BAD_MODULE_INPUT)
  return value
}

// True when the objects and arrays of the value nest max levels or less.
function depthOk(value: unknown, max: number): boolean {
  if (value === null || typeof value !== 'object') return true
  if (max === 0) return false
  const items = Array.isArray(value) ? value : Object.values(value)
  return items.every(item => depthOk(item, max - 1))
}

// Keep only the times in the window. Take a place when one is free.
function takePlace(times: number[], now: number, limit: number, windowMs: number): boolean {
  while (times.length > 0 && now - (times[0] as number) >= windowMs) times.shift()
  if (times.length >= limit) return false
  times.push(now)
  return true
}

// The entry of a module that is installed and on, or null. devAllowed is false in a packaged
// app. Then a dev module counts as off.
export function activeModule(
  state: ModulesState,
  moduleId: unknown,
  devAllowed: boolean,
): ModuleEntry | null {
  if (typeof moduleId !== 'string') return null
  const { modules } = state
  const entry = Object.hasOwn(modules, moduleId) ? modules[moduleId] : undefined
  if (entry?.enabled !== true) return null
  if (entry.source.kind === 'dev' && !devAllowed) return null
  return entry
}

function windowOf(w: RateWindow | undefined): { resetsAt: number; usedPercent: number } | null {
  return w ? { resetsAt: w.resetsAt, usedPercent: w.usedPercent } : null
}

export function createHeimdall(deps: HeimdallDeps): Heimdall {
  const log = deps.log ?? ((message: string) => console.error(message))
  const callTimes = new Map<string, number[]>()
  const notifyTimes = new Map<string, number[]>()
  const setTimes = new Map<string, number[]>()
  const inFlight = new Map<string, number>()
  // The PR lookups that run now, the calls that wait for a place, and the end of the wait after
  // an unavailable result for each folder and branch.
  let lookups = 0
  const lookupWaits: (() => void)[] = []
  const prDown = new Map<string, number>()

  const activeEntry = (moduleId: unknown): ModuleEntry | null =>
    activeModule(deps.state(), moduleId, deps.devAllowed)

  function timesOf(map: Map<string, number[]>, moduleId: string): number[] {
    let times = map.get(moduleId)
    if (!times) {
      times = []
      map.set(moduleId, times)
    }
    return times
  }

  async function limitedLookup(row: SessionRow): Promise<PrInfo> {
    while (lookups >= PR_LOOKUPS) await new Promise<void>(resolve => lookupWaits.push(resolve))
    lookups += 1
    try {
      return await deps.sessions.pr(row)
    } finally {
      lookups -= 1
      lookupWaits.shift()?.()
    }
  }

  // The https PR link of the session, or null. A failed lookup gives null, and the other rows
  // stay.
  async function prUrlOf(row: SessionRow): Promise<string | null> {
    if (!row.branch) return null
    const key = `${row.cwd}\0${row.branch}`
    const now = deps.now()
    const until = prDown.get(key)
    if (until !== undefined && now < until) return null
    const info = await limitedLookup(row).catch(() => null)
    if (info?.kind === 'unavailable') {
      for (const [k, end] of prDown) if (end <= now) prDown.delete(k)
      prDown.set(key, now + PR_RETRY_MS)
      return null
    }
    prDown.delete(key)
    return info?.kind === 'pr' && info.url.startsWith('https://') ? info.url : null
  }

  const calls = new Map<string, CallDef>()

  calls.set('storage.get', {
    permission: null,
    run: ({ moduleId }, args) => {
      const key = storageKey(argsObject(args, ['key'], ['key']).key)
      return deps.store.get(moduleId, key)
    },
  })

  calls.set('storage.set', {
    permission: null,
    run: async ({ moduleId }, args) => {
      const input = argsObject(args, ['key', 'value'], ['key', 'value'])
      const key = storageKey(input.key)
      if (input.value === undefined || !depthOk(input.value, MAX_DEPTH)) {
        refuse(REFUSED_BAD_MODULE_INPUT)
      }
      if (
        !takePlace(timesOf(setTimes, moduleId), deps.now(), STORAGE_SETS_PER_SECOND, RATE_WINDOW_MS)
      ) {
        refuse(REFUSED_TOO_MANY_CALLS)
      }
      // The JSON text of the value. null removes the key.
      const text = input.value === null ? null : JSON.stringify(input.value)
      if (!(await deps.store.set(moduleId, key, text))) refuse(REFUSED_STORAGE_FULL)
      return null
    },
  })

  calls.set('notify', {
    permission: 'notify',
    run: ({ entry, moduleId }, args) => {
      const input = argsObject(args, ['title', 'body'], ['title'])
      const { title } = input
      const body = input.body ?? ''
      if (typeof title !== 'string' || title.trim() === '' || title.length > MAX_TITLE) {
        refuse(REFUSED_BAD_MODULE_INPUT)
      }
      if (typeof body !== 'string' || body.length > MAX_BODY) refuse(REFUSED_BAD_MODULE_INPUT)
      const times = timesOf(notifyTimes, moduleId)
      if (!takePlace(times, deps.now(), NOTIFY_PER_MINUTE, NOTIFY_WINDOW_MS)) {
        refuse(REFUSED_TOO_MANY_CALLS)
      }
      deps.notify({ body, moduleId, moduleName: entry.manifest.name, title })
      return null
    },
  })

  calls.set('sessions.list', {
    permission: 'read-sessions',
    run: async (_ctx, args) => {
      noArgs(args)
      // A session that Discuss started stays hidden (ruling P12). The saved list of the modules
      // state holds the sessions of earlier runs. The Discuss part also knows a session at once,
      // before its save ends.
      const saved = new Set(deps.state().discussSessions ?? [])
      const hidden = (row: SessionRow): boolean =>
        saved.has(row.sessionId) || deps.discuss?.isDiscussSession?.(row.sessionId) === true
      return Promise.all(
        deps.sessions
          .rows()
          .filter(row => !hidden(row))
          .map(async row => ({
            branch: row.branch ?? null,
            folder: row.cwd,
            name: row.name,
            prUrl: await prUrlOf(row),
            state: row.state,
          })),
      )
    },
  })

  calls.set('usage.get', {
    permission: 'read-usage',
    run: async (_ctx, args) => {
      noArgs(args)
      const { account, snapshot } = await deps.usage()
      const source = usageSource(snapshot, deps.now(), account)
      if (source === null) return null
      return {
        fiveHour: windowOf(source.limits.fiveHour),
        sevenDay: windowOf(source.limits.sevenDay),
        source: source.kind,
        updatedAt: source.kind === 'account' ? source.account.fetchedAt : source.snapshot.updatedAt,
      }
    },
  })

  calls.set('serviceStatus.get', {
    permission: 'read-service-status',
    run: async (_ctx, args) => {
      noArgs(args)
      const list = await deps.serviceStatus()
      return list.map(s => ({
        checkedAt: s.checkedAt,
        id: s.id,
        incidents: s.incidents.map(i => ({
          impact: i.impact,
          name: i.name,
          startedAt: i.startedAt,
          status: i.status,
        })),
        level: s.level,
        name: s.name,
        since: s.since,
      }))
    },
  })

  const { discuss, jobs } = deps
  if (jobs) {
    // The input of a job leaves the Mac, so it passes the secret filter (ruling S-A6).
    calls.set('claude.job', {
      permission: 'claude-jobs',
      run: ({ moduleId }, args) => jobs.run(moduleId, filterSecretValue(args)),
    })
  }
  if (discuss) {
    calls.set('discuss.request', {
      permission: 'discuss',
      run: ({ moduleId }, args) => discuss.request(moduleId, args),
    })
  }

  // Each check before the first await runs at once, so a flood of calls cannot pass a cap
  // while earlier calls wait.
  async function call(moduleId: string, name: string, args: unknown): Promise<unknown> {
    const entry = activeEntry(moduleId)
    if (entry === null) refuse(REFUSED_MODULE_OFF)
    if (!takePlace(timesOf(callTimes, moduleId), deps.now(), MODULE_RATE, RATE_WINDOW_MS)) {
      refuse(REFUSED_TOO_MANY_CALLS)
    }
    const open = inFlight.get(moduleId) ?? 0
    if (open >= MODULE_IN_FLIGHT) refuse(REFUSED_TOO_MANY_CALLS)
    const bytes = jsonBytes(args)
    if (bytes === null) refuse(REFUSED_BAD_MODULE_INPUT)
    if (bytes > MODULE_MESSAGE_BYTES) refuse(REFUSED_MESSAGE_TOO_LARGE)
    if (!depthOk(args, MAX_DEPTH + 1)) refuse(REFUSED_BAD_MODULE_INPUT)
    const def = typeof name === 'string' ? calls.get(name) : undefined
    if (def === undefined) refuse(REFUSED_UNKNOWN_CALL)
    const { permission } = def
    if (permission !== null && !entry.granted.includes(permission)) refuse(REFUSED_NOT_ALLOWED)
    inFlight.set(moduleId, open + 1)
    try {
      const result = await def.run({ entry, moduleId }, args)
      // The user can turn the module off or remove the permission while the call runs.
      const now = activeEntry(moduleId)
      if (now === null) refuse(REFUSED_MODULE_OFF)
      if (permission !== null && !now.granted.includes(permission)) refuse(REFUSED_NOT_ALLOWED)
      const value = filterSecretValue(result)
      if ((jsonBytes(value) ?? Number.POSITIVE_INFINITY) > MODULE_MESSAGE_BYTES) {
        refuse(REFUSED_MESSAGE_TOO_LARGE)
      }
      return value
    } catch (error) {
      const message = error instanceof Error ? error.message : ''
      // A part gives a fixed code, but its text still passes the filter.
      if (message.startsWith('refused: ')) throw new Error(filterSecrets(message))
      // The error text can hold a token, so the log line also passes the filter.
      log(filterSecrets(`Heimdall: the ${name} call of the module ${moduleId} failed. ${error}`))
      throw new Error(REFUSED_CALL_FAILED)
    } finally {
      const left = (inFlight.get(moduleId) ?? 1) - 1
      if (left > 0) inFlight.set(moduleId, left)
      else inFlight.delete(moduleId)
    }
  }

  function event(moduleId: string, name: string, data: unknown): void {
    if (activeEntry(moduleId) === null) return
    if (typeof name !== 'string' || !EVENT_NAME.test(name)) return
    let value: unknown
    try {
      value = filterSecretValue(data)
    } catch {
      return
    }
    if ((jsonBytes(value) ?? Number.POSITIVE_INFINITY) > MODULE_MESSAGE_BYTES) return
    deps.emit(moduleId, name, value)
  }

  return { call, event }
}
