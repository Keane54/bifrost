// The repository store runs the real git on repositories in a temporary folder only.
// The env has no global and no system git config, and the remote is a file:// URL.

import { existsSync } from 'node:fs'
import {
  chmod,
  link,
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
  CommitError,
  createRepoStore,
  MAX_FIX_FILE,
  REASON_NOT_OWNED,
  type RepoStore,
  remoteBase,
  type UnsafeRule,
} from '../../../src/main/reviews/repo-store'
import { REASON_PUSH_GIT_FAILED, reasonCommitFailed } from '../../../src/main/reviews/round-text'

const FETCH_FAILED = "Bifrost couldn't get the pull request from GitHub: "
const PREPARE_FAILED = "Bifrost couldn't prepare its copy of the pull request: "
// The name of the test is long, so it is a constant. Then each line has 100 characters or less.
const GIT_RUN_TEST =
  'createRepoGit puts GIT_CONFIG before the arguments and sets GIT_TERMINAL_PROMPT=0'
const UNSAFE_TEST =
  'commitFix refuses a workflow file, .gitmodules, a submodule, a link, a hard link ' +
  'and a file over MAX_FIX_FILE'
// The env of the store has no git identity. A test home gives it with extraConfig.
const IDENTITY = ['-c', 'user.name=Bifrost Test', '-c', 'user.email=bifrost-test@example.invalid']

let base: string
let env: Record<string, string>
let commits: { base: string; first: string; head: string; link: string; sub: string }

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

type StoreOpts = {
  env?: Record<string, string>
  extraConfig?: string[]
  home?: string
  remote?: string
}

async function makeStore(opts: StoreOpts = {}): Promise<{
  calls: Call[]
  home: string
  store: RepoStore
}> {
  const home = opts.home ?? (await mkdtemp(join(base, 'home-')))
  const extraConfig = opts.extraConfig ?? IDENTITY
  const calls: Call[] = []
  const exec: ExecFn = (file, args, execOpts) => {
    const skip = GIT_CONFIG.length + extraConfig.length
    calls.push({ args: args.slice(skip), timeoutMs: execOpts?.timeoutMs })
    return execFile(file, args, execOpts)
  }
  const store = createRepoStore({
    bifrostHome: home,
    git: createRepoGit({ env: async () => opts.env ?? env, exec, extraConfig }),
    remoteBase: opts.remote ?? remoteBase(base),
  })
  return { calls, home, store }
}

// The options that come before the git command of a call on a worktree.
const WORKTREE_OPTION = /^--(?:git-dir=|work-tree=|literal-pathspecs$)/
// The git command of a call, after the options that name the git folder and the worktree.
const commandOf = (call: Call): string | undefined =>
  call.args.find(arg => !WORKTREE_OPTION.test(arg))
const callsOf = (calls: Call[], command: string): Call[] =>
  calls.filter(call => commandOf(call) === command)
const clonesIn = (calls: Call[]): Call[] => callsOf(calls, 'clone')

// The setup runs many git commands. It needs more time when other tests run at once.
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
  // PR 10 adds a workflow file and a submodule to PR 8.
  await git(['switch', '-q', '-c', 'pr10'], work)
  await mkdir(join(work, '.github/workflows'), { recursive: true })
  await writeFile(join(work, '.github/workflows/ci.yml'), 'on: push\n')
  await git(['add', '.'], work)
  await git(['update-index', '--add', '--cacheinfo', `160000,${first},vendor/lib`], work)
  await git(['commit', '-q', '-m', 'submodule'], work)
  const sub = await git(['rev-parse', 'HEAD'], work)
  // main moves on after the start of the PR.
  await git(['switch', '-q', 'main'], work)
  await writeFile(join(work, 'README.md'), 'hello\nmain moved\n')
  await git(['commit', '-q', '-am', 'main'], work)
  const main = await git(['rev-parse', 'HEAD'], work)
  commits = { base: main, first, head, link, sub }
  for (const name of ['acme/api', 'globex/web']) {
    const bare = join(base, 'git-remotes', `${name}.git`)
    await git(['clone', '-q', '--bare', work, bare])
    await git(['update-ref', 'refs/pull/7/head', head], bare)
    await git(['update-ref', 'refs/pull/8/head', link], bare)
    await git(['update-ref', 'refs/pull/10/head', sub], bare)
    for (const branch of ['pr', 'pr8', 'pr10']) {
      await git(['update-ref', '-d', `refs/heads/${branch}`], bare)
    }
  }
}, 60_000)

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

  it('puts extraConfig after GIT_CONFIG and before the arguments', async () => {
    const exec = vi.fn<ExecFn>(async () => ({ code: 0, stderr: '', stdout: '' }))
    const repoGit = createRepoGit({ env: async () => ({}), exec, extraConfig: IDENTITY })
    await repoGit.run(['commit', '--quiet'])
    expect(exec.mock.calls[0]?.[1]).toEqual([...GIT_CONFIG, ...IDENTITY, 'commit', '--quiet'])
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

  it('fetchPr adds the config that stops each prompt only when asked', async () => {
    const { calls, store } = await makeStore()
    const clone = await store.ensureClone('acme', 'api')
    await store.fetchPr(clone, 7, 'main')
    const plain = calls.find(call => call.args.includes('fetch'))?.args ?? []
    expect(plain).not.toContain('core.askPass=')
    expect(plain).not.toContain('protocol.ssh.allow=never')
    const before = calls.length
    expect(await store.fetchPr(clone, 7, 'main', { noPrompt: true })).toEqual({
      base: commits.base,
      head: commits.head,
      mergeBase: commits.first,
    })
    const quiet = calls.slice(before).find(call => call.args.includes('fetch'))?.args ?? []
    expect(quiet.slice(0, 6)).toEqual([
      `--git-dir=${join(clone, '.git')}`,
      '-c',
      'core.askPass=',
      '-c',
      'protocol.ssh.allow=never',
      'fetch',
    ])
    // Only the fetch reaches the network, so only the fetch gets the config.
    for (const call of calls.slice(before).filter(c => !c.args.includes('fetch'))) {
      expect(call.args).not.toContain('core.askPass=')
    }
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

// A worktree of a PR, ready for the changes of a session.
async function fixWorktree(
  number = 7,
  opts: StoreOpts = {},
): Promise<{ calls: Call[]; clone: string; head: string; path: string; store: RepoStore }> {
  const { calls, store } = await makeStore(opts)
  const clone = await store.ensureClone('acme', 'api')
  const { head } = await store.fetchPr(clone, number, 'main')
  const path = await store.prepareWorktree(clone, number, head)
  return { calls, clone, head, path, store }
}

// Run git on the worktree of a PR, with its admin folder named. The output is not trimmed.
async function onAdmin(clone: string, number: number, args: string[]): Promise<string> {
  const admin = adminPath(clone, number)
  const result = await execFile(
    'git',
    [`--git-dir=${admin}`, `--work-tree=${worktreePath(clone, number)}`, ...args],
    { cwd: base, env, timeoutMs: 30_000 },
  )
  if (result.code !== 0) throw new Error(`git ${args.join(' ')}: ${result.stderr}`)
  return result.stdout
}

// The message of a commit, as git keeps it.
async function messageOf(clone: string, sha: string): Promise<string> {
  const raw = await onAdmin(clone, 7, ['cat-file', 'commit', sha])
  return raw.slice(raw.indexOf('\n\n') + 2)
}

// Each change makes one path that Bifrost must not commit, and gives that path.
const UNSAFE: [string, UnsafeRule, (path: string) => Promise<string>][] = [
  [
    'a new workflow file',
    'workflow',
    async path => {
      await writeFile(join(path, '.github/workflows/deploy.yml'), 'on: push\n')
      return '.github/workflows/deploy.yml'
    },
  ],
  [
    'a workflow file in another case',
    'workflow',
    async path => {
      await writeFile(join(path, '.github/workflows/ci.yml'), 'on: pull_request\n')
      return '.GitHub/Workflows/ci.yml'
    },
  ],
  [
    'a file of a GitHub action',
    'workflow',
    async path => {
      await mkdir(join(path, '.github/actions/setup'), { recursive: true })
      await writeFile(join(path, '.github/actions/setup/action.yml'), 'runs:\n  using: node20\n')
      return '.github/actions/setup/action.yml'
    },
  ],
  [
    'a file of a GitHub action in another case',
    'workflow',
    async path => {
      await mkdir(join(path, '.github/actions'), { recursive: true })
      await writeFile(join(path, '.github/actions/x.sh'), 'echo x\n')
      return '.GitHub/Actions/x.sh'
    },
  ],
  [
    'a file in the .claude folder',
    'claude',
    async path => {
      await mkdir(join(path, '.claude'), { recursive: true })
      await writeFile(join(path, '.claude/settings.json'), '{}\n')
      return '.claude/settings.json'
    },
  ],
  [
    'a file in a .claude folder below the root, in another case',
    'claude',
    async path => {
      await mkdir(join(path, 'docs/.claude/skills'), { recursive: true })
      await writeFile(join(path, 'docs/.claude/skills/x.md'), 'x\n')
      return 'docs/.Claude/skills/x.md'
    },
  ],
  [
    '.gitmodules',
    'submodule',
    async path => {
      await writeFile(join(path, '.gitmodules'), '[submodule "x"]\n\tpath = x\n')
      return '.gitmodules'
    },
  ],
  [
    'a deleted submodule',
    'submodule',
    async path => {
      await rm(join(path, 'vendor/lib'), { force: true, recursive: true })
      return 'vendor/lib'
    },
  ],
  [
    'a file in a submodule',
    'submodule',
    async path => {
      await mkdir(join(path, 'vendor/lib'), { recursive: true })
      await writeFile(join(path, 'vendor/lib/x.ts'), 'x\n')
      return 'vendor/lib/x.ts'
    },
  ],
  [
    'a new link',
    'link',
    async path => {
      await symlink(join(base, 'secret.txt'), join(path, 'src/key.ts'))
      return 'src/key.ts'
    },
  ],
  [
    'a link of the PR that the session changed',
    'link',
    async path => {
      // core.symlinks=false keeps the link mode for the plain file.
      await writeFile(join(path, 'src/escape.ts'), '/etc/hosts')
      return 'src/escape.ts'
    },
  ],
  [
    'a hard link',
    'link',
    async path => {
      await link(join(base, 'secret.txt'), join(path, 'key.txt'))
      return 'key.txt'
    },
  ],
  [
    'a folder',
    'link',
    async path => {
      await mkdir(join(path, 'more'))
      await writeFile(join(path, 'more/x.ts'), 'x\n')
      return 'more'
    },
  ],
  [
    'a path through a link in the worktree',
    'link',
    async path => {
      await symlink(join(path, 'src'), join(path, 'alias'))
      return 'alias/limit.ts'
    },
  ],
  [
    'a file over MAX_FIX_FILE',
    'large',
    async path => {
      await writeFile(join(path, 'big.bin'), Buffer.alloc(MAX_FIX_FILE + 1, 120))
      return 'big.bin'
    },
  ],
  [
    'a path through a link out of the worktree',
    'outside',
    async path => {
      const victim = await mkdtemp(join(base, 'victim-'))
      await writeFile(join(victim, 'x.ts'), 'secret\n')
      await symlink(victim, join(path, 'out'))
      return 'out/x.ts'
    },
  ],
  [
    'a file that a git filter handles, as Git LFS does',
    'filter',
    async path => {
      // The session can change .gitattributes without a list of it in the result.
      await writeFile(join(path, '.gitattributes'), '*.bin filter=lfs diff=lfs merge=lfs -text\n')
      await writeFile(join(path, 'data.bin'), 'not a pointer\n')
      return 'data.bin'
    },
  ],
  ['a path with ..', 'outside', async () => '../x.ts'],
  ['a path in the .git folder', 'outside', async () => '.git/config'],
]

describe('the fix commit', { timeout: 30_000 }, () => {
  it('changedPaths lists a changed, a new and a deleted file', async () => {
    const { calls, clone, path, store } = await fixWorktree()
    expect(await store.changedPaths(clone, 7)).toEqual([])
    await writeFile(join(path, 'src/limit.ts'), 'changed\n')
    await mkdir(join(path, 'docs/new folder'), { recursive: true })
    await writeFile(join(path, 'docs/new folder/a b.md'), 'new\n')
    await rm(join(path, 'src/new.ts'))
    // .gitignore holds *.log, so the file is not a change.
    await writeFile(join(path, 'debug.log'), 'ignored\n')
    expect((await store.changedPaths(clone, 7)).sort()).toEqual([
      'docs/new folder/a b.md',
      'src/limit.ts',
      'src/new.ts',
    ])
    expect(callsOf(calls, 'status').at(-1)?.args).toEqual([
      `--git-dir=${adminPath(clone, 7)}`,
      `--work-tree=${path}`,
      'status',
      '--porcelain=v1',
      '-z',
      '--untracked-files=all',
      '--no-renames',
    ])
  })

  it('commitFix commits only the listed paths, and its parent is the head', async () => {
    const { calls, clone, head, path, store } = await fixWorktree()
    await writeFile(join(path, 'src/limit.ts'), 'export const limit = 5\n')
    await writeFile(join(path, 'src/extra.ts'), 'export const extra = 1\n')
    // A file of MAX_FIX_FILE bytes is not too large.
    await writeFile(join(path, 'src/max.bin'), Buffer.alloc(MAX_FIX_FILE, 120))
    await rm(join(path, 'src/new.ts'))
    await writeFile(join(path, 'README.md'), 'not listed\n')
    await writeFile(join(path, 'stray.txt'), 'not listed\n')
    const before = calls.length
    const message = '  fix(api): keep the limit   \n\n\n\nThe body.  \n\n'
    const made = await store.commitFix(clone, 7, {
      head,
      message,
      paths: ['src/limit.ts', 'src/extra.ts', 'src/max.bin', 'src/new.ts'],
    })
    if (!made.ok) throw new Error(`commitFix refused ${made.rule}`)
    expect(made.sha).toMatch(/^[0-9a-f]{40}$/)
    expect((await onAdmin(clone, 7, ['rev-parse', 'HEAD'])).trim()).toBe(made.sha)
    expect((await onAdmin(clone, 7, ['rev-list', '--parents', '-n', '1', made.sha])).trim()).toBe(
      `${made.sha} ${head}`,
    )
    const changes = await onAdmin(clone, 7, [
      'diff-tree',
      '-r',
      '--no-renames',
      '--name-status',
      head,
      made.sha,
    ])
    expect(changes.trim().split('\n').sort()).toEqual([
      'A\tsrc/extra.ts',
      'A\tsrc/max.bin',
      'D\tsrc/new.ts',
      'M\tsrc/limit.ts',
    ])
    expect(await onAdmin(clone, 7, ['show', `${made.sha}:src/extra.ts`])).toBe(
      'export const extra = 1\n',
    )
    // --cleanup=whitespace removes the white space at the end of each line and the extra empty
    // lines. It keeps the spaces at the start of a line.
    expect(await messageOf(clone, made.sha)).toBe('  fix(api): keep the limit\n\nThe body.\n')
    const raw = await onAdmin(clone, 7, ['cat-file', 'commit', made.sha])
    expect(raw).toContain('\nauthor Bifrost Test <bifrost-test@example.invalid> ')
    expect(raw).not.toContain('gpgsig')
    const own = calls.slice(before)
    // The files that the result does not list stay as changes in the worktree.
    expect(await readFile(join(path, 'README.md'), 'utf8')).toBe('not listed\n')
    expect((await store.changedPaths(clone, 7)).sort()).toEqual(['README.md', 'stray.txt'])

    for (const call of own) {
      expect(call.args.slice(0, 3)).toEqual([
        `--git-dir=${adminPath(clone, 7)}`,
        `--work-tree=${path}`,
        '--literal-pathspecs',
      ])
    }
    expect(callsOf(own, 'commit')).toHaveLength(1)
    expect(callsOf(own, 'commit')[0]?.args.slice(3)).toEqual([
      'commit',
      '--quiet',
      '--no-gpg-sign',
      '--cleanup=whitespace',
      '-m',
      message,
    ])
  })

  it.each(UNSAFE)(`${UNSAFE_TEST}: %s`, async (_name, rule, make) => {
    const { calls, clone, head, path, store } = await fixWorktree(10)
    await writeFile(join(path, 'src/limit.ts'), 'changed\n')
    const bad = await make(path)
    const before = calls.length
    const paths = ['src/limit.ts', bad]
    expect(await store.commitFix(clone, 10, { head, message: 'fix: x', paths })).toEqual({
      ok: false,
      rule,
    })
    // The checks run before git adds a file.
    expect(callsOf(calls.slice(before), 'add')).toEqual([])
    expect(callsOf(calls.slice(before), 'commit')).toEqual([])
    expect((await onAdmin(clone, 10, ['rev-parse', 'HEAD'])).trim()).toBe(head)
  })

  it('commitFix refuses a path that did not change', async () => {
    const { calls, clone, head, path, store } = await fixWorktree()
    await writeFile(join(path, 'src/limit.ts'), 'changed\n')
    await rm(join(path, 'docs'), { force: true, recursive: true })
    const fix = (paths: string[]) => store.commitFix(clone, 7, { head, message: 'fix: x', paths })
    const unchanged = { ok: false, rule: 'unchanged' }
    expect(await fix(['README.md'])).toEqual(unchanged)
    expect(await fix(['src/limit.ts', 'README.md'])).toEqual(unchanged)
    // The head has no such file, so there is nothing to delete.
    expect(await fix(['src/missing.ts'])).toEqual(unchanged)
    // A folder is not a file.
    expect(await fix(['docs'])).toEqual(unchanged)
    // An add with no paths adds each change of the worktree. So git never gets that add.
    const before = calls.length
    expect(await fix([])).toEqual(unchanged)
    expect(calls.slice(before)).toEqual([])
    expect(callsOf(calls, 'commit')).toEqual([])
    expect((await onAdmin(clone, 7, ['rev-parse', 'HEAD'])).trim()).toBe(head)
  })

  it('commitFix gives the same commit a second time', async () => {
    const { calls, clone, head, path, store } = await fixWorktree()
    await writeFile(join(path, 'src/limit.ts'), 'changed\n')
    const o = { head, message: 'fix: keep the limit\n\nThe body.', paths: ['src/limit.ts'] }
    const first = await store.commitFix(clone, 7, o)
    if (!first.ok) throw new Error(`commitFix refused ${first.rule}`)
    expect(await store.commitFix(clone, 7, o)).toEqual(first)
    // After the commit, the round cleans the worktree at the new commit. A run after a restart
    // still finds the commit.
    await store.checkAndClean(clone, 7, first.sha)
    expect(await store.commitFix(clone, 7, o)).toEqual(first)
    expect(callsOf(calls, 'commit')).toHaveLength(1)
    // A commit with another message is not the same fix, and the worktree is not at the head.
    await expect(store.commitFix(clone, 7, { ...o, message: 'fix: other' })).rejects.toThrow(
      /^Bifrost couldn't commit Claude's fix: \S/,
    )
    expect(callsOf(calls, 'commit')).toHaveLength(1)
  })

  it('a path with a glob character is taken as it is', async () => {
    const { clone, head, path, store } = await fixWorktree()
    await writeFile(join(path, '*.ts'), 'glob\n')
    await writeFile(join(path, 'a.ts'), 'plain\n')
    const made = await store.commitFix(clone, 7, { head, message: 'fix: glob', paths: ['*.ts'] })
    if (!made.ok) throw new Error(`commitFix refused ${made.rule}`)
    const names = await onAdmin(clone, 7, ['diff-tree', '-r', '--name-only', head, made.sha])
    expect(names).toBe('*.ts\n')
  })

  it('commitFix never signs, so no passphrase prompt can open', async () => {
    const marker = join(base, 'gpg-called-by-commit')
    const program = join(base, 'fake-gpg-commit.sh')
    await writeFile(program, `#!/bin/sh\ntouch '${marker}'\nexit 1\n`, { mode: 0o755 })
    const config = join(base, 'sign-commit.gitconfig')
    await writeFile(config, `[commit]\n\tgpgsign = true\n[gpg]\n\tprogram = ${program}\n`)
    const { clone, head, path, store } = await fixWorktree(7, {
      env: { ...env, GIT_CONFIG_GLOBAL: config },
    })
    await writeFile(join(path, 'src/limit.ts'), 'changed\n')
    const made = await store.commitFix(clone, 7, {
      head,
      message: 'fix: x',
      paths: ['src/limit.ts'],
    })
    if (!made.ok) throw new Error(`commitFix refused ${made.rule}`)
    expect(await onAdmin(clone, 7, ['cat-file', 'commit', made.sha])).not.toContain('gpgsig')
    expect(existsSync(marker)).toBe(false)
  })

  it('commitFix gives the git line as the detail, and a fixed text for a failed add', async () => {
    // user.useConfigOnly stops git from making an identity from the host name.
    const { clone, head, path, store } = await fixWorktree(7, {
      extraConfig: ['-c', 'user.useConfigOnly=true'],
    })
    await writeFile(join(path, 'src/limit.ts'), 'changed\n')
    const error = await store
      .commitFix(clone, 7, { head, message: 'fix: x', paths: ['src/limit.ts'] })
      .catch((e: unknown) => e)
    // The row gets a fixed text. The line of git goes only to the Event log.
    expect(error).toBeInstanceOf(CommitError)
    expect((error as CommitError).message).toBe(reasonCommitFailed(REASON_PUSH_GIT_FAILED))
    expect((error as CommitError).detail).toContain('Author identity unknown')
    // .gitignore holds *.log, so the add fails. The text does not name the file of the session.
    const other = await fixWorktree()
    await writeFile(join(other.path, 'debug.log'), 'x\n')
    const failed = other.store.commitFix(other.clone, 7, {
      head: other.head,
      message: 'fix: x',
      paths: ['debug.log'],
    })
    await expect(failed).rejects.toThrow(
      reasonCommitFailed("git couldn't add the files of the fix."),
    )
  })

  it('commitFix refuses a file that changes while git adds it', async () => {
    const home = await mkdtemp(join(base, 'home-'))
    const real = createRepoGit({ env: async () => env, exec: execFile, extraConfig: IDENTITY })
    let commits = 0
    let wt: string | null = null
    // A process of the session writes the file again just before the add of commitFix.
    const repoGit: RepoGit = {
      run: async (args, opts) => {
        const command = commandOf({ args, timeoutMs: undefined })
        if (command === 'add' && wt !== null) {
          await writeFile(join(wt, 'src/limit.ts'), 'changed again\n')
        }
        if (command === 'commit') commits++
        return real.run(args, opts)
      },
    }
    const store = createRepoStore({ bifrostHome: home, git: repoGit, remoteBase: remoteBase(base) })
    const clone = await store.ensureClone('acme', 'api')
    const { head } = await store.fetchPr(clone, 7, 'main')
    wt = await store.prepareWorktree(clone, 7, head)
    await writeFile(join(wt, 'src/limit.ts'), 'changed\n')
    await expect(
      store.commitFix(clone, 7, { head, message: 'fix: x', paths: ['src/limit.ts'] }),
    ).rejects.toThrow(reasonCommitFailed('a file changed while Bifrost committed it.'))
    expect(commits).toBe(0)
  })

  it.runIf(process.platform === 'darwin')(
    'commitFix takes a name with an accent in either Unicode form',
    async () => {
      const { clone, head, path, store } = await fixWorktree()
      // macOS keeps the name as written. git gives it in the composed form.
      await writeFile(join(path, 'caf\u00e9.ts'.normalize('NFD')), 'x\n')
      const changed = await store.changedPaths(clone, 7)
      expect(changed).toEqual(['caf\u00e9.ts'])
      const made = await store.commitFix(clone, 7, { head, message: 'fix: x', paths: changed })
      expect(made.ok).toBe(true)
    },
  )

  it('commitFix gives a fixed text for a file that it cannot read', async () => {
    const { clone, head, path, store } = await fixWorktree()
    await writeFile(join(path, 'src/limit.ts'), 'changed\n')
    // A link to itself: each read through it fails with ELOOP and the full path.
    await symlink('spin', join(path, 'spin'))
    const made = store.commitFix(clone, 7, {
      head,
      message: 'fix: x',
      paths: ['src/limit.ts', 'spin/x.ts'],
    })
    const error = (await made.catch((e: Error) => e)) as Error
    expect(error.message).toBe(reasonCommitFailed("one of its files can't be read."))
  })

  it('changedPaths and commitFix refuse a worktree outside reposRoot', async () => {
    const { store } = await makeStore()
    const victim = await mkdtemp(join(base, 'victim-'))
    await expect(store.changedPaths(victim, 7)).rejects.toThrow(REASON_NOT_OWNED)
    await expect(
      store.commitFix(victim, 7, { head: commits.head, message: 'fix: x', paths: ['a.ts'] }),
    ).rejects.toThrow(REASON_NOT_OWNED)
  })
})
