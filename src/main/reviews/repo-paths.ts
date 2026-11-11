// The paths of the clones, worktrees and input folders that Bifrost owns.
// All names of owner and repository are in lower case.

import { isAbsolute, join, relative, resolve, sep } from 'node:path'
import { REPO_KEY } from '../../shared/reviews'

export const REFUSED_BAD_REPO = 'refused: bad repository name'

export function reposRoot(bifrostHome: string): string {
  return join(bifrostHome, 'reviews', 'repos')
}

// The clone of owner/repo. A name that fails REPO_KEY throws, so the path never leaves the root.
export function clonePath(bifrostHome: string, owner: string, repo: string): string {
  if (!REPO_KEY.test(`${owner}/${repo}`)) throw new Error(REFUSED_BAD_REPO)
  return join(reposRoot(bifrostHome), owner.toLowerCase(), repo.toLowerCase())
}

// The worktree of a PR. It is the cwd of the review session.
export function worktreePath(clone: string, number: number): string {
  return join(clone, '.bifrost-worktrees', String(number))
}

// The input folder of a PR. The review session gets it with --add-dir.
export function ioPath(clone: string, number: number): string {
  return join(clone, '.bifrost-io', String(number))
}

// The folder in the clone where git keeps the data of the worktree of a PR.
export function adminPath(clone: string, number: number): string {
  return join(clone, '.git', 'worktrees', String(number))
}

// True when path is below root. The check uses the resolved paths, so ".." cannot go up out of
// root. The root itself is not inside the root. This check does not resolve links.
export function isInside(root: string, path: string): boolean {
  const rel = relative(resolve(root), resolve(path))
  if (rel === '' || isAbsolute(rel)) return false
  return rel !== '..' && !rel.startsWith(`..${sep}`)
}
