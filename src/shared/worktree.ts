import type { SessionRow } from './types'

// The worktree of a session. Claude Code makes it in <repo>/.claude/worktrees/<name>.
const MARK = '/.claude/worktrees/'

// The worktree root and the repo of a cwd. A cwd in a subfolder gives the same root.
// A cwd outside .claude/worktrees/<name> gives null.
// A relative path, a '.' or '..' segment and an empty repo part also give null.
export function worktreeRoot(cwd: string): { worktree: string; repo: string } | null {
  if (!cwd.startsWith('/')) return null
  if (cwd.split('/').some(part => part === '.' || part === '..')) return null
  const at = cwd.indexOf(MARK)
  if (at <= 0) return null
  const rest = cwd.slice(at + MARK.length)
  const name = rest.split('/')[0]
  if (name === '') return null
  return { repo: cwd.slice(0, at), worktree: cwd.slice(0, at + MARK.length) + name }
}

// The worktree root of a row: from its cwd, else from the worktree that Bifrost stored while the
// session ran. A stopped session reports its start folder as its cwd (M4 controller check).
// A stored path that worktreeRoot refuses gives null.
export function worktreeOf(row: { cwd: string; worktree?: string }): string | null {
  const root =
    worktreeRoot(row.cwd) ?? (row.worktree === undefined ? null : worktreeRoot(row.worktree))
  return root?.worktree ?? null
}

// The row that runs in the worktree of a parked row, else undefined (spec 8).
// claude rm can remove a clean worktree when its session is stopped, also while another session
// uses that folder. So Delete of a parked row is blocked while such a row exists.
// Only a parked row can be blocked, and only a row that is not parked can block. So two parked
// rows never block each other. A plain folder never blocks. The row itself never counts.
export function folderUser<T extends Pick<SessionRow, 'sessionId' | 'state' | 'cwd' | 'worktree'>>(
  row: T,
  rows: readonly T[],
): T | undefined {
  if (row.state !== 'parked') return undefined
  const root = worktreeOf(row)
  if (root === null) return undefined
  return rows.find(
    r => r.sessionId !== row.sessionId && r.state !== 'parked' && worktreeOf(r) === root,
  )
}
