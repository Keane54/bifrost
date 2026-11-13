// The live check of the bifrost-resolve-comments skill in Bifrost mode. The script starts one
// real Claude Code session with the Haiku model on a small PR of the user with three review
// items: a thread that asks for the fix of a bug, a PR comment that asks a product question, and
// a thread that says thanks. Then it checks the result file with the checks of the product, and
// it makes the fix commit with commitFix. It prints only: "valid" or the reason, the outcome of
// each item by its place, whether a commit is there, the checks value, and the commit or the
// rule that refused it.
//
// Run it by hand only, from the root of the repository:
//   node scripts/reviews/check-request-skill.ts
// It does not run in CI or in pnpm test. Each run uses a real session and costs tokens.
//
// The set-up, all in .m0-sandbox/r3-live of the main checkout:
// - The script makes the same base commit and head commit in the object store of the main
//   repository and in a local bare repository, with git plumbing and fixed dates. So both have
//   the same commit IDs. The script moves no ref of the main repository, makes no branch there and
//   changes no file of the checkout. The objects stay until a later gc deletes them.
// - The cwd of the session is a linked worktree of the main repository, detached at the head
//   commit. A new clone is a new git root, and Claude Code does not trust it. The main
//   repository has the trust of the user, so its linked worktree needs no trust step. The
//   script never accepts a trust prompt.
// - The product makes its clone of the bare repository, fetches the PR, makes the worktree of
//   the PR and writes the input folder, as in a request round. The input folder is outside the
//   cwd of the session. The session gets it with --add-dir.
// - After the turn, the script copies the files of the session worktree to the worktree of the
//   clone. Then changedPaths and commitFix run on the clone, never on the main repository.
// The script never pushes and never runs gh. git can use only file:// remotes here.
// At the end, the script stops and removes the session, removes the linked worktree and deletes
// its sandbox folder.
//
// The modules of src/main import each other with no file extension. Plain node cannot load them.
// So the script first adds a resolve hook that tries a .ts file when a path fails.

import { existsSync, realpathSync } from 'node:fs'
import { cp, mkdir, readdir, rm } from 'node:fs/promises'
import { registerHooks } from 'node:module'
import { homedir, userInfo } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import type { ExecResult } from '../../src/main/claude/cli.ts'
import type { WorkItem } from '../../src/main/reviews/model.ts'
import type { PrComment } from '../../src/main/reviews/pr-data.ts'
import type { RequestContext, RequestThread } from '../../src/main/reviews/request-query.ts'

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
const { prKey } = await import('../../src/shared/reviews.ts')
const { createRepoGit, GIT_CONFIG } = await import('../../src/main/reviews/repo-git.ts')
const { isInside } = await import('../../src/main/reviews/repo-paths.ts')
const { createRepoStore } = await import('../../src/main/reviews/repo-store.ts')
const { writeRequestFiles } = await import('../../src/main/reviews/request-input.ts')
const { parseRequestResult } = await import('../../src/main/reviews/request-result.ts')
const { claudeSettingsFile, readUserSandboxProblem, requestPrompt, requestSessionArgs } =
  await import('../../src/main/reviews/request-session.ts')
const { readResultFile } = await import('../../src/main/reviews/result-file.ts')
const { skillsSourceDir } = await import('../../src/main/skills/skills-folder.ts')

// The script touches only sessions with a name that starts with this text.
const PREFIX = 'bifrost-test-r3-live-'
const MODEL = 'haiku'
const POLL_MS = 2_000
const TURN_LIMIT_MS = 10 * 60_000
const CLAUDE_TIMEOUT_MS = 60_000
// After claude stop, the script waits this long at most for the end of the process.
const STOP_WAIT_MS = 15_000
const STOP_POLL_MS = 1_000
const OWNER = 'bifrost-live'
const REPO = 'fixture'
const PR_NUMBER = 1
const VIEWER = 'fixture-author'
const HEAD_REF = 'add-item-limit'
// The fixed time of both commits. With it, the main repository and the bare repository get the
// same commit IDs.
const COMMIT_DATE = '2026-11-12T09:00:00+0000'
// git can use only file:// remotes, so no git command of this script can reach GitHub.
const NO_NETWORK: readonly string[] = [
  '-c',
  'protocol.allow=never',
  '-c',
  'protocol.file.allow=always',
]
// The git identity of the fix commit.
const IDENTITY: readonly string[] = [
  '-c',
  'user.name=Bifrost live check',
  '-c',
  'user.email=live-check@example.invalid',
]

// The files of the PR. The head commit adds src/limit.ts. Its comment allows 1 to MAX_ITEMS
// items, but the check uses "<", so a request for exactly MAX_ITEMS items is refused.
const README = '# Fixture\n\nA small client of the items API.\n'
const ITEMS = `// The items API client.

// The path of the items API.
export const ITEMS_PATH = '/api/items'
`
const LIMIT = `// The limits of one request to the items API.

// The most items that one request can ask for.
export const MAX_ITEMS = 100

// True when a request for count items is allowed. A request can ask for 1 to MAX_ITEMS items.
export function isAllowed(count: number): boolean {
  return count >= 1 && count < MAX_ITEMS
}
`
// The line of the bug in src/limit.ts, and the line of its comment.
const BUG_LINE = 8
const COMMENT_LINE = 6

function fail(message: string): never {
  throw new Error(message)
}

const sleep = (ms: number): Promise<void> => new Promise(done => setTimeout(done, ms))

// The env for git. No GIT_ variable of the shell goes through, and git reads no config of the
// user. The commit identity and the commit time are fixed.
function gitEnv(): Record<string, string> {
  const env: Record<string, string> = {}
  for (const [key, value] of Object.entries(process.env)) {
    if (value !== undefined && !key.startsWith('GIT_')) env[key] = value
  }
  return {
    ...env,
    GIT_AUTHOR_DATE: COMMIT_DATE,
    GIT_AUTHOR_EMAIL: 'live-check@example.invalid',
    GIT_AUTHOR_NAME: 'Bifrost live check',
    GIT_COMMITTER_DATE: COMMIT_DATE,
    GIT_COMMITTER_EMAIL: 'live-check@example.invalid',
    GIT_COMMITTER_NAME: 'Bifrost live check',
    GIT_CONFIG_GLOBAL: '/dev/null',
    GIT_CONFIG_NOSYSTEM: '1',
    GIT_TERMINAL_PROMPT: '0',
  }
}

// The home folder of the user, as the env line of .m0-sandbox/cl.sh gives it to claude.
const home = process.env.HOME ?? homedir()
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
const sandbox = join(sandboxRoot, 'r3-live')
const worktree = join(sandbox, 'wt')
const bifrostHome = join(sandbox, 'home')
const remotes = join(sandbox, 'remotes')
const bare = join(remotes, OWNER, `${REPO}.git`)

// Run git with the settings of the product. Without a git folder, the command runs in the
// sandbox. Only git plumbing and the worktree commands run here.
async function git(dir: string | null, args: string[], input?: string): Promise<string> {
  const where = dir === null ? [] : [`--git-dir=${dir}`]
  const result = await execFile('git', [...GIT_CONFIG, ...NO_NETWORK, ...where, ...args], {
    cwd: dir === null ? sandbox : mainCheckout,
    env: gitEnv(),
    ...(input === undefined ? {} : { input }),
  })
  if (result.code !== 0) fail(`git ${args[0]} failed: ${result.stderr.trim().split('\n')[0]}`)
  return result.stdout.trim()
}

// Make the base commit and the head commit in a git folder. Give both IDs.
async function makeCommits(dir: string): Promise<{ base: string; head: string }> {
  const blob = (text: string): Promise<string> =>
    git(dir, ['hash-object', '-w', '--no-filters', '--stdin'], text)
  const tree = (entries: { mode: string; type: string; sha: string; name: string }[]) =>
    git(dir, ['mktree'], entries.map(e => `${e.mode} ${e.type} ${e.sha}\t${e.name}\n`).join(''))
  const readme = await blob(README)
  const items = { mode: '100644', name: 'items.ts', sha: await blob(ITEMS), type: 'blob' }
  const limit = { mode: '100644', name: 'limit.ts', sha: await blob(LIMIT), type: 'blob' }
  const srcBase = await tree([items])
  const srcHead = await tree([items, limit])
  const baseTree = await tree([
    { mode: '100644', name: 'README.md', sha: readme, type: 'blob' },
    { mode: '040000', name: 'src', sha: srcBase, type: 'tree' },
  ])
  const headTree = await tree([
    { mode: '100644', name: 'README.md', sha: readme, type: 'blob' },
    { mode: '040000', name: 'src', sha: srcHead, type: 'tree' },
  ])
  const base = await git(dir, ['commit-tree', '--no-gpg-sign', '-m', 'Add the client', baseTree])
  const head = await git(dir, [
    'commit-tree',
    '--no-gpg-sign',
    '-p',
    base,
    '-m',
    'Add the item limit',
    headTree,
  ])
  return { base, head }
}

// Make the bare repository with main at the base commit and the PR branch at the head commit.
// HEAD names main, so main is the default branch.
async function makeRemote(): Promise<{ base: string; head: string }> {
  await mkdir(dirname(bare), { mode: 0o700, recursive: true })
  await git(null, ['init', '--quiet', '--bare', '--initial-branch=main', bare])
  const made = await makeCommits(bare)
  await git(bare, ['update-ref', 'refs/heads/main', made.base])
  await git(bare, ['update-ref', `refs/heads/${HEAD_REF}`, made.head])
  await git(bare, ['update-ref', `refs/pull/${PR_NUMBER}/head`, made.head])
  return made
}

// Run claude with the env line of .m0-sandbox/cl.sh: a clean login env, and cwd as the folder.
// The env has no variable of the parent session. execFile gives claude a closed stdin.
function claude(args: string[], cwd: string): Promise<ExecResult> {
  const env = [
    '-i',
    `HOME=${home}`,
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

// Remove the linked worktree and delete the sandbox folder. The bare repository, the clone and
// the input folder are in the sandbox folder. A missing folder is not an error.
async function cleanUp(): Promise<void> {
  if (!isInside(sandboxRoot, sandbox)) fail('refused: the sandbox folder is not in .m0-sandbox')
  const listed = await git(gitDir, ['worktree', 'list', '--porcelain'])
  const known = listed
    .split('\n')
    .some(line => line.startsWith('worktree ') && samePath(line.slice(9), worktree))
  if (known) await git(gitDir, ['worktree', 'remove', '--force', worktree])
  await rm(sandbox, { force: true, recursive: true })
}

// Give the worktree of the clone the files of the session worktree. The .git entry of each
// worktree stays as it is. A link stays a link, so the checks of commitFix see it.
async function copyChanges(from: string, to: string): Promise<void> {
  if (!isInside(sandbox, to)) fail('refused: the worktree of the clone is not in the sandbox')
  for (const name of await readdir(to)) {
    if (name !== '.git') await rm(join(to, name), { force: true, recursive: true })
  }
  for (const name of await readdir(from)) {
    if (name === '.git') continue
    await cp(join(from, name), join(to, name), {
      errorOnExist: true,
      force: false,
      recursive: true,
      verbatimSymlinks: true,
    })
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
  fail('the turn did not end in 10 minutes')
}

const at = (iso: string): number => Date.parse(iso)

// A comment of a member of the repository.
function memberComment(
  id: string,
  n: number,
  login: string,
  body: string,
  time: string,
): PrComment {
  return {
    author: { association: 'MEMBER', bot: false, login },
    body,
    createdAt: at(time),
    databaseId: n,
    id,
  }
}

// A review thread on a line of src/limit.ts, with one comment of a member. The diff hunk ends at
// that line, as on GitHub.
function memberThread(
  n: number,
  line: number,
  login: string,
  body: string,
  time: string,
): RequestThread {
  const lines = LIMIT.split('\n').slice(0, line)
  return {
    comments: [memberComment(`PRRC_live${n}`, n, login, body, time)],
    diffHunk: `@@ -0,0 +1,${line} @@\n${lines.map(text => `+${text}`).join('\n')}`,
    id: `PRRT_live${n}`,
    isOutdated: false,
    isResolved: false,
    line,
    path: 'src/limit.ts',
    reviewId: `PRR_live${n}`,
    viewerCanReply: true,
  }
}

// The context of the PR as a request round reads it from GitHub. The script makes it by hand,
// with no gh call.
function makeContext(base: string, head: string): RequestContext {
  const bug = memberThread(
    1,
    BUG_LINE,
    'fixture-lead',
    'The comment above says that a request can ask for 1 to MAX_ITEMS items, but this check ' +
      'refuses a request for exactly MAX_ITEMS items. Please fix it.',
    '2026-11-12T10:00:00Z',
  )
  const question = memberComment(
    'IC_live2',
    2,
    'fixture-pm',
    'Should accounts on the free plan get the same limit of 100 items, or a lower one? ' +
      'Nobody has decided this yet.',
    '2026-11-12T10:05:00Z',
  )
  const thanks = memberThread(
    3,
    COMMENT_LINE,
    'fixture-dev',
    'Thanks for this comment. It makes the allowed range easy to see.',
    '2026-11-12T10:10:00Z',
  )
  return {
    author: VIEWER,
    baseRef: 'main',
    baseSha: base,
    body:
      'Adds MAX_ITEMS and isAllowed, so that the client can check a request before it ' +
      'sends it.',
    comments: [question],
    decisions: [],
    defaultBranch: 'main',
    headRef: HEAD_REF,
    headSha: head,
    id: 'PR_live1',
    isCrossRepository: false,
    number: PR_NUMBER,
    owner: OWNER,
    repo: REPO,
    requested: [],
    reviews: [],
    state: 'OPEN',
    threads: [bug, thanks],
    title: 'Add a limit to the item requests',
    truncated: false,
    updatedAt: at('2026-11-12T10:10:00Z'),
    url: `https://github.com/${OWNER}/${REPO}/pull/${PR_NUMBER}`,
    viewerPending: false,
  }
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

  // The commits in the main repository give the cwd of the session. The commits in the bare
  // repository give the clone of the product. Both must have the same IDs.
  const { base, head } = await makeCommits(gitDir)
  const remote = await makeRemote()
  if (remote.base !== base || remote.head !== head) {
    fail('the bare repository got other commit IDs than the main repository')
  }
  await git(gitDir, ['worktree', 'add', '--quiet', '--detach', worktree, head])

  const env = gitEnv()
  const repos = createRepoStore({
    bifrostHome,
    git: createRepoGit({
      env: async () => env,
      exec: execFile,
      extraConfig: [...NO_NETWORK, ...IDENTITY],
    }),
    remoteBase: `file://${remotes}/`,
  })
  const clone = await repos.ensureClone(OWNER, REPO)
  const fetched = await repos.fetchPr(clone, PR_NUMBER, 'main')
  if (fetched.head !== head || fetched.base !== base) fail('the clone got other commits')
  const cloneWorktree = await repos.prepareWorktree(clone, PR_NUMBER, head)

  const context = makeContext(base, head)
  const items: WorkItem[] = [
    { id: 'PRRT_live1', kind: 'thread' },
    { id: 'IC_live2', kind: 'comment' },
    { id: 'PRRT_live3', kind: 'thread' },
  ]
  const written = await writeRequestFiles(
    { repos, skillsDir: pluginDir },
    { clone, context, fetched, items, number: PR_NUMBER, questions: {}, viewer: VIEWER },
  )
  if (!written.ok) fail(written.message)

  // The user settings load in the session, as in the product. A sandbox key there can make the
  // sandbox weaker, so the check refuses to start.
  const problem = await readUserSandboxProblem(claudeSettingsFile(home))
  if (problem !== null) fail(problem)

  const stamp = new Date().toISOString().replace(/\D/g, '').slice(0, 14)
  const name = `${PREFIX}${stamp}`
  // The cwd is a linked worktree of the main repository, so its git data is in the .git folder
  // of the main repository. The sandbox denies the writes there.
  const args = requestSessionArgs({
    clone: mainCheckout,
    ioDir: dirname(written.inputFile),
    model: MODEL,
    name,
    pluginDir,
    prompt: requestPrompt(written.inputFile),
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

    await copyChanges(worktree, cloneWorktree)
    const changed = new Set(await repos.changedPaths(clone, PR_NUMBER))
    const read = await readResultFile(written.input.files.result)
    if (!read.ok) {
      console.log(`the result file is ${read.reason}`)
      process.exitCode = 1
      return
    }
    const ids = written.input.items.map(item => item.id)
    const parsed = parseRequestResult(read.text, {
      changed,
      headSha: head,
      items: ids,
      pr: prKey(OWNER, REPO, PR_NUMBER),
    })
    if (!parsed.ok) {
      console.log(parsed.reason)
      process.exitCode = 1
      return
    }
    const { result } = parsed
    console.log('valid')
    for (const [index, item] of written.input.items.entries()) {
      const outcome = result.items.find(entry => entry.id === item.id)?.outcome
      console.log(`item ${index + 1} (${item.kind}): ${outcome ?? 'missing'}`)
    }
    console.log(`commit: ${result.commit === null ? 'no' : 'yes'}`)
    console.log(`checks: ${result.checks}`)
    if (result.commit === null) return

    const made = await repos.commitFix(clone, PR_NUMBER, {
      head,
      message: result.commit.message,
      paths: result.commit.paths,
    })
    if (made.ok) {
      console.log(`committed ${made.sha.slice(0, 7)}`)
    } else {
      console.log(`not committed: ${made.rule}`)
      process.exitCode = 1
    }
  } finally {
    await removeSession(shortId, name)
  }
}

try {
  await run()
} catch (error) {
  console.error(`check-request-skill failed: ${(error as Error).message}`)
  process.exitCode = 1
} finally {
  try {
    if (ready) await cleanUp()
  } catch (error) {
    console.error(`check-request-skill clean-up failed: ${(error as Error).message}`)
    process.exitCode = 1
  }
}
