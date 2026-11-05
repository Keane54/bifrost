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
