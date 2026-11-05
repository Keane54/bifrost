// The worktree of a session. Claude Code makes it in <repo>/.claude/worktrees/<name>.
const MARK = '/.claude/worktrees/'

// The worktree root and the repo of a cwd. A cwd in a subfolder gives the same root.
// A cwd outside .claude/worktrees/<name> gives null.
export function worktreeRoot(cwd: string): { worktree: string; repo: string } | null {
  const at = cwd.indexOf(MARK)
  if (at < 0) return null
  const rest = cwd.slice(at + MARK.length)
  const name = rest.split('/')[0]
  if (name === '') return null
  return { repo: cwd.slice(0, at), worktree: cwd.slice(0, at + MARK.length) + name }
}
