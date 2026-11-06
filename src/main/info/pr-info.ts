// The pull request of a session, from the GitHub CLI (gh). gh runs in the folder of the session.
import type { PrInfo } from '../../shared/types'
import type { ExecFn, ExecResult } from '../claude/cli'

// A result stays this long for one folder and one branch.
// A good answer is a PR or none. none is a good answer: the branch has no PR.
export const PR_CACHE_MS = 300_000
// A failed check (unavailable) stays a short time, so a fix shows soon and gh is not called again
// at once.
export const PR_FAIL_CACHE_MS = 30_000
export const GH_TIMEOUT_MS = 10_000
export const GH_ARGS = ['pr', 'view', '--json', 'number,title,url,state']

const REASON_NOT_INSTALLED = "GitHub CLI (gh) isn't installed."
const REASON_TIMEOUT = "GitHub CLI (gh) didn't answer within 10 seconds."
const REASON_FAILED = "GitHub CLI (gh) couldn't check for a PR."
const REASON_NO_FOLDER = "The session folder isn't there any more."
const REASON_MAX = 200

function unavailable(reason: string): PrInfo {
  return { kind: 'unavailable', reason }
}

// Read the JSON of gh. Give null when a value is missing or has the wrong type.
function readPr(stdout: string): PrInfo | null {
  let data: unknown
  try {
    data = JSON.parse(stdout)
  } catch {
    return null
  }
  if (typeof data !== 'object' || data === null) return null
  const { number, state, title, url } = data as Record<string, unknown>
  if (typeof number !== 'number' || !Number.isInteger(number)) return null
  if (typeof url !== 'string' || !url.startsWith('https://')) return null
  if (typeof title !== 'string' || typeof state !== 'string') return null
  return { kind: 'pr', number, state, title, url }
}

export function parsePrView(result: ExecResult): PrInfo {
  if (result.code === 0 && !result.timedOut) {
    const pr = readPr(result.stdout)
    if (pr) return pr
  }
  if (/no pull requests found/i.test(result.stderr)) return { kind: 'none' }
  if (result.timedOut) return unavailable(REASON_TIMEOUT)
  if (result.stderr.includes('ENOENT')) return unavailable(REASON_NOT_INSTALLED)
  const line = result.stderr.trim().split('\n')[0]?.trim().slice(0, REASON_MAX)
  return unavailable(line ? line : REASON_FAILED)
}

export interface PrLookupDeps {
  exec: ExecFn
  // The env for gh. Node finds gh through the PATH of this env.
  env(): Promise<Record<string, string>>
  now(): number
  // True when the folder exists. A spawn in a missing folder also gives ENOENT.
  exists(dir: string): boolean | Promise<boolean>
}

export interface PrLookup {
  lookup(cwd: string, branch: string | undefined): Promise<PrInfo>
  // The URL of the cached PR of the folder and the branch, or null.
  url(cwd: string, branch: string | undefined): string | null
}

interface Entry {
  at: number
  result: PrInfo
}

export function createPrLookup(deps: PrLookupDeps): PrLookup {
  const cache = new Map<string, Entry>()
  const running = new Map<string, Promise<PrInfo>>()
  const keyOf = (cwd: string, branch: string): string => `${cwd}\0${branch}`

  const young = (entry: Entry, now: number): boolean =>
    now - entry.at < (entry.result.kind === 'unavailable' ? PR_FAIL_CACHE_MS : PR_CACHE_MS)

  const fresh = (key: string): Entry | undefined => {
    const entry = cache.get(key)
    return entry && young(entry, deps.now()) ? entry : undefined
  }

  async function run(key: string, cwd: string): Promise<PrInfo> {
    if (!(await deps.exists(cwd))) return unavailable(REASON_NO_FOLDER)
    const raw = await deps.exec('gh', GH_ARGS, {
      cwd,
      env: await deps.env(),
      timeoutMs: GH_TIMEOUT_MS,
    })
    // ENOENT also comes when the folder went away after the check. Check the folder again.
    const result =
      !raw.timedOut && raw.stderr.includes('ENOENT') && !(await deps.exists(cwd))
        ? unavailable(REASON_NO_FOLDER)
        : parsePrView(raw)
    const now = deps.now()
    // Forget old entries, so the cache does not grow.
    for (const [k, e] of cache) if (!young(e, now)) cache.delete(k)
    cache.set(key, { at: now, result })
    return result
  }

  return {
    lookup(cwd, branch) {
      if (!cwd.startsWith('/') || !branch) return Promise.resolve({ kind: 'none' })
      const key = keyOf(cwd, branch)
      const hit = fresh(key)
      if (hit) return Promise.resolve(hit.result)
      const same = running.get(key)
      if (same) return same
      const promise = run(key, cwd).finally(() => running.delete(key))
      running.set(key, promise)
      return promise
    },
    url(cwd, branch) {
      if (!branch) return null
      const result = fresh(keyOf(cwd, branch))?.result
      return result?.kind === 'pr' ? result.url : null
    },
  }
}
