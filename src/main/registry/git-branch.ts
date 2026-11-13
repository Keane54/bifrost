import { realpathSync } from 'node:fs'
import { readFile, stat } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
import type { ExecFn } from '../claude/cli'
import { isInside } from '../reviews/repo-paths'

// True when the folder is the root or a folder below it. The check also compares the real paths,
// because a session can report the real path of a folder that the root names through a link.
function inRoot(root: string, cwd: string): boolean {
  const below = (r: string, p: string): boolean => r === p || isInside(r, p)
  if (below(root, cwd)) return true
  try {
    return below(realpathSync.native(root), realpathSync.native(cwd))
  } catch {
    return false
  }
}

// Read the branch name of a directory. Return null when git fails. A folder in skipRoot (the
// reviews folder of Bifrost) gives null with no git command: a PR session can write its .git file
// and its git config, and git reads both.
export async function readBranch(
  exec: ExecFn,
  cwd: string,
  skipRoot?: string,
): Promise<string | null> {
  if (skipRoot !== undefined && inRoot(skipRoot, cwd)) return null
  const result = await exec('git', ['-C', cwd, 'rev-parse', '--abbrev-ref', 'HEAD'], {
    timeoutMs: 2000,
  })
  return result.code === 0 ? result.stdout.trim() : null
}

// The branch name in the text of a HEAD file. "ref: refs/heads/<name>" gives the name. A full
// hash (a detached head) gives "HEAD", as git does. Other text gives undefined: ask git.
export function branchOfHead(text: string): string | undefined {
  const body = text.trim()
  const ref = /^ref: refs\/heads\/(.+)$/.exec(body)
  if (ref) return ref[1]
  return /^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$/.test(body) ? 'HEAD' : undefined
}

// The file system calls of the branch reader. A test gives a fake.
export interface BranchFs {
  readFile(path: string): Promise<string>
  stat(path: string): Promise<{ mtimeMs: number; isFile(): boolean; isDirectory(): boolean }>
}

const nodeFs: BranchFs = {
  readFile: path => readFile(path, 'utf8'),
  stat: path => stat(path),
}

// Find the HEAD file of a folder. Go up from the folder to the root. A ".git" folder holds HEAD.
// A ".git" file holds "gitdir: <path>" (a linked worktree). A relative path starts at the folder.
// Return null when no ".git" exists. Throw when a ".git" file has no gitdir.
async function findHead(fs: BranchFs, cwd: string): Promise<string | null> {
  let dir = resolve(cwd)
  for (;;) {
    const dotGit = join(dir, '.git')
    const info = await fs.stat(dotGit).catch(() => null)
    if (info?.isDirectory()) return join(dotGit, 'HEAD')
    if (info?.isFile()) {
      const match = /^gitdir:\s*(.+)$/m.exec(await fs.readFile(dotGit))
      if (!match) throw new Error('no gitdir')
      return join(resolve(dir, match[1].trim()), 'HEAD')
    }
    const parent = dirname(dir)
    if (parent === dir) return null
    dir = parent
  }
}

interface Cached {
  head: string
  mtimeMs: number
  branch: string
}

// The options of the branch reader. A folder in skipRoot (the reviews folder of Bifrost) gives
// null with no file read and no git command. A test gives a fake fs.
export interface BranchReaderOptions {
  skipRoot?: string
  fs?: BranchFs
}

// A reader that gets the branch from the HEAD file with no process. It reads a HEAD file again
// only when its mtime changes. When it cannot decide, it asks git.
export function createBranchReader(
  exec: ExecFn,
  { skipRoot, fs = nodeFs }: BranchReaderOptions = {},
): { read(cwd: string): Promise<string | null> } {
  // One entry for each folder of a row, so the cache needs no size limit.
  const cache = new Map<string, Cached>()
  return {
    async read(cwd) {
      // A PR session can write the .git file, the HEAD file and the git config of its folder.
      if (skipRoot !== undefined && inRoot(skipRoot, cwd)) {
        cache.delete(cwd)
        return null
      }
      // A folder that is gone has no branch. Do not use a parent repo.
      const folder = await fs.stat(cwd).catch(() => null)
      if (!folder?.isDirectory()) {
        cache.delete(cwd)
        return null
      }
      try {
        const head = await findHead(fs, cwd)
        if (head === null) return null
        // The .git file of a folder outside the reviews folder can point into it. Read no HEAD
        // file there, and run no git.
        if (skipRoot !== undefined && inRoot(skipRoot, dirname(head))) {
          cache.delete(cwd)
          return null
        }
        const { mtimeMs } = await fs.stat(head)
        const hit = cache.get(cwd)
        if (hit && hit.head === head && hit.mtimeMs === mtimeMs) return hit.branch
        const branch = branchOfHead(await fs.readFile(head))
        if (branch !== undefined) {
          cache.set(cwd, { branch, head, mtimeMs })
          return branch
        }
      } catch {
        // A file error uses git.
      }
      cache.delete(cwd)
      return readBranch(exec, cwd, skipRoot)
    },
  }
}
