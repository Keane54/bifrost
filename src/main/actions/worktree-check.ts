// The check before a Delete (spec 9.1). A session in a worktree can have work that is not merged.
// All git commands only read. The renderer sends a session ID. The paths come from the row.
import type { SessionRow, WorktreeCheck } from '../../shared/types'
import { worktreeOf, worktreeRoot } from '../../shared/worktree'
import type { ExecFn } from '../claude/cli'
import { OPEN } from './actions'
import { failure } from './claude-output'
import { REFUSED_DELETE_EXTERNAL, REFUSED_UNKNOWN } from './session-actions'

export { worktreeRoot }

const GIT_TIMEOUT_MS = 5000
// A failed check tries one more time after this wait (Task 17 bug 5).
export const CHECK_RETRY_MS = 500
const OPEN_TIMEOUT_MS = 10_000
const REFUSED_NO_WORKTREE = 'refused: the session has no worktree'

export interface WorktreeActionDeps {
  rows(): SessionRow[]
  exec: ExecFn
}

export interface WorktreeActions {
  deleteCheck(sessionId: unknown): Promise<WorktreeCheck | null>
  openWorktree(sessionId: unknown): Promise<void>
}

// Run one git command. This gives the trimmed output, or null for any failure.
async function git(exec: ExecFn, args: string[]): Promise<string | null> {
  try {
    const result = await exec('git', args, { timeoutMs: GIT_TIMEOUT_MS })
    if (result.code !== 0 || result.timedOut === true) return null
    return result.stdout
  } catch {
    return null
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms))
}

// Count the changed files and the commits that are not merged. null means a command failed.
// A failed check tries one more time after CHECK_RETRY_MS. A git command of the session or an
// install in the worktree can make one check fail (Task 17 bug 5).
export async function checkWorktree(cwd: string, exec: ExecFn): Promise<WorktreeCheck | null> {
  const first = await countWork(cwd, exec)
  if (first !== null) return first
  await sleep(CHECK_RETRY_MS)
  return countWork(cwd, exec)
}

// One check. The base is the commit that the main checkout has now. It also works for a detached
// HEAD. git status gets --no-optional-locks, so it does not write the index.lock of the worktree.
async function countWork(cwd: string, exec: ExecFn): Promise<WorktreeCheck | null> {
  const root = worktreeRoot(cwd)
  if (!root) return { branch: null, changedFiles: 0, unmergedCommits: 0, worktree: null }
  const { worktree, repo } = root
  const status = await git(exec, ['--no-optional-locks', '-C', worktree, 'status', '--porcelain'])
  if (status === null) return null
  const head = await git(exec, ['-C', worktree, 'rev-parse', '--abbrev-ref', 'HEAD'])
  if (head === null) return null
  const base = (await git(exec, ['-C', repo, 'rev-parse', 'HEAD']))?.trim()
  if (!base) return null
  const count = (await git(exec, ['-C', worktree, 'rev-list', '--count', `${base}..HEAD`]))?.trim()
  if (count === undefined || !/^\d+$/.test(count)) return null
  const branch = head.trim()
  return {
    branch: branch === '' || branch === 'HEAD' ? null : branch,
    changedFiles: status.split('\n').filter(line => line.trim() !== '').length,
    unmergedCommits: Number(count),
    worktree,
  }
}

// The count of the changed files that git tracks in a worktree: the porcelain lines that do not
// start with "??". Untracked files do not count. null means a git failure. A failed read tries
// one more time after CHECK_RETRY_MS, as checkWorktree does. The Delete of a running worktree
// session uses this count before the stop (final review M3).
export async function trackedChanges(worktree: string, exec: ExecFn): Promise<number | null> {
  const read = async (): Promise<number | null> => {
    const status = await git(exec, ['--no-optional-locks', '-C', worktree, 'status', '--porcelain'])
    if (status === null) return null
    return status.split('\n').filter(line => line.trim() !== '' && !line.startsWith('??')).length
  }
  const first = await read()
  if (first !== null) return first
  await sleep(CHECK_RETRY_MS)
  return read()
}

// A commit ID from git rev-parse.
const COMMIT = /^[0-9a-f]{40}$/

// The check of a Delete after the stop: the counts and the HEAD commit of the worktree.
// The discard value of claude rm starts with the HEAD commit. null means that a git command
// failed, or that the folder is not in a worktree.
export async function checkWorktreeHead(
  worktree: string,
  exec: ExecFn,
): Promise<(WorktreeCheck & { head: string }) | null> {
  const check = await checkWorktree(worktree, exec)
  if (check === null || check.worktree === null) return null
  const head = (await git(exec, ['-C', check.worktree, 'rev-parse', 'HEAD']))?.trim()
  if (head === undefined || !COMMIT.test(head)) return null
  return { ...check, head }
}

export function createWorktreeActions(deps: WorktreeActionDeps): WorktreeActions {
  // The row of a Delete. An unknown session and an external session are refused.
  const find = (sessionId: unknown): SessionRow => {
    const row =
      typeof sessionId === 'string' ? deps.rows().find(r => r.sessionId === sessionId) : undefined
    if (!row) throw new Error(REFUSED_UNKNOWN)
    if (row.kind === 'external') throw new Error(REFUSED_DELETE_EXTERNAL)
    return row
  }

  return {
    // A stopped session reports its start folder as its cwd. Then the check uses the worktree
    // that Bifrost stored while the session ran.
    async deleteCheck(sessionId) {
      const row = find(sessionId)
      const dir = worktreeOf(row) ?? row.cwd
      if (dir === '') return null
      return checkWorktree(dir, deps.exec)
    },

    async openWorktree(sessionId) {
      const worktree = worktreeOf(find(sessionId))
      if (worktree === null) throw new Error(REFUSED_NO_WORKTREE)
      const result = await deps.exec(OPEN, [worktree], { timeoutMs: OPEN_TIMEOUT_MS })
      if (result.code !== 0) throw new Error(failure(result, 'open'))
    },
  }
}
