// The live check of the bifrost-review skill in Bifrost mode. The script starts one real Claude
// Code session with the Haiku model on a small PR with a known bug. Then it checks the result
// file with the checks of the product. It prints only: "valid" or the reason, the
// recommendation, and the comment count.
//
// Run it by hand only, from the root of the repository:
//   node scripts/reviews/check-review-skill.ts
// It does not run in CI or in pnpm test. Each run uses a real session and costs tokens.
//
// The set-up:
// - The base commit and the head commit of the PR go into the object store of the main
//   repository, with git plumbing. The script moves no ref, makes no branch and changes no file
//   of the checkout. The objects stay until a later gc deletes them.
// - The cwd of the session is a linked worktree of the main repository, detached at the head
//   commit. A new clone is a new git root, and Claude Code does not trust it. The main
//   repository has the trust of the user, so its linked worktree needs no trust step. The
//   script never accepts a trust prompt.
// - The input folder is outside the worktree. The session gets it with --add-dir.
// At the end, the script stops and removes the session, removes the worktree and deletes its
// sandbox folder.
//
// The modules of src/main import each other with no file extension. Plain node cannot load them.
// So the script first adds a resolve hook that tries a .ts file when a path fails.

import { existsSync, realpathSync } from 'node:fs'
import { chmod, mkdir, rm } from 'node:fs/promises'
import { registerHooks } from 'node:module'
import { homedir, userInfo } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import type { ExecResult } from '../../src/main/claude/cli.ts'
import type { RepoStore } from '../../src/main/reviews/repo-store.ts'
import type { ReviewContext } from '../../src/main/reviews/review-query.ts'

registerHooks({
  resolve(specifier, context, nextResolve) {
    try {
      return nextResolve(specifier, context)
    } catch (err) {
      const relative = specifier.startsWith('.') || specifier.startsWith('/')
      if (!relative) throw err
      for (const suffix of ['.ts', '/index.ts']) {
        try {
          return nextResolve(specifier + suffix, context)
        } catch {
          // Try the next suffix.
        }
      }
      throw err
    }
  },
})

const { execFile } = await import('../../src/main/claude/cli.ts')
const { parseAgents } = await import('../../src/main/claude/agents.ts')
const { claudeFailure, isTrustError, parseShortId, SHORT_ID } = await import(
  '../../src/main/actions/claude-output.ts'
)
const { createRepoGit, GIT_CONFIG } = await import('../../src/main/reviews/repo-git.ts')
const { isInside } = await import('../../src/main/reviews/repo-paths.ts')
const { createRepoStore } = await import('../../src/main/reviews/repo-store.ts')
const { writeRoundFiles } = await import('../../src/main/reviews/review-input.ts')
const { reviewPrompt, reviewSessionArgs } = await import('../../src/main/reviews/review-session.ts')
const { parseReviewResult, readResultFile } = await import('../../src/main/reviews/result-file.ts')
const { skillsSourceDir } = await import('../../src/main/skills/skills-folder.ts')

// The script touches only sessions with a name that starts with this text.
const PREFIX = 'bifrost-test-r2-live-'
const MODEL = 'haiku'
const POLL_MS = 2_000
const TURN_LIMIT_MS = 5 * 60_000
const CLAUDE_TIMEOUT_MS = 60_000
// After claude stop, the script waits this long at most for the end of the process.
const STOP_WAIT_MS = 15_000
const STOP_POLL_MS = 1_000
const PR_NUMBER = 1

// The files of the PR. The head commit adds sumFirst. Its loop runs one time too many: with
// "<=", it adds the value at index n, and for n equal to the length it adds undefined.
const README = '# Fixture\n\nA small library of helpers for lists of numbers.\n'
const LIST_BASE = `// Helpers for lists of numbers.

// The largest value of the list, or null when the list is empty.
export function largest(values) {
  if (values.length === 0) return null
  let best = values[0]
  for (const value of values) if (value > best) best = value
  return best
}
`
const LIST_HEAD = `${LIST_BASE}
// The sum of the first n values of the list. n is 0 or more, and not more than the length of
// the list.
export function sumFirst(values, n) {
  let total = 0
  for (let i = 0; i <= n; i++) total += values[i]
  return total
}
`
const LIST_TEST = `import { expect, test } from 'vitest'
import { sumFirst } from '../src/list.js'

test('sumFirst adds the first n values', () => {
  expect(sumFirst([1, 2, 3, 4], 2)).toBe(3)
})
`

function fail(message: string): never {
  throw new Error(message)
}

const sleep = (ms: number): Promise<void> => new Promise(done => setTimeout(done, ms))

// The env for git. No GIT_ variable of the shell goes through, and git reads no config of the
// user. The commit identity is fixed.
function gitEnv(): Record<string, string> {
  const env: Record<string, string> = {}
  for (const [key, value] of Object.entries(process.env)) {
    if (value !== undefined && !key.startsWith('GIT_')) env[key] = value
  }
  return {
    ...env,
    GIT_AUTHOR_EMAIL: 'live-check@example.invalid',
    GIT_AUTHOR_NAME: 'Bifrost live check',
    GIT_COMMITTER_EMAIL: 'live-check@example.invalid',
    GIT_COMMITTER_NAME: 'Bifrost live check',
    GIT_CONFIG_GLOBAL: '/dev/null',
    GIT_CONFIG_NOSYSTEM: '1',
    GIT_TERMINAL_PROMPT: '0',
  }
}

const scriptRepo = resolve(import.meta.dirname, '..', '..')
const pluginDir = skillsSourceDir(scriptRepo)

// The git folder of the main repository. In a linked worktree, this is the common git folder.
async function commonGitDir(): Promise<string> {
  const args = ['rev-parse', '--path-format=absolute', '--git-common-dir']
  const result = await execFile('git', args, { cwd: scriptRepo, env: gitEnv() })
  if (result.code !== 0) fail('git could not find the main repository')
  return realpathSync(result.stdout.trim())
}

const gitDir = await commonGitDir()
const mainCheckout = dirname(gitDir)
const sandboxRoot = join(mainCheckout, '.m0-sandbox')
const sandbox = join(sandboxRoot, 'r2-live')
const worktree = join(sandbox, 'wt')
const io = join(sandbox, 'io')

// Run git on the main repository, with the settings of the product. Only git plumbing, the
// worktree commands and the diff run here.
async function git(args: string[], input?: string): Promise<string> {
  const result = await execFile('git', [...GIT_CONFIG, `--git-dir=${gitDir}`, ...args], {
    cwd: mainCheckout,
    env: gitEnv(),
    ...(input === undefined ? {} : { input }),
  })
  if (result.code !== 0) fail(`git ${args[0]} failed: ${result.stderr.trim().split('\n')[0]}`)
  return result.stdout.trim()
}

async function blob(text: string): Promise<string> {
  return git(['hash-object', '-w', '--no-filters', '--stdin'], text)
}

async function tree(entries: { mode: string; type: string; sha: string; name: string }[]) {
  const lines = entries.map(e => `${e.mode} ${e.type} ${e.sha}\t${e.name}\n`).join('')
  return git(['mktree'], lines)
}

// Make the base commit and the head commit. Give both IDs.
async function makeCommits(): Promise<{ base: string; head: string }> {
  const readme = await blob(README)
  const srcBase = await tree([
    { mode: '100644', name: 'list.js', sha: await blob(LIST_BASE), type: 'blob' },
  ])
  const srcHead = await tree([
    { mode: '100644', name: 'list.js', sha: await blob(LIST_HEAD), type: 'blob' },
  ])
  const testTree = await tree([
    { mode: '100644', name: 'list.test.js', sha: await blob(LIST_TEST), type: 'blob' },
  ])
  const baseTree = await tree([
    { mode: '100644', name: 'README.md', sha: readme, type: 'blob' },
    { mode: '040000', name: 'src', sha: srcBase, type: 'tree' },
  ])
  const headTree = await tree([
    { mode: '100644', name: 'README.md', sha: readme, type: 'blob' },
    { mode: '040000', name: 'src', sha: srcHead, type: 'tree' },
    { mode: '040000', name: 'test', sha: testTree, type: 'tree' },
  ])
  const base = await git(['commit-tree', '--no-gpg-sign', '-m', 'Add the list helpers', baseTree])
  const head = await git([
    'commit-tree',
    '--no-gpg-sign',
    '-p',
    base,
    '-m',
    'Add sumFirst',
    headTree,
  ])
  return { base, head }
}

// Run claude with the env line of .m0-sandbox/cl.sh: a clean login env, and cwd as the folder.
// The env has no variable of the parent session. execFile gives claude a closed stdin.
function claude(args: string[], cwd: string): Promise<ExecResult> {
  const env = [
    '-i',
    `HOME=${process.env.HOME ?? homedir()}`,
    `USER=${process.env.USER ?? userInfo().username}`,
    `LOGNAME=${process.env.LOGNAME ?? userInfo().username}`,
    'SHELL=/bin/zsh',
    'TERM=xterm-256color',
    `LANG=${process.env.LANG ?? 'en_GB.UTF-8'}`,
    `TMPDIR=${process.env.TMPDIR ?? '/tmp'}`,
  ]
  const shell = ['/bin/zsh', '-lic', 'cd "$0" && exec claude "$@"', cwd]
  return execFile('/usr/bin/env', [...env, ...shell, ...args], { timeoutMs: CLAUDE_TIMEOUT_MS })
}

// The list with --all also holds the stopped sessions, so the check of the leftover sessions and
// the find of the session also see a session that stopped.
async function agents() {
  const result = await claude(['agents', '--json', '--all'], sandboxRoot)
  if (result.code !== 0) fail(claudeFailure(result, 'claude agents'))
  const list = parseAgents(result.stdout)
  if (list.error !== undefined) fail(`claude agents: ${list.error}`)
  return list.entries
}

// Stop and remove the session of this run. Find it by its short ID, or by its name when claude
// gave no ID. Act only on an entry with a test name.
async function removeSession(shortId: string | null, name: string): Promise<void> {
  const matches = (await agents()).filter(e =>
    shortId === null ? e.name === name : e.id === shortId,
  )
  if (matches.length !== 1) return
  const id = matches[0]?.id
  if (!matches[0]?.name.startsWith(PREFIX)) fail('refused: that session is not a test session')
  if (id === undefined || !SHORT_ID.test(id)) fail('the session has no valid short ID')
  await claude(['stop', id], sandboxRoot)
  await waitForStop(id)
  const removed = await claude(['rm', id], sandboxRoot)
  if (removed.code !== 0) fail(claudeFailure(removed, 'claude rm'))
}

// Wait until the process of the session ends after claude stop: the entry has no pid, or the
// entry is gone. The wait has a limit. Then claude rm runs in any case.
async function waitForStop(id: string): Promise<void> {
  const limit = Date.now() + STOP_WAIT_MS
  while (Date.now() < limit) {
    const entry = (await agents()).find(e => e.id === id)
    if (entry?.pid === undefined) return
    await sleep(STOP_POLL_MS)
  }
}

const samePath = (a: string, b: string): boolean =>
  a === b || (existsSync(a) && existsSync(b) && realpathSync(a) === realpathSync(b))

// Remove the worktree and delete the sandbox folder. A missing folder is not an error.
async function cleanUp(): Promise<void> {
  if (!isInside(sandboxRoot, sandbox)) fail('refused: the sandbox folder is not in .m0-sandbox')
  const listed = await git(['worktree', 'list', '--porcelain'])
  const known = listed
    .split('\n')
    .some(line => line.startsWith('worktree ') && samePath(line.slice(9), worktree))
  if (known) await git(['worktree', 'remove', '--force', worktree])
  await rm(sandbox, { force: true, recursive: true })
}

// The repository store of the round files. The diff and the commit checks are the functions of
// the product, on the main repository. The input folder is the folder of this check. The script
// does not use the other functions.
function makeRepos(): RepoStore {
  const env = gitEnv()
  const product = createRepoStore({
    bifrostHome: join(sandbox, 'home'),
    git: createRepoGit({ env: async () => env, exec: execFile }),
    remoteBase: 'file:///nonexistent/',
  })
  const unused = (): never => fail('the check does not use this function of the store')
  return {
    changedPaths: unused,
    checkAndClean: unused,
    cloneOf: unused,
    commitFix: unused,
    ensureClone: unused,
    fetchPr: unused,
    hasCommit: product.hasCommit,
    isAncestor: product.isAncestor,
    prepareWorktree: unused,
    removeAll: unused,
    removeWorktree: unused,
    async resetIo() {
      await rm(io, { force: true, recursive: true })
      await mkdir(io, { mode: 0o700 })
      await chmod(io, 0o700)
      return io
    },
    writeDiff: product.writeDiff,
  }
}

// Wait for the end of the turn: status idle after status busy. A turn that ends with a question
// gives the status waiting. That also ends the wait, and then the check of the result fails.
async function waitForTurn(shortId: string): Promise<void> {
  const limit = Date.now() + TURN_LIMIT_MS
  let sawBusy = false
  while (Date.now() < limit) {
    await sleep(POLL_MS)
    const entry = (await agents()).find(e => e.id === shortId)
    if (entry === undefined) continue
    if (!entry.name.startsWith(PREFIX)) fail('refused: that session is not a test session')
    if (entry.status === 'busy') sawBusy = true
    else if (sawBusy && (entry.status === 'idle' || entry.status === 'waiting')) return
  }
  fail('the turn did not end in 5 minutes')
}

// True after the check of the leftover sessions. Before that, the script deletes nothing.
let ready = false

async function run(): Promise<void> {
  if ((await agents()).some(entry => entry.name.startsWith(PREFIX))) {
    fail(`a session with a name that starts with ${PREFIX} exists. Remove it first`)
  }
  ready = true
  await cleanUp()
  await mkdir(sandbox, { mode: 0o700, recursive: true })

  const { base, head } = await makeCommits()
  await git(['worktree', 'add', '--quiet', '--detach', worktree, head])

  const context: ReviewContext = {
    author: 'fixture-author',
    baseRef: 'main',
    baseSha: base,
    body:
      'Adds `sumFirst(values, n)`, which gives the sum of the first n values of a list. ' +
      'The test covers the normal case.',
    ci: null,
    headRef: 'add-sum-first',
    headSha: head,
    number: PR_NUMBER,
    owner: 'bifrost-live',
    pending: null,
    prId: 'PR_fixture',
    repo: 'fixture',
    reviews: [],
    state: 'OPEN',
    threads: [],
    title: 'Add sumFirst to the list helpers',
    truncated: false,
    url: `https://github.com/bifrost-live/fixture/pull/${PR_NUMBER}`,
  }
  const written = await writeRoundFiles(
    { repos: makeRepos(), skillsDir: pluginDir },
    {
      clone: mainCheckout,
      context,
      fetched: { base, head, mergeBase: base },
      number: PR_NUMBER,
      viewer: 'fixture-reviewer',
    },
  )
  if (!written.ok) fail(written.message)

  const stamp = new Date().toISOString().replace(/\D/g, '').slice(0, 14)
  const name = `${PREFIX}${stamp}`
  const args = reviewSessionArgs({
    ioDir: io,
    model: MODEL,
    name,
    pluginDir,
    prompt: reviewPrompt(written.inputFile),
  })
  const started = await claude(args, worktree)
  const shortId = parseShortId(started.stdout)
  try {
    if (isTrustError(started.stdout) || isTrustError(started.stderr)) {
      fail('Claude Code does not trust the worktree. The check accepts no trust prompt')
    }
    if (started.code !== 0) fail(claudeFailure(started, 'claude --bg'))
    if (shortId === null) fail('claude --bg did not give a session ID')
    await waitForTurn(shortId)

    const read = await readResultFile(written.input.files.result)
    if (!read.ok) {
      console.log(`the result file is ${read.reason}`)
      return
    }
    const parsed = parseReviewResult(read.text, {
      files: written.files,
      headSha: head,
      pr: written.input.pr.key,
    })
    if (!parsed.ok) {
      console.log(parsed.reason)
      return
    }
    console.log('valid')
    console.log(`recommendation: ${parsed.result.recommendation}`)
    console.log(`comments: ${parsed.result.comments.length}`)
  } finally {
    await removeSession(shortId, name)
  }
}

try {
  await run()
} catch (error) {
  console.error(`check-review-skill failed: ${(error as Error).message}`)
  process.exitCode = 1
} finally {
  try {
    if (ready) await cleanUp()
  } catch (error) {
    console.error(`check-review-skill clean-up failed: ${(error as Error).message}`)
    process.exitCode = 1
  }
}
