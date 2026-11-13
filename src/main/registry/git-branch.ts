import { readFile, stat } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
import type { ExecFn } from '../claude/cli'

// Read the branch name of a directory. Return null when git fails.
export async function readBranch(exec: ExecFn, cwd: string): Promise<string | null> {
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

// A reader that gets the branch from the HEAD file with no process. It reads a HEAD file again
// only when its mtime changes. When it cannot decide, it asks git.
export function createBranchReader(
  exec: ExecFn,
  fs: BranchFs = nodeFs,
): { read(cwd: string): Promise<string | null> } {
  // One entry for each folder of a row, so the cache needs no size limit.
  const cache = new Map<string, Cached>()
  return {
    async read(cwd) {
      // A folder that is gone has no branch. Do not use a parent repo.
      const folder = await fs.stat(cwd).catch(() => null)
      if (!folder?.isDirectory()) {
        cache.delete(cwd)
        return null
      }
      try {
        const head = await findHead(fs, cwd)
        if (head === null) return null
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
      return readBranch(exec, cwd)
    },
  }
}
