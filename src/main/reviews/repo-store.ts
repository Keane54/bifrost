// The repository store of the Reviews feature. Bifrost keeps its own clone of each repository,
// one worktree for each reviewed PR and one input folder for each PR, all below reposRoot.
// Bifrost owns these folders, so it can reset, clean and delete them. Each delete first checks
// that the path is inside reposRoot, also after each link resolves.

import { existsSync } from 'node:fs'
import { chmod, mkdir, readdir, readFile, realpath, rename, rm, writeFile } from 'node:fs/promises'
import { basename, dirname, join, resolve } from 'node:path'
import type { ExecResult } from '../claude/cli'
import { CLONE_TIMEOUT_MS, type RepoGit } from './repo-git'
import { adminPath, clonePath, ioPath, isInside, reposRoot, worktreePath } from './repo-paths'

export const REASON_NOT_OWNED =
  "That folder isn't in Bifrost's reviews folder, so Bifrost left it alone."
const FETCH_FAILED = "Bifrost couldn't get the pull request from GitHub: "
const PREPARE_FAILED = "Bifrost couldn't prepare its copy of the pull request: "
const LINE_MAX = 200
// A full object ID: SHA-1 or SHA-256.
const OBJECT_ID = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/
// The end of the name of the temporary folder of a clone. A repository name cannot hold "~", so
// this folder is never the clone of another repository.
const TEMP_SUFFIX = '~cloning'

// The start of the remote URL. In a test home, the remotes are bare repositories on the disk.
export function remoteBase(testHome: string | null): string {
  return testHome === null ? 'https://github.com/' : `file://${testHome}/git-remotes/`
}

export interface FetchedPr {
  head: string
  base: string
  mergeBase: string
}

export interface RepoStore {
  // The clone path when the clone has a .git folder. Else null.
  cloneOf(owner: string, repo: string): string | null
  // Make the clone when it is missing, and give its path.
  ensureClone(owner: string, repo: string): Promise<string>
  // Fetch the PR head and the base branch. Give both commits and their merge base.
  fetchPr(clone: string, number: number, baseRef: string): Promise<FetchedPr>
  hasCommit(clone: string, sha: string): Promise<boolean>
  // True when commit a is an ancestor of commit b.
  isAncestor(clone: string, a: string, b: string): Promise<boolean>
  // Write the diff to file. merge-base mode gives the changes of the PR only.
  writeDiff(
    clone: string,
    from: string,
    to: string,
    file: string,
    mode: 'merge-base' | 'direct',
  ): Promise<void>
  // Make a new worktree of the PR, detached at head. Give its path.
  prepareWorktree(clone: string, number: number, head: string): Promise<string>
  // Count the changes in the worktree, then reset and clean it.
  checkAndClean(clone: string, number: number, head: string): Promise<{ changed: number }>
  // Delete the input folder of the PR and make a new, empty one. Give its path.
  resetIo(clone: string, number: number): Promise<string>
  // Remove the worktree and the input folder of the PR. A missing folder is not an error.
  removeWorktree(clone: string, number: number): Promise<void>
  // Delete each clone. reposRoot stays.
  removeAll(): Promise<void>
}

export interface RepoStoreDeps {
  git: RepoGit
  bifrostHome: string
  remoteBase: string
}

const failed = (result: ExecResult): boolean => result.code !== 0 || result.timedOut === true

// The first line of stderr, for the error text.
function reason(result: ExecResult): string {
  if (result.timedOut) return 'git took too long.'
  const line = result.stderr
    .split('\n')
    .map(part => part.trim())
    .find(part => part !== '')
  return line === undefined ? `git stopped with exit code ${result.code}.` : line.slice(0, LINE_MAX)
}

function checkCommit(sha: string): void {
  if (!OBJECT_ID.test(sha)) throw new Error(`${PREPARE_FAILED}the commit ID isn't valid.`)
}

// The real path of path, with each link resolved. A part that does not exist stays as it is.
async function realOf(path: string): Promise<string> {
  const rest: string[] = []
  let at = resolve(path)
  for (;;) {
    try {
      return join(await realpath(at), ...rest)
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code
      if (code !== 'ENOENT' && code !== 'ENOTDIR') throw error
      const up = dirname(at)
      if (up === at) return resolve(path)
      rest.unshift(basename(at))
      at = up
    }
  }
}

export function createRepoStore(deps: RepoStoreDeps): RepoStore {
  const root = reposRoot(deps.bifrostHome)
  // The clones that run now, by clone path.
  const cloning = new Map<string, Promise<string>>()

  const isClone = (clone: string): boolean => existsSync(join(clone, '.git'))

  // Throw unless path is inside the root, before and after each link resolves. The last part
  // of the path does not resolve, because rm deletes a link and not the folder that it names.
  async function checkOwned(path: string): Promise<void> {
    if (!isInside(root, path)) throw new Error(REASON_NOT_OWNED)
    const target = resolve(path)
    const real = join(await realOf(dirname(target)), basename(target))
    if (!isInside(await realOf(root), real)) throw new Error(REASON_NOT_OWNED)
  }

  // The guarded delete. A missing path is not an error.
  async function remove(path: string): Promise<void> {
    await checkOwned(path)
    await rm(path, { force: true, recursive: true })
  }

  // Run git in the clone. A failure throws the prefix and the first line of stderr.
  async function run(
    clone: string,
    args: string[],
    prefix: string,
    timeoutMs?: number,
  ): Promise<string> {
    const result = await deps.git.run(args, {
      cwd: clone,
      ...(timeoutMs === undefined ? {} : { timeoutMs }),
    })
    if (failed(result)) throw new Error(`${prefix}${reason(result)}`)
    return result.stdout
  }

  async function makeClone(owner: string, repo: string, clone: string): Promise<string> {
    const folder = dirname(clone)
    const temp = `${clone}${TEMP_SUFFIX}`
    await mkdir(folder, { mode: 0o700, recursive: true })
    // An earlier run can stop during a clone and leave the temporary folder.
    await remove(temp)
    await mkdir(temp, { mode: 0o700 })
    const url = `${deps.remoteBase}${owner.toLowerCase()}/${repo.toLowerCase()}.git`
    try {
      const result = await deps.git.run(
        ['clone', '--quiet', '--no-checkout', '--filter=blob:none', '--', url, temp],
        { cwd: folder, timeoutMs: CLONE_TIMEOUT_MS },
      )
      if (failed(result)) {
        throw new Error(`Bifrost couldn't copy ${owner}/${repo}: ${reason(result)}`)
      }
      // A folder with no .git can stay after a failed delete. The new clone replaces it.
      await remove(clone)
      await rename(temp, clone)
    } catch (error) {
      await remove(temp).catch(() => undefined)
      throw error
    }
    return clone
  }

  async function isBranchName(clone: string, name: string): Promise<boolean> {
    const result = await deps.git.run(['check-ref-format', '--branch', name], { cwd: clone })
    // --branch expands a name like @{-1}. So the output must be the same name.
    return !failed(result) && result.stdout.trim() === name
  }

  async function commitOf(clone: string, ref: string): Promise<string> {
    const args = ['rev-parse', '--verify', '--quiet', `${ref}^{commit}`]
    const sha = (await run(clone, args, PREPARE_FAILED)).trim()
    checkCommit(sha)
    return sha
  }

  // True when the admin folder of the PR names the .git file of its worktree.
  async function linksBack(clone: string, number: number): Promise<boolean> {
    const admin = adminPath(clone, number)
    try {
      const named = (await readFile(join(admin, 'gitdir'), 'utf8')).trim()
      const [left, right] = await Promise.all([
        realpath(resolve(admin, named)),
        realpath(join(worktreePath(clone, number), '.git')),
      ])
      return left === right
    } catch {
      return false
    }
  }

  // Remove the worktree folder. git also deletes the admin folder. If git fails, for example
  // because the session changed the .git file, the guarded delete removes the folder. Then the
  // next worktree prune removes the admin folder.
  async function dropWorktree(clone: string, path: string): Promise<void> {
    await checkOwned(path)
    if (isClone(clone)) {
      await deps.git.run(['worktree', 'remove', '--force', '--force', path], { cwd: clone })
    }
    await remove(path)
  }

  return {
    async checkAndClean(clone, number, head) {
      checkCommit(head)
      const path = worktreePath(clone, number)
      const admin = adminPath(clone, number)
      await checkOwned(path)
      // The session can change the .git file of its worktree. So each command names the admin
      // folder and the worktree, and git never reads that file.
      const on = [`--git-dir=${admin}`, `--work-tree=${path}`]
      const status = await run(
        clone,
        [...on, 'status', '--porcelain', '--untracked-files=all', '--ignored'],
        PREPARE_FAILED,
      )
      const changed = status.split('\n').filter(line => line !== '').length
      await run(clone, [...on, 'reset', '--hard', '--quiet', head], PREPARE_FAILED)
      await run(clone, [...on, 'clean', '-ffdx', '--quiet'], PREPARE_FAILED)
      const gitFile = join(path, '.git')
      await remove(gitFile)
      // The flag wx makes a new file. It does not follow a link.
      await writeFile(gitFile, `gitdir: ${admin}\n`, { flag: 'wx', mode: 0o644 })
      return { changed }
    },

    cloneOf(owner, repo) {
      const clone = clonePath(deps.bifrostHome, owner, repo)
      return isClone(clone) ? clone : null
    },

    ensureClone(owner, repo) {
      let clone: string
      try {
        clone = clonePath(deps.bifrostHome, owner, repo)
      } catch (error) {
        return Promise.reject(error)
      }
      // A second call during a clone gets the same promise.
      const running = cloning.get(clone)
      if (running !== undefined) return running
      if (isClone(clone)) return Promise.resolve(clone)
      const made = makeClone(owner, repo, clone).finally(() => cloning.delete(clone))
      cloning.set(clone, made)
      return made
    },

    async fetchPr(clone, number, baseRef) {
      if (baseRef.startsWith('-') || !(await isBranchName(clone, baseRef))) {
        throw new Error(`${FETCH_FAILED}the name of the base branch isn't valid.`)
      }
      const prRef = `refs/bifrost/pr/${number}`
      const baseRefLocal = `refs/bifrost/base/${number}`
      await run(
        clone,
        [
          'fetch',
          '--quiet',
          '--no-tags',
          '--',
          'origin',
          `+refs/pull/${number}/head:${prRef}`,
          `+refs/heads/${baseRef}:${baseRefLocal}`,
        ],
        FETCH_FAILED,
      )
      const head = await commitOf(clone, prRef)
      const base = await commitOf(clone, baseRefLocal)
      const mergeBase = (await run(clone, ['merge-base', head, base], PREPARE_FAILED)).trim()
      checkCommit(mergeBase)
      return { base, head, mergeBase }
    },

    async hasCommit(clone, sha) {
      if (!OBJECT_ID.test(sha)) return false
      return !failed(await deps.git.run(['cat-file', '-e', `${sha}^{commit}`], { cwd: clone }))
    },

    async isAncestor(clone, a, b) {
      if (!OBJECT_ID.test(a) || !OBJECT_ID.test(b)) return false
      return !failed(await deps.git.run(['merge-base', '--is-ancestor', a, b], { cwd: clone }))
    },

    async prepareWorktree(clone, number, head) {
      checkCommit(head)
      const path = worktreePath(clone, number)
      await checkOwned(path)
      await dropWorktree(clone, path)
      await run(clone, ['worktree', 'prune'], PREPARE_FAILED)
      await mkdir(dirname(path), { mode: 0o700, recursive: true })
      // The checkout downloads the files of the head, so it gets the long timeout.
      await run(
        clone,
        ['worktree', 'add', '--quiet', '--detach', '--force', path, head],
        PREPARE_FAILED,
        CLONE_TIMEOUT_MS,
      )
      // git names the admin folder after the worktree folder. An old admin folder with that
      // name makes git choose another name, and then the commands of checkAndClean fail.
      if (!(await linksBack(clone, number))) {
        await dropWorktree(clone, path)
        await deps.git.run(['worktree', 'prune'], { cwd: clone })
        throw new Error(`${PREPARE_FAILED}git didn't link the worktree to its admin folder.`)
      }
      await chmod(path, 0o700)
      return path
    },

    async removeAll() {
      // A clone that runs now would come back after the delete. So wait for it first.
      await Promise.allSettled([...cloning.values()])
      let names: string[]
      try {
        names = await readdir(root)
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === 'ENOENT') return
        throw error
      }
      for (const name of names) await remove(join(root, name))
    },

    async removeWorktree(clone, number) {
      const path = worktreePath(clone, number)
      const io = ioPath(clone, number)
      await checkOwned(path)
      await checkOwned(io)
      await dropWorktree(clone, path)
      const pruned = isClone(clone)
        ? await deps.git.run(['worktree', 'prune'], { cwd: clone })
        : null
      await remove(io)
      if (pruned !== null && failed(pruned)) throw new Error(`${PREPARE_FAILED}${reason(pruned)}`)
    },

    async resetIo(clone, number) {
      const io = ioPath(clone, number)
      await remove(io)
      await mkdir(dirname(io), { mode: 0o700, recursive: true })
      await mkdir(io, { mode: 0o700 })
      await chmod(io, 0o700)
      return io
    },

    async writeDiff(clone, from, to, file, mode) {
      checkCommit(from)
      checkCommit(to)
      const range = mode === 'merge-base' ? [`${from}...${to}`] : [from, to]
      // The fixed prefixes keep the a/ and b/ paths when the git config of the user changes
      // them (diff.noprefix).
      await run(
        clone,
        [
          'diff',
          '--no-ext-diff',
          '--no-textconv',
          '--no-color',
          '--find-renames',
          '--src-prefix=a/',
          '--dst-prefix=b/',
          `--output=${file}`,
          ...range,
          '--',
        ],
        PREPARE_FAILED,
      )
    },
  }
}
