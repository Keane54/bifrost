// The push of a fix runs the real git on repositories in a temporary folder only. The remote is a
// bare repository with a file:// URL. The env has no global and no system git config. No test
// reaches the network.

import { existsSync } from 'node:fs'
import { chmod, mkdir, mkdtemp, rm, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { type ExecFn, type ExecResult, execFile } from '../../../src/main/claude/cli'
import type { Gh } from '../../../src/main/reviews/gh'
import { createRepoGit, GIT_CONFIG, type RepoGit } from '../../../src/main/reviews/repo-git'
import {
  createFixPusher,
  createSignedPusher,
  type FixPusher,
  MAX_LOOKUP_COMMITS,
  MAX_LOOKUP_RANGE,
  MAX_PUSH_TRIES,
  MAX_SIGNED_BYTES,
  NO_PROMPT_CONFIG,
  type PushOutcome,
} from '../../../src/main/reviews/request-push'
import {
  REASON_FILTER_CHANGE,
  REASON_PUSH_CONFLICT,
  REASON_PUSH_GIT_FAILED,
  REASON_PUSH_MOVED,
  REASON_PUSH_NEW_BRANCH,
  REASON_PUSH_TARGET,
  REASON_SIGNED_EXECUTABLE,
  REASON_SIGNED_LINK,
  REASON_SIGNED_TOO_LARGE,
  REASON_WRITE_FAILED,
  REASON_WRITE_TIMEOUT,
  reasonCommitFailed,
  reasonPushFailed,
  reasonUnsafeChange,
} from '../../../src/main/reviews/round-text'

const IDENTITY = ['-c', 'user.name=Bifrost Test', '-c', 'user.email=bifrost-test@example.invalid']
const TARGET_TEST =
  'refuses the default branch, the base branch, a name that starts with -, ' +
  'another origin URL and a push URL'
const LINES = Array.from({ length: 10 }, (_, i) => `line ${i + 1}`)

let base: string
let env: Record<string, string>

const text = (lines: string[]): string => `${lines.join('\n')}\n`
const withLine3 = (line: string): string => text(LINES.map((l, i) => (i === 2 ? line : l)))

async function git(
  args: string[],
  cwd: string,
  extra: Record<string, string> = {},
): Promise<string> {
  const result = await execFile('git', [...IDENTITY, ...args], {
    cwd,
    env: { ...env, ...extra },
    timeoutMs: 30_000,
  })
  if (result.code !== 0) throw new Error(`git ${args.join(' ')}: ${result.stderr}`)
  return result.stdout.trim()
}

// The git command of an argument list, after the options that come before it.
function commandOf(args: readonly string[]): string | undefined {
  for (let i = 0; i < args.length; i++) {
    const arg = args[i] as string
    if (arg === '-c') i++
    else if (!arg.startsWith('-')) return arg
  }
  return undefined
}

type PushInput = Parameters<FixPusher['push']>[0]

interface Repo {
  bare: string
  calls: string[][]
  clone: string
  fix: string
  head: string
  hub: FakeGitHub
  main: string
  push(o?: Partial<PushInput>): Promise<PushOutcome>
  // The push of the signed pusher, which sends the fix through the fake GitHub.
  signed(o?: Partial<PushInput>): Promise<PushOutcome>
  user: string
}

interface Places {
  bare: string
  head: string
  user: string
}

// The input of createCommitOnBranch, as the fake GitHub reads it from stdin.
interface CommitInput {
  branch: { repositoryNameWithOwner: string; branchName: string }
  expectedHeadOid: string
  message: { headline: string; body?: string }
  fileChanges: { additions: { path: string; contents: string }[]; deletions: { path: string }[] }
}

interface GitHubHooks {
  // Runs before GitHub makes the commit of call n (the first call is 1).
  before?(n: number, at: Places): Promise<void>
  // A text: GitHub makes no commit for call n, and gives this GraphQL error.
  refuse?(n: number): string | null
  // The answer of call n in place of the true answer. oid is the commit that GitHub made.
  answer?(n: number, oid: string | null, at: Places): Promise<ExecResult | undefined>
}

interface FakeGitHub {
  gh: Gh
  calls: { args: string[]; input: CommitInput | null }[]
}

const graphqlError = (message: string): ExecResult => ({
  code: 1,
  stderr: `gh: ${message}`,
  stdout: JSON.stringify({ data: { createCommitOnBranch: null }, errors: [{ message }] }),
})

// Do createCommitOnBranch on the bare remote with real git, as GitHub does it: the ref moves
// only from expectedHeadOid, the commit has that one parent, and each file is a regular file.
async function makeCommit(bare: string, input: CommitInput): Promise<string | { error: string }> {
  const ref = `refs/heads/${input.branch.branchName}`
  const now = await git(['rev-parse', '--verify', ref], bare)
  if (now !== input.expectedHeadOid) {
    return { error: `Expected branch to point to "${input.expectedHeadOid}" but it did not.` }
  }
  const work = await mkdtemp(join(base, 'github-'))
  // A delete from the index needs a work tree. The empty temporary folder is that work tree.
  const index = { GIT_INDEX_FILE: join(work, 'index'), GIT_WORK_TREE: work }
  await git(['read-tree', now], bare, index)
  for (const [i, file] of input.fileChanges.additions.entries()) {
    const blob = join(work, `blob-${i}`)
    await writeFile(blob, Buffer.from(file.contents, 'base64'))
    const id = await git(['hash-object', '-w', '--no-filters', '--', blob], bare)
    await git(['update-index', '--add', '--cacheinfo', `100644,${id},${file.path}`], bare, index)
  }
  for (const file of input.fileChanges.deletions) {
    await git(['update-index', '--force-remove', '--', file.path], bare, index)
  }
  const tree = await git(['write-tree'], bare, index)
  const { body, headline } = input.message
  const message = body === undefined ? headline : `${headline}\n\n${body}`
  const oid = await git(['commit-tree', tree, '-p', now, '-m', message], bare)
  await git(['update-ref', ref, oid, now], bare)
  return oid
}

// A fake gh that acts as GitHub for createCommitOnBranch on the bare remote. It never calls
// GitHub. Each other call fails.
function fakeGitHub(at: Places, hooks: GitHubHooks): FakeGitHub {
  const calls: FakeGitHub['calls'] = []
  const gh: Gh = {
    async run(args, opts) {
      const input =
        opts?.input === undefined
          ? null
          : (JSON.parse(opts.input) as { variables: { input: CommitInput } }).variables.input
      calls.push({ args, input })
      const n = calls.length
      if (args.join(' ') !== 'api graphql --input -' || input === null) {
        return { code: 1, stderr: 'unexpected call', stdout: '' }
      }
      await hooks.before?.(n, at)
      const refusal = hooks.refuse?.(n) ?? null
      const made = refusal === null ? await makeCommit(at.bare, input) : { error: refusal }
      const oid = typeof made === 'string' ? made : null
      const other = await hooks.answer?.(n, oid, at)
      if (other !== undefined) return other
      if (typeof made !== 'string') return graphqlError(made.error)
      const data = { createCommitOnBranch: { commit: { oid: made } } }
      return { code: 0, stderr: '', stdout: JSON.stringify({ data }) }
    },
  }
  return { calls, gh }
}

// A commit of the user on the branch, pushed to the remote. It gives the new commit.
async function userPush(user: string, file: string, content: string): Promise<string> {
  await writeFile(join(user, file), content)
  await git(['add', '--', file], user)
  await git(['commit', '-q', '-m', `user: ${file}`], user)
  await git(['push', '-q', 'origin', 'feature'], user)
  return git(['rev-parse', 'HEAD'], user)
}

// A remote with main and feature, the clone of Bifrost with a fix commit on feature, and a
// second clone that acts as the user.
async function setup(
  opts: {
    env?: Record<string, string>
    wrap?: (real: RepoGit, at: Places) => RepoGit
    // More files of the head commit of the PR. A mode of 0o755 makes a program.
    headFiles?: Record<string, { text: string; mode?: number }>
    // More changes of the head commit of the PR, staged in the work repository.
    head?: (work: string) => Promise<void>
    // The change of the fix commit, staged in the clone. Without it, the fix changes line 3 of
    // limit.txt.
    change?: (clone: string) => Promise<void>
    message?: string
    github?: GitHubHooks
  } = {},
): Promise<Repo> {
  const tmp = await mkdtemp(join(base, 'repo-'))
  const work = join(tmp, 'work')
  await git(['init', '-q', '-b', 'main', work], tmp)
  await writeFile(join(work, 'limit.txt'), text(LINES))
  await writeFile(join(work, 'README.md'), 'hello\n')
  await git(['add', '.'], work)
  await git(['commit', '-q', '-m', 'first'], work)
  const main = await git(['rev-parse', 'HEAD'], work)
  await git(['switch', '-q', '-c', 'feature'], work)
  await writeFile(join(work, 'feature.txt'), 'feature\n')
  for (const [name, file] of Object.entries(opts.headFiles ?? {})) {
    await mkdir(dirname(join(work, name)), { recursive: true })
    await writeFile(join(work, name), file.text, { mode: file.mode ?? 0o644 })
  }
  await git(['add', '.'], work)
  await opts.head?.(work)
  await git(['commit', '-q', '-m', 'feature'], work)
  const head = await git(['rev-parse', 'HEAD'], work)
  // The bare clone takes the current branch as its default branch.
  await git(['switch', '-q', 'main'], work)
  await mkdir(join(tmp, 'remotes', 'acme'), { recursive: true })
  const bare = join(tmp, 'remotes', 'acme', 'api.git')
  await git(['clone', '-q', '--bare', work, bare], tmp)
  const clone = join(tmp, 'clone')
  const user = join(tmp, 'user')
  await git(['clone', '-q', '--origin', 'origin', `file://${bare}`, clone], tmp)
  await git(['clone', '-q', `file://${bare}`, user], tmp)
  await git(['switch', '-q', 'feature'], clone)
  await git(['switch', '-q', 'feature'], user)
  if (opts.change === undefined) {
    await writeFile(join(clone, 'limit.txt'), withLine3('line 3 fixed'))
    await git(['commit', '-q', '-am', 'fix: line 3'], clone)
  } else {
    await opts.change(clone)
    await git(['commit', '-q', '-m', opts.message ?? 'fix: line 3'], clone)
  }
  const fix = await git(['rev-parse', 'HEAD'], clone)

  const calls: string[][] = []
  const exec: ExecFn = (file, args, execOpts) => {
    calls.push(args.slice(GIT_CONFIG.length + IDENTITY.length))
    return execFile(file, args, execOpts)
  }
  const real = createRepoGit({ env: async () => opts.env ?? env, exec, extraConfig: IDENTITY })
  const places = { bare, head, user }
  const repoGit = opts.wrap?.(real, places) ?? real
  const remoteBase = `file://${tmp}/remotes/`
  const pusher = createFixPusher({ git: repoGit, remoteBase })
  const hub = fakeGitHub(places, opts.github ?? {})
  const signedPusher = createSignedPusher({ gh: hub.gh, git: repoGit, remoteBase })
  const input = (o: Partial<PushInput>): PushInput => ({
    baseRef: 'main',
    clone,
    defaultBranch: 'main',
    fix,
    headRef: 'feature',
    number: 7,
    owner: 'acme',
    repo: 'api',
    ...o,
  })
  const push = (o: Partial<PushInput> = {}): Promise<PushOutcome> => pusher.push(input(o))
  const signed = (o: Partial<PushInput> = {}): Promise<PushOutcome> =>
    signedPusher.push(input({ crossRepository: false, ...o }))
  return { bare, calls, clone, fix, head, hub, main, push, signed, user }
}

const remoteRef = (repo: Repo, branch: string): Promise<string> =>
  git(['rev-parse', `refs/heads/${branch}`], repo.bare)
const pushesOf = (calls: string[][]): string[][] => calls.filter(call => commandOf(call) === 'push')

// A fake program that writes the marker file and prints x.
async function fakeProgram(name: string): Promise<{ marker: string; program: string }> {
  const folder = await mkdtemp(join(base, `${name}-`))
  const marker = join(folder, 'called')
  const program = join(folder, `${name}.sh`)
  await writeFile(program, `#!/bin/sh\ntouch '${marker}'\necho x\n`, { mode: 0o755 })
  return { marker, program }
}

// A RepoGit that runs before(args) before each push, then the real push.
const beforePush =
  (before: (at: Places) => Promise<void>) =>
  (real: RepoGit, at: Places): RepoGit => ({
    run: async (args, o) => {
      if (commandOf(args) === 'push') await before(at)
      return real.run(args, o)
    },
  })

beforeAll(async () => {
  base = await mkdtemp(join(tmpdir(), 'bifrost-request-push-'))
  env = {
    GIT_CONFIG_GLOBAL: '/dev/null',
    GIT_CONFIG_NOSYSTEM: '1',
    HOME: base,
    PATH: process.env.PATH ?? '/usr/bin:/bin',
  }
})

afterAll(async () => {
  await rm(base, { force: true, recursive: true })
})

// Each test runs real git commands. A slow machine needs more than the default 5 seconds.
describe('createFixPusher', { timeout: 30_000 }, () => {
  it('pushes a fix that is a fast-forward', async () => {
    const repo = await setup()
    expect(await repo.push()).toEqual({ already: false, merged: false, ok: true, sha: repo.fix })
    expect(await remoteRef(repo, 'feature')).toBe(repo.fix)
    expect(await remoteRef(repo, 'main')).toBe(repo.main)
    expect(pushesOf(repo.calls)).toHaveLength(1)
    // Each command names the .git folder of the clone.
    for (const call of repo.calls) expect(call[0]).toBe(`--git-dir=${join(repo.clone, '.git')}`)
  })

  it('a second push of the same fix pushes nothing and gives already', async () => {
    const repo = await setup()
    await repo.push()
    expect(await repo.push()).toEqual({ already: true, merged: false, ok: true, sha: repo.fix })
    expect(pushesOf(repo.calls)).toHaveLength(1)
    expect(await remoteRef(repo, 'feature')).toBe(repo.fix)
  })

  it('merges a remote that moved, with two parents, and pushes the merge', async () => {
    const repo = await setup()
    const moved = await userPush(repo.user, 'README.md', 'hello\nfrom the user\n')
    const outcome = await repo.push()
    if (!outcome.ok) throw new Error(outcome.message)
    expect(outcome).toEqual({ already: false, merged: true, ok: true, sha: outcome.sha })
    expect(outcome.sha).not.toBe(repo.fix)
    expect(await remoteRef(repo, 'feature')).toBe(outcome.sha)
    expect(await git(['rev-list', '--parents', '-n', '1', outcome.sha], repo.bare)).toBe(
      `${outcome.sha} ${repo.fix} ${moved}`,
    )
    expect(await git(['log', '-1', '--format=%B', outcome.sha], repo.bare)).toBe(
      "Merge remote-tracking branch 'origin/feature'",
    )
    expect(await git(['show', `${outcome.sha}:limit.txt`], repo.bare)).toContain('line 3 fixed')
    expect(await git(['show', `${outcome.sha}:README.md`], repo.bare)).toContain('from the user')
    expect(pushesOf(repo.calls)).toHaveLength(1)
    // A retry after a quit finds the fix in the merge on the remote.
    expect(await repo.push()).toEqual({ already: true, merged: false, ok: true, sha: repo.fix })
    expect(pushesOf(repo.calls)).toHaveLength(1)
  })

  it('a conflict pushes nothing and leaves the remote as it was', async () => {
    const repo = await setup()
    const moved = await userPush(repo.user, 'limit.txt', withLine3('line 3 by the user'))
    expect(await repo.push()).toEqual({
      message: REASON_PUSH_CONFLICT,
      ok: false,
      reason: 'conflict',
    })
    expect(await remoteRef(repo, 'feature')).toBe(moved)
    expect(pushesOf(repo.calls)).toEqual([])
  })

  it('a refused push tries one more time, then gives moved', async () => {
    expect(MAX_PUSH_TRIES).toBe(2)
    // Just before each push, the user pushes a commit. So each push loses the race, and git
    // refuses it.
    let count = 0
    const always = await setup({
      wrap: beforePush(async at => {
        count++
        await userPush(at.user, `race-${count}.txt`, 'race\n')
      }),
    })
    expect(await always.push()).toEqual({
      message: REASON_PUSH_MOVED,
      ok: false,
      reason: 'moved',
    })
    expect(pushesOf(always.calls)).toHaveLength(MAX_PUSH_TRIES)
    expect(await remoteRef(always, 'feature')).toBe(await git(['rev-parse', 'HEAD'], always.user))

    // The user pushes before the first push only. The second try merges and pushes.
    let once = false
    const first = await setup({
      wrap: beforePush(async at => {
        if (once) return
        once = true
        await userPush(at.user, 'race.txt', 'race\n')
      }),
    })
    const outcome = await first.push()
    if (!outcome.ok) throw new Error(outcome.message)
    expect(outcome).toMatchObject({ already: false, merged: true })
    expect(pushesOf(first.calls)).toHaveLength(2)
    expect(await remoteRef(first, 'feature')).toBe(outcome.sha)
  })

  it(TARGET_TEST, async () => {
    const repo = await setup()
    const refused = { message: REASON_PUSH_TARGET, ok: false, reason: 'refused' }
    const cases: Partial<PushInput>[] = [
      // The default branch, also when the base is another branch, and in another case.
      { baseRef: 'develop', headRef: 'main' },
      { baseRef: 'develop', headRef: 'Main' },
      // origin/HEAD of the clone names main, also when the PR data names another default.
      { baseRef: 'develop', defaultBranch: 'trunk', headRef: 'main' },
      // The base branch.
      { baseRef: 'develop', headRef: 'develop' },
      { baseRef: 'feature' },
      // A name that starts with -, or that is not a branch name.
      { headRef: '-feature' },
      { headRef: '--upload-pack=touch x' },
      { headRef: 'a..b' },
      { headRef: '@{-1}' },
      { headRef: 'feature:main' },
      { headRef: '' },
      // No default branch to compare with.
      { defaultBranch: '' },
      // Another repository than the origin of the clone.
      { owner: 'globex' },
      { repo: 'web' },
      { owner: '../acme' },
      // Values that are not a PR number or a commit ID.
      { number: 0 },
      { number: 1.5 },
      { fix: 'feature' },
    ]
    for (const values of cases) {
      expect(await repo.push(values), JSON.stringify(values)).toEqual(refused)
    }

    const other = `file://${join(repo.bare, '..', 'other.git')}`
    const url = `file://${repo.bare}`
    await git(['remote', 'set-url', 'origin', other], repo.clone)
    expect(await repo.push()).toEqual(refused)
    // The URL of the clone is in lower case.
    await git(['remote', 'set-url', 'origin', url.replace('acme/api', 'Acme/API')], repo.clone)
    expect(await repo.push()).toEqual(refused)
    // A second URL: git pushes to each URL of a remote.
    await git(['remote', 'set-url', 'origin', url], repo.clone)
    await git(['config', '--add', 'remote.origin.url', other], repo.clone)
    expect(await repo.push()).toEqual(refused)
    await git(['config', '--unset', '--fixed-value', 'remote.origin.url', other], repo.clone)
    await git(['config', 'remote.origin.pushurl', url], repo.clone)
    expect(await repo.push()).toEqual(refused)

    // No refusal reached the remote.
    const network = repo.calls.filter(call => ['fetch', 'push'].includes(commandOf(call) ?? ''))
    expect(network).toEqual([])
    expect(await remoteRef(repo, 'feature')).toBe(repo.head)
  })

  it('the push arguments never have a force flag or a + refspec', async () => {
    const calls: string[][] = []
    const fast = await setup()
    await fast.push()
    calls.push(...fast.calls)
    const merge = await setup()
    await userPush(merge.user, 'README.md', 'hello\nfrom the user\n')
    await merge.push()
    calls.push(...merge.calls)
    let count = 0
    const moved = await setup({
      wrap: beforePush(async at => {
        count++
        await userPush(at.user, `race-${count}.txt`, 'race\n')
      }),
    })
    await moved.push()
    calls.push(...moved.calls)

    const pushes = pushesOf(calls)
    expect(pushes).toHaveLength(4)
    for (const call of pushes) {
      const at = call.indexOf('push')
      expect(call.slice(0, at)).toEqual([
        expect.stringMatching(/^--git-dir=/),
        ...NO_PROMPT_CONFIG,
        '-c',
        'push.gpgSign=false',
      ])
      expect(call.slice(at + 1)).toEqual([
        '--porcelain',
        '--no-follow-tags',
        '--recurse-submodules=no',
        'origin',
        expect.stringMatching(/^[0-9a-f]{40}:refs\/heads\/feature$/),
      ])
      for (const item of call) {
        expect(item).not.toMatch(/^[+:]|^--(?:force|mirror|delete|all|tags|prune)|^-[a-z]*[fd]$/)
      }
    }
  })

  it('each git command of the push gets the config that stops each prompt', async () => {
    expect(NO_PROMPT_CONFIG).toEqual(['-c', 'core.askPass=', '-c', 'protocol.ssh.allow=never'])
    const repo = await setup()
    await userPush(repo.user, 'README.md', 'hello\nfrom the user\n')
    await repo.push()
    expect(repo.calls.length).toBeGreaterThan(10)
    for (const call of repo.calls) expect(call.slice(1, 5)).toEqual([...NO_PROMPT_CONFIG])
  })

  it('NO_PROMPT_CONFIG stops an askpass program and ssh', async () => {
    const askpass = await fakeProgram('askpass')
    const ssh = await fakeProgram('ssh')
    const repo = await setup()
    const promptEnv = { ...env, GIT_TERMINAL_PROMPT: '0', SSH_ASKPASS: askpass.program }
    // A credential prompt, as an https remote with no gh login gives it. The helpers are off.
    const fill = (config: readonly string[]) =>
      execFile(
        'git',
        [
          '-c',
          'credential.helper=',
          '-c',
          `core.askPass=${askpass.program}`,
          ...config,
          'credential',
          'fill',
        ],
        { cwd: repo.clone, env: promptEnv, input: 'protocol=https\nhost=example.invalid\n\n' },
      )
    const sshFetch = (config: readonly string[]) =>
      execFile(
        'git',
        [
          '-c',
          `core.sshCommand=${ssh.program}`,
          ...config,
          'fetch',
          'ssh://git@example.invalid/x.git',
        ],
        { cwd: repo.clone, env: promptEnv },
      )
    // Without the config, git runs both programs. So the checks below can fail.
    await fill([])
    await sshFetch([])
    expect(existsSync(askpass.marker)).toBe(true)
    expect(existsSync(ssh.marker)).toBe(true)
    await rm(askpass.marker)
    await rm(ssh.marker)
    expect((await fill(NO_PROMPT_CONFIG)).code).not.toBe(0)
    expect((await sshFetch(NO_PROMPT_CONFIG)).stderr).toContain("transport 'ssh' not allowed")
    expect(existsSync(askpass.marker)).toBe(false)
    expect(existsSync(ssh.marker)).toBe(false)
  })

  it('refuses a fetch URL or a push URL that insteadOf sends to another place', async () => {
    const ssh = await fakeProgram('ssh')
    for (const key of ['insteadOf', 'pushInsteadOf']) {
      const config = join(await mkdtemp(join(base, 'config-')), 'user.gitconfig')
      const repo = await setup({ env: { ...env, GIT_CONFIG_GLOBAL: config } })
      // config --get-all remote.origin.url still gives the file:// URL.
      const from = `file://${dirname(dirname(repo.bare))}/`
      const rewrite = `[url "ssh://git@example.invalid/"]\n\t${key} = ${from}\n`
      await writeFile(config, `${rewrite}[core]\n\tsshCommand = ${ssh.program}\n`)
      expect(await repo.push(), key).toEqual({
        message: REASON_PUSH_TARGET,
        ok: false,
        reason: 'refused',
      })
      const network = repo.calls.filter(call => ['fetch', 'push'].includes(commandOf(call) ?? ''))
      expect(network).toEqual([])
      expect(await remoteRef(repo, 'feature')).toBe(repo.head)
    }
    expect(existsSync(ssh.marker)).toBe(false)
  })

  it('a push that makes the branch again gives refused', async () => {
    // The PR merges, and GitHub deletes the branch between the fetch and the push.
    const repo = await setup({
      wrap: beforePush(async at => {
        await git(['update-ref', '-d', 'refs/heads/feature'], at.bare)
      }),
    })
    expect(await repo.push()).toEqual({
      message: REASON_PUSH_NEW_BRANCH,
      ok: false,
      reason: 'refused',
    })
    expect(pushesOf(repo.calls)).toHaveLength(1)
  })

  it('a push that times out after it reached the remote gives the true outcome', async () => {
    const timedOut = { code: 1, stderr: '', stdout: '', timedOut: true }
    // The push reaches the remote, but the answer comes too late.
    const late = await setup({
      wrap: (real: RepoGit): RepoGit => ({
        run: async (args, o) => {
          const result = await real.run(args, o)
          return commandOf(args) === 'push' ? timedOut : result
        },
      }),
    })
    expect(await late.push()).toEqual({ already: false, merged: false, ok: true, sha: late.fix })
    // The push stops before it reaches the remote.
    const early = await setup({
      wrap: (real: RepoGit): RepoGit => ({
        run: async (args, o) => (commandOf(args) === 'push' ? timedOut : real.run(args, o)),
      }),
    })
    // The row gets a fixed text. The text of git is the detail for the Event log.
    expect(await early.push()).toEqual({
      detail: 'git took too long.',
      message: reasonPushFailed(REASON_PUSH_GIT_FAILED),
      ok: false,
      reason: 'refused',
    })
    expect(await remoteRef(early, 'feature')).toBe(early.head)
    // Only the late push ran git. The early one stopped before git.
    expect(pushesOf(late.calls)).toHaveLength(1)
    expect(pushesOf(early.calls)).toEqual([])
  })

  it('a failed fetch after a good push fetches once more', async () => {
    const lost = { code: 128, stderr: 'fatal: the network went away', stdout: '' }
    // Each fetch after the push fails `fails` times, then works.
    const failingAfterPush =
      (fails: number) =>
      (real: RepoGit): RepoGit => {
        let pushed = false
        let left = fails
        return {
          run: async (args, o) => {
            const command = commandOf(args)
            if (command === 'push') pushed = true
            if (command === 'fetch' && pushed && left > 0) {
              left--
              return lost
            }
            return real.run(args, o)
          },
        }
      }
    const once = await setup({ wrap: failingAfterPush(1) })
    expect(await once.push()).toEqual({ already: false, merged: false, ok: true, sha: once.fix })
    const twice = await setup({ wrap: failingAfterPush(2) })
    expect(await twice.push()).toEqual({
      detail: 'fatal: the network went away',
      message: reasonPushFailed(REASON_PUSH_GIT_FAILED),
      ok: false,
      reason: 'refused',
    })
  })

  it('a push that GitHub refuses gives not-landed and does not try again', async () => {
    const repo = await setup()
    await writeFile(
      join(repo.bare, 'hooks', 'pre-receive'),
      '#!/bin/sh\necho "GH006: Protected branch update failed" >&2\nexit 1\n',
      { mode: 0o755 },
    )
    // The fetch after the push shows that the branch does not have the fix.
    expect(await repo.push()).toEqual({
      detail: 'remote: GH006: Protected branch update failed',
      message: reasonPushFailed(REASON_PUSH_GIT_FAILED),
      ok: false,
      reason: 'not-landed',
    })
    expect(pushesOf(repo.calls)).toHaveLength(1)
    expect(await remoteRef(repo, 'feature')).toBe(repo.head)
  })

  it('a failed push with no fetch after it gives refused, because GitHub can have it', async () => {
    const lost = { code: 128, stderr: 'fatal: the network went away', stdout: '' }
    const repo = await setup({
      wrap: (real: RepoGit): RepoGit => {
        let pushed = false
        return {
          run: async (args, o) => {
            const command = commandOf(args)
            if (command === 'push') {
              pushed = true
              return { code: 1, stderr: 'error: failed to push some refs', stdout: '' }
            }
            if (command === 'fetch' && pushed) return lost
            return real.run(args, o)
          },
        }
      },
    })
    expect(await repo.push()).toEqual({
      detail: 'error: failed to push some refs',
      message: reasonPushFailed(REASON_PUSH_GIT_FAILED),
      ok: false,
      reason: 'refused',
    })
  })

  it('a branch that the user rewrote gets no merge and no push', async () => {
    // The user resets the branch to main. A push of the fix would be a fast-forward that puts
    // back the commit that the user removed.
    const reset = await setup()
    await git(['update-ref', 'refs/heads/feature', reset.main], reset.bare)
    expect(await reset.push()).toEqual({
      message: REASON_PUSH_CONFLICT,
      ok: false,
      reason: 'conflict',
    })
    expect(await remoteRef(reset, 'feature')).toBe(reset.main)
    // The user rebases: a new commit on main takes the place of the old head.
    const rebased = await setup()
    const tree = await git(['rev-parse', `${rebased.head}^{tree}`], rebased.bare)
    const again = await git(
      ['commit-tree', tree, '-p', rebased.main, '-m', 'rebased'],
      rebased.bare,
    )
    await git(['update-ref', 'refs/heads/feature', again], rebased.bare)
    expect(await rebased.push()).toEqual({
      message: REASON_PUSH_CONFLICT,
      ok: false,
      reason: 'conflict',
    })
    expect(await remoteRef(rebased, 'feature')).toBe(again)
    expect(pushesOf([...reset.calls, ...rebased.calls])).toEqual([])
  })

  it('a branch that is gone from the remote is never made again', async () => {
    const repo = await setup()
    await git(['update-ref', '-d', 'refs/heads/feature'], repo.bare)
    const outcome = await repo.push()
    expect(outcome).toMatchObject({ ok: false, reason: 'refused' })
    expect(outcome.ok ? '' : outcome.message).toMatch(/^GitHub didn't take the push: \S/)
    expect(pushesOf(repo.calls)).toEqual([])
    const shown = await execFile('git', ['show-ref', '--verify', 'refs/heads/feature'], {
      cwd: repo.bare,
      env,
    })
    expect(shown.code).not.toBe(0)
  })

  it('gives refused when the branch does not hold the pushed commit after the push', async () => {
    // Just after the push, the branch goes back to the head of the round.
    const repo = await setup({
      wrap: (real, at) => ({
        run: async (args, o) => {
          const result = await real.run(args, o)
          if (commandOf(args) === 'push' && result.code === 0) {
            await git(['update-ref', 'refs/heads/feature', at.head], at.bare)
          }
          return result
        },
      }),
    })
    expect(await repo.push()).toEqual({
      message: reasonPushFailed("the branch on GitHub doesn't have the fix after the push."),
      ok: false,
      reason: 'refused',
    })
    expect(pushesOf(repo.calls)).toHaveLength(1)
  })

  it('the merge commit and the push never sign, so no passphrase prompt can open', async () => {
    const marker = join(base, 'gpg-called-by-push')
    const program = join(base, 'fake-gpg-push.sh')
    await writeFile(program, `#!/bin/sh\ntouch '${marker}'\nexit 1\n`, { mode: 0o755 })
    const config = join(base, 'sign-push.gitconfig')
    await writeFile(
      config,
      `[commit]\n\tgpgsign = true\n[push]\n\tgpgSign = true\n[gpg]\n\tprogram = ${program}\n`,
    )
    const repo = await setup({ env: { ...env, GIT_CONFIG_GLOBAL: config } })
    await userPush(repo.user, 'README.md', 'hello\nfrom the user\n')
    const outcome = await repo.push()
    if (!outcome.ok) throw new Error(outcome.message)
    expect(outcome.merged).toBe(true)
    expect(await git(['cat-file', 'commit', outcome.sha], repo.bare)).not.toContain('gpgsig')
    expect(existsSync(marker)).toBe(false)
  })
})

const b64 = (content: string | Buffer): string => Buffer.from(content).toString('base64')
const networkOf = (calls: string[][]): string[][] =>
  calls.filter(call => ['fetch', 'push'].includes(commandOf(call) ?? ''))
const timedOut: ExecResult = { code: 1, stderr: '', stdout: '', timedOut: true }
// Stage each change of the worktree of the clone.
const addAll = (clone: string): Promise<string> => git(['add', '-A'], clone)

// A RepoGit whose fetch fails while cut() is true.
const cutFetch =
  (cut: () => boolean) =>
  (real: RepoGit): RepoGit => ({
    run: async (args, o) =>
      commandOf(args) === 'fetch' && cut()
        ? { code: 128, stderr: 'fatal: the network went away', stdout: '' }
        : real.run(args, o),
  })

// The signed pusher runs the real git on the clone and a fake gh that makes the commit in the
// bare remote, as GitHub does. No test reaches the network.
describe('createSignedPusher', { timeout: 60_000 }, () => {
  it('sends the fix commit through GitHub and gives the commit that GitHub made', async () => {
    const repo = await setup()
    const outcome = await repo.signed()
    if (!outcome.ok) throw new Error(outcome.message)
    expect(outcome).toEqual({ already: false, merged: false, ok: true, sha: outcome.sha })
    expect(outcome.sha).not.toBe(repo.fix)
    expect(await remoteRef(repo, 'feature')).toBe(outcome.sha)
    expect(await remoteRef(repo, 'main')).toBe(repo.main)
    // One parent, the head of the round, and the same files as the local fix commit.
    expect(await git(['rev-list', '--parents', '-n', '1', outcome.sha], repo.bare)).toBe(
      `${outcome.sha} ${repo.head}`,
    )
    expect(await git(['rev-parse', `${outcome.sha}^{tree}`], repo.bare)).toBe(
      await git(['rev-parse', `${repo.fix}^{tree}`], repo.clone),
    )
    expect(await git(['log', '-1', '--format=%B', outcome.sha], repo.bare)).toBe('fix: line 3')
    expect(repo.hub.calls).toEqual([
      {
        args: ['api', 'graphql', '--input', '-'],
        input: {
          branch: { branchName: 'feature', repositoryNameWithOwner: 'acme/api' },
          expectedHeadOid: repo.head,
          fileChanges: {
            additions: [{ contents: b64(withLine3('line 3 fixed')), path: 'limit.txt' }],
            deletions: [],
          },
          message: { headline: 'fix: line 3' },
        },
      },
    ])
    // git pushed nothing. Each git command names the .git folder and stops each prompt.
    expect(pushesOf(repo.calls)).toEqual([])
    for (const call of repo.calls) {
      expect(call[0]).toBe(`--git-dir=${join(repo.clone, '.git')}`)
      expect(call.slice(1, 5)).toEqual([...NO_PROMPT_CONFIG])
    }
    // A second push after a quit finds the commit on GitHub and sends nothing.
    expect(await repo.signed()).toEqual({
      already: true,
      merged: false,
      ok: true,
      sha: outcome.sha,
    })
    expect(repo.hub.calls).toHaveLength(1)
  })

  it('reads each file from the commit: a binary file, a new file and a delete', async () => {
    const binary = Buffer.from(Array.from({ length: 1024 }, (_, i) => (i * 7) % 256))
    const repo = await setup({
      change: async clone => {
        await writeFile(join(clone, 'limit.txt'), withLine3('line 3 fixed'))
        await mkdir(join(clone, 'img'))
        await writeFile(join(clone, 'img', 'data.bin'), binary)
        await rm(join(clone, 'README.md'))
        await addAll(clone)
      },
      message: 'fix: three files\n\nThe body.\nThe second line.\n',
    })
    // The worktree of the clone changes after the commit. Bifrost sends the commit only.
    await writeFile(join(repo.clone, 'limit.txt'), 'changed after the commit\n')
    const outcome = await repo.signed()
    if (!outcome.ok) throw new Error(outcome.message)
    expect(repo.hub.calls[0]?.input).toMatchObject({
      fileChanges: {
        additions: [
          { contents: b64(binary), path: 'img/data.bin' },
          { contents: b64(withLine3('line 3 fixed')), path: 'limit.txt' },
        ],
        deletions: [{ path: 'README.md' }],
      },
      message: { body: 'The body.\nThe second line.', headline: 'fix: three files' },
    })
    expect(await git(['rev-parse', `${outcome.sha}^{tree}`], repo.bare)).toBe(
      await git(['rev-parse', `${repo.fix}^{tree}`], repo.clone),
    )
    expect(await git(['log', '-1', '--format=%B', outcome.sha], repo.bare)).toBe(
      'fix: three files\n\nThe body.\nThe second line.',
    )
  })

  it('refuses a file that must stay executable before any write (ruling S22)', async () => {
    const program = { mode: 0o755, text: '#!/bin/sh\necho run\n' }
    const refused = { message: REASON_SIGNED_EXECUTABLE, ok: false, reason: 'not-landed' }
    const changes: ((clone: string) => Promise<void>)[] = [
      // A change of a program.
      async clone => {
        await writeFile(join(clone, 'run.sh'), '#!/bin/sh\necho fixed\n')
        await addAll(clone)
      },
      // A new program.
      async clone => {
        await writeFile(join(clone, 'tool.sh'), '#!/bin/sh\n', { mode: 0o755 })
        await addAll(clone)
      },
      // A plain file that becomes a program.
      async clone => {
        await writeFile(join(clone, 'limit.txt'), withLine3('line 3 fixed'))
        await chmod(join(clone, 'limit.txt'), 0o755)
        await addAll(clone)
      },
      // A program that becomes a plain file.
      async clone => {
        await chmod(join(clone, 'run.sh'), 0o644)
        await addAll(clone)
      },
    ]
    for (const [i, change] of changes.entries()) {
      const repo = await setup({ change, headFiles: { 'run.sh': program } })
      expect(await repo.signed(), String(i)).toEqual(refused)
      expect(repo.hub.calls).toEqual([])
      expect(networkOf(repo.calls)).toEqual([])
      expect(await remoteRef(repo, 'feature')).toBe(repo.head)
    }
    // A delete of a program needs no mode.
    const removed = await setup({
      change: async clone => {
        await rm(join(clone, 'run.sh'))
        await addAll(clone)
      },
      headFiles: { 'run.sh': program },
    })
    const outcome = await removed.signed()
    if (!outcome.ok) throw new Error(outcome.message)
    expect(removed.hub.calls[0]?.input?.fileChanges).toEqual({
      additions: [],
      deletions: [{ path: 'run.sh' }],
    })
  })

  it('refuses a link and a submodule too, which commitFix refuses before', async () => {
    const changes: ((clone: string) => Promise<void>)[] = [
      async clone => {
        await symlink('limit.txt', join(clone, 'link.txt'))
        await addAll(clone)
      },
      async clone => {
        const head = await git(['rev-parse', 'HEAD'], clone)
        await git(['update-index', '--add', '--cacheinfo', `160000,${head},vendor/sub`], clone)
      },
    ]
    for (const change of changes) {
      const repo = await setup({ change })
      expect(await repo.signed()).toEqual({
        message: REASON_SIGNED_LINK,
        ok: false,
        reason: 'not-landed',
      })
      expect(repo.hub.calls).toEqual([])
    }
  })

  it('refuses a link or a submodule of the head that becomes a plain file', async () => {
    const link = await setup({
      change: async clone => {
        await rm(join(clone, 'link.txt'))
        await writeFile(join(clone, 'link.txt'), 'a plain file now\n')
        await addAll(clone)
      },
      head: async work => {
        await symlink('limit.txt', join(work, 'link.txt'))
        await git(['add', '--', 'link.txt'], work)
      },
    })
    const submodule = await setup({
      change: async clone => {
        await git(['update-index', '--force-remove', '--', 'vendor/sub'], clone)
        await rm(join(clone, 'vendor', 'sub'), { force: true, recursive: true })
        await writeFile(join(clone, 'vendor', 'sub'), 'a plain file now\n')
        await git(['add', '--', 'vendor/sub'], clone)
      },
      head: async work => {
        const first = await git(['rev-parse', 'HEAD'], work)
        await git(['update-index', '--add', '--cacheinfo', `160000,${first},vendor/sub`], work)
      },
    })
    for (const repo of [link, submodule]) {
      // The head has the link or the submodule, and the fix has a plain file in its place.
      const [path, mode] = repo === link ? ['link.txt', '120000'] : ['vendor/sub', '160000']
      expect(await git(['ls-tree', repo.head, '--', path], repo.clone)).toMatch(`${mode} `)
      expect(await git(['ls-tree', repo.fix, '--', path], repo.clone)).toMatch('100644 blob ')
      expect(await repo.signed(), path).toEqual({
        message: REASON_SIGNED_LINK,
        ok: false,
        reason: 'not-landed',
      })
      expect(repo.hub.calls).toEqual([])
      expect(networkOf(repo.calls)).toEqual([])
    }
  })

  it('refuses a fix over 4 MB before any write, and takes a fix of 4 MB (ruling S23)', async () => {
    expect(MAX_SIGNED_BYTES).toBe(4 * 1024 * 1024)
    const files = (count: number, size: number) => async (clone: string) => {
      for (let i = 0; i < count; i++) {
        await writeFile(join(clone, `big-${i}.txt`), Buffer.alloc(size, 97 + i))
      }
      await addAll(clone)
    }
    const over = await setup({ change: files(5, 900 * 1024) })
    expect(await over.signed()).toEqual({
      message: REASON_SIGNED_TOO_LARGE,
      ok: false,
      reason: 'not-landed',
    })
    expect(over.hub.calls).toEqual([])
    expect(networkOf(over.calls)).toEqual([])
    const limit = await setup({ change: files(4, 1024 * 1024) })
    expect(await limit.signed()).toMatchObject({ ok: true })
  })

  it('sends the fix on a head that moved before the push and changed no fix path', async () => {
    const repo = await setup()
    const moved = await userPush(repo.user, 'README.md', 'hello\nfrom the user\n')
    const outcome = await repo.signed()
    if (!outcome.ok) throw new Error(outcome.message)
    expect(repo.hub.calls.map(call => call.input?.expectedHeadOid)).toEqual([moved])
    expect(await git(['rev-list', '--parents', '-n', '1', outcome.sha], repo.bare)).toBe(
      `${outcome.sha} ${moved}`,
    )
    expect(await git(['show', `${outcome.sha}:README.md`], repo.bare)).toContain('from the user')
    expect(await git(['show', `${outcome.sha}:limit.txt`], repo.bare)).toContain('line 3 fixed')
  })

  it('a branch that moves during the call gets one more try when no fix path changed', async () => {
    let moved = ''
    const repo = await setup({
      github: {
        async before(n, at) {
          if (n === 1) moved = await userPush(at.user, 'README.md', 'hello\nfrom the user\n')
        },
      },
    })
    const outcome = await repo.signed()
    if (!outcome.ok) throw new Error(outcome.message)
    expect(repo.hub.calls.map(call => call.input?.expectedHeadOid)).toEqual([repo.head, moved])
    expect(await remoteRef(repo, 'feature')).toBe(outcome.sha)
    expect(await git(['rev-list', '--parents', '-n', '1', outcome.sha], repo.bare)).toBe(
      `${outcome.sha} ${moved}`,
    )
  })

  it('a head that changed a fix path is a conflict, before the call or during it', async () => {
    const conflict = { message: REASON_PUSH_CONFLICT, ok: false, reason: 'conflict' }
    const before = await setup()
    const moved = await userPush(before.user, 'limit.txt', withLine3('line 3 by the user'))
    expect(await before.signed()).toEqual(conflict)
    expect(before.hub.calls).toEqual([])
    expect(await remoteRef(before, 'feature')).toBe(moved)

    const during = await setup({
      github: {
        async before(n, at) {
          if (n === 1) await userPush(at.user, 'limit.txt', withLine3('line 3 by the user'))
        },
      },
    })
    expect(await during.signed()).toEqual(conflict)
    expect(during.hub.calls).toHaveLength(1)

    // The user rewrote the branch.
    const reset = await setup()
    await git(['update-ref', 'refs/heads/feature', reset.main], reset.bare)
    expect(await reset.signed()).toEqual(conflict)
    expect(reset.hub.calls).toEqual([])
  })

  it('a branch that keeps moving gives moved after MAX_PUSH_TRIES calls', async () => {
    const repo = await setup({
      github: {
        async before(n, at) {
          await userPush(at.user, `race-${n}.txt`, 'race\n')
        },
      },
    })
    expect(await repo.signed()).toEqual({ message: REASON_PUSH_MOVED, ok: false, reason: 'moved' })
    expect(repo.hub.calls).toHaveLength(MAX_PUSH_TRIES)
  })

  it('an unknown result keeps the outbox, and the next run finds the commit', async () => {
    let cut = false
    const repo = await setup({
      github: {
        async answer(n) {
          if (n !== 1) return undefined
          // GitHub made the commit, but the answer came too late, and the network went away.
          cut = true
          return timedOut
        },
      },
      wrap: cutFetch(() => cut),
    })
    expect(await repo.signed()).toEqual({
      message: reasonPushFailed(REASON_WRITE_TIMEOUT),
      ok: false,
      reason: 'refused',
    })
    const landed = await remoteRef(repo, 'feature')
    expect(landed).not.toBe(repo.head)
    // The user pushes on top of the commit before the next run.
    cut = false
    await git(['pull', '-q', '--ff-only', 'origin', 'feature'], repo.user)
    await userPush(repo.user, 'README.md', 'hello\nfrom the user\n')
    expect(await repo.signed()).toEqual({ already: true, merged: false, ok: true, sha: landed })
    expect(repo.hub.calls).toHaveLength(1)
  })

  it('an unknown result that the fetch after it shows as landed is a success', async () => {
    const repo = await setup({
      github: { answer: async n => (n === 1 ? timedOut : undefined) },
    })
    const outcome = await repo.signed()
    expect(outcome).toEqual({
      already: false,
      merged: false,
      ok: true,
      sha: await remoteRef(repo, 'feature'),
    })
    expect(repo.hub.calls).toHaveLength(1)
  })

  it('looks for the commit after the head that the call expected, after many commits', async () => {
    expect(MAX_LOOKUP_COMMITS).toBe(20)
    let cut = false
    const repo = await setup({
      github: {
        async answer(n) {
          if (n !== 1) return undefined
          cut = true
          return timedOut
        },
      },
      wrap: cutFetch(() => cut),
    })
    // The user pushes many commits before the call, and many more after it.
    for (let i = 0; i < MAX_LOOKUP_COMMITS + 5; i++) {
      await userPush(repo.user, `before-${i}.txt`, 'before\n')
    }
    await repo.signed()
    const landed = await remoteRef(repo, 'feature')
    cut = false
    await git(['pull', '-q', '--ff-only', 'origin', 'feature'], repo.user)
    for (let i = 0; i < MAX_LOOKUP_COMMITS + 5; i++) {
      await userPush(repo.user, `after-${i}.txt`, 'after\n')
    }
    expect(await repo.signed()).toEqual({ already: true, merged: false, ok: true, sha: landed })
    expect(repo.hub.calls).toHaveLength(1)
    // The search reads a fixed count of commits at most.
    expect(MAX_LOOKUP_RANGE).toBe(1000)
    const lists = repo.calls.filter(call => commandOf(call) === 'rev-list')
    expect(lists.length).toBeGreaterThan(0)
    for (const call of lists) expect(call).toContain(`--max-count=${MAX_LOOKUP_RANGE}`)
  })

  it('a commit with the same files and another message counts as landed', async () => {
    let cut = false
    let theirs = ''
    const repo = await setup({
      github: {
        async answer(n, _oid, at) {
          if (n !== 1) return undefined
          // The commit of GitHub goes, and the user pushes a commit with the same files.
          await git(['update-ref', 'refs/heads/feature', at.head], at.bare)
          await writeFile(join(at.user, 'limit.txt'), withLine3('line 3 fixed'))
          await git(['commit', '-q', '-am', 'fix: line 3 again'], at.user)
          await git(['push', '-q', 'origin', 'feature'], at.user)
          theirs = await git(['rev-parse', 'HEAD'], at.user)
          cut = true
          return timedOut
        },
      },
      wrap: cutFetch(() => cut),
    })
    await repo.signed()
    cut = false
    // The proof is the content only: the files of the fix paths equal the files of the fix.
    expect(await repo.signed()).toEqual({ already: true, merged: false, ok: true, sha: theirs })
    expect(repo.hub.calls).toHaveLength(1)
  })

  it('does not take a commit with other files as the landed commit', async () => {
    let cut = false
    const repo = await setup({
      github: {
        async answer(n, _oid, at) {
          if (n !== 1) return undefined
          // The commit of GitHub goes. The user pushes a commit with the message of the fix and
          // another line 3.
          await git(['update-ref', 'refs/heads/feature', at.head], at.bare)
          await writeFile(join(at.user, 'limit.txt'), withLine3('line 3 by the user'))
          await git(['commit', '-q', '-am', 'fix: line 3'], at.user)
          await git(['push', '-q', 'origin', 'feature'], at.user)
          cut = true
          return timedOut
        },
      },
      wrap: cutFetch(() => cut),
    })
    await repo.signed()
    cut = false
    // The next run sees the change of the user on limit.txt, so the fix does not go again.
    expect(await repo.signed()).toEqual({
      message: REASON_PUSH_CONFLICT,
      ok: false,
      reason: 'conflict',
    })
    expect(repo.hub.calls).toHaveLength(1)
  })

  it('a GraphQL error with no new commit gives not-landed', async () => {
    const repo = await setup({ github: { refuse: () => 'Repository rule violations found' } })
    // The row gets a fixed text. The text of GitHub is the detail for the Event log.
    expect(await repo.signed()).toEqual({
      detail: 'Repository rule violations found',
      message: reasonPushFailed(REASON_WRITE_FAILED),
      ok: false,
      reason: 'not-landed',
    })
    expect(repo.hub.calls).toHaveLength(1)
    expect(await remoteRef(repo, 'feature')).toBe(repo.head)
  })

  it('a GraphQL error is not-landed only when the fetch after it works', async () => {
    let cut = false
    const repo = await setup({
      github: {
        async answer() {
          cut = true
          return undefined
        },
        refuse: () => 'Something went wrong',
      },
      wrap: cutFetch(() => cut),
    })
    expect(await repo.signed()).toEqual({
      detail: 'Something went wrong',
      message: reasonPushFailed(REASON_WRITE_FAILED),
      ok: false,
      reason: 'refused',
    })
    // GitHub gave an error, but the commit is on the branch: it landed.
    const made = await setup({
      github: { answer: async () => graphqlError('Something went wrong') },
    })
    const outcome = await made.signed()
    expect(outcome).toEqual({
      already: false,
      merged: false,
      ok: true,
      sha: await remoteRef(made, 'feature'),
    })
  })

  it('gives refused when the branch does not hold the commit after a good answer', async () => {
    const repo = await setup({
      github: {
        async answer(_n, _oid, at) {
          await git(['update-ref', 'refs/heads/feature', at.head], at.bare)
          return undefined
        },
      },
    })
    expect(await repo.signed()).toEqual({
      message: reasonPushFailed("the branch on GitHub doesn't have the fix after the push."),
      ok: false,
      reason: 'refused',
    })
  })

  it('refuses a fork PR, the default branch and another repository before any call', async () => {
    const repo = await setup()
    const refused = { message: REASON_PUSH_TARGET, ok: false, reason: 'refused' }
    const cases: Partial<PushInput>[] = [
      { crossRepository: true },
      // A missing value counts as a fork.
      { crossRepository: undefined },
      { baseRef: 'develop', headRef: 'main' },
      { headRef: 'Main' },
      { baseRef: 'feature' },
      { owner: 'globex' },
      { repo: 'web' },
      { fix: 'feature' },
    ]
    for (const values of cases) {
      expect(await repo.signed(values), JSON.stringify(values)).toEqual(refused)
    }
    expect(repo.hub.calls).toEqual([])
    expect(networkOf(repo.calls)).toEqual([])
    expect(await remoteRef(repo, 'feature')).toBe(repo.head)
  })
})

describe('the texts of the fix commit and the push', () => {
  it('are exact', () => {
    expect(REASON_PUSH_TARGET).toBe("Bifrost won't push to this branch, so it posted nothing.")
    expect(REASON_PUSH_CONFLICT).toBe(
      "Someone pushed to this branch, and Claude's fix doesn't merge cleanly. " +
        'Bifrost posted the other replies. Choose Try again to let Claude fix it on the new code.',
    )
    expect(REASON_PUSH_MOVED).toBe(
      'The branch kept changing while Bifrost pushed. Bifrost posted the other replies. ' +
        'Choose Try again.',
    )
    expect(reasonPushFailed('x y')).toBe("GitHub didn't take the push: x y")
    expect(reasonCommitFailed('x y')).toBe("Bifrost couldn't commit Claude's fix: x y")
    expect(REASON_PUSH_NEW_BRANCH).toBe(
      'The branch was deleted on GitHub while Bifrost pushed, so the push made it again. ' +
        "Delete it on GitHub if you don't need it.",
    )
    expect(REASON_FILTER_CHANGE).toBe(
      'Claude changed a file that Git LFS or another git filter handles. ' +
        "Bifrost can't push that safely, so nothing was posted. Make this change yourself.",
    )
    expect(reasonUnsafeChange('filter')).toBe(REASON_FILTER_CHANGE)
    expect(REASON_SIGNED_EXECUTABLE).toBe(
      "Claude's fix changes a file that must stay executable, and GitHub can't keep that in a " +
        'commit it signs. Nothing was posted. Turn off Sign commits through GitHub for this fix ' +
        'and choose Try again, or make the change yourself.',
    )
    expect(REASON_SIGNED_LINK).toBe(
      "Claude's fix changes a link or a submodule, and GitHub can't keep that in a commit it " +
        'signs. Nothing was posted. Turn off Sign commits through GitHub for this fix and choose ' +
        'Try again, or make the change yourself.',
    )
    expect(REASON_SIGNED_TOO_LARGE).toBe(
      "Claude's fix is over 4 MB, which is too large for a commit that GitHub signs. Nothing " +
        'was posted. Turn off Sign commits through GitHub for this fix and choose Try again, ' +
        'or make the change yourself.',
    )
    const what = {
      claude: 'a file in a .claude folder',
      large: 'a file over 1 MB',
      link: 'a file link',
      outside: 'a file outside its folder',
      submodule: 'a submodule',
      unchanged: "a file list that doesn't match its changes",
      workflow: 'a GitHub workflow or action file',
    } as const
    for (const [rule, name] of Object.entries(what)) {
      expect(reasonUnsafeChange(rule as keyof typeof what)).toBe(
        `Claude changed ${name}, which Bifrost doesn't push. Nothing was posted.`,
      )
    }
  })
})
