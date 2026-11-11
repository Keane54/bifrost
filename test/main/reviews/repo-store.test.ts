// The repository store runs the real git on repositories in a temporary folder only.
// The env has no global and no system git config, and the remote is a file:// URL.

import { existsSync } from 'node:fs'
import {
  chmod,
  lstat,
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  realpath,
  rm,
  stat,
  symlink,
  writeFile,
} from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { basename, dirname, join, resolve } from 'node:path'
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest'
import { type ExecFn, execFile } from '../../../src/main/claude/cli'
import {
  CLONE_TIMEOUT_MS,
  createRepoGit,
  GIT_CONFIG,
  GIT_MAX_BUFFER,
  GIT_TIMEOUT_MS,
  type RepoGit,
} from '../../../src/main/reviews/repo-git'
import {
  adminPath,
  clonePath,
  ioPath,
  REFUSED_BAD_REPO,
  reposRoot,
  worktreePath,
} from '../../../src/main/reviews/repo-paths'
import {
  createRepoStore,
  REASON_NOT_OWNED,
  type RepoStore,
  remoteBase,
} from '../../../src/main/reviews/repo-store'

const FETCH_FAILED = "Bifrost couldn't get the pull request from GitHub: "
const PREPARE_FAILED = "Bifrost couldn't prepare its copy of the pull request: "
// The name of the test is long, so it is a constant. Then each line has 100 characters or less.
const GIT_RUN_TEST =
  'createRepoGit puts GIT_CONFIG before the arguments and sets GIT_TERMINAL_PROMPT=0'

let base: string
let env: Record<string, string>
let commits: { base: string; first: string; head: string; link: string }

async function git(args: string[], cwd = base): Promise<string> {
  const result = await execFile('git', args, { cwd, env, timeoutMs: 30_000 })
  if (result.code !== 0) throw new Error(`git ${args.join(' ')}: ${result.stderr}`)
  return result.stdout.trim()
}

// Each file below the folder, with its change time and its content.
async function snapshot(dir: string): Promise<Record<string, string>> {
  const out: Record<string, string> = {}
  for (const name of (await readdir(dir, { recursive: true })).sort()) {
    const path = join(dir, name)
    const info = await lstat(path)
    out[name] = info.isFile() ? `${info.mtimeMs}:${await readFile(path, 'utf8')}` : 'folder'
  }
  return out
}

type Call = { args: string[]; timeoutMs: number | undefined }

async function makeStore(
  opts: { env?: Record<string, string>; home?: string; remote?: string } = {},
): Promise<{
  calls: Call[]
  home: string
  store: RepoStore
}> {
  const home = opts.home ?? (await mkdtemp(join(base, 'home-')))
  const calls: Call[] = []
  const exec: ExecFn = (file, args, execOpts) => {
    calls.push({ args: args.slice(GIT_CONFIG.length), timeoutMs: execOpts?.timeoutMs })
    return execFile(file, args, execOpts)
  }
  const store = createRepoStore({
    bifrostHome: home,
    git: createRepoGit({ env: async () => opts.env ?? env, exec }),
    remoteBase: opts.remote ?? remoteBase(base),
  })
  return { calls, home, store }
}

// The git command of a call, after the options that name the git folder and the worktree.
const commandOf = (call: Call): string | undefined =>
  call.args.find(arg => !arg.startsWith('--git-dir=') && !arg.startsWith('--work-tree='))
const callsOf = (calls: Call[], command: string): Call[] =>
  calls.filter(call => commandOf(call) === command)
const clonesIn = (calls: Call[]): Call[] => callsOf(calls, 'clone')

beforeAll(async () => {
  base = await mkdtemp(join(tmpdir(), 'bifrost-repo-store-'))
  env = {
    GIT_AUTHOR_EMAIL: 'test@example.invalid',
    GIT_AUTHOR_NAME: 'Bifrost Test',
    GIT_COMMITTER_EMAIL: 'test@example.invalid',
    GIT_COMMITTER_NAME: 'Bifrost Test',
    GIT_CONFIG_GLOBAL: '/dev/null',
    GIT_CONFIG_NOSYSTEM: '1',
    HOME: base,
    PATH: process.env.PATH ?? '/usr/bin:/bin',
  }
  const work = join(base, 'work')
  await git(['init', '-q', '-b', 'main', work])
  await mkdir(join(work, 'src'))
  await mkdir(join(work, 'docs'))
  const lines = Array.from({ length: 20 }, (_, i) => `export const line${i + 1} = ${i + 1}`)
  await writeFile(join(work, 'src/limit.ts'), `${lines.join('\n')}\n`)
  await writeFile(join(work, 'docs/guide.md'), 'One.\nTwo.\nThree.\nFour.\nFive.\n')
  await writeFile(join(work, 'README.md'), 'hello\n')
  await writeFile(join(work, '.gitignore'), '*.log\n')
  await git(['add', '.'], work)
  await git(['commit', '-q', '-m', 'first'], work)
  const first = await git(['rev-parse', 'HEAD'], work)
  // The PR changes line 12, adds a file and renames a file.
  await git(['switch', '-q', '-c', 'pr'], work)
  lines[11] = 'export const line12 = 1200'
  await writeFile(join(work, 'src/limit.ts'), `${lines.join('\n')}\n`)
  await writeFile(join(work, 'src/new.ts'), 'export const fresh = true\n')
  await git(['mv', 'docs/guide.md', 'docs/renamed.md'], work)
  await git(['add', '.'], work)
  await git(['commit', '-q', '-m', 'pr'], work)
  const head = await git(['rev-parse', 'HEAD'], work)
  // PR 8 adds a symbolic link to a file outside the repository.
  await writeFile(join(base, 'secret.txt'), 'secret')
  await git(['switch', '-q', '-c', 'pr8'], work)
  await symlink(join(base, 'secret.txt'), join(work, 'src/escape.ts'))
  await git(['add', '.'], work)
  await git(['commit', '-q', '-m', 'link'], work)
  const link = await git(['rev-parse', 'HEAD'], work)
  // main moves on after the start of the PR.
  await git(['switch', '-q', 'main'], work)
  await writeFile(join(work, 'README.md'), 'hello\nmain moved\n')
  await git(['commit', '-q', '-am', 'main'], work)
  const main = await git(['rev-parse', 'HEAD'], work)
  commits = { base: main, first, head, link }
  for (const name of ['acme/api', 'globex/web']) {
    const bare = join(base, 'git-remotes', `${name}.git`)
    await git(['clone', '-q', '--bare', work, bare])
    await git(['update-ref', 'refs/pull/7/head', head], bare)
    await git(['update-ref', 'refs/pull/8/head', link], bare)
    await git(['update-ref', '-d', 'refs/heads/pr'], bare)
    await git(['update-ref', '-d', 'refs/heads/pr8'], bare)
  }
})

afterAll(async () => {
  await rm(base, { force: true, recursive: true })
})

describe('remoteBase', () => {
  it('gives GitHub, or the git-remotes folder of a test home', () => {
    expect(remoteBase(null)).toBe('https://github.com/')
    expect(remoteBase('/t/home')).toBe('file:///t/home/git-remotes/')
  })
})

describe('createRepoGit', () => {
  it(GIT_RUN_TEST, async () => {
    expect(GIT_CONFIG).toEqual([
      '-c',
      'core.hooksPath=/dev/null',
      '-c',
      'core.fsmonitor=false',
      '-c',
      'core.quotePath=false',
      '-c',
      'credential.helper=',
      '-c',
      'credential.helper=!gh auth git-credential',
      '-c',
      'advice.detachedHead=false',
      '-c',
      'core.symlinks=false',
      '-c',
      'submodule.recurse=false',
    ])
    expect(GIT_TIMEOUT_MS).toBe(120_000)
    expect(CLONE_TIMEOUT_MS).toBe(900_000)
    const exec = vi.fn<ExecFn>(async () => ({ code: 0, stderr: '', stdout: 'ok' }))
    const repoGit = createRepoGit({
      env: async () => ({ GIT_TERMINAL_PROMPT: '1', PATH: '/bin' }),
      exec,
    })
    expect((await repoGit.run(['status'], { cwd: '/w' })).stdout).toBe('ok')
    expect(exec).toHaveBeenCalledWith('git', [...GIT_CONFIG, 'status'], {
      cwd: '/w',
      env: {
        GCM_INTERACTIVE: 'never',
        GIT_LFS_SKIP_SMUDGE: '1',
        GIT_TERMINAL_PROMPT: '0',
        PATH: '/bin',
      },
      maxBuffer: GIT_MAX_BUFFER,
      timeoutMs: GIT_TIMEOUT_MS,
    })
    await repoGit.run(['fetch'], { timeoutMs: 5 })
    expect(exec).toHaveBeenLastCalledWith('git', [...GIT_CONFIG, 'fetch'], {
      env: expect.objectContaining({ GIT_TERMINAL_PROMPT: '0' }),
      maxBuffer: GIT_MAX_BUFFER,
      timeoutMs: 5,
    })
  })

  it('removes each GIT_ variable of the env, but keeps the git config of a test home', async () => {
    const exec = vi.fn<ExecFn>(async () => ({ code: 0, stderr: '', stdout: '' }))
    const repoGit = createRepoGit({
      env: async () => ({
        GIT_ASKPASS: '/x/askpass',
        GIT_COMMON_DIR: '/x/common',
        GIT_CONFIG_COUNT: '1',
        GIT_CONFIG_GLOBAL: '/dev/null',
        GIT_CONFIG_KEY_0: 'core.hooksPath',
        GIT_CONFIG_NOSYSTEM: '1',
        GIT_CONFIG_PARAMETERS: "'core.hookspath'='/x'",
        GIT_CONFIG_VALUE_0: '/x/hooks',
        GIT_DIR: '/x/.git',
        GIT_INDEX_FILE: '/x/index',
        GIT_OBJECT_DIRECTORY: '/x/objects',
        GIT_TRACE: '1',
        GIT_TRACE2_EVENT: '/x/trace',
        GIT_WORK_TREE: '/x',
        HOME: '/h',
        PATH: '/bin',
      }),
      exec,
    })
    await repoGit.run(['status'])
    expect(exec.mock.calls[0]?.[2]?.env).toEqual({
      GCM_INTERACTIVE: 'never',
      GIT_CONFIG_GLOBAL: '/dev/null',
      GIT_CONFIG_NOSYSTEM: '1',
      GIT_LFS_SKIP_SMUDGE: '1',
      GIT_TERMINAL_PROMPT: '0',
      HOME: '/h',
      PATH: '/bin',
    })
  })
})

// Each test runs real git commands. A slow machine needs more than the default 5 seconds.
describe('createRepoStore', { timeout: 30_000 }, () => {
  it('clones once and leaves no temporary folder after a failed clone', async () => {
    const { calls, home, store } = await makeStore()
    const clone = await store.ensureClone('Acme', 'API')
    expect(clone).toBe(clonePath(home, 'acme', 'api'))
    expect(existsSync(join(clone, '.git'))).toBe(true)
    expect((await stat(clone)).mode & 0o777).toBe(0o700)
    expect((await stat(reposRoot(home))).mode & 0o777).toBe(0o700)
    expect(await store.ensureClone('acme', 'api')).toBe(clone)
    const clones = clonesIn(calls)
    expect(clones).toHaveLength(1)
    expect(clones[0]?.timeoutMs).toBe(CLONE_TIMEOUT_MS)
    expect(clones[0]?.args).toEqual(
      expect.arrayContaining([
        '--no-checkout',
        '--filter=blob:none',
        `${remoteBase(base)}acme/api.git`,
      ]),
    )

    const failed = store.ensureClone('acme', 'missing')
    await expect(failed).rejects.toThrow(/^Bifrost couldn't copy acme\/missing: \S/)
    const message = (await failed.catch((error: Error) => error)) as Error
    expect(message.message.length).toBeLessThanOrEqual(
      "Bifrost couldn't copy acme/missing: ".length + 200,
    )
    expect(await readdir(join(reposRoot(home), 'acme'))).toEqual(['api'])
    expect(store.cloneOf('acme', 'missing')).toBeNull()
  })

  it('deletes a temporary folder that an earlier run left', async () => {
    const wrong = await makeStore({ remote: `file://${base}/nowhere/` })
    await expect(wrong.store.ensureClone('acme', 'api')).rejects.toThrow(/^Bifrost couldn't copy/)
    const temp = clonesIn(wrong.calls)[0]?.args.at(-1) as string
    expect(dirname(temp)).toBe(join(reposRoot(wrong.home), 'acme'))
    expect(existsSync(temp)).toBe(false)
    // An earlier run stopped during the clone and left its temporary folder.
    await mkdir(join(temp, '.git'), { recursive: true })
    await writeFile(join(temp, 'junk'), 'x')
    const { store } = await makeStore({ home: wrong.home })
    const clone = await store.ensureClone('acme', 'api')
    expect(existsSync(temp)).toBe(false)
    expect(await readdir(dirname(clone))).toEqual(['api'])
  })

  it('two calls of ensureClone during one clone run one git clone', async () => {
    const { calls, store } = await makeStore()
    const first = store.ensureClone('acme', 'api')
    const second = store.ensureClone('ACME', 'Api')
    expect(second).toBe(first)
    expect(await second).toBe(await first)
    expect(clonesIn(calls)).toHaveLength(1)
  })

  it('cloneOf gives null before the clone and the path after it', async () => {
    const { home, store } = await makeStore()
    expect(store.cloneOf('acme', 'api')).toBeNull()
    // A folder with no .git is not a clone. ensureClone replaces it.
    await mkdir(join(clonePath(home, 'acme', 'api'), '.bifrost-io'), { recursive: true })
    expect(store.cloneOf('acme', 'api')).toBeNull()
    const clone = await store.ensureClone('acme', 'api')
    expect(store.cloneOf('Acme', 'Api')).toBe(clone)
    expect(() => store.cloneOf('acme', '..')).toThrow(REFUSED_BAD_REPO)
    await expect(store.ensureClone('acme', '..')).rejects.toThrow(REFUSED_BAD_REPO)
  })

  it('resetIo deletes the old input folder and makes a new one with mode 0700', async () => {
    const { store } = await makeStore()
    const clone = await store.ensureClone('acme', 'api')
    const io = await store.resetIo(clone, 7)
    expect(io).toBe(ioPath(clone, 7))
    await writeFile(join(io, 'result.json'), '{}')
    await mkdir(join(io, 'sub'))
    await writeFile(join(io, 'sub', 'x.txt'), 'x')
    expect(await store.resetIo(clone, 7)).toBe(io)
    expect(await readdir(io)).toEqual([])
    expect((await stat(io)).mode & 0o777).toBe(0o700)
    expect((await stat(dirname(io))).mode & 0o777).toBe(0o700)
  })

  it('fetches the PR head and the base, and refuses a base name that starts with -', async () => {
    const { calls, store } = await makeStore()
    const clone = await store.ensureClone('acme', 'api')
    expect(await store.fetchPr(clone, 7, 'main')).toEqual({
      base: commits.base,
      head: commits.head,
      mergeBase: commits.first,
    })
    expect(await git(['rev-parse', 'refs/bifrost/pr/7'], clone)).toBe(commits.head)
    expect(await git(['rev-parse', 'refs/bifrost/base/7'], clone)).toBe(commits.base)
    const fetches = (): Call[] => callsOf(calls, 'fetch')
    // Each command on the clone names its .git folder.
    for (const call of calls.filter(call => commandOf(call) !== 'clone')) {
      expect(call.args[0]).toBe(`--git-dir=${join(clone, '.git')}`)
    }
    expect(fetches()).toHaveLength(1)
    expect(fetches()[0]?.args).toEqual(
      expect.arrayContaining([
        '--no-tags',
        '+refs/pull/7/head:refs/bifrost/pr/7',
        '+refs/heads/main:refs/bifrost/base/7',
      ]),
    )
    for (const bad of ['-main', '--upload-pack=touch x', 'a..b', '@{-1}', 'main:x', 'a b', '']) {
      await expect(store.fetchPr(clone, 7, bad), bad).rejects.toThrow(FETCH_FAILED)
    }
    expect(fetches()).toHaveLength(1)
    // A name that starts with - never goes to git.
    expect(calls.some(call => call.args.some(arg => arg.includes('-main')))).toBe(false)
    // The remote has no PR 9.
    await expect(store.fetchPr(clone, 9, 'main')).rejects.toThrow(
      /^Bifrost couldn't get the pull request from GitHub: \S/,
    )
  })

  it('hasCommit and isAncestor read the clone', async () => {
    const { store } = await makeStore()
    const clone = await store.ensureClone('acme', 'api')
    await store.fetchPr(clone, 7, 'main')
    expect(await store.hasCommit(clone, commits.head)).toBe(true)
    expect(await store.hasCommit(clone, '0'.repeat(40))).toBe(false)
    expect(await store.hasCommit(clone, 'main')).toBe(false)
    expect(await store.isAncestor(clone, commits.first, commits.head)).toBe(true)
    expect(await store.isAncestor(clone, commits.base, commits.head)).toBe(false)
    expect(await store.isAncestor(clone, '--help', commits.head)).toBe(false)
  })

  it('writes the merge-base diff and the direct diff', async () => {
    const { store } = await makeStore()
    const clone = await store.ensureClone('acme', 'api')
    const pr = await store.fetchPr(clone, 7, 'main')
    const io = await store.resetIo(clone, 7)
    await store.writeDiff(clone, pr.base, pr.head, join(io, 'full.diff'), 'merge-base')
    await store.writeDiff(clone, pr.base, pr.head, join(io, 'since.diff'), 'direct')
    const full = await readFile(join(io, 'full.diff'), 'utf8')
    expect(full).toContain('diff --git a/src/limit.ts b/src/limit.ts')
    expect(full).toContain('+export const line12 = 1200')
    expect(full).toContain('+++ b/src/new.ts')
    expect(full).toContain('rename from docs/guide.md')
    expect(full).not.toContain('README.md')
    const direct = await readFile(join(io, 'since.diff'), 'utf8')
    expect(direct).toContain('diff --git a/README.md b/README.md')
    expect(direct).toContain('-main moved')
    expect(direct).toContain('+export const line12 = 1200')
    await expect(
      store.writeDiff(clone, 'main', pr.head, join(io, 'x.diff'), 'direct'),
    ).rejects.toThrow(PREPARE_FAILED)
    expect(existsSync(join(io, 'x.diff'))).toBe(false)
  })

  it('prepares a detached worktree at the head', async () => {
    const { store } = await makeStore()
    const clone = await store.ensureClone('acme', 'api')
    const pr = await store.fetchPr(clone, 7, 'main')
    const path = await store.prepareWorktree(clone, 7, pr.head)
    const admin = adminPath(clone, 7)
    expect(path).toBe(worktreePath(clone, 7))
    expect(await git([`--git-dir=${admin}`, 'rev-parse', 'HEAD'])).toBe(pr.head)
    const branch = await execFile('git', [`--git-dir=${admin}`, 'symbolic-ref', '-q', 'HEAD'], {
      cwd: base,
      env,
    })
    expect(branch.code).toBe(1)
    expect(await readFile(join(path, 'src/new.ts'), 'utf8')).toContain('fresh')
    const named = (await readFile(join(admin, 'gitdir'), 'utf8')).trim()
    expect(await realpath(named)).toBe(await realpath(join(path, '.git')))
    expect((await stat(path)).mode & 0o777).toBe(0o700)

    // A second prepare gives a new worktree with the same admin folder.
    await writeFile(join(path, 'stray.txt'), 'x')
    expect(await store.prepareWorktree(clone, 7, commits.first)).toBe(path)
    expect(await git([`--git-dir=${admin}`, 'rev-parse', 'HEAD'])).toBe(commits.first)
    expect(existsSync(join(path, 'stray.txt'))).toBe(false)
    expect(existsSync(join(path, 'src/new.ts'))).toBe(false)
    expect(await readdir(join(clone, '.git', 'worktrees'))).toEqual(['7'])

    await expect(store.prepareWorktree(clone, 7, 'main')).rejects.toThrow(PREPARE_FAILED)
    await expect(store.prepareWorktree(clone, 8, '1'.repeat(40))).rejects.toThrow(PREPARE_FAILED)
  })

  it('cleans a worktree whose .git file the session changed', async () => {
    const { store } = await makeStore()
    const clone = await store.ensureClone('acme', 'api')
    const pr = await store.fetchPr(clone, 7, 'main')
    const path = await store.prepareWorktree(clone, 7, pr.head)
    const admin = adminPath(clone, 7)
    // A git folder that a git command would change if it read the changed .git file.
    const other = await mkdtemp(join(base, 'other-'))
    await git(['init', '-q', '--bare', other])
    const before = await snapshot(other)

    await writeFile(join(path, 'stray.txt'), 'stray')
    await writeFile(join(path, 'debug.log'), 'ignored')
    await writeFile(join(path, 'src/limit.ts'), 'changed\n')
    await writeFile(join(path, '.git'), `gitdir: ${other}\n`)

    const { changed } = await store.checkAndClean(clone, 7, pr.head)
    expect(changed).toBeGreaterThanOrEqual(2)
    expect(changed).toBe(3)
    expect(
      await git([
        `--git-dir=${admin}`,
        `--work-tree=${path}`,
        'status',
        '--porcelain',
        '--untracked-files=all',
        '--ignored',
      ]),
    ).toBe('')
    expect(await readFile(join(path, '.git'), 'utf8')).toBe(`gitdir: ${admin}\n`)
    expect(existsSync(join(path, 'stray.txt'))).toBe(false)
    expect(existsSync(join(path, 'debug.log'))).toBe(false)
    expect(await readFile(join(path, 'src/limit.ts'), 'utf8')).toContain('line12 = 1200')
    // The .git file works again.
    expect(await git(['rev-parse', 'HEAD'], path)).toBe(pr.head)
    expect(await snapshot(other)).toEqual(before)

    // A clean worktree gives 0.
    expect(await store.checkAndClean(clone, 7, pr.head)).toEqual({ changed: 0 })
  })

  it('removes a worktree that is already gone', async () => {
    const { home, store } = await makeStore()
    const clone = await store.ensureClone('acme', 'api')
    const pr = await store.fetchPr(clone, 7, 'main')
    const path = await store.prepareWorktree(clone, 7, pr.head)
    const io = await store.resetIo(clone, 7)
    await rm(path, { force: true, recursive: true })
    await store.removeWorktree(clone, 7)
    expect(existsSync(adminPath(clone, 7))).toBe(false)
    expect(existsSync(io)).toBe(false)
    expect(await git(['worktree', 'list', '--porcelain'], clone)).not.toContain(
      '.bifrost-worktrees',
    )

    // A worktree whose .git file the session changed also goes.
    const again = await store.prepareWorktree(clone, 7, pr.head)
    await writeFile(join(again, '.git'), `gitdir: ${base}\n`)
    await store.removeWorktree(clone, 7)
    expect(existsSync(again)).toBe(false)
    expect(existsSync(adminPath(clone, 7))).toBe(false)

    // Nothing to remove is not an error.
    await store.removeWorktree(clone, 8)
    await store.removeWorktree(clonePath(home, 'acme', 'nothing'), 3)
  })

  it('refuses to delete a folder outside reposRoot', async () => {
    const { home, store } = await makeStore()
    const clone = await store.ensureClone('acme', 'api')
    const root = reposRoot(home)
    const victim = await mkdtemp(join(base, 'victim-'))
    const keep = [join(ioPath(victim, 7), 'keep.txt'), join(worktreePath(victim, 7), 'keep.txt')]
    for (const file of keep) {
      await mkdir(dirname(file), { recursive: true })
      await writeFile(file, 'keep')
    }
    // The same folder through .. and through a link below the root.
    const up = `${root}/acme/../../../../${basename(victim)}`
    expect(resolve(up)).toBe(victim)
    const link = join(root, 'evil')
    await symlink(victim, link)
    for (const outside of [victim, up, link]) {
      await expect(store.resetIo(outside, 7), outside).rejects.toThrow(REASON_NOT_OWNED)
      await expect(store.removeWorktree(outside, 7), outside).rejects.toThrow(REASON_NOT_OWNED)
      await expect(store.prepareWorktree(outside, 7, commits.head), outside).rejects.toThrow(
        REASON_NOT_OWNED,
      )
      await expect(store.checkAndClean(outside, 7, commits.head), outside).rejects.toThrow(
        REASON_NOT_OWNED,
      )
    }
    // A link in the clone, for example a link that a session made.
    await symlink(join(victim, '.bifrost-io'), join(clone, '.bifrost-io'))
    await expect(store.resetIo(clone, 7)).rejects.toThrow(REASON_NOT_OWNED)
    await expect(store.removeWorktree(clone, 7)).rejects.toThrow(REASON_NOT_OWNED)
    for (const file of keep) expect(await readFile(file, 'utf8')).toBe('keep')
  })

  it('removeAll deletes each clone and keeps reposRoot', async () => {
    const { home, store } = await makeStore()
    await store.ensureClone('acme', 'api')
    await store.ensureClone('globex', 'web')
    const root = reposRoot(home)
    const victim = await mkdtemp(join(base, 'victim-'))
    await writeFile(join(victim, 'keep.txt'), 'keep')
    await symlink(victim, join(root, 'link'))
    await store.removeAll()
    expect(await readdir(root)).toEqual([])
    expect((await stat(root)).isDirectory()).toBe(true)
    // The delete removes the link, not the folder that the link names.
    expect(await readFile(join(victim, 'keep.txt'), 'utf8')).toBe('keep')
    expect(store.cloneOf('acme', 'api')).toBeNull()
    // No root is not an error.
    const empty = await makeStore()
    await empty.store.removeAll()
    expect(existsSync(reposRoot(empty.home))).toBe(false)
  })

  it('a clone folder with no .git never lets git act on an outer repository', async () => {
    const outer = await mkdtemp(join(base, 'outer-'))
    await git(['init', '-q', '-b', 'main', outer])
    await writeFile(join(outer, 'a.txt'), 'a\n')
    await git(['add', '.'], outer)
    await git(['commit', '-q', '-m', 'one'], outer)
    const one = await git(['rev-parse', 'HEAD'], outer)
    await writeFile(join(outer, 'a.txt'), 'b\n')
    await git(['commit', '-q', '-am', 'two'], outer)
    const two = await git(['rev-parse', 'HEAD'], outer)
    const home = join(outer, 'home')
    await mkdir(home)
    const { store } = await makeStore({ home })
    const clone = clonePath(home, 'acme', 'api')
    // resetIo makes the clone folder, but not its .git folder.
    const io = await store.resetIo(clone, 7)
    expect(existsSync(join(clone, '.git'))).toBe(false)
    const before = await snapshot(join(outer, '.git'))

    await expect(store.fetchPr(clone, 7, 'main')).rejects.toThrow(FETCH_FAILED)
    expect(await store.hasCommit(clone, two)).toBe(false)
    expect(await store.isAncestor(clone, one, two)).toBe(false)
    await expect(store.writeDiff(clone, one, two, join(io, 'full.diff'), 'direct')).rejects.toThrow(
      PREPARE_FAILED,
    )
    await expect(store.prepareWorktree(clone, 7, two)).rejects.toThrow(PREPARE_FAILED)
    await expect(store.checkAndClean(clone, 7, two)).rejects.toThrow(PREPARE_FAILED)
    await store.removeWorktree(clone, 7)

    expect(await snapshot(join(outer, '.git'))).toEqual(before)
    expect(await git(['worktree', 'list', '--porcelain'], outer)).not.toContain('.bifrost')
  })

  it('checks out a symbolic link of the PR as a plain file', async () => {
    const { store } = await makeStore()
    const clone = await store.ensureClone('acme', 'api')
    const pr = await store.fetchPr(clone, 8, 'main')
    expect(pr.head).toBe(commits.link)
    const path = await store.prepareWorktree(clone, 8, pr.head)
    const file = join(path, 'src/escape.ts')
    const secret = join(base, 'secret.txt')
    const isPlain = async (): Promise<void> => {
      const info = await lstat(file)
      expect(info.isSymbolicLink()).toBe(false)
      expect(info.isFile()).toBe(true)
      expect(await readFile(file, 'utf8')).toBe(secret)
    }
    await isPlain()
    expect(await store.checkAndClean(clone, 8, pr.head)).toEqual({ changed: 0 })
    await isPlain()
    // The session writes the file. The clean gives the plain file back.
    await writeFile(file, 'changed\n')
    expect(await store.checkAndClean(clone, 8, pr.head)).toEqual({ changed: 1 })
    await isPlain()
    expect(await readFile(secret, 'utf8')).toBe('secret')
  })

  it('cleans the worktree also when the count of changes fails', async () => {
    const home = await mkdtemp(join(base, 'home-'))
    const real = createRepoGit({ env: async () => env, exec: execFile })
    // The status command gives more output than the buffer holds.
    const overflow = {
      code: 1,
      overflow: true,
      stderr: 'stdout maxBuffer length exceeded',
      stdout: '',
    }
    const repoGit: RepoGit = {
      run: (args, opts) =>
        args.includes('status') ? Promise.resolve(overflow) : real.run(args, opts),
    }
    const store = createRepoStore({ bifrostHome: home, git: repoGit, remoteBase: remoteBase(base) })
    const clone = await store.ensureClone('acme', 'api')
    const pr = await store.fetchPr(clone, 7, 'main')
    const path = await store.prepareWorktree(clone, 7, pr.head)
    await writeFile(join(path, 'stray.txt'), 'stray')
    await writeFile(join(path, 'src/limit.ts'), 'changed\n')
    await writeFile(join(path, '.git'), `gitdir: ${base}\n`)
    await expect(store.checkAndClean(clone, 7, pr.head)).rejects.toThrow(
      `${PREPARE_FAILED}git gave too much output.`,
    )
    expect(existsSync(join(path, 'stray.txt'))).toBe(false)
    expect(await readFile(join(path, 'src/limit.ts'), 'utf8')).toContain('line12 = 1200')
    expect(await readFile(join(path, '.git'), 'utf8')).toBe(`gitdir: ${adminPath(clone, 7)}\n`)
  })

  it('removeAll moves each folder away first, so a delete that stops leaves no clone', async () => {
    const { home, store } = await makeStore()
    const clone = await store.ensureClone('acme', 'api')
    const root = reposRoot(home)
    // rm cannot empty a folder with no write permission, so the delete stops half way.
    const locked = join(clone, '.bifrost-io', '7', 'locked')
    const moved = join(root, 'acme~deleting', 'api', '.bifrost-io', '7', 'locked')
    await mkdir(locked, { recursive: true })
    await writeFile(join(locked, 'x'), 'x')
    await chmod(locked, 0o500)
    try {
      await expect(store.removeAll()).rejects.toThrow()
      expect(existsSync(clone)).toBe(false)
      expect(store.cloneOf('acme', 'api')).toBeNull()
    } finally {
      for (const dir of [locked, moved]) await chmod(dir, 0o700).catch(() => undefined)
    }
    expect(await readdir(root)).toEqual(['acme~deleting'])
    // The next removeAll also deletes the folder that the earlier one left.
    await store.ensureClone('acme', 'api')
    await store.removeAll()
    expect(await readdir(root)).toEqual([])
  })

  it('clones with the remote name origin when the user config names another', async () => {
    const config = join(base, 'user.gitconfig')
    await writeFile(config, '[clone]\n\tdefaultRemoteName = upstream\n[diff]\n\tnoprefix = true\n')
    const { store } = await makeStore({ env: { ...env, GIT_CONFIG_GLOBAL: config } })
    const clone = await store.ensureClone('acme', 'api')
    const pr = await store.fetchPr(clone, 7, 'main')
    expect(pr.head).toBe(commits.head)
    const io = await store.resetIo(clone, 7)
    await store.writeDiff(clone, pr.base, pr.head, join(io, 'full.diff'), 'merge-base')
    expect(await readFile(join(io, 'full.diff'), 'utf8')).toContain(
      'diff --git a/src/limit.ts b/src/limit.ts',
    )
  })
})
