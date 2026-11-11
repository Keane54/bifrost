import { existsSync } from 'node:fs'
import { mkdir, mkdtemp, readdir, realpath, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ExecResult } from '../../../src/main/claude/cli'
import type { Gh } from '../../../src/main/reviews/gh'
import type { PollData, PrData } from '../../../src/main/reviews/pr-data'
import { clonePath, ioPath, isInside, worktreePath } from '../../../src/main/reviews/repo-paths'
import type { RepoStore } from '../../../src/main/reviews/repo-store'
import {
  type ReviewSessions,
  type StartOutcome,
  TEST_PREFIX,
} from '../../../src/main/reviews/review-session'
import {
  draftNotice,
  REASON_CLOSED_WHILE_POSTING,
  REASON_NO_RESULT,
  REASON_POST_TIMEOUT,
  REASON_PR_CHANGED,
  REASON_PR_CLOSED,
  REASON_STOPPED,
  REASON_TIMEOUT,
  reasonBadResult,
  reasonPostFailed,
  reviewedNotice,
  trustNotice,
} from '../../../src/main/reviews/round-text'
import {
  CLONE_RETRY_MS,
  createReviewRunner,
  END_SETTLE_MS,
  GONE_GRACE_MS,
  IDLE_STOP_MS,
  NO_START_MS,
  PASS_MS,
  REFUSED_NOT_REVIEWABLE,
  REFUSED_REVIEWS_BUSY,
  REFUSED_UNKNOWN_REPO,
  type ReviewRunner,
  ROUND_LIMIT_MS,
  roundEnd,
} from '../../../src/main/reviews/rounds'
import {
  type ActiveRound,
  EMPTY_STATE,
  emptyPrState,
  parseState,
  type ReviewsState,
} from '../../../src/main/reviews/state'
import type { ReviewsStateStore } from '../../../src/main/reviews/state-store'
import type { RequestNotice } from '../../../src/main/reviews/watcher'
import type { ModelChoice } from '../../../src/shared/new-session'
import { prKey } from '../../../src/shared/reviews'
import type { SessionRow } from '../../../src/shared/types'

const T0 = new Date('2026-11-11T10:00:00Z')
const HEAD = 'a'.repeat(40)
const BASE = 'b'.repeat(40)
const NEW_HEAD = 'c'.repeat(40)
const VIEWER = 'me'
const KEY = 'acme/web#7'

// One file with one hunk: the right side has lines 1 to 4.
const DIFF = [
  'diff --git a/src/a.ts b/src/a.ts',
  'index 1111111..2222222 100644',
  '--- a/src/a.ts',
  '+++ b/src/a.ts',
  '@@ -1,3 +1,4 @@',
  ' one',
  '+two',
  ' three',
  ' four',
  '',
].join('\n')

// A diff of another file. The session can write it into its input folder.
const OTHER_DIFF = DIFF.replaceAll('src/a.ts', 'src/evil.ts')

const short = (n: number): string => n.toString(16).padStart(8, '0')

function resultText(over: Record<string, unknown> = {}, key = KEY): string {
  return JSON.stringify({
    comments: [{ body: 'Check this.', line: 2, path: 'src/a.ts', side: 'RIGHT' }],
    headSha: HEAD,
    pr: key,
    recommendation: 'comment',
    summary: 'Looks fine overall.',
    version: 1,
    why: 'One small point.',
    ...over,
  })
}

const approve = (key = KEY): string =>
  resultText({ comments: [], recommendation: 'approve', summary: '' }, key)
const APPROVE = approve()

function pr(number: number, repo = 'web', owner = 'acme'): PrData {
  return {
    additions: 1,
    author: 'alice',
    baseRef: 'main',
    comments: [],
    createdAt: 1,
    decisions: [],
    deletions: 1,
    failedChecks: 0,
    headRef: 'f',
    headSha: HEAD,
    isCrossRepository: false,
    isDraft: false,
    key: prKey(owner, repo, number),
    number,
    owner,
    repo,
    requestedAt: 1,
    requestedTeams: [],
    requestedUsers: [VIEWER],
    reviewDecision: null,
    reviews: [],
    threads: [],
    title: `PR ${number}`,
    truncatedChecks: false,
    truncatedComments: false,
    truncatedReviews: false,
    truncatedThreads: false,
    updatedAt: 5,
    url: `https://github.com/${owner}/${repo}/pull/${number}`,
    viewerPendingReviewId: null,
  }
}

function pollOf(toReview: PrData[], mine: PrData[] = [], over: Partial<PollData> = {}): PollData {
  return {
    errors: [],
    mine,
    mineHasMore: false,
    rateLimit: null,
    toReview,
    toReviewHasMore: false,
    viewer: VIEWER,
    ...over,
  }
}

function row(n: number, over: Partial<SessionRow> = {}): SessionRow {
  return {
    box: 'none',
    boxSince: null,
    claudeName: `s${n}`,
    cwd: '/w',
    flashing: false,
    kind: 'owned',
    lastActivity: Date.now(),
    name: `s${n}`,
    prSession: true,
    sessionId: `sess-${n}`,
    shortId: short(n),
    startedAt: 0,
    state: 'working',
    status: 'busy',
    ...over,
  }
}

const IDLE: Partial<SessionRow> = { state: 'idle', status: 'idle' }
const PROMPT: Partial<SessionRow> = {
  box: 'red',
  boxReason: 'prompt',
  state: 'needs-you',
  status: 'waiting',
}

function memoryStore(initial: ReviewsState): ReviewsStateStore {
  let current = structuredClone(initial)
  let queue: Promise<unknown> = Promise.resolve()
  return {
    change(fn) {
      const run = queue.then(() => {
        current = fn(current)
        return current
      })
      queue = run.catch(() => {})
      return run
    },
    get: () => current,
  }
}

const ok = (data: unknown): ExecResult => ({ code: 0, stderr: '', stdout: JSON.stringify(data) })

interface Context {
  state: 'OPEN' | 'CLOSED' | 'MERGED'
  head: string
  pending: { id: string; body: string; commit: string } | null
}

function contextAnswer(c: Context): ExecResult {
  return ok({
    data: {
      repository: {
        pullRequest: {
          author: { login: 'alice' },
          baseRefName: 'main',
          baseRefOid: BASE,
          body: 'The body.',
          headRefName: 'f',
          headRefOid: c.head,
          pending: {
            nodes: c.pending
              ? [
                  {
                    body: c.pending.body,
                    commit: { oid: c.pending.commit },
                    id: c.pending.id,
                    viewerDidAuthor: true,
                  },
                ]
              : [],
          },
          reviews: { nodes: [], pageInfo: { endCursor: null, hasNextPage: false } },
          state: c.state,
          title: 'A PR',
          url: 'https://github.com/acme/web/pull/7',
        },
      },
    },
  })
}

let dir: string

interface Options {
  state?: ReviewsState
  max?: number
  ignore?: string[]
  testHome?: boolean
  model?: ModelChoice
  // The folder of this harness. Two harnesses in one test need two folders.
  id?: string
}

function make(o: Options = {}) {
  const base = join(dir, o.id ?? 'a')
  const home = join(base, 'home')
  const claudeJson = join(base, 'claude.json')
  const skillsDir = join(dir, 'skills')
  const store = memoryStore(o.state ?? EMPTY_STATE)
  const calls = {
    changed: 0,
    cleaned: [] as number[],
    clones: [] as string[],
    diffs: [] as { from: string; to: string; file: string; mode: string }[],
    gh: [] as { args: string[]; input?: string }[],
    logs: [] as string[],
    notices: [] as RequestNotice[],
    polls: 0,
    removeAll: 0,
    removes: [] as { shortId: string; sessionId: string; name: string }[],
    starts: [] as { cwd: string; args: string[]; name: string }[],
    stops: [] as string[],
    worktreesRemoved: [] as number[],
  }
  const ctx: Context = { head: HEAD, pending: null, state: 'OPEN' }
  let started = 0
  const okStart = (s: { name: string }): StartOutcome => {
    started++
    return { name: s.name, ok: true, sessionId: `sess-${started}`, shortId: short(started) }
  }
  const fake = {
    changed: 0,
    cloned: new Set<string>(),
    cloneFail: new Set<string>(),
    cloneGate: null as Promise<void> | null,
    head: HEAD,
    post: null as ExecResult | null,
    start: okStart as (s: {
      cwd: string
      args: string[]
      name: string
    }) => StartOutcome | Promise<StartOutcome>,
  }
  let rows: SessionRow[] = []
  let last: PollData | null = null

  const repos: RepoStore = {
    async checkAndClean(_clone, number) {
      calls.cleaned.push(number)
      return { changed: fake.changed }
    },
    cloneOf(owner, repo) {
      const path = clonePath(home, owner, repo)
      return fake.cloned.has(path) ? path : null
    },
    async ensureClone(owner, repo) {
      const name = `${owner}/${repo}`.toLowerCase()
      calls.clones.push(name)
      if (fake.cloneGate) await fake.cloneGate
      if (fake.cloneFail.has(name)) throw new Error(`Bifrost couldn't copy ${name}: no access.`)
      const path = clonePath(home, owner, repo)
      await mkdir(path, { recursive: true })
      fake.cloned.add(path)
      return path
    },
    async fetchPr() {
      return { base: BASE, head: fake.head, mergeBase: BASE }
    },
    hasCommit: async () => false,
    isAncestor: async () => false,
    async prepareWorktree(clone, number) {
      const path = worktreePath(clone, number)
      await mkdir(path, { recursive: true })
      return path
    },
    async removeAll() {
      calls.removeAll++
      fake.cloned.clear()
    },
    async removeWorktree(_clone, number) {
      calls.worktreesRemoved.push(number)
    },
    async resetIo(clone, number) {
      const io = ioPath(clone, number)
      await rm(io, { force: true, recursive: true })
      await mkdir(io, { recursive: true })
      return io
    },
    async writeDiff(_clone, from, to, file, mode) {
      calls.diffs.push({ file, from, mode, to })
      await writeFile(file, DIFF)
    },
  }

  const gh: Gh = {
    async run(args, opts) {
      calls.gh.push(opts?.input === undefined ? { args } : { args, input: opts.input })
      const query = args.find(a => a.startsWith('query=')) ?? ''
      if (query.includes('query ReviewContext')) return contextAnswer(ctx)
      if (query.includes('mutation AddThread')) {
        return ok({ data: { addPullRequestReviewThread: { thread: { id: 'THR_1' } } } })
      }
      if (query.includes('mutation SetBody')) {
        return ok({
          data: {
            updatePullRequestReview: { pullRequestReview: { id: 'PRR_user', state: 'PENDING' } },
          },
        })
      }
      if (args.includes('POST')) return fake.post ?? ok({ node_id: 'PRR_new', state: 'PENDING' })
      return { code: 1, stderr: 'unexpected call', stdout: '' }
    },
  }

  const sessions: ReviewSessions = {
    async remove(r) {
      calls.removes.push(r)
    },
    async start(s) {
      calls.starts.push(s)
      return fake.start(s)
    },
    async stop(shortId) {
      calls.stops.push(shortId)
    },
  }

  const runner: ReviewRunner = createReviewRunner({
    bifrostHome: home,
    changed: () => {
      calls.changed++
    },
    claudeJson,
    gh,
    log: m => calls.logs.push(m),
    notify: n => calls.notices.push(n),
    now: () => Date.now(),
    repos,
    requestPoll: () => {
      calls.polls++
    },
    rows: () => rows,
    sessions,
    settings: () => ({
      reviewsIgnore: o.ignore ?? [],
      reviewsMaxSessions: o.max ?? 3,
      reviewsReviewModel: o.model ?? '',
    }),
    skillsDir,
    store,
    testHome: o.testHome ?? false,
    toReviewPr: key => last?.toReview.find(p => p.key === key) ?? null,
    viewer: () => last?.viewer ?? null,
  })

  const cloneOf = (repo = 'web', owner = 'acme') => clonePath(home, owner, repo)
  const h = {
    calls,
    clone: cloneOf,
    ctx,
    fake,
    home,
    io: (number = 7, repo = 'web') => ioPath(cloneOf(repo), number),
    okStart,
    async poll(data: PollData) {
      last = data
      runner.afterPoll(data)
      await runner.settled()
    },
    posts: () => calls.gh.filter(c => c.args.includes('POST')),
    pr: (key = KEY) => store.get().prs[key],
    // Make the clone of a repository before the test.
    async preClone(repo = 'web', owner = 'acme') {
      const path = cloneOf(repo, owner)
      await mkdir(path, { recursive: true })
      fake.cloned.add(path)
    },
    async rowsNow(next: SessionRow[]) {
      rows = next
      runner.onRows(next)
      await runner.settled()
    },
    runner,
    setRows(next: SessionRow[]) {
      rows = next
    },
    state: () => store.get(),
    store,
    async tick(ms: number) {
      await vi.advanceTimersByTimeAsync(ms)
      await runner.settled()
    },
    // Write ~/.claude.json with these folders trusted, then tell the runner.
    async trust(...paths: string[]) {
      await h.writeTrust(paths)
      runner.trustChanged()
      await runner.settled()
    },
    async writeResult(text: string, number = 7, repo = 'web') {
      await writeFile(join(h.io(number, repo), 'result.json'), text)
    },
    async writeTrust(paths: string[]) {
      await mkdir(base, { recursive: true })
      const projects = Object.fromEntries(paths.map(p => [p, { hasTrustDialogAccepted: true }]))
      await writeFile(claudeJson, JSON.stringify({ projects }))
    },
  }
  return h
}

type Harness = ReturnType<typeof make>

// The clones of the PRs exist, the trusted ones are trusted, the runner runs and has a poll.
async function ready(h: Harness, prs: PrData[], trusted = ['web']): Promise<void> {
  for (const repo of new Set(prs.map(p => p.repo))) await h.preClone(repo)
  await h.writeTrust(trusted.map(repo => h.clone(repo)))
  h.runner.start()
  await h.runner.settled()
  await h.poll(pollOf(prs))
}

// The session of round n works, can write a result, then goes idle. The timer ends the round.
async function endTurn(
  h: Harness,
  o: { n?: number; result?: string; number?: number; others?: SessionRow[] } = {},
): Promise<void> {
  const n = o.n ?? 1
  const others = o.others ?? []
  await h.rowsNow([row(n), ...others])
  if (o.result !== undefined) await h.writeResult(o.result, o.number ?? 7)
  await h.rowsNow([row(n, IDLE), ...others])
  await h.tick(END_SETTLE_MS + PASS_MS)
}

async function review(h: Harness, key = KEY): Promise<void> {
  await h.runner.review(key)
  await h.runner.settled()
}

beforeEach(async () => {
  vi.useFakeTimers()
  vi.setSystemTime(T0)
  dir = await realpath(await mkdtemp(join(tmpdir(), 'bifrost-rounds-')))
  await mkdir(join(dir, 'skills/skills/bifrost-review'), { recursive: true })
  await mkdir(join(dir, 'skills/skills/bifrost-humanise'), { recursive: true })
  await writeFile(join(dir, 'skills/skills/bifrost-review/bifrost-mode.md'), '# mode\n')
  await writeFile(join(dir, 'skills/skills/bifrost-humanise/rules.md'), '# rules\n')
})

afterEach(async () => {
  vi.useRealTimers()
  await rm(dir, { force: true, recursive: true })
})

describe('roundEnd', () => {
  it('roundEnd: one test for each rule', () => {
    const now = 10 * 60 * 60_000
    const base = {
      idleSince: null,
      now,
      resultExists: false,
      row: undefined,
      rowsSince: now,
      seenWorking: false,
      startedAt: now,
    }
    const working = row(1)
    // The time limit comes first, also for a session that works.
    expect(roundEnd({ ...base, row: working, startedAt: now - ROUND_LIMIT_MS })).toBe('timeout')
    expect(roundEnd({ ...base, row: working, startedAt: now - ROUND_LIMIT_MS + 1 })).toBe('wait')
    // No row: gone after the grace time from the first good registry update.
    expect(roundEnd({ ...base, rowsSince: now - GONE_GRACE_MS })).toBe('gone')
    expect(roundEnd({ ...base, rowsSince: now - GONE_GRACE_MS + 1 })).toBe('wait')
    // Working, or a red prompt box: wait, also with an old idle time and a result.
    const old = { idleSince: now - NO_START_MS, resultExists: true, seenWorking: true }
    expect(roundEnd({ ...base, ...old, row: working })).toBe('wait')
    expect(roundEnd({ ...base, ...old, row: row(1, PROMPT) })).toBe('wait')
    // Idle, parked or an error box.
    const ends = [
      row(1, IDLE),
      row(1, { state: 'parked', status: 'stopped' }),
      row(1, { box: 'red', boxReason: 'error', state: 'error', status: 'idle' }),
    ]
    for (const r of ends) {
      const at = { ...base, row: r }
      expect(roundEnd({ ...at, idleSince: now - END_SETTLE_MS, resultExists: true })).toBe('ended')
      expect(roundEnd({ ...at, idleSince: now - END_SETTLE_MS, seenWorking: true })).toBe('ended')
      expect(roundEnd({ ...at, idleSince: now - END_SETTLE_MS + 1, seenWorking: true })).toBe(
        'wait',
      )
      expect(roundEnd({ ...at, idleSince: now - END_SETTLE_MS })).toBe('wait')
      expect(roundEnd({ ...at, idleSince: now - NO_START_MS + 1 })).toBe('wait')
      expect(roundEnd({ ...at, idleSince: now - NO_START_MS })).toBe('ended')
      expect(roundEnd({ ...at, resultExists: true, seenWorking: true })).toBe('wait')
    }
  })

  it('has the values of the brief', () => {
    expect(ROUND_LIMIT_MS).toBe(30 * 60_000)
    expect(IDLE_STOP_MS).toBe(10 * 60_000)
    expect(END_SETTLE_MS).toBe(10_000)
    expect(NO_START_MS).toBe(120_000)
    expect(GONE_GRACE_MS).toBe(60_000)
    expect(CLONE_RETRY_MS).toBe(60 * 60_000)
    expect(PASS_MS).toBe(5_000)
    expect(REFUSED_NOT_REVIEWABLE).toBe('refused: this pull request cannot get a review now')
    expect(REFUSED_REVIEWS_BUSY).toBe('refused: reviews are busy')
    expect(REFUSED_UNKNOWN_REPO).toBe('refused: unknown repository')
  })
})

describe('clones and the set-up', () => {
  it(
    'the set-up clones the repositories of both tabs, skips the ignored ones and sends ' +
      'no notification',
    async () => {
      const h = make({ ignore: ['other/*'] })
      h.runner.start()
      await h.runner.settled()
      await h.poll(pollOf([pr(7), pr(3, 'x', 'other')], [pr(9, 'api')]))
      expect(h.calls.clones).toEqual(['acme/web', 'acme/api'])
      expect(h.state().setUpAt).toBe(T0.getTime())
      expect(h.calls.notices).toEqual([])
      expect(h.calls.changed).toBeGreaterThan(0)
      // Both clones need trust. The strip lists them in the order of the names.
      expect(h.runner.trust()).toEqual([
        { repo: 'acme/api', waiting: 1 },
        { repo: 'acme/web', waiting: 1 },
      ])
      expect(h.runner.clonePathOf('acme/web')).toBe(h.clone('web'))
      expect(h.runner.clonePathOf('other/x')).toBeNull()
      expect(h.runner.clonePathOf('bad name')).toBeNull()
    },
  )

  it('a repository that shows during the set-up joins it', async () => {
    const h = make()
    let release = (): void => {}
    h.fake.cloneGate = new Promise(resolve => {
      release = resolve
    })
    h.runner.start()
    await h.runner.settled()
    h.runner.afterPoll(pollOf([pr(7)]))
    h.runner.afterPoll(pollOf([pr(7), pr(2, 'api')]))
    release()
    await h.runner.settled()
    expect(h.calls.clones).toEqual(['acme/web', 'acme/api'])
    expect(h.state().setUpAt).toBe(T0.getTime())
    expect(h.calls.notices).toEqual([])
  })

  it('the set-up runs once for a state from R1 with no setUpAt', async () => {
    const r1 = parseState({
      baseline: [],
      pauses: {},
      prs: {},
      requests: { [KEY]: { baseline: true, firstSeen: 1 } },
      turnedOnAt: 1,
      version: 1,
    })
    expect(r1.setUpAt).toBeNull()
    const h = make({ state: r1 })
    h.runner.start()
    await h.runner.settled()
    await h.poll(pollOf([pr(7)]))
    expect(h.calls.clones).toEqual(['acme/web'])
    expect(h.calls.notices).toEqual([])
    const first = h.state().setUpAt
    expect(first).toBe(T0.getTime())
    await h.tick(2 * 60_000)
    await h.poll(pollOf([pr(7)]))
    expect(h.state().setUpAt).toBe(first)
    expect(h.calls.clones).toEqual(['acme/web'])
    expect(h.calls.notices).toEqual([])
  })

  it(
    'a repository that shows after the set-up gets its clone and ' + 'one trust notification',
    async () => {
      const h = make()
      h.runner.start()
      await h.runner.settled()
      await h.poll(pollOf([pr(7)]))
      expect(h.calls.notices).toEqual([])
      await h.tick(60_000)
      await h.poll(pollOf([pr(7), pr(2, 'api')]))
      expect(h.calls.clones).toEqual(['acme/web', 'acme/api'])
      expect(h.calls.notices).toEqual([trustNotice('acme/api')])
      expect(h.state().repos['acme/api']).toEqual({ trustNotifiedAt: T0.getTime() + 60_000 })
      await h.poll(pollOf([pr(7), pr(2, 'api')]))
      expect(h.calls.notices).toHaveLength(1)
      // A new repository that is trusted gets no notification.
      await h.writeTrust([h.clone('ops')])
      await h.poll(pollOf([pr(7), pr(2, 'api'), pr(4, 'ops')]))
      expect(h.calls.clones).toEqual(['acme/web', 'acme/api', 'acme/ops'])
      expect(h.calls.notices).toHaveLength(1)
    },
  )

  it(
    'one clone runs at a time, and a failed clone logs once ' + 'and waits CLONE_RETRY_MS',
    async () => {
      const h = make()
      let release = (): void => {}
      h.fake.cloneGate = new Promise(resolve => {
        release = resolve
      })
      h.runner.start()
      await h.runner.settled()
      h.runner.afterPoll(pollOf([pr(1), pr(2, 'api')]))
      for (let i = 0; i < 20; i++) await Promise.resolve()
      expect(h.calls.clones).toEqual(['acme/web'])
      release()
      await h.runner.settled()
      expect(h.calls.clones).toEqual(['acme/web', 'acme/api'])

      const f = make({ id: 'b' })
      f.fake.cloneFail.add('acme/api')
      f.runner.start()
      await f.runner.settled()
      await f.poll(pollOf([pr(1), pr(2, 'api')]))
      const tries = () => f.calls.clones.filter(c => c === 'acme/api').length
      const lines = () => f.calls.logs.filter(l => l.includes('acme/api'))
      expect(tries()).toBe(1)
      expect(lines()).toHaveLength(1)
      // The set-up ends also when a clone fails.
      expect(f.state().setUpAt).toBe(T0.getTime())
      await f.tick(2 * 60_000)
      await f.poll(pollOf([pr(1), pr(2, 'api')]))
      expect(tries()).toBe(1)
      await f.tick(CLONE_RETRY_MS)
      await f.poll(pollOf([pr(1), pr(2, 'api')]))
      expect(tries()).toBe(2)
      expect(lines()).toHaveLength(1)
    },
  )

  it('stop ends the clone order after the clone that runs', async () => {
    const h = make()
    let release = (): void => {}
    h.fake.cloneGate = new Promise(resolve => {
      release = resolve
    })
    h.runner.start()
    await h.runner.settled()
    h.runner.afterPoll(pollOf([pr(1), pr(2, 'api')]))
    for (let i = 0; i < 20; i++) await Promise.resolve()
    h.runner.stop()
    release()
    await h.runner.settled()
    expect(h.calls.clones).toEqual(['acme/web'])
    expect(h.state().setUpAt).toBeNull()
  })

  it('trust() counts the PRs of both tabs for each repository that needs trust', async () => {
    const h = make()
    for (const repo of ['web', 'api', 'ops']) await h.preClone(repo)
    await h.writeTrust([h.clone('ops')])
    h.runner.start()
    await h.runner.settled()
    await h.poll(
      pollOf([pr(1), pr(2), pr(3, 'api'), pr(5, 'ops')], [pr(4), pr(6, 'api'), pr(8, 'web')]),
    )
    expect(h.runner.trust()).toEqual([
      { repo: 'acme/api', waiting: 2 },
      { repo: 'acme/web', waiting: 4 },
    ])
    await h.trust(h.clone('web'), h.clone('ops'))
    expect(h.runner.trust()).toEqual([{ repo: 'acme/api', waiting: 2 }])
    // The poll reads the trust again while a clone needs trust.
    await h.writeTrust([h.clone('web'), h.clone('ops'), h.clone('api')])
    await h.poll(pollOf([pr(1), pr(3, 'api')]))
    expect(h.runner.trust()).toEqual([])
  })
})

describe('the queue', () => {
  it('a click queues the PR and the round starts when a slot is free', async () => {
    const h = make({ max: 1 })
    await ready(h, [pr(7), pr(8)])
    await review(h, KEY)
    expect(h.pr()?.round?.phase).toBe('running')
    expect(h.pr()?.actedAt).toBe(T0.getTime())
    await h.tick(1000)
    await review(h, 'acme/web#8')
    expect(h.runner.session('acme/web#8')).toBe('queued')
    expect(h.state().queue).toEqual([
      { at: T0.getTime() + 1000, key: 'acme/web#8', kind: 'review' },
    ])
    expect(h.pr('acme/web#8')?.actedAt).toBe(T0.getTime() + 1000)
    expect(h.calls.starts).toHaveLength(1)
    await endTurn(h, { result: APPROVE })
    expect(h.pr()?.round).toBeNull()
    expect(h.pr('acme/web#8')?.round?.phase).toBe('running')
    expect(h.state().queue).toEqual([])
    expect(h.calls.starts).toHaveLength(2)
  })

  it('the queue starts the oldest first and runs reviewsMaxSessions rounds at most', async () => {
    const h = make({ max: 2 })
    await ready(h, [pr(1), pr(2), pr(3), pr(4)])
    for (const n of [4, 1, 2, 3]) {
      await review(h, `acme/web#${n}`)
      await h.tick(1000)
    }
    const names = () => h.calls.starts.map(s => s.name)
    expect(names()).toEqual(['web-4-review', 'web-1-review'])
    expect(h.state().queue.map(e => e.key)).toEqual(['acme/web#2', 'acme/web#3'])
    await endTurn(h, { n: 1, number: 4, others: [row(2)], result: approve('acme/web#4') })
    expect(names()).toEqual(['web-4-review', 'web-1-review', 'web-2-review'])
    expect(h.state().queue.map(e => e.key)).toEqual(['acme/web#3'])
    const running = Object.values(h.state().prs).filter(p => p.round !== null)
    expect(running).toHaveLength(2)
  })

  it('a round whose session waits for the user does not use a slot', async () => {
    const h = make({ max: 1 })
    await ready(h, [pr(7), pr(8)])
    await review(h, KEY)
    await review(h, 'acme/web#8')
    expect(h.runner.session('acme/web#8')).toBe('queued')
    await h.rowsNow([row(1, PROMPT)])
    expect(h.pr('acme/web#8')?.round?.phase).toBe('running')
    expect(h.calls.starts).toHaveLength(2)
  })

  it('an untrusted clone waits as trust-needed and blocks nothing', async () => {
    const h = make({ max: 1 })
    await ready(h, [pr(7), pr(8, 'api')], ['api'])
    await review(h, KEY)
    expect(h.runner.session(KEY)).toBe('trust-needed')
    expect(h.calls.starts).toEqual([])
    await review(h, 'acme/api#8')
    expect(h.runner.session('acme/api#8')).toBe('reviewing')
    expect(h.calls.starts).toHaveLength(1)
    expect(h.calls.starts[0]?.cwd).toBe(worktreePath(h.clone('api'), 8))
    // The trust of web comes. The entry waits for a free slot.
    await h.trust(h.clone('web'), h.clone('api'))
    expect(h.runner.session(KEY)).toBe('queued')
    expect(h.calls.starts).toHaveLength(1)
  })

  it('a trust error at the start puts the entry back', async () => {
    const h = make()
    await ready(h, [pr(7)])
    // Time goes on during the start. The entry keeps the time of the click.
    h.fake.start = s => {
      vi.setSystemTime(T0.getTime() + 5000)
      return { message: 'Workspace not trusted.', name: s.name, ok: false, trust: true }
    }
    await review(h)
    expect(h.state().queue).toEqual([{ at: T0.getTime(), key: KEY, kind: 'review' }])
    expect(h.pr()?.round).toBeNull()
    expect(h.pr()?.lastError).toBeNull()
    expect(h.runner.session(KEY)).toBe('trust-needed')
    expect(h.runner.trust()).toEqual([{ repo: 'acme/web', waiting: 1 }])
    // Nothing tries again by itself.
    await h.tick(2 * 60_000)
    await h.poll(pollOf([pr(7)]))
    expect(h.calls.starts).toHaveLength(1)
    // The trust step of the user starts it again.
    h.fake.start = h.okStart
    await h.trust(h.clone('web'))
    expect(h.calls.starts).toHaveLength(2)
    expect(h.pr()?.round?.phase).toBe('running')
  })

  it('a second review of a queued key is refused', async () => {
    const h = make({ max: 1 })
    await ready(h, [pr(7), pr(8)])
    await review(h, KEY)
    await review(h, 'acme/web#8')
    await expect(h.runner.review('acme/web#8')).rejects.toThrow(REFUSED_NOT_REVIEWABLE)
    await expect(h.runner.review(KEY)).rejects.toThrow(REFUSED_NOT_REVIEWABLE)
    await expect(h.runner.review('acme/web#99')).rejects.toThrow(REFUSED_NOT_REVIEWABLE)
    expect(h.state().queue.map(e => e.key)).toEqual(['acme/web#8'])
  })

  it('a review request for a key that is queued adds no second entry', async () => {
    const h = make()
    await ready(h, [pr(7)], [])
    await Promise.all([h.runner.review(KEY), h.runner.review(KEY)])
    await h.runner.settled()
    expect(h.state().queue).toEqual([{ at: T0.getTime(), key: KEY, kind: 'review' }])
    await expect(h.runner.review(KEY)).rejects.toThrow(REFUSED_NOT_REVIEWABLE)
    expect(h.state().queue).toHaveLength(1)
  })

  it('cancel removes a queue entry and refuses a key with a running round', async () => {
    const h = make({ max: 1 })
    await ready(h, [pr(7), pr(8)])
    await review(h, KEY)
    await review(h, 'acme/web#8')
    const before = h.calls.changed
    await h.runner.cancel('acme/web#8')
    expect(h.state().queue).toEqual([])
    expect(h.runner.session('acme/web#8')).toBeNull()
    expect(h.calls.changed).toBeGreaterThan(before)
    await expect(h.runner.cancel(KEY)).rejects.toThrow(REFUSED_NOT_REVIEWABLE)
    expect(h.pr()?.round?.phase).toBe('running')
  })
})

describe('session(key)', () => {
  const queued: ReviewsState = {
    ...EMPTY_STATE,
    queue: [{ at: 1, key: KEY, kind: 'review' }],
    setUpAt: 1,
  }

  it('reviewing while a round runs', async () => {
    const h = make()
    await ready(h, [pr(7)])
    await review(h)
    expect(h.runner.session(KEY)).toBe('reviewing')
    expect(h.runner.busy()).toBe(true)
  })

  it('queued for a queue entry with no clone', async () => {
    const h = make({ state: queued })
    h.runner.start()
    await h.runner.settled()
    expect(h.runner.session(KEY)).toBe('queued')
  })

  it('queued for a queue entry with a trusted clone', async () => {
    const h = make({ state: queued })
    await h.preClone()
    await h.writeTrust([h.clone()])
    h.runner.start()
    await h.runner.settled()
    expect(h.runner.session(KEY)).toBe('queued')
  })

  it('trust-needed for a queue entry with a clone that is not trusted', async () => {
    const h = make({ state: queued })
    await h.preClone()
    h.runner.start()
    await h.runner.settled()
    expect(h.runner.session(KEY)).toBe('trust-needed')
  })

  it('null after a round, also while the review session is idle', async () => {
    const h = make()
    await ready(h, [pr(7)])
    await review(h)
    await endTurn(h, { result: APPROVE })
    expect(h.pr()?.round).toBeNull()
    expect(h.runner.session(KEY)).toBeNull()
    expect(h.runner.busy()).toBe(false)
    expect(h.runner.sessionOf(KEY)).toBe('sess-1')
    h.setRows([row(1, { state: 'parked', status: 'stopped' })])
    expect(h.runner.sessionOf(KEY)).toBeNull()
  })
})

describe('the review round', () => {
  it(
    'a valid result posts a pending review with the reviewed head and saves the ' +
      'recommendation',
    async () => {
      const h = make()
      await ready(h, [pr(7)])
      await review(h)
      const start = h.calls.starts[0]
      expect(start?.name).toBe('web-7-review')
      expect(start?.cwd).toBe(worktreePath(h.clone(), 7))
      expect(start?.args).toContain('--add-dir')
      expect(start?.args).not.toContain('--model')
      expect(start?.args.at(-1)).toBe(`/bifrost-review bifrost-input=${join(h.io(), 'input.json')}`)
      expect(h.pr()?.round).toMatchObject({
        headSha: HEAD,
        phase: 'running',
        sessionId: 'sess-1',
        shortId: short(1),
      })
      expect(h.pr()?.review).toEqual({
        name: 'web-7-review',
        sessionId: 'sess-1',
        shortId: short(1),
      })
      await h.tick(3000)
      const end = Date.now()
      await endTurn(h, { result: resultText() })
      const posts = h.posts()
      expect(posts).toHaveLength(1)
      expect(posts[0]?.args).toContain('repos/acme/web/pulls/7/reviews')
      expect(JSON.parse(posts[0]?.input ?? '')).toEqual({
        body: 'Looks fine overall.',
        comments: [{ body: 'Check this.', line: 2, path: 'src/a.ts', side: 'RIGHT' }],
        commit_id: HEAD,
      })
      const at = h.pr()?.recommendation?.at ?? 0
      expect(at).toBeGreaterThan(end)
      expect(h.pr()?.recommendation).toEqual({
        at,
        headSha: HEAD,
        reviewId: 'PRR_new',
        value: 'comment',
        why: 'One small point.',
      })
      expect(h.pr()?.lastReviewedCommit).toBe(HEAD)
      expect(h.pr()?.lastError).toBeNull()
      expect(h.pr()?.round).toBeNull()
      expect(h.state().drafts).toEqual([
        { at, body: 'Check this.', line: 2, path: 'src/a.ts', prKey: KEY, reviewId: 'PRR_new' },
        { at, body: 'Looks fine overall.', line: 0, path: '', prKey: KEY, reviewId: 'PRR_new' },
      ])
      expect(h.calls.polls).toBe(1)
      expect(h.calls.notices).toEqual([draftNotice({ number: 7, repo: 'web' }, 'comment')])
    },
  )

  it('a test home uses haiku and the test prefix', async () => {
    const h = make({ model: 'opus', testHome: true })
    await ready(h, [pr(7)])
    await review(h)
    const start = h.calls.starts[0]
    expect(start?.name).toBe(`${TEST_PREFIX}web-7-review`)
    const args = start?.args ?? []
    expect(args[args.indexOf('--model') + 1]).toBe('haiku')
    const other = make({ id: 'b', model: 'opus' })
    await ready(other, [pr(7)])
    await review(other)
    const otherArgs = other.calls.starts[0]?.args ?? []
    expect(otherArgs[otherArgs.indexOf('--model') + 1]).toBe('opus')
  })

  it('an Approve with no text saves the mark and posts nothing', async () => {
    const h = make()
    await ready(h, [pr(7)])
    await review(h)
    await endTurn(h, { result: APPROVE })
    expect(h.posts()).toEqual([])
    const contexts = h.calls.gh.filter(c => c.args.some(a => a.includes('query ReviewContext')))
    expect(contexts).toHaveLength(1)
    expect(h.pr()?.recommendation).toMatchObject({
      headSha: HEAD,
      reviewId: null,
      value: 'approve',
      why: 'One small point.',
    })
    expect(h.pr()?.lastReviewedCommit).toBe(HEAD)
    expect(h.state().drafts).toEqual([])
    expect(h.calls.notices).toEqual([reviewedNotice({ number: 7, repo: 'web' })])
  })

  it('a bad result file fails the round with the reason and posts nothing', async () => {
    const h = make()
    await ready(h, [pr(7)])
    await review(h)
    await endTurn(h, { result: resultText({}, 'acme/web#8') })
    expect(h.pr()?.lastError).toBe(reasonBadResult('the pr field is not this pull request'))
    expect(h.pr()?.round).toBeNull()
    expect(h.pr()?.recommendation).toBeNull()
    expect(h.pr()?.lastReviewedCommit).toBeNull()
    expect(h.posts()).toEqual([])
    expect(h.calls.notices).toEqual([])
    // A folder in place of the file is not a regular file.
    await review(h)
    await mkdir(join(h.io(), 'result.json'))
    await endTurn(h, { n: 2 })
    expect(h.pr()?.lastError).toBe(reasonBadResult('not a regular file'))
    expect(h.posts()).toEqual([])
  })

  it(
    'checks the result against the diff that Bifrost wrote, ' + 'not the files in the input folder',
    async () => {
      const h = make()
      await ready(h, [pr(7)])
      await review(h)
      // The session can write in its input folder.
      await writeFile(join(h.io(), 'full.diff'), OTHER_DIFF)
      await writeFile(join(h.io(), 'input.json'), JSON.stringify({ pr: { key: 'acme/web#8' } }))
      const evil = resultText({
        comments: [{ body: 'x', line: 2, path: 'src/evil.ts', side: 'RIGHT' }],
      })
      await endTurn(h, { result: evil })
      expect(h.pr()?.lastError).toBe(
        reasonBadResult('comment 1 is on a file that is not in the diff'),
      )
      expect(h.posts()).toEqual([])
    },
  )

  it('a session that ends with no result fails the round', async () => {
    const h = make()
    await ready(h, [pr(7)])
    await review(h)
    await endTurn(h)
    expect(h.pr()?.lastError).toBe(REASON_NO_RESULT)
    expect(h.pr()?.round).toBeNull()
    expect(h.posts()).toEqual([])
    // A session that never works ends after NO_START_MS.
    await review(h)
    await h.rowsNow([row(2, IDLE)])
    await h.tick(NO_START_MS - PASS_MS)
    expect(h.pr()?.round?.phase).toBe('running')
    await h.tick(2 * PASS_MS)
    expect(h.pr()?.round).toBeNull()
    expect(h.pr()?.lastError).toBe(REASON_NO_RESULT)
  })

  it('the round times out after 30 minutes and stops the session', async () => {
    const h = make()
    await ready(h, [pr(7)])
    await review(h)
    await h.rowsNow([row(1)])
    await h.writeResult(resultText())
    await h.tick(ROUND_LIMIT_MS - PASS_MS)
    expect(h.pr()?.round?.phase).toBe('running')
    await h.tick(2 * PASS_MS)
    expect(h.calls.stops).toEqual([short(1)])
    expect(h.pr()?.lastError).toBe(REASON_TIMEOUT)
    expect(h.pr()?.round).toBeNull()
    expect(h.posts()).toEqual([])
  })

  it('a session that goes during the round fails the round and posts nothing', async () => {
    const h = make()
    await ready(h, [pr(7)])
    await review(h)
    await h.rowsNow([row(1)])
    await h.writeResult(resultText())
    await h.rowsNow([])
    await h.tick(GONE_GRACE_MS - PASS_MS)
    expect(h.pr()?.round?.phase).toBe('running')
    await h.tick(2 * PASS_MS)
    expect(h.pr()?.lastError).toBe(REASON_STOPPED)
    expect(h.pr()?.round).toBeNull()
    expect(h.posts()).toEqual([])
  })

  it('a request that goes during the round stops it and posts nothing', async () => {
    const h = make({ max: 1 })
    await ready(h, [pr(7), pr(8)])
    await review(h, KEY)
    await review(h, 'acme/web#8')
    await h.rowsNow([row(1)])
    await h.writeResult(resultText())
    // A partial answer or a long list does nothing.
    await h.poll(pollOf([], [], { errors: ['x'] }))
    await h.poll(pollOf([], [], { toReviewHasMore: true }))
    expect(h.pr()?.round?.phase).toBe('running')
    expect(h.state().queue).toHaveLength(1)
    // A complete answer without the two requests.
    await h.poll(pollOf([]))
    expect(h.calls.removes).toEqual([
      { name: 'web-7-review', sessionId: 'sess-1', shortId: short(1) },
    ])
    expect([...h.calls.worktreesRemoved].sort()).toEqual([7, 8])
    expect(h.state().queue).toEqual([])
    for (const key of [KEY, 'acme/web#8']) {
      expect(h.pr(key)).toMatchObject({
        actedAt: null,
        lastError: null,
        recommendation: null,
        review: null,
        round: null,
      })
    }
    await h.rowsNow([row(1, IDLE)])
    await h.tick(END_SETTLE_MS + PASS_MS)
    expect(h.posts()).toEqual([])
    expect(h.calls.starts).toHaveLength(1)
    expect(h.pr()?.lastError).toBeNull()
  })

  it('a request that goes while the round prepares removes the new session', async () => {
    const h = make()
    await ready(h, [pr(7)])
    let release = (): void => {}
    const gate = new Promise<void>(resolve => {
      release = resolve
    })
    let reached = (): void => {}
    const atStart = new Promise<void>(resolve => {
      reached = resolve
    })
    // The start waits until the request is gone.
    h.fake.start = async s => {
      reached()
      await gate
      return h.okStart(s)
    }
    await h.runner.review(KEY)
    await atStart
    h.runner.afterPoll(pollOf([]))
    release()
    await h.runner.settled()
    expect(h.calls.removes).toEqual([
      { name: 'web-7-review', sessionId: 'sess-1', shortId: short(1) },
    ])
    expect(h.calls.worktreesRemoved).toContain(7)
    expect(h.pr()).toMatchObject({ lastError: null, review: null, round: null })
    expect(h.state().queue).toEqual([])
  })

  it('a push during the round keeps the reviewed commit', async () => {
    const h = make()
    await ready(h, [pr(7)])
    await review(h)
    h.ctx.head = NEW_HEAD
    h.fake.head = NEW_HEAD
    await endTurn(h, { result: resultText() })
    const posts = h.posts()
    expect(posts).toHaveLength(1)
    expect(JSON.parse(posts[0]?.input ?? '').commit_id).toBe(HEAD)
    expect(h.pr()?.recommendation?.headSha).toBe(HEAD)
    expect(h.pr()?.lastReviewedCommit).toBe(HEAD)
  })

  it('a round ends by the 5 second timer when no row changes', async () => {
    const h = make()
    await ready(h, [pr(7)])
    await review(h)
    await h.rowsNow([row(1)])
    await h.writeResult(resultText())
    await h.rowsNow([row(1, IDLE)])
    const onRows = vi.spyOn(h.runner, 'onRows')
    await h.tick(END_SETTLE_MS + PASS_MS)
    expect(onRows).not.toHaveBeenCalled()
    expect(h.posts()).toHaveLength(1)
    expect(h.pr()?.round).toBeNull()
  })

  it('recovers each phase after a restart', async () => {
    const now = T0.getTime()
    const round = (over: Partial<ActiveRound>): ActiveRound => ({
      at: 100,
      headSha: null,
      phase: 'preparing',
      sessionId: null,
      shortId: null,
      startedAt: now - 60_000,
      stoppedByUser: false,
      ...over,
    })
    const state: ReviewsState = {
      ...EMPTY_STATE,
      prs: {
        'acme/web#1': { ...emptyPrState(), round: round({ at: 100 }) },
        'acme/web#2': {
          ...emptyPrState(),
          review: { name: 'web-2-review', sessionId: 'sess-10', shortId: short(10) },
          round: round({
            at: 101,
            baseSha: BASE,
            headSha: HEAD,
            phase: 'running',
            sessionId: 'sess-10',
            shortId: short(10),
          }),
        },
        'acme/web#3': {
          ...emptyPrState(),
          round: round({ at: 102, headSha: HEAD, phase: 'posting' }),
        },
      },
      setUpAt: 1,
    }
    const h = make({ state })
    await h.preClone()
    await h.writeTrust([h.clone()])
    // The input folder of PR 2 holds files that the session changed.
    await mkdir(h.io(2), { recursive: true })
    await writeFile(join(h.io(2), 'full.diff'), OTHER_DIFF)
    await writeFile(join(h.io(2), 'input.json'), '{"pr":{"key":"acme/web#9"}}')
    await h.writeResult(resultText({}, 'acme/web#2'), 2)
    h.runner.start()
    await h.runner.settled()
    expect(h.state().queue).toEqual([{ at: 100, key: 'acme/web#1', kind: 'review' }])
    expect(h.pr('acme/web#1')?.round).toBeNull()
    expect(h.pr('acme/web#3')?.round).toBeNull()
    expect(h.pr('acme/web#3')?.lastError).toBe(REASON_CLOSED_WHILE_POSTING)
    expect(h.pr('acme/web#2')?.round?.phase).toBe('running')
    expect(h.posts()).toEqual([])
    // The first poll lets the queue start.
    await h.poll(pollOf([pr(1), pr(2), pr(3)]))
    expect(h.pr('acme/web#1')?.round?.phase).toBe('running')
    // The running round waits for the same session, then ends.
    await h.rowsNow([row(10, IDLE), row(1)])
    await h.tick(END_SETTLE_MS + PASS_MS)
    expect(h.pr('acme/web#2')?.round).toBeNull()
    expect(h.pr('acme/web#2')?.lastError).toBeNull()
    const posts = h.posts()
    expect(posts).toHaveLength(1)
    expect(posts[0]?.args).toContain('repos/acme/web/pulls/2/reviews')
    expect(JSON.parse(posts[0]?.input ?? '').commit_id).toBe(HEAD)
    // Bifrost made the diff again from its clone, in a folder of its own, and deleted it.
    const rebuilt = h.calls.diffs.filter(d => !isInside(h.io(1), d.file))
    expect(rebuilt).toHaveLength(1)
    expect(rebuilt[0]).toMatchObject({ from: BASE, mode: 'merge-base', to: HEAD })
    expect(isInside(join(h.home, 'reviews'), rebuilt[0]?.file ?? '')).toBe(true)
    expect(isInside(join(h.home, 'reviews', 'repos'), rebuilt[0]?.file ?? '')).toBe(false)
    expect(existsSync(rebuilt[0]?.file ?? '')).toBe(false)
    const left = await readdir(join(h.home, 'reviews'))
    expect(left).toEqual(['repos'])
  })

  it('cleans the worktree after each round and logs the count', async () => {
    const h = make()
    await ready(h, [pr(7)])
    h.fake.changed = 3
    await review(h)
    await endTurn(h, { result: APPROVE })
    expect(h.calls.cleaned).toEqual([7])
    expect(h.calls.logs).toContain('The review session changed 3 files in its worktree.')
    // A failed round cleans too. No change gives no log line.
    h.fake.changed = 0
    const lines = h.calls.logs.length
    await review(h)
    await endTurn(h, { n: 2 })
    expect(h.calls.cleaned).toEqual([7, 7])
    expect(h.calls.logs).toHaveLength(lines)
  })

  it('stops a review session that is idle for 10 minutes', async () => {
    const h = make()
    await ready(h, [pr(7)])
    await review(h)
    await endTurn(h, { result: APPROVE })
    const since = Date.now()
    await h.rowsNow([row(1, { ...IDLE, lastActivity: since })])
    await h.tick(IDLE_STOP_MS - 1000)
    await h.rowsNow([row(1, { ...IDLE, lastActivity: since })])
    expect(h.calls.stops).toEqual([])
    await h.tick(1000)
    await h.rowsNow([row(1, { ...IDLE, lastActivity: since })])
    expect(h.calls.stops).toEqual([short(1)])
    await h.rowsNow([row(1, { ...IDLE, lastActivity: since })])
    expect(h.calls.stops).toEqual([short(1)])
    // A session with a prompt is not idle.
    const p = make({ id: 'b' })
    await ready(p, [pr(7)])
    await review(p)
    await endTurn(p, { result: APPROVE })
    await p.tick(IDLE_STOP_MS)
    await p.rowsNow([row(1, { ...PROMPT, lastActivity: T0.getTime() })])
    expect(p.calls.stops).toEqual([])
  })

  it(
    'stopSession during a round fails it with REASON_STOPPED, ' + 'and after a round only stops',
    async () => {
      const h = make()
      await ready(h, [pr(7)])
      await review(h)
      await h.rowsNow([row(1)])
      await h.runner.stopSession(KEY)
      expect(h.calls.stops).toEqual([short(1)])
      expect(h.pr()?.round?.stoppedByUser).toBe(true)
      await h.writeResult(resultText())
      await h.rowsNow([row(1, { state: 'parked', status: 'stopped' })])
      await h.tick(END_SETTLE_MS + PASS_MS)
      expect(h.pr()?.lastError).toBe(REASON_STOPPED)
      expect(h.pr()?.round).toBeNull()
      expect(h.posts()).toEqual([])
      // A stop before the session wrote a result also gives REASON_STOPPED.
      await review(h)
      await h.rowsNow([row(2)])
      await h.runner.stopSession(KEY)
      await h.rowsNow([row(2, { state: 'parked', status: 'stopped' })])
      await h.tick(END_SETTLE_MS + PASS_MS)
      expect(h.pr()?.lastError).toBe(REASON_STOPPED)
      expect(h.calls.stops).toEqual([short(1), short(2)])
      // After a round.
      const a = make({ id: 'b' })
      await ready(a, [pr(7)])
      await review(a)
      await endTurn(a, { result: APPROVE })
      const before = structuredClone(a.pr())
      await a.runner.stopSession(KEY)
      expect(a.calls.stops).toEqual([short(1)])
      expect(a.pr()).toEqual(before)
    },
  )

  it('a PR that is closed fails the round with REASON_PR_CLOSED', async () => {
    const h = make()
    await ready(h, [pr(7)])
    h.ctx.state = 'CLOSED'
    await review(h)
    expect(h.pr()?.lastError).toBe(REASON_PR_CLOSED)
    expect(h.pr()?.round).toBeNull()
    expect(h.calls.starts).toEqual([])
  })

  it('a head that changed while preparing fails with REASON_PR_CHANGED', async () => {
    const h = make()
    await ready(h, [pr(7)])
    h.fake.head = NEW_HEAD
    await review(h)
    expect(h.pr()?.lastError).toBe(REASON_PR_CHANGED)
    expect(h.pr()?.round).toBeNull()
    expect(h.calls.starts).toEqual([])
  })

  it('a pending review made by the user during the round gets the comments', async () => {
    const h = make()
    await ready(h, [pr(7)])
    await review(h)
    h.ctx.pending = { body: 'My notes.', commit: HEAD, id: 'PRR_user' }
    await endTurn(h, { result: resultText() })
    expect(h.posts()).toEqual([])
    const fields = h.calls.gh.flatMap(c => c.args)
    expect(fields.some(a => a.startsWith('query=mutation AddThread'))).toBe(true)
    expect(fields).toContain('review=PRR_user')
    expect(fields).toContain('body=My notes.\n\nLooks fine overall.')
    expect(h.pr()?.recommendation?.reviewId).toBe('PRR_user')
    expect(h.state().drafts.map(d => d.reviewId)).toEqual(['PRR_user', 'PRR_user'])
  })

  it('a failed post fails the round, and Bifrost never posts again by itself', async () => {
    const h = make()
    await ready(h, [pr(7)])
    await review(h)
    h.fake.post = { code: 1, stderr: 'gh: Unprocessable Entity (HTTP 422)', stdout: '' }
    await endTurn(h, { result: resultText() })
    expect(h.pr()?.lastError).toBe(reasonPostFailed('gh: Unprocessable Entity (HTTP 422)'))
    expect(h.pr()?.recommendation).toBeNull()
    // A post with an unknown result shows its message as it is.
    h.fake.post = { code: 1, stderr: '', stdout: '', timedOut: true }
    await review(h)
    await endTurn(h, { n: 2, result: resultText() })
    expect(h.pr()?.lastError).toBe(REASON_POST_TIMEOUT)
    await h.tick(10 * 60_000)
    await h.poll(pollOf([pr(7)]))
    await h.rowsNow([row(2, IDLE)])
    expect(h.posts()).toHaveLength(2)
  })

  it(
    'a start with no row in 30 seconds fails the round and stops the session when its ' +
      'row shows',
    async () => {
      const h = make()
      await ready(h, [pr(7)])
      const message = 'The session 0000000f did not start in 30 seconds.'
      h.fake.start = s => ({ message, name: s.name, ok: false, trust: false })
      await review(h)
      expect(h.pr()?.lastError).toBe(message)
      expect(h.pr()?.round).toBeNull()
      expect(h.pr()?.review).toEqual({ name: 'web-7-review', sessionId: '' })
      expect(h.runner.session(KEY)).toBeNull()
      await h.rowsNow([row(15, { claudeName: 'web-7-review', name: 'web-7-review' })])
      expect(h.calls.stops).toEqual([short(15)])
      expect(h.pr()?.review).toEqual({
        name: 'web-7-review',
        sessionId: 'sess-15',
        shortId: short(15),
      })
      await h.rowsNow([row(15, { claudeName: 'web-7-review', name: 'web-7-review' })])
      expect(h.calls.stops).toEqual([short(15)])
    },
  )

  it(
    'removeClones refuses while a round runs, ' + 'and clears the queue, repos and setUpAt',
    async () => {
      const state: ReviewsState = {
        ...EMPTY_STATE,
        repos: { 'acme/api': { trustNotifiedAt: 5 } },
      }
      const h = make({ max: 1, state })
      await ready(h, [pr(7), pr(8, 'api')])
      expect(h.state().setUpAt).toBe(T0.getTime())
      await review(h, KEY)
      await review(h, 'acme/api#8')
      expect(h.runner.session('acme/api#8')).toBe('trust-needed')
      await expect(h.runner.removeClones()).rejects.toThrow(REFUSED_REVIEWS_BUSY)
      expect(h.calls.removeAll).toBe(0)
      await endTurn(h, { result: APPROVE })
      expect(h.pr()?.recommendation?.value).toBe('approve')
      await h.runner.removeClones()
      expect(h.calls.removes).toEqual([
        { name: 'web-7-review', sessionId: 'sess-1', shortId: short(1) },
      ])
      expect(h.calls.removeAll).toBe(1)
      expect(h.state().queue).toEqual([])
      expect(h.state().repos).toEqual({})
      expect(h.state().setUpAt).toBeNull()
      expect(h.pr()).toMatchObject({
        actedAt: null,
        lastError: null,
        recommendation: null,
        review: null,
        round: null,
      })
      expect(h.runner.trust()).toEqual([])
      // The next good poll runs the set-up again.
      await h.poll(pollOf([pr(7), pr(8, 'api')]))
      expect(h.calls.clones).toEqual(['acme/web', 'acme/api'])
      expect(h.state().setUpAt).not.toBeNull()
      expect(h.calls.notices.filter(n => n.title === 'Trust needed')).toEqual([])
    },
  )
})
