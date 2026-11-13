// The repository store of the Reviews feature. Bifrost keeps its own clone of each repository,
// one worktree for each reviewed PR and one input folder for each PR, all below reposRoot.
// Bifrost owns these folders, so it can reset, clean and delete them. Each delete first checks
// that the path is inside reposRoot, also after each link resolves.
// Each git command names its git folder with --git-dir. So when the .git folder of a clone is
// missing, git fails. It never searches the parent folders and acts on another repository.

import { existsSync, type Stats } from 'node:fs'
import {
  chmod,
  lstat,
  mkdir,
  readdir,
  readFile,
  realpath,
  rename,
  rm,
  writeFile,
} from 'node:fs/promises'
import { basename, dirname, join, resolve } from 'node:path'
import type { ExecResult } from '../claude/cli'
import { CLONE_TIMEOUT_MS, NO_PROMPT_CONFIG, type RepoGit } from './repo-git'
import { adminPath, clonePath, ioPath, isInside, reposRoot, worktreePath } from './repo-paths'
import { REASON_PUSH_GIT_FAILED, reasonCommitFailed } from './round-text'

export const REASON_NOT_OWNED =
  "That folder isn't in Bifrost's reviews folder, so Bifrost left it alone."
const FETCH_FAILED = "Bifrost couldn't get the pull request from GitHub: "
const PREPARE_FAILED = "Bifrost couldn't prepare its copy of the pull request: "
const LINE_MAX = 200
// A full object ID in lower case, as git gives it: SHA-1 or SHA-256. Each check of a commit ID
// uses this one pattern.
export const OBJECT_ID = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/
// The end of the name of the temporary folder of a clone. A repository name cannot hold "~", so
// this folder is never the clone of another repository.
const TEMP_SUFFIX = '~cloning'
// removeAll first moves each folder of the root to a name with this end, then deletes it.
// An owner name cannot hold "~" either.
const DELETE_SUFFIX = '~deleting'

// The start of the remote URL. In a test home, the remotes are bare repositories on the disk.
export function remoteBase(testHome: string | null): string {
  return testHome === null ? 'https://github.com/' : `file://${testHome}/git-remotes/`
}

export interface FetchedPr {
  head: string
  base: string
  mergeBase: string
}

// The largest file of a fix commit, in bytes.
export const MAX_FIX_FILE = 1024 * 1024
// Why Bifrost does not commit a path of a fix.
export type UnsafeRule =
  | 'workflow'
  | 'claude'
  | 'submodule'
  | 'link'
  | 'large'
  | 'outside'
  | 'unchanged'
  | 'filter'
export type FixCommit = { ok: true; sha: string } | { ok: false; rule: UnsafeRule }

export interface RepoStore {
  // The clone path when the clone has a .git folder. Else null.
  cloneOf(owner: string, repo: string): string | null
  // Make the clone when it is missing, and give its path.
  ensureClone(owner: string, repo: string): Promise<string>
  // Fetch the PR head and the base branch. Give both commits and their merge base. noPrompt adds
  // NO_PROMPT_CONFIG to the fetch: a request round starts with no click, so it must never show a
  // prompt. An R2 review keeps the fetch as it is, because it can need SSH.
  fetchPr(
    clone: string,
    number: number,
    baseRef: string,
    opts?: { noPrompt?: boolean },
  ): Promise<FetchedPr>
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
  // Count the changes in the worktree, then reset and clean it. The reset and the clean also run
  // when the count fails. Then the count error throws.
  checkAndClean(clone: string, number: number, head: string): Promise<{ changed: number }>
  // The paths that changed in the worktree of the PR: changed, new and deleted files. An ignored
  // file is not a change.
  changedPaths(clone: string, number: number): Promise<string[]>
  // Commit the listed paths of the worktree, with head as the only parent. A path that Bifrost
  // must not push gives its rule, and then nothing is committed. A second run gives the same
  // commit. A failed git command throws reasonCommitFailed.
  commitFix(
    clone: string,
    number: number,
    o: { head: string; paths: readonly string[]; message: string },
  ): Promise<FixCommit>
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
  if (result.overflow) return 'git gave too much output.'
  if (result.timedOut) return 'git took too long.'
  const line = result.stderr
    .split('\n')
    .map(part => part.trim())
    .find(part => part !== '')
  return line === undefined ? `git stopped with exit code ${result.code}.` : line.slice(0, LINE_MAX)
}

// A failed git command of the fix commit. The message is a fixed text for the row. detail is the
// first line of the stderr of git, for the Event log only.
export class CommitError extends Error {
  constructor(
    message: string,
    readonly detail?: string,
  ) {
    super(message)
  }
}

// The push module uses the same rules for a failed git command and its error text, and the same
// reads of a commit message.
export { cleanMessage, commitParts, failed as gitFailed, reason as gitReason }

function checkCommit(sha: string): void {
  if (!OBJECT_ID.test(sha)) throw new Error(`${PREPARE_FAILED}the commit ID isn't valid.`)
}

// The fixed error texts of commitFix. An error of git add can name a file of the session, so the
// user never sees the text of that error.
const ADD_FAILED = "git couldn't add the files of the fix."
const BAD_ID = "the commit ID isn't valid."
const BAD_LIST = "git gave a list of changes that Bifrost couldn't read."
const BAD_PARENT = "the new commit doesn't have the pull request head as its only parent."
const FILE_CHANGED = 'a file changed while Bifrost committed it.'
const NOT_AT_HEAD = "its copy of the pull request isn't at the commit that Claude worked on."
const READ_FAILED = "one of its files can't be read."
// The modes of git for a submodule, a link and a folder.
const GITLINK = '160000'
const SYMLINK = '120000'
const TREE = '040000'
// The modes that a path of a fix can have in the commit: a file, a program, or no file.
const FILE_MODES: readonly string[] = ['100644', '100755', '000000']

// The message as git commit --cleanup=whitespace keeps it. Each line loses the white space at its
// end. Empty lines at the start and at the end go, and more empty lines become one. The message
// ends with a new line. git also treats a tab and a carriage return as white space here.
function cleanMessage(message: string): string {
  const lines: string[] = []
  let gap = false
  for (const raw of message.split('\n')) {
    const line = raw.replace(/[ \t\r]+$/, '')
    if (line === '') {
      gap = lines.length > 0
      continue
    }
    if (gap) lines.push('')
    gap = false
    lines.push(line)
  }
  return lines.length === 0 ? '' : `${lines.join('\n')}\n`
}

// True when the path is not a clean relative path: empty parts, ".", "..", a .git folder in any
// case, or a backslash.
function badPath(path: string): boolean {
  if (path.includes('\\') || path.includes('\0')) return true
  return path
    .split('/')
    .some(part => part === '' || part === '.' || part === '..' || part.toLowerCase() === '.git')
}

// The path and each folder above it, for example a, a/b and a/b/c.ts.
function withParents(path: string): string[] {
  const parts = path.split('/')
  return parts.map((_, i) => parts.slice(0, i + 1).join('/'))
}

// True when the path is the folder or a path below it.
const atOrBelow = (path: string, folder: string): boolean =>
  path === folder || path.startsWith(`${folder}/`)

// The text rules of a path, with no read of a file. A file system that ignores case finds these
// files also with another case, so the check ignores case.
// - GitHub workflows and actions are CI code.
// - A .claude folder can hold settings, hooks or skills of Claude Code, at the root or below it.
function nameRule(path: string): UnsafeRule | null {
  const lower = path.toLowerCase()
  if (badPath(path)) return 'outside'
  if (atOrBelow(lower, '.github/workflows') || atOrBelow(lower, '.github/actions')) {
    return 'workflow'
  }
  if (lower.split('/').includes('.claude')) return 'claude'
  if (lower === '.gitmodules') return 'submodule'
  return null
}

// lstat, or null for a missing file. A file below a file is also missing.
async function lstatOrNull(path: string): Promise<Stats | null> {
  try {
    return await lstat(path)
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code
    if (code === 'ENOENT' || code === 'ENOTDIR') return null
    throw error
  }
}

// The identity and the state of a file. A change of the file, another file in its place or a new
// hard link of it gives another key, because each of them changes the change time.
function statKey(info: Stats | null): string {
  if (info === null) return 'missing'
  return [info.dev, info.ino, info.mode, info.nlink, info.size, info.mtimeMs, info.ctimeMs].join(
    ':',
  )
}

// The mode of each entry of git ls-tree -z, by path.
function treeModes(listing: string): Map<string, string> {
  const modes = new Map<string, string>()
  for (const entry of listing.split('\0')) {
    const match = /^(\d{6}) \w+ [0-9a-f]+\t(.+)$/s.exec(entry)
    if (match !== null) modes.set(match[2] as string, match[1] as string)
  }
  return modes
}

// The new mode of each path of git diff-index --raw -z, by path. Null when the output is not in
// that form.
function stagedModes(raw: string): Map<string, string> | null {
  const parts = raw.split('\0')
  if (parts.at(-1) === '') parts.pop()
  if (parts.length % 2 !== 0) return null
  const modes = new Map<string, string>()
  for (let i = 0; i < parts.length; i += 2) {
    const match = /^:\d{6} (\d{6}) \S+ \S+ [A-Z]\d*$/.exec(parts[i] as string)
    if (match === null) return null
    modes.set(parts[i + 1] as string, match[1] as string)
  }
  return modes
}

// The parents and the message of a commit, from git cat-file commit. A line of a signature
// starts with a space, so it is never a parent line.
function commitParts(raw: string): { message: string; parents: string[] } {
  const end = raw.indexOf('\n\n')
  const header = end === -1 ? raw : raw.slice(0, end)
  return {
    message: end === -1 ? '' : raw.slice(end + 2),
    parents: header
      .split('\n')
      .filter(line => line.startsWith('parent '))
      .map(line => line.slice('parent '.length)),
  }
}

// True when the two lists hold the same items, each one time.
function sameSet(a: readonly string[], b: readonly string[]): boolean {
  const left = new Set(a)
  const right = new Set(b)
  return left.size === a.length && right.size === b.length && a.length === b.length
    ? b.every(item => left.has(item))
    : false
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

  // Run git on the worktree of a PR. The session can change the .git file of its worktree. So
  // each command names the admin folder and the worktree, and git never reads that file.
  function onWorktree(clone: string, number: number, args: string[]): Promise<ExecResult> {
    return deps.git.run(
      [
        `--git-dir=${adminPath(clone, number)}`,
        `--work-tree=${worktreePath(clone, number)}`,
        ...args,
      ],
      { cwd: clone },
    )
  }

  // Run git on the clone, with its .git folder named. A missing .git folder makes git fail.
  function gitIn(clone: string, args: string[], timeoutMs?: number): Promise<ExecResult> {
    return deps.git.run([`--git-dir=${join(clone, '.git')}`, ...args], {
      cwd: clone,
      ...(timeoutMs === undefined ? {} : { timeoutMs }),
    })
  }

  // Run git on the clone. A failure throws the prefix and the first line of stderr.
  async function mustIn(
    clone: string,
    args: string[],
    prefix: string,
    timeoutMs?: number,
  ): Promise<string> {
    const result = await gitIn(clone, args, timeoutMs)
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
        // --origin keeps the remote name origin when the git config of the user names another.
        [
          'clone',
          '--quiet',
          '--no-checkout',
          '--filter=blob:none',
          '--origin',
          'origin',
          '--',
          url,
          temp,
        ],
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
    const result = await gitIn(clone, ['check-ref-format', '--branch', name])
    // --branch expands a name like @{-1}. So the output must be the same name.
    return !failed(result) && result.stdout.trim() === name
  }

  async function commitOf(clone: string, ref: string): Promise<string> {
    const args = ['rev-parse', '--verify', '--quiet', `${ref}^{commit}`]
    const sha = (await mustIn(clone, args, PREPARE_FAILED)).trim()
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
      await gitIn(clone, ['worktree', 'remove', '--force', '--force', path])
    }
    await remove(path)
  }

  return {
    async changedPaths(clone, number) {
      await checkOwned(worktreePath(clone, number))
      const result = await onWorktree(clone, number, [
        'status',
        '--porcelain=v1',
        '-z',
        '--untracked-files=all',
        '--no-renames',
      ])
      if (failed(result)) throw new Error(`${PREPARE_FAILED}${reason(result)}`)
      // Each entry is two status letters, a space and the path. -z keeps each path as it is.
      return result.stdout
        .split('\0')
        .filter(entry => entry.length > 3)
        .map(entry => entry.slice(3))
    },
    async checkAndClean(clone, number, head) {
      checkCommit(head)
      const path = worktreePath(clone, number)
      const admin = adminPath(clone, number)
      await checkOwned(path)
      const status = await onWorktree(clone, number, [
        'status',
        '--porcelain',
        '--untracked-files=all',
        '--ignored',
      ])
      // A failed count does not stop the reset and the clean.
      const reset = await onWorktree(clone, number, ['reset', '--hard', '--quiet', head])
      const clean = await onWorktree(clone, number, ['clean', '-ffdx', '--quiet'])
      if (existsSync(path)) {
        const gitFile = join(path, '.git')
        await remove(gitFile)
        // The flag wx makes a new file. It does not follow a link.
        await writeFile(gitFile, `gitdir: ${admin}\n`, { flag: 'wx', mode: 0o644 })
      }
      const failure = [reset, clean, status].find(failed)
      if (failure !== undefined) throw new Error(`${PREPARE_FAILED}${reason(failure)}`)
      return { changed: status.stdout.split('\n').filter(line => line !== '').length }
    },

    cloneOf(owner, repo) {
      const clone = clonePath(deps.bifrostHome, owner, repo)
      return isClone(clone) ? clone : null
    },

    async commitFix(clone, number, o) {
      const path = worktreePath(clone, number)
      await checkOwned(path)
      if (!OBJECT_ID.test(o.head)) throw new Error(reasonCommitFailed(BAD_ID))
      const paths = [...new Set(o.paths)]
      // git add with no paths adds each change of the worktree.
      if (paths.length === 0) return { ok: false, rule: 'unchanged' }
      // A path is a literal path, never a pattern.
      const run = async (args: string[], fixedLine?: string): Promise<string> => {
        const result = await onWorktree(clone, number, ['--literal-pathspecs', ...args])
        if (failed(result)) {
          if (fixedLine !== undefined) throw new Error(reasonCommitFailed(fixedLine))
          throw new CommitError(reasonCommitFailed(REASON_PUSH_GIT_FAILED), reason(result))
        }
        return result.stdout
      }
      const message = cleanMessage(o.message)
      // The error of a file read names the full path of a file of the session. So the user gets
      // a fixed text.
      const read = async <T>(how: () => Promise<T>): Promise<T> => {
        try {
          return await how()
        } catch {
          throw new Error(reasonCommitFailed(READ_FAILED))
        }
      }

      // A run after a restart finds the commit of the first run as the head of the worktree.
      const current = (await run(['rev-parse', '--verify', 'HEAD^{commit}'])).trim()
      if (current !== o.head) {
        const parts = commitParts(await run(['cat-file', 'commit', current]))
        const same = parts.message === message && sameSet(parts.parents, [o.head])
        const names = same
          ? await run(['diff-tree', '-r', '-z', '--no-renames', '--name-only', o.head, current])
          : ''
        if (same && sameSet(names.split('\0').filter(Boolean), paths)) {
          return { ok: true, sha: current }
        }
        throw new Error(reasonCommitFailed(NOT_AT_HEAD))
      }

      for (const file of paths) {
        const rule = nameRule(file)
        if (rule !== null) return { ok: false, rule }
      }
      const modes = treeModes(
        await run([
          'ls-tree',
          '-z',
          '--full-tree',
          o.head,
          '--',
          ...new Set(paths.flatMap(withParents)),
        ]),
      )
      const root = await read(() => realOf(path))
      const keys: string[] = []
      for (const file of paths) {
        const full = join(path, file)
        const info = await read(() => lstatOrNull(full))
        if (withParents(file).some(part => modes.get(part) === GITLINK)) {
          return { ok: false, rule: 'submodule' }
        }
        const atHead = modes.get(file)
        if (info === null) {
          // A delete of a file that the head does not have changes nothing.
          if (atHead === undefined || atHead === TREE) return { ok: false, rule: 'unchanged' }
        } else {
          // core.symlinks=false keeps the link mode of the head for a plain file.
          const plain = info.isFile() && !info.isSymbolicLink() && info.nlink === 1
          if (!plain || atHead === SYMLINK) return { ok: false, rule: 'link' }
          if (info.size > MAX_FIX_FILE) return { ok: false, rule: 'large' }
        }
        const real = await read(() => realOf(full))
        if (!isInside(root, real)) return { ok: false, rule: 'outside' }
        // A folder above the file is a link to another folder of the worktree. macOS can keep a
        // name with an accent in another Unicode form, so both paths get the same form first.
        if (real.normalize('NFC') !== join(root, file).normalize('NFC')) {
          return { ok: false, rule: 'link' }
        }
        keys.push(statKey(info))
      }

      // git add runs the clean filter of a file. The worktree .gitattributes, which the session
      // can change, chooses the filter. A delete runs no filter.
      const present = paths.filter((_, i) => keys[i] !== 'missing')
      if (present.length > 0) {
        // Each entry is the path, the name of the attribute and its value.
        const entries = (await run(['check-attr', '-z', 'filter', '--', ...present])).split('\0')
        const values = entries.filter((_, i) => i % 3 === 2)
        const unset = (value: string): boolean => value === 'unspecified' || value === 'unset'
        if (values.length !== present.length || !values.every(unset)) {
          return { ok: false, rule: 'filter' }
        }
      }

      await run(['read-tree', o.head])
      await run(['add', '-A', '--', ...paths], ADD_FAILED)
      // A process of the session can still change a file. The commit holds the checked files only.
      for (const [i, file] of paths.entries()) {
        if (statKey(await read(() => lstatOrNull(join(path, file)))) !== keys[i]) {
          throw new Error(reasonCommitFailed(FILE_CHANGED))
        }
      }
      const staged = stagedModes(
        await run(['diff-index', '--cached', '--no-renames', '--raw', '-z', o.head, '--']),
      )
      if (staged === null) throw new Error(reasonCommitFailed(BAD_LIST))
      for (const mode of staged.values()) {
        if (mode === GITLINK) return { ok: false, rule: 'submodule' }
        if (!FILE_MODES.includes(mode)) return { ok: false, rule: 'link' }
      }
      if (!sameSet([...staged.keys()], paths)) return { ok: false, rule: 'unchanged' }

      // The commit never signs: a key can need a passphrase or a prompt of a password app, and
      // a round never waits for a person. Hooks do not run (GIT_CONFIG).
      await run(['commit', '--quiet', '--no-gpg-sign', '--cleanup=whitespace', '-m', o.message])
      const sha = (await run(['rev-parse', '--verify', 'HEAD^{commit}'])).trim()
      const made = commitParts(await run(['cat-file', 'commit', sha]))
      if (!OBJECT_ID.test(sha) || !sameSet(made.parents, [o.head])) {
        throw new Error(reasonCommitFailed(BAD_PARENT))
      }
      return { ok: true, sha }
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

    async fetchPr(clone, number, baseRef, opts) {
      if (baseRef.startsWith('-') || !(await isBranchName(clone, baseRef))) {
        throw new Error(`${FETCH_FAILED}the name of the base branch isn't valid.`)
      }
      const prRef = `refs/bifrost/pr/${number}`
      const baseRefLocal = `refs/bifrost/base/${number}`
      await mustIn(
        clone,
        [
          ...(opts?.noPrompt === true ? NO_PROMPT_CONFIG : []),
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
      const mergeBase = (await mustIn(clone, ['merge-base', head, base], PREPARE_FAILED)).trim()
      checkCommit(mergeBase)
      return { base, head, mergeBase }
    },

    async hasCommit(clone, sha) {
      if (!OBJECT_ID.test(sha)) return false
      return !failed(await gitIn(clone, ['cat-file', '-e', `${sha}^{commit}`]))
    },

    async isAncestor(clone, a, b) {
      if (!OBJECT_ID.test(a) || !OBJECT_ID.test(b)) return false
      return !failed(await gitIn(clone, ['merge-base', '--is-ancestor', a, b]))
    },

    async prepareWorktree(clone, number, head) {
      checkCommit(head)
      const path = worktreePath(clone, number)
      await checkOwned(path)
      await dropWorktree(clone, path)
      await mustIn(clone, ['worktree', 'prune'], PREPARE_FAILED)
      await mkdir(dirname(path), { mode: 0o700, recursive: true })
      // The checkout downloads the files of the head, so it gets the long timeout.
      await mustIn(
        clone,
        ['worktree', 'add', '--quiet', '--detach', '--force', path, head],
        PREPARE_FAILED,
        CLONE_TIMEOUT_MS,
      )
      // git names the admin folder after the worktree folder. An old admin folder with that
      // name makes git choose another name, and then the commands of checkAndClean fail.
      if (!(await linksBack(clone, number))) {
        await dropWorktree(clone, path)
        await gitIn(clone, ['worktree', 'prune'])
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
      // A delete that stops half way can leave a .git folder that looks like a clone. So each
      // folder moves to a new name first, and cloneOf no longer finds its clones.
      // First delete each folder that an earlier removeAll left, so that its name is free.
      for (const name of names.filter(entry => entry.endsWith(DELETE_SUFFIX))) {
        await remove(join(root, name))
      }
      for (const name of names.filter(entry => !entry.endsWith(DELETE_SUFFIX))) {
        const from = join(root, name)
        const to = join(root, `${name}${DELETE_SUFFIX}`)
        await checkOwned(from)
        await checkOwned(to)
        await rename(from, to)
        await remove(to)
      }
    },

    async removeWorktree(clone, number) {
      const path = worktreePath(clone, number)
      const io = ioPath(clone, number)
      await checkOwned(path)
      await checkOwned(io)
      await dropWorktree(clone, path)
      const pruned = isClone(clone) ? await gitIn(clone, ['worktree', 'prune']) : null
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
      await mustIn(
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
