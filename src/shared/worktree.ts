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

// Another row in the worktree of the row, else undefined (spec 8 of the skills design). The
// state of each row does not matter. claude rm can remove a clean worktree while another session
// uses it. So a Delete of a row with such a row keeps the folder and defers the claude rm.
// A plain folder gives undefined. The row itself never counts.
export function folderSharer<T extends Pick<SessionRow, 'sessionId' | 'cwd' | 'worktree'>>(
  row: T,
  rows: readonly T[],
): T | undefined {
  const root = worktreeOf(row)
  if (root === null) return undefined
  return rows.find(r => r.sessionId !== row.sessionId && worktreeOf(r) === root)
}
