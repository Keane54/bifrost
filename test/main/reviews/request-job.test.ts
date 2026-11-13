// The request round (Task 7): the trigger, the end, the posts, Needs you, the answers, the drop
// and the restart recovery. The runner runs both jobs on fakes: a fake GitHub that answers by
// the name of the operation, a fake pusher, a fake repository store, fake sessions and an
// in-memory store. No test calls the real gh, git, claude or the network.

import { mkdir, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ExecResult } from '../../../src/main/claude/cli'
import type { Gh } from '../../../src/main/reviews/gh'
import type { PollData, PrData, ReviewState } from '../../../src/main/reviews/pr-data'
import { clonePath, ioPath, worktreePath } from '../../../src/main/reviews/repo-paths'
import { CommitError, type RepoStore, type UnsafeRule } from '../../../src/main/reviews/repo-store'
import type { RequestInput } from '../../../src/main/reviews/request-input'
import { createRequestJob } from '../../../src/main/reviews/request-job'
import type { FixPusher, PushOutcome } from '../../../src/main/reviews/request-push'
import { requestPrompt, requestSessionArgs } from '../../../src/main/reviews/request-session'
import { createReviewJob } from '../../../src/main/reviews/review-job'
import type { ReviewSessions, StartOutcome } from '../../../src/main/reviews/review-session'
import {
  needsYouNotice,
  REASON_COMMIT_ERROR,
  REASON_FIX_BLOCKED,
  REASON_FIX_END_FAILED,
  REASON_FIX_NO_RESULT,
  REASON_FIX_START_FAILED,
  REASON_FIX_STOPPED,
  REASON_FIX_TIMEOUT,
  REASON_FORK,
  REASON_POSTS_READ_FAILED,
  REASON_PR_READ_FAILED,
  REASON_PUSH_CONFLICT,
  REASON_PUSH_GIT_FAILED,
  REASON_READ_AFTER_POSTS,
  REASON_REPLIES_WAITING,
  REASON_SIGNED_EXECUTABLE,
  REASON_TOO_MANY_COMMENTS,
  REASON_USER_SANDBOX,
  REASON_WRITE_FAILED,
  reasonCommitFailed,
  reasonFixBadResult,
  reasonPostsStopped,
  reasonPushFailed,
  reasonUnsafeChange,
  reasonUserStoppedPosts,
} from '../../../src/main/reviews/round-text'
import {
  createReviewRunner,
  END_SETTLE_MS,
  PASS_MS,
  REFUSED_BAD_ANSWER,
  REFUSED_NOT_HANDLEABLE,
  REFUSED_UNKNOWN_QUESTION,
  type ReviewRunner,
  ROUND_LIMIT_MS,
} from '../../../src/main/reviews/rounds'
import {
  EMPTY_STATE,
  emptyPrState,
  MAX_ANSWER,
  MAX_AUTHOR,
  MAX_QUOTE,
  MAX_ROUND_ITEMS,
  MAX_WHERE,
  type Outbox,
  type Post,
  type PrState,
  type Question,
  type ReviewsState,
} from '../../../src/main/reviews/state'
import type { ReviewsStateStore } from '../../../src/main/reviews/state-store'
import type { RequestNotice } from '../../../src/main/reviews/watcher'
import type { ModelChoice } from '../../../src/shared/new-session'
import { COPILOT_LOGIN } from '../../../src/shared/reviews'
import type { SessionRow } from '../../../src/shared/types'

const T0 = new Date('2026-11-12T10:00:00Z')
const VIEWER = 'dana'
const KEY = 'acme/api#9'
// The round head, the merge base, the fix commit, an earlier commit of the PR, a commit that is
// not in the PR, and the tip of the base branch.
const HEAD = 'a'.repeat(40)
const BASE = 'b'.repeat(40)
const FIX = 'c'.repeat(40)
const BY = 'e'.repeat(40)
const OUT = 'f'.repeat(40)
const MAIN_TIP = '9'.repeat(40)
// The commit that GitHub makes for a signed fix.
const SIGNED = '7'.repeat(40)
// The history: BASE <- BY <- HEAD <- FIX.
const PARENT: Record<string, string> = { [BY]: BASE, [FIX]: HEAD, [HEAD]: BY }
const FIX_FROM = T0.getTime() - 60 * 60_000
const ASKED = T0.getTime() - 10 * 60_000
// The zero-width space that defuses a mention.
const Z = '\u200b'

const short = (n: number): string => n.toString(16).padStart(8, '0')

interface User {
  login: string
  bot?: boolean
  association?: string
}
const RAVI: User = { association: 'MEMBER', login: 'ravi' }
const MIA: User = { association: 'MEMBER', login: 'mia' }
const ME: User = { association: 'OWNER', login: VIEWER }
const COPILOT: User = { association: 'NONE', bot: true, login: COPILOT_LOGIN }
const EVE: User = { association: 'NONE', login: 'eve' }

interface Note {
  url?: string
  id: string
  by: User
  body: string
  at: number
}
interface Thread {
  id: string
  resolved: boolean
  path: string
  line: number | null
  review: string | null
  notes: Note[]
}
interface Review {
  id: string
  by: User
  state: ReviewState
  body: string
  at: number
}
// The PR on the fake GitHub. The writes change it.
interface Hub {
  state: 'OPEN' | 'CLOSED' | 'MERGED'
  author: string
  fork: boolean
  updatedAt: number
  threads: Thread[]
  comments: Note[]
  reviews: Review[]
  decisions: { login: string; userId: string; state: ReviewState }[]
  requested: string[]
  pending: boolean
  // True when GitHub has more threads than the read gives.
  truncated?: boolean
}

const note = (id: string, by: User = RAVI, at = ASKED, body = `Please look at ${id}.`): Note => ({
  at,
  body,
  by,
  id,
})

function thread(id: string, by: User = RAVI, at = ASKED, over: Partial<Thread> = {}): Thread {
  return {
    id,
    line: 3,
    notes: [note(`${id}_c1`, by, at, `Please fix ${id}.`)],
    path: 'src/a.ts',
    resolved: false,
    review: `PRR_${id}`,
    ...over,
  }
}

function hubOf(over: Partial<Hub> = {}): Hub {
  return {
    author: VIEWER,
    comments: [],
    decisions: [],
    fork: false,
    pending: false,
    requested: [],
    reviews: [],
    state: 'OPEN',
    threads: [thread('PRRT_1')],
    updatedAt: ASKED,
    ...over,
  }
}

const iso = (t: number): string => new Date(t).toISOString()
const ok = (data: unknown): ExecResult => ({ code: 0, stderr: '', stdout: JSON.stringify(data) })
const page = (nodes: unknown[]) => ({ nodes, pageInfo: { endCursor: null, hasNextPage: false } })
// A page that says GitHub has more items, but gives no cursor. The read counts the list as cut.
const cut = (more: boolean, nodes: unknown[]) => ({
  nodes,
  pageInfo: { endCursor: null, hasNextPage: more },
})
const answerPr = (pullRequest: unknown): ExecResult => ok({ data: { repository: { pullRequest } } })
const authorNode = (u: User) => ({
  author: { __typename: u.bot ? 'Bot' : 'User', login: u.login },
  authorAssociation: u.association ?? 'NONE',
})
const noteNode = (n: Note, review: string | null = null) => ({
  ...authorNode(n.by),
  body: n.body,
  createdAt: iso(n.at),
  databaseId: 1,
  diffHunk: '@@ -1,3 +1,4 @@',
  id: n.id,
  pullRequestReview: review === null ? null : { id: review },
  url: n.url ?? `https://github.com/acme/api/pull/9#note-${n.id}`,
})

function contextNode(hub: Hub) {
  return {
    author: { login: hub.author },
    baseRefName: 'main',
    baseRefOid: MAIN_TIP,
    body: 'The body.',
    headRefName: 'feature',
    headRefOid: HEAD,
    id: 'PR_9',
    isCrossRepository: hub.fork,
    latestOpinionatedReviews: {
      nodes: hub.decisions.map(d => ({
        author: { __typename: 'User', id: d.userId, login: d.login },
        state: d.state,
      })),
      pageInfo: { hasNextPage: false },
    },
    pending: { nodes: hub.pending ? [{ viewerDidAuthor: true }] : [] },
    repository: { defaultBranchRef: { name: 'main' } },
    reviewRequests: {
      nodes: hub.requested.map(login => ({ requestedReviewer: { __typename: 'User', login } })),
      pageInfo: { hasNextPage: false },
    },
    reviews: page(
      hub.reviews.map(r => ({
        ...authorNode(r.by),
        body: r.body,
        commit: { oid: HEAD },
        databaseId: 2,
        id: r.id,
        state: r.state,
        submittedAt: iso(r.at),
        url: `https://github.com/acme/api/pull/9#review-${r.id}`,
      })),
    ),
    state: hub.state,
    title: 'Add the rate limit',
    updatedAt: iso(hub.updatedAt),
    url: 'https://github.com/acme/api/pull/9',
  }
}

const threadsNode = (hub: Hub) => ({
  reviewThreads: cut(
    hub.truncated === true,
    hub.threads.map(t => ({
      comments: page(t.notes.map(n => noteNode(n, t.review))),
      id: t.id,
      isOutdated: false,
      isResolved: t.resolved,
      line: t.line,
      path: t.path,
      viewerCanReply: true,
    })),
  ),
})

const asComment = (n: Note) => ({
  author: { association: n.by.association ?? 'NONE', bot: n.by.bot === true, login: n.by.login },
  body: n.body,
  createdAt: n.at,
  databaseId: 1,
  id: n.id,
})

// The PR as the poll gives it. The poll lists are the same as the full lists here.
function polled(hub: Hub, over: Partial<PrData> = {}): PrData {
  return {
    additions: 1,
    approvals: 0,
    author: hub.author,
    baseRef: 'main',
    ci: null,
    comments: hub.comments.map(asComment),
    createdAt: 1,
    decisions: [],
    deletions: 1,
    failedChecks: 0,
    headRef: 'feature',
    headSha: HEAD,
    isCrossRepository: hub.fork,
    isDraft: false,
    key: KEY,
    number: 9,
    owner: 'acme',
    repo: 'api',
    requestedAt: 1,
    requestedTeams: [],
    requestedUsers: [...hub.requested],
    reviewDecision: null,
    reviews: hub.reviews.map(r => ({
      author: asComment(note('x', r.by)).author,
      body: r.body,
      commit: HEAD,
      databaseId: 2,
      id: r.id,
      state: r.state,
      submittedAt: r.at,
    })),
    threads: hub.threads.map(t => ({
      comments: t.notes.map(asComment),
      id: t.id,
      isResolved: t.resolved,
      line: t.line,
      path: t.path,
      reviewId: t.review,
    })),
    title: 'Add the rate limit',
    truncatedChecks: false,
    truncatedComments: false,
    truncatedReviews: false,
    truncatedThreads: false,
    updatedAt: hub.updatedAt,
    url: 'https://github.com/acme/api/pull/9',
    viewerPendingReviewId: null,
    viewerReviews: [],
    ...over,
  }
}

// A To review PR of another person. Only the review job uses it.
function toReview(number: number): PrData {
  return {
    ...polled(hubOf({ author: 'alice', threads: [] })),
    key: `acme/web#${number}`,
    number,
    repo: 'web',
    requestedUsers: [VIEWER],
    url: `https://github.com/acme/web/pull/${number}`,
  }
}

function pollOf(mine: PrData[], over: Partial<PollData> = {}): PollData {
  return {
    errors: [],
    mine,
    mineHasMore: false,
    rateLimit: null,
    toReview: [],
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

// failIf: the first save whose new state matches fails, and the state stays.
interface StoreHooks {
  failIf: ((next: ReviewsState) => boolean) | null
}

function memoryStore(initial: ReviewsState, hooks: StoreHooks): ReviewsStateStore {
  let current = structuredClone(initial)
  let queue: Promise<unknown> = Promise.resolve()
  return {
    change(fn) {
      const run = queue.then(() => {
        const next = fn(current)
        if (hooks.failIf?.(next)) {
          hooks.failIf = null
          throw new Error('the disk is full')
        }
        current = next
        return current
      })
      queue = run.catch(() => {})
      return run
    },
    get: () => current,
  }
}

type Op =
  | 'RequestContext'
  | 'RequestThreads'
  | 'RequestComments'
  | 'ThreadComments'
  | 'ReplyToThread'
  | 'ResolveThread'
  | 'CommentOnPr'
  | 'RequestReviewer'
const WRITES: readonly Op[] = ['ReplyToThread', 'ResolveThread', 'CommentOnPr', 'RequestReviewer']

interface Write {
  op: Op
  vars: Record<string, string>
}

// The -f and -F fields of one gh call.
function varsOf(args: string[]): Record<string, string> {
  const out: Record<string, string> = {}
  for (let i = 0; i < args.length; i++) {
    if (args[i] !== '-f' && args[i] !== '-F') continue
    const field = args[i + 1] ?? ''
    const at = field.indexOf('=')
    out[field.slice(0, at)] = field.slice(at + 1)
  }
  return out
}

// A promise that the test opens, and a promise that resolves when the code reaches the gate.
function gate(): { wait: Promise<void>; open(): void; reach(): void; reached: Promise<void> } {
  let open = (): void => {}
  let reach = (): void => {}
  const wait = new Promise<void>(resolve => {
    open = resolve
  })
  const reached = new Promise<void>(resolve => {
    reach = resolve
  })
  return { open, reach, reached, wait }
}

const DIFF = 'diff --git a/src/a.ts b/src/a.ts\n--- a/src/a.ts\n+++ b/src/a.ts\n@@ -1 +1 @@\n'

let dir: string

interface Options {
  state?: Partial<ReviewsState>
  hub?: Hub
  autoFix?: boolean
  max?: number
  model?: ModelChoice
  testHome?: boolean
  // Sign commits through GitHub.
  signed?: boolean
  // The folder of this harness. Two harnesses in one test share the skills folder only.
  id?: string
}

function make(o: Options = {}) {
  const base = join(dir, o.id ?? 'a')
  const home = join(base, 'home')
  const claudeJson = join(base, 'claude.json')
  const claudeSettings = join(base, 'settings.json')
  const skillsDir = join(dir, 'skills')
  const hooks: StoreHooks = { failIf: null }
  const store = memoryStore(
    { ...EMPTY_STATE, fixFrom: FIX_FROM, setUpAt: 1, turnedOnAt: FIX_FROM - 3_600_000, ...o.state },
    hooks,
  )
  const hub = o.hub ?? hubOf()
  const settings = {
    reviewsAutoFix: o.autoFix ?? true,
    reviewsIgnore: [] as string[],
    reviewsMaxSessions: o.max ?? 3,
    reviewsRequestModel: o.model ?? ('opus' as ModelChoice),
    reviewsReviewModel: '' as ModelChoice,
    reviewsSignedCommits: o.signed ?? false,
  }
  const calls = {
    autoFixOff: 0,
    changed: 0,
    changedPaths: 0,
    cleaned: [] as { number: number; head: string }[],
    commits: [] as { number: number; head: string; paths: string[]; message: string }[],
    events: [] as string[],
    fetches: [] as unknown[],
    gh: [] as string[],
    logs: [] as string[],
    notices: [] as RequestNotice[],
    polls: 0,
    pushes: [] as Parameters<FixPusher['push']>[0][],
    removeAll: 0,
    removes: [] as { shortId: string; sessionId: string; name: string }[],
    signedPushes: [] as Parameters<FixPusher['push']>[0][],
    starts: [] as { cwd: string; args: string[]; name: string }[],
    stops: [] as string[],
    worktrees: [] as number[],
    worktreesRemoved: [] as number[],
    writes: [] as Write[],
  }
  const cloned = new Set<string>()
  let started = 0
  const okStart = (s: { name: string }): StartOutcome => {
    started++
    return { name: s.name, ok: true, sessionId: `sess-${started}`, shortId: short(started) }
  }
  const fake = {
    changed: ['src/a.ts'] as string[],
    cloneGate: null as Promise<void> | null,
    commitError: null as Error | null,
    commitRule: null as UnsafeRule | null,
    // True when the read of the PR context fails. A function decides at each read.
    contextFails: false as boolean | (() => boolean),
    // A write for which hold gives a promise records its change, then waits for the promise.
    hold: (_w: Write): Promise<void> | null => null,
    push: (_o: Parameters<FixPusher['push']>[0]): PushOutcome => ({
      already: false,
      merged: false,
      ok: true,
      sha: FIX,
    }),
    signedPush: (_o: Parameters<FixPusher['push']>[0]): PushOutcome => ({
      already: false,
      merged: false,
      ok: true,
      sha: SIGNED,
    }),
    start: okStart as (s: { name: string }) => StartOutcome,
    // The answer of a write that fails, or undefined for the normal answer.
    writeFails: (_w: Write): ExecResult | undefined => undefined,
  }
  let rows: SessionRow[] = []
  let last: PollData | null = null

  const isAncestor = (a: string, b: string): boolean => {
    for (let at: string | undefined = b; at !== undefined; at = PARENT[at]) {
      if (at === a) return true
    }
    return false
  }

  const repos: RepoStore = {
    async changedPaths() {
      calls.changedPaths++
      return [...fake.changed]
    },
    async checkAndClean(_clone, number, head) {
      calls.cleaned.push({ head, number })
      return { changed: 0 }
    },
    cloneOf(owner, repo) {
      const path = clonePath(home, owner, repo)
      return cloned.has(path) ? path : null
    },
    async commitFix(_clone, number, c) {
      calls.commits.push({ head: c.head, message: c.message, number, paths: [...c.paths] })
      if (fake.commitError) throw fake.commitError
      if (fake.commitRule) return { ok: false, rule: fake.commitRule }
      return { ok: true, sha: FIX }
    },
    async ensureClone(owner, repo) {
      if (fake.cloneGate) await fake.cloneGate
      const path = clonePath(home, owner, repo)
      await mkdir(path, { recursive: true })
      cloned.add(path)
      return path
    },
    async fetchPr(_clone, _number, _baseRef, opts) {
      calls.fetches.push(opts)
      return { base: MAIN_TIP, head: HEAD, mergeBase: BASE }
    },
    hasCommit: async () => true,
    isAncestor: async (_clone, a, b) => isAncestor(a, b),
    async prepareWorktree(clone, number) {
      calls.worktrees.push(number)
      const path = worktreePath(clone, number)
      await mkdir(path, { recursive: true })
      return path
    },
    async removeAll() {
      calls.removeAll++
      cloned.clear()
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
    async writeDiff(_clone, _from, _to, file) {
      await writeFile(file, DIFF)
    },
  }

  let writeCount = 0
  const write = async (w: Write): Promise<ExecResult> => {
    calls.writes.push(w)
    const failed = fake.writeFails(w)
    if (failed !== undefined) return failed
    const n = ++writeCount
    const at = Date.now()
    let out: ExecResult
    if (w.op === 'ReplyToThread') {
      const id = `PRRC_r${n}`
      hub.threads.find(t => t.id === w.vars.thread)?.notes.push(note(id, ME, at, w.vars.body))
      out = ok({
        data: {
          addPullRequestReviewThreadReply: {
            comment: { createdAt: iso(at), id, state: 'SUBMITTED' },
          },
        },
      })
    } else if (w.op === 'ResolveThread') {
      const t = hub.threads.find(x => x.id === w.vars.thread)
      if (t) t.resolved = true
      out = ok({
        data: { resolveReviewThread: { thread: { id: w.vars.thread, isResolved: true } } },
      })
    } else if (w.op === 'CommentOnPr') {
      const id = `IC_r${n}`
      hub.comments.push(note(id, ME, at, w.vars.body))
      out = ok({ data: { addComment: { commentEdge: { node: { createdAt: iso(at), id } } } } })
    } else {
      const login = hub.decisions.find(d => d.userId === w.vars.user)?.login
      if (login) hub.requested.push(login)
      out = ok({ data: { requestReviews: { pullRequest: { id: 'PR_9' } } } })
    }
    const wait = fake.hold(w)
    if (wait !== null) await wait
    return out
  }

  const gh: Gh = {
    async run(args) {
      const vars = varsOf(args)
      const op = /^(?:query|mutation) (\w+)/.exec(vars.query ?? '')?.[1] as Op | undefined
      calls.gh.push(op ?? 'unknown')
      if (op !== undefined && WRITES.includes(op)) {
        const { query: _query, ...rest } = vars
        return write({ op, vars: rest })
      }
      const contextFails =
        typeof fake.contextFails === 'function' ? fake.contextFails() : fake.contextFails
      if (op === 'RequestContext' && contextFails) {
        return { code: 1, stderr: 'gh: Server Error (HTTP 502)', stdout: '' }
      }
      if (op === 'RequestContext') return answerPr(contextNode(hub))
      if (op === 'RequestThreads') return answerPr(threadsNode(hub))
      if (op === 'RequestComments')
        return answerPr({ comments: page(hub.comments.map(n => noteNode(n))) })
      return { code: 1, stderr: 'unexpected call', stdout: '' }
    },
  }

  const pusher: FixPusher = {
    async push(p) {
      calls.pushes.push(p)
      return fake.push(p)
    },
  }
  const signedPusher: FixPusher = {
    async push(p) {
      calls.signedPushes.push(p)
      return fake.signedPush(p)
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
    claudeSettings,
    eventNotice: t => calls.events.push(t),
    gh,
    jobs: [createReviewJob(), createRequestJob({ pusher, signedPusher, sleep: async () => {} })],
    log: m => calls.logs.push(m),
    minePr: key => last?.mine.find(p => p.key === key) ?? null,
    notify: n => calls.notices.push(n),
    now: () => Date.now(),
    repos,
    requestPoll: () => {
      calls.polls++
    },
    rows: () => rows,
    sessions,
    settings: () => settings,
    skillsDir,
    store,
    testHome: o.testHome ?? false,
    toReviewPr: key => last?.toReview.find(p => p.key === key) ?? null,
    async turnOffAutoFix() {
      calls.autoFixOff++
      settings.reviewsAutoFix = false
    },
    viewer: () => last?.viewer ?? null,
  })

  const clone = clonePath(home, 'acme', 'api')
  const h = {
    calls,
    clone,
    cloneOf: (owner: string, repo: string) => clonePath(home, owner, repo),
    fake,
    hooks,
    hub,
    // The item IDs of the input of the last round.
    async inputItems(): Promise<RequestInput['items']> {
      const text = await readFile(join(ioPath(clone, 9), 'input.json'), 'utf8')
      return (JSON.parse(text) as RequestInput).items
    },
    io: ioPath(clone, 9),
    ops: (op: Op) => calls.writes.filter(w => w.op === op),
    async poll(data: PollData = pollOf([polled(hub)])) {
      last = data
      runner.afterPoll(data)
      await runner.settled()
    },
    pr: (): PrState => store.get().prs[KEY] ?? emptyPrState(),
    async preClone(owner = 'acme', repo = 'api') {
      const path = clonePath(home, owner, repo)
      await mkdir(path, { recursive: true })
      cloned.add(path)
    },
    async rowsNow(next: SessionRow[]) {
      rows = next
      runner.onRows(next)
      await runner.settled()
    },
    runner,
    // The last poll, with no afterPoll.
    setPoll(data: PollData) {
      last = data
    },
    setRows(next: SessionRow[]) {
      rows = next
    },
    settings,
    async settingsFile(text: string) {
      await mkdir(base, { recursive: true })
      await writeFile(claudeSettings, text)
    },
    state: () => store.get(),
    store,
    async tick(ms: number) {
      await vi.advanceTimersByTimeAsync(ms)
      await runner.settled()
    },
    async trust(...paths: string[]) {
      await mkdir(base, { recursive: true })
      const projects = Object.fromEntries(paths.map(p => [p, { hasTrustDialogAccepted: true }]))
      await writeFile(claudeJson, JSON.stringify({ projects }))
    },
    async writeResult(text: string) {
      await writeFile(join(ioPath(clone, 9), 'result.json'), text)
    },
  }
  return h
}

type Harness = ReturnType<typeof make>

// The clone exists and is trusted, the runner runs, and the first poll came.
async function ready(h: Harness, data?: PollData): Promise<void> {
  await h.preClone()
  await h.trust(h.clone)
  h.runner.start()
  await h.runner.settled()
  await h.poll(data)
}

// The session of round n works, can write a result, then goes idle. The timer ends the round.
async function endTurn(h: Harness, o: { n?: number; result?: string } = {}): Promise<void> {
  const n = o.n ?? 1
  await h.rowsNow([row(n)])
  if (o.result !== undefined) await h.writeResult(o.result)
  await h.rowsNow([row(n, IDLE)])
  await h.tick(END_SETTLE_MS + PASS_MS)
}

const COMMIT = { message: 'fix: rename the value', paths: ['src/a.ts'] }

function result(items: unknown[], over: Record<string, unknown> = {}): string {
  return JSON.stringify({
    checks: 'passed',
    commit: null,
    headSha: HEAD,
    items,
    pr: KEY,
    version: 1,
    ...over,
  })
}

const fixed = (id: string, by?: string) => ({ id, outcome: 'fixed', ...(by ? { by } : {}) })
const noFix = (id: string, reply = 'We keep this, because the old name is in the API.') => ({
  id,
  outcome: 'no-fix',
  reply,
})
const needsYou = (id: string, question = 'Which name do you want?') => ({
  id,
  outcome: 'needs-you',
  question,
})

const question = (over: Partial<Question> = {}): Question => ({
  answer: null,
  at: ASKED + 1,
  question: 'Which name do you want?',
  seenUntil: ASKED,
  where: 'src/a.ts line 3',
  ...over,
})

const roundItems = (h: Harness): string[] => Object.keys(h.pr().round?.items ?? {})

beforeEach(async () => {
  vi.useFakeTimers()
  vi.setSystemTime(T0)
  dir = await realpath(await mkdtemp(join(tmpdir(), 'bifrost-request-job-')))
  await mkdir(join(dir, 'skills/skills/bifrost-resolve-comments'), { recursive: true })
  await mkdir(join(dir, 'skills/skills/bifrost-humanise'), { recursive: true })
  await writeFile(join(dir, 'skills/skills/bifrost-resolve-comments/bifrost-mode.md'), '# mode\n')
  await writeFile(join(dir, 'skills/skills/bifrost-humanise/rules.md'), '# rules\n')
})

afterEach(async () => {
  vi.useRealTimers()
  await rm(dir, { force: true, recursive: true })
})

describe('the trigger', () => {
  it(
    'a poll with new work queues one request ' + 'round, and a second poll adds no second entry',
    async () => {
      const h = make({ max: 0 })
      await ready(h)
      expect(h.state().queue).toEqual([{ at: Date.now(), key: KEY, kind: 'request' }])
      const first = h.state().queue
      await h.tick(1_000)
      await h.poll()
      expect(h.state().queue).toEqual(first)
      expect(h.runner.mine(KEY).claude).toBe('queued')
      // With a free slot, the entry starts, and a poll during the round adds no entry.
      h.settings.reviewsMaxSessions = 1
      await h.poll()
      expect(h.state().queue).toEqual([])
      expect(h.pr().round).toMatchObject({ kind: 'request', phase: 'running' })
      await h.poll()
      expect(h.state().queue).toEqual([])
      expect(h.calls.starts).toHaveLength(1)
    },
  )

  it(
    'with Handle comments automatically off, a poll ' +
      'queues nothing, and Handle now queues a round',
    async () => {
      const h = make({ autoFix: false })
      await ready(h)
      expect(h.state().queue).toEqual([])
      expect(h.calls.starts).toEqual([])
      expect(h.runner.mine(KEY).claude).toBe('waiting')
      await h.runner.handle(KEY, 'all')
      await h.runner.settled()
      expect(h.calls.starts).toHaveLength(1)
      expect(roundItems(h)).toEqual(['PRRT_1'])
      // The click is spent when the session starts.
      expect(h.pr().handleOlder).toBe(false)
    },
  )

  it('the first poll of R3 sets fixFrom and starts nothing for older comments', async () => {
    // An R2 user: Watch GitHub is on since before the comment, and fixFrom is not set yet.
    const h = make({ state: { fixFrom: null, turnedOnAt: ASKED - 3_600_000 } })
    await ready(h)
    expect(h.state().fixFrom).toBe(T0.getTime())
    expect(h.state().queue).toEqual([])
    await h.tick(60_000)
    await h.poll()
    expect(h.state().queue).toEqual([])
    expect(h.calls.starts).toEqual([])
    // The row counts the older comment, and Handle now handles it.
    expect(h.runner.mine(KEY).claude).toBe('waiting')
    // Ruling S20: a comment that comes after fixFrom waits for the confirm of the user too.
    h.hub.threads.push(thread('PRRT_2', RAVI, Date.now()))
    await h.poll()
    expect(h.calls.starts).toEqual([])
  })

  it('an R2 user gets no automatic round before the confirm, but Handle now works', async () => {
    const h = make({ state: { fixFrom: null, turnedOnAt: ASKED - 3_600_000 } })
    await ready(h)
    // The first poll of R3 saves the flag and turns the setting off, so the row shows it off.
    expect(h.state()).toMatchObject({ autoFixConsent: false, fixFrom: T0.getTime() })
    expect(h.calls.autoFixOff).toBe(1)
    expect(h.settings.reviewsAutoFix).toBe(false)
    await h.tick(60_000)
    h.hub.threads.push(thread('PRRT_2', RAVI, Date.now()))
    await h.poll()
    expect(h.state().queue).toEqual([])
    // The saved flag stops automatic rounds also when the setting is on, for example after a
    // failed save of the settings.
    h.settings.reviewsAutoFix = true
    await h.poll()
    expect(h.state().queue).toEqual([])
    expect(h.calls.starts).toEqual([])
    expect(h.calls.autoFixOff).toBe(1)
    // A round of a click takes only the items of the click, as with automatic rounds off.
    await h.runner.handle(KEY, 'all')
    await h.runner.settled()
    expect(h.calls.starts).toHaveLength(1)
    expect(roundItems(h)).toEqual(['PRRT_1', 'PRRT_2'])
    await endTurn(h, { result: result([noFix('PRRT_1'), noFix('PRRT_2')]) })
    // The user turns the setting on with its confirm. Then new comments start rounds.
    await h.runner.autoFixChanged(true)
    expect(h.state().autoFixConsent).toBe(true)
    await h.tick(60_000)
    h.hub.threads.push(thread('PRRT_3', RAVI, Date.now()))
    await h.poll()
    expect(h.calls.starts).toHaveLength(2)
    expect(roundItems(h)).toEqual(['PRRT_3'])
  })

  it('a user who turns Watch GitHub on after R3 needs no second confirm', async () => {
    const h = make({ state: { fixFrom: null, turnedOnAt: null } })
    await h.runner.watchTurnedOn()
    await ready(h)
    expect(h.state().autoFixConsent).toBeNull()
    expect(h.calls.autoFixOff).toBe(0)
    // The comment from before the turn-on waits. A new comment starts a round.
    expect(h.calls.starts).toEqual([])
    await h.tick(60_000)
    h.hub.threads.push(thread('PRRT_2', RAVI, Date.now()))
    await h.poll()
    expect(h.calls.starts).toHaveLength(1)
    expect(roundItems(h)).toEqual(['PRRT_2'])
  })

  it('a fork PR never gets a round and shows Fork', async () => {
    const h = make({ hub: hubOf({ fork: true }) })
    await ready(h)
    expect(h.state().queue).toEqual([])
    expect(h.runner.mine(KEY)).toEqual({
      claude: 'fork',
      error: REASON_FORK,
      fixing: 0,
      sessionId: null,
    })
    await expect(h.runner.handle(KEY, 'all')).rejects.toThrow(REFUSED_NOT_HANDLEABLE)
    expect(h.state().queue).toEqual([])
  })

  it('a held item does not start a round by itself', async () => {
    const h = make({
      state: { prs: { [KEY]: { ...emptyPrState(), checkedAt: ASKED, held: ['PRRT_1'] } } },
    })
    await ready(h)
    expect(h.state().queue).toEqual([])
    // A trusted comment from before the full read of the failed round does not reopen it.
    h.hub.threads[0]?.notes.push(note('PRRT_1_c2', RAVI, ASKED - 1))
    await h.poll()
    expect(h.state().queue).toEqual([])
    // A newer trusted comment does.
    h.hub.threads[0]?.notes.push(note('PRRT_1_c3', RAVI, Date.now()))
    await h.poll()
    expect(h.calls.starts).toHaveLength(1)
    expect(roundItems(h)).toEqual(['PRRT_1'])
  })

  it(
    'no new round starts while an outbox exists, ' + 'and Handle now sends the outbox first',
    async () => {
      const h = make()
      // The resolve fails once, so the outbox stays for Try again.
      let resolves = 0
      h.fake.writeFails = w =>
        w.op === 'ResolveThread' && resolves++ === 0
          ? { code: 1, stderr: 'gh: Not allowed (HTTP 403)', stdout: '' }
          : undefined
      await ready(h)
      await endTurn(h, { result: result([noFix('PRRT_1')]) })
      expect(h.pr().outbox).not.toBeNull()
      expect(h.pr().lastError).toMatch(/^GitHub stopped after 1 of 3 updates/)
      // New work waits for the outbox.
      h.hub.threads.push(thread('PRRT_2', RAVI, Date.now()))
      await h.poll()
      expect(h.state().queue).toEqual([])
      expect(h.calls.starts).toHaveLength(1)
      await h.runner.handle(KEY, 'all')
      await h.runner.settled()
      expect(h.ops('ReplyToThread')).toHaveLength(1)
      expect(h.ops('ResolveThread')).toHaveLength(2)
      expect(h.pr().outbox).toBeNull()
      expect(h.pr().handled.PRRT_1).toBeDefined()
      expect(h.calls.starts).toHaveLength(2)
      expect(roundItems(h)).toEqual(['PRRT_2'])
    },
  )
})

describe('the preparation and the start', () => {
  it(
    'the round reads the full context and works ' + 'only on new items, at most MAX_ROUND_ITEMS',
    async () => {
      const fresh = Array.from({ length: MAX_ROUND_ITEMS + 2 }, (_, i) =>
        thread(`PRRT_n${i}`, RAVI, ASKED + (MAX_ROUND_ITEMS + 2 - i) * 1_000),
      )
      const hub = hubOf({
        reviews: [
          {
            at: ASKED - 5_000,
            body: 'Copilot reviewed 2 files.',
            by: COPILOT,
            id: 'PRR_cop',
            state: 'COMMENTED',
          },
        ],
        threads: [
          ...fresh,
          thread('PRRT_old', RAVI, FIX_FROM - 1_000),
          thread('PRRT_done', RAVI),
          thread('PRRT_eve', EVE),
        ],
        updatedAt: ASKED + 99_000,
      })
      const state = {
        prs: {
          [KEY]: { ...emptyPrState(), handled: { PRRT_done: { at: ASKED, lastReplyAt: ASKED } } },
        },
      }
      const h = make({ hub, state })
      // The poll shows no thread, but its thread list is cut.
      await ready(h, pollOf([polled(hub, { threads: [], truncatedThreads: true })]))
      expect(h.calls.gh.slice(0, 3)).toEqual([
        'RequestContext',
        'RequestThreads',
        'RequestComments',
      ])
      // The oldest new items first, by the time of the first comment.
      const want = fresh
        .map(t => t.id)
        .reverse()
        .slice(0, MAX_ROUND_ITEMS)
      expect(roundItems(h)).toEqual(want)
      expect((await h.inputItems()).map(i => i.id)).toEqual(want)
      expect(h.pr().round?.items?.[`PRRT_n${MAX_ROUND_ITEMS + 1}`]).toBe(ASKED + 1_000)
      expect(h.pr()).toMatchObject({ checkedAt: ASKED + 99_000, firstCopilotReview: 'PRR_cop' })
    },
  )

  it('a round with no work after the full read starts no session and saves checkedAt', async () => {
    const hub = hubOf({ threads: [thread('PRRT_old', RAVI, FIX_FROM - 1_000)], updatedAt: ASKED })
    const h = make({ hub })
    await ready(h, pollOf([polled(hub, { threads: [], truncatedThreads: true })]))
    expect(h.calls.gh).toContain('RequestContext')
    expect(h.calls.starts).toEqual([])
    expect(h.calls.worktrees).toEqual([])
    expect(h.pr()).toMatchObject({ checkedAt: ASKED, lastError: null, round: null })
    // The next poll has no newer update, so it queues nothing.
    const reads = h.calls.gh.length
    await h.poll(pollOf([polled(hub, { threads: [], truncatedThreads: true })]))
    expect(h.state().queue).toEqual([])
    expect(h.calls.gh).toHaveLength(reads)
  })

  it(
    'the start uses the request args, the -request name ' +
      'and the request model, and haiku in a test home',
    async () => {
      for (const testHome of [false, true]) {
        const h = make({ id: String(testHome), model: 'opus', testHome })
        await ready(h)
        const start = h.calls.starts[0]
        const name = testHome ? 'bifrost-test-api-9-request' : 'api-9-request'
        expect(start?.name).toBe(name)
        expect(start?.cwd).toBe(worktreePath(h.clone, 9))
        expect(start?.args).toEqual(
          requestSessionArgs({
            clone: h.clone,
            ioDir: h.io,
            model: testHome ? 'haiku' : 'opus',
            name,
            pluginDir: join(dir, 'skills'),
            prompt: requestPrompt(join(h.io, 'input.json')),
          }),
        )
        expect(h.pr().request).toEqual({ name, sessionId: 'sess-1', shortId: short(1) })
        expect(h.pr().round).toMatchObject({
          baseSha: BASE,
          headSha: HEAD,
          items: { PRRT_1: ASKED },
          kind: 'request',
          phase: 'running',
          sessionId: 'sess-1',
          shortId: short(1),
        })
      }
    },
  )

  it('a cut context fails the round before the session and holds its work', async () => {
    const h = make({ hub: hubOf({ truncated: true, updatedAt: ASKED }) })
    await ready(h)
    expect(h.calls.gh).toContain('RequestContext')
    expect(h.calls.starts).toEqual([])
    expect(h.calls.worktrees).toEqual([])
    expect(h.calls.fetches).toEqual([])
    expect(h.pr()).toMatchObject({
      checkedAt: ASKED,
      held: ['PRRT_1'],
      lastError: REASON_TOO_MANY_COMMENTS,
      round: null,
    })
    expect(h.runner.mine(KEY).claude).toBe('error')
    // The next poll does not read the pull request again.
    const reads = h.calls.gh.length
    await h.poll()
    expect(h.state().queue).toEqual([])
    expect(h.calls.gh).toHaveLength(reads)
  })

  it('the fetch of a request round gets the config that stops each prompt', async () => {
    const h = make()
    await ready(h)
    expect(h.calls.starts).toHaveLength(1)
    expect(h.calls.fetches).toEqual([{ noPrompt: true }])
  })

  it('a user sandbox problem fails the round with its reason and starts no session', async () => {
    const h = make()
    await h.settingsFile(
      JSON.stringify({ sandbox: { network: { allowedDomains: ['github.com'] } } }),
    )
    await ready(h)
    expect(h.calls.starts).toEqual([])
    expect(h.pr()).toMatchObject({ held: ['PRRT_1'], lastError: REASON_USER_SANDBOX, round: null })
    expect(h.runner.mine(KEY).claude).toBe('error')
  })

  it(
    'a failed start holds the items, and only ' + 'a started session takes items out of held',
    async () => {
      const h = make({ state: { prs: { [KEY]: { ...emptyPrState(), held: ['PRRT_gone'] } } } })
      h.fake.start = s => ({
        message: 'claude did not start',
        name: s.name,
        ok: false,
        trust: false,
      })
      await ready(h)
      expect(h.pr()).toMatchObject({
        handleOlder: false,
        held: ['PRRT_gone', 'PRRT_1'],
        lastError: REASON_FIX_START_FAILED,
        round: null,
      })
      // The failed start does not come back at the next poll.
      await h.poll()
      expect(h.calls.starts).toHaveLength(1)
      // Try again takes the held item. The held item that the round did not take stays.
      h.fake.start = s => ({ name: s.name, ok: true, sessionId: 'sess-2', shortId: short(2) })
      await h.runner.retry(KEY)
      await h.runner.settled()
      expect(roundItems(h)).toEqual(['PRRT_1'])
      expect(h.pr()).toMatchObject({ handleOlder: false, held: ['PRRT_gone'], lastError: null })
    },
  )
})

describe('the end and the posts', () => {
  it(
    'a valid result commits, pushes, replies, resolves ' +
      'and marks each item handled with a lastReplyAt',
    async () => {
      const hub = hubOf({
        comments: [note('IC_1', RAVI, ASKED + 1, 'Add a test, @mia.')],
        threads: [thread('PRRT_1')],
      })
      const h = make({ hub })
      await ready(h)
      await endTurn(h, {
        result: result([fixed('PRRT_1'), noFix('IC_1', 'The tests cover it.')], { commit: COMMIT }),
      })
      expect(h.calls.commits).toEqual([{ head: HEAD, number: 9, ...COMMIT }])
      // The worktree is clean at the fix commit after the commit.
      expect(h.calls.cleaned).toEqual([{ head: FIX, number: 9 }])
      expect(h.calls.signedPushes).toEqual([])
      expect(h.calls.pushes).toEqual([
        {
          baseRef: 'main',
          clone: h.clone,
          crossRepository: false,
          defaultBranch: 'main',
          fix: FIX,
          headRef: 'feature',
          number: 9,
          owner: 'acme',
          repo: 'api',
        },
      ])
      expect(h.calls.writes.map(w => w.op)).toEqual([
        'ReplyToThread',
        'ResolveThread',
        'CommentOnPr',
      ])
      expect(h.ops('ReplyToThread')[0]?.vars).toEqual({
        body: 'Fixed by ccccccc',
        thread: 'PRRT_1',
      })
      expect(h.ops('CommentOnPr')[0]?.vars.body).toBe(
        `> Add a test, @${Z}mia.\n\nThe tests cover it.`,
      )
      const at = expect.any(Number)
      expect(h.pr()).toMatchObject({
        handled: {
          IC_1: { at, lastReplyAt: ASKED + 1 },
          PRRT_1: { at, lastReplyAt: ASKED },
        },
        lastError: null,
        outbox: null,
        round: null,
      })
      expect(h.state().posted.map(p => p.body)).toEqual([
        'Fixed by ccccccc',
        `> Add a test, @${Z}mia.\n\nThe tests cover it.`,
      ])
      expect(h.calls.polls).toBe(1)
      expect(h.calls.notices).toEqual([])
      // The session stays after its round.
      expect(h.calls.removes).toEqual([])
      expect(h.pr().request?.sessionId).toBe('sess-1')
    },
  )

  it(
    'a needs-you item becomes a question, sends ' + 'one notification and starts no new round',
    async () => {
      const long = `src/${'a'.repeat(400)}.ts`
      const hub = hubOf({
        comments: [note('IC_1', MIA, ASKED + 1)],
        threads: [thread('PRRT_1', RAVI, ASKED, { path: long }), thread('PRRT_2')],
      })
      const h = make({ hub })
      await ready(h)
      await endTurn(h, {
        result: result([
          needsYou('PRRT_1', 'Rename it in the API too?'),
          needsYou('IC_1', 'Is a unit test enough?'),
          noFix('PRRT_2'),
        ]),
      })
      const now = h.pr().questions.IC_1?.at
      expect(now).toBeGreaterThan(ASKED)
      expect(h.pr().questions).toEqual({
        IC_1: {
          answer: null,
          at: now,
          author: 'mia',
          body: 'Please look at IC_1.',
          kind: 'comment',
          question: 'Is a unit test enough?',
          seenUntil: ASKED + 1,
          url: 'https://github.com/acme/api/pull/9#note-IC_1',
          where: 'Comment from mia',
        },
        PRRT_1: {
          answer: null,
          at: now,
          author: 'ravi',
          body: 'Please fix PRRT_1.',
          kind: 'thread',
          question: 'Rename it in the API too?',
          seenUntil: ASKED,
          url: 'https://github.com/acme/api/pull/9#note-PRRT_1_c1',
          where: `${long} line 3`.slice(0, MAX_WHERE),
        },
      })
      expect(h.calls.writes.map(w => w.op)).toEqual(['ReplyToThread', 'ResolveThread'])
      const pr = { number: 9, repo: 'api' }
      expect(h.calls.notices).toEqual([needsYouNotice(pr, 2)])
      expect(needsYouNotice(pr, 2)).toEqual({
        body: 'Claude needs your answer on 2 comments.',
        title: 'api #9',
      })
      expect(needsYouNotice(pr, 1).body).toBe('Claude needs your answer on 1 comment.')
      expect(h.runner.mine(KEY).claude).toBe('needs-you')
      await h.poll()
      expect(h.state().queue).toEqual([])
      expect(h.calls.starts).toHaveLength(1)
    },
  )

  it('cuts the body and the author of a question, and drops a URL that is not GitHub', async () => {
    const hub = hubOf({
      threads: [
        thread('PRRT_1', { association: 'MEMBER', login: 'r'.repeat(80) }, ASKED, {
          notes: [
            {
              ...note('PRRT_1_c1', RAVI, ASKED, `${'w'.repeat(MAX_QUOTE + 50)}`),
              url: 'http://github.com/acme/api/pull/9#x',
            },
          ],
        }),
      ],
    })
    const h = make({ hub })
    await ready(h)
    await endTurn(h, { result: result([needsYou('PRRT_1', 'Which one?')]) })
    const q = h.pr().questions.PRRT_1
    expect(q?.body).toBe(`${'w'.repeat(MAX_QUOTE - 1)}\u2026`)
    expect(q?.author?.length).toBeLessThanOrEqual(MAX_AUTHOR)
    expect(q).not.toHaveProperty('url')
  })

  it('saves no body for a blank comment, and keeps the kind', async () => {
    const hub = hubOf({
      threads: [
        thread('PRRT_1', RAVI, ASKED, { notes: [note('PRRT_1_c1', RAVI, ASKED, ' \n\t ')] }),
      ],
    })
    const h = make({ hub })
    await ready(h)
    await endTurn(h, { result: result([needsYou('PRRT_1', 'Which one?')]) })
    const q = h.pr().questions.PRRT_1
    expect(q).not.toHaveProperty('body')
    expect(q?.kind).toBe('thread')
  })

  it('a No action item posts nothing and is handled', async () => {
    const h = make()
    await ready(h)
    await endTurn(h, { result: result([{ id: 'PRRT_1', outcome: 'no-action' }]) })
    expect(h.calls.writes).toEqual([])
    expect(h.calls.pushes).toEqual([])
    // With no commit, the worktree is clean at the head at once.
    expect(h.calls.cleaned).toEqual([{ head: HEAD, number: 9 }])
    expect(h.pr()).toMatchObject({
      handled: { PRRT_1: { at: expect.any(Number), lastReplyAt: ASKED } },
      lastError: null,
      outbox: null,
      round: null,
    })
  })

  const failures: [string, (h: Harness) => Promise<void>, string, number][] = [
    [
      'a bad result',
      h => endTurn(h, { result: 'not json' }),
      reasonFixBadResult('the result is not valid JSON'),
      0,
    ],
    ['no result', h => endTurn(h), REASON_FIX_NO_RESULT, 0],
    [
      'a timeout',
      async h => {
        await h.rowsNow([row(1)])
        await h.tick(ROUND_LIMIT_MS)
      },
      REASON_FIX_TIMEOUT,
      1,
    ],
    [
      'a stopped session',
      async h => {
        await h.rowsNow([row(1)])
        await h.writeResult(result([noFix('PRRT_1')]))
        await h.runner.stopSession(KEY)
        await h.rowsNow([row(1, IDLE)])
        await h.tick(END_SETTLE_MS + PASS_MS)
      },
      REASON_FIX_STOPPED,
      1,
    ],
  ]
  it.each(failures)(
    'a bad result, no result, a timeout and a stopped ' +
      'session each post nothing and hold the items: %s',
    async (_name, end, message, stops) => {
      const h = make()
      await ready(h)
      await end(h)
      expect(h.calls.writes).toEqual([])
      expect(h.calls.pushes).toEqual([])
      expect(h.calls.stops).toHaveLength(stops)
      expect(h.calls.cleaned).toEqual([{ head: HEAD, number: 9 }])
      expect(h.pr()).toMatchObject({
        held: ['PRRT_1'],
        lastError: message,
        outbox: null,
        round: null,
      })
      expect(h.calls.notices).toEqual([])
      await h.poll()
      expect(h.state().queue).toEqual([])
    },
  )

  it('a session that asks (blocked) posts a valid result and stops', async () => {
    const h = make()
    await ready(h)
    await h.rowsNow([row(1)])
    await h.writeResult(result([noFix('PRRT_1')]))
    await h.rowsNow([row(1, PROMPT)])
    await h.tick(PASS_MS)
    expect(h.calls.stops).toEqual([short(1)])
    expect(h.calls.writes.map(w => w.op)).toEqual(['ReplyToThread', 'ResolveThread'])
    expect(h.pr()).toMatchObject({ lastError: null, round: null })
    // With no valid result, a session that asks fails the round.
    h.hub.threads.push(thread('PRRT_2', RAVI, Date.now()))
    await h.poll()
    await h.rowsNow([row(2)])
    await h.rowsNow([row(2, PROMPT)])
    await h.tick(PASS_MS)
    expect(h.calls.stops).toEqual([short(1), short(2)])
    expect(h.pr()).toMatchObject({ held: ['PRRT_2'], lastError: REASON_FIX_BLOCKED, round: null })
  })

  it('a fixed item by a commit that is not in the pull request is a bad result', async () => {
    for (const by of [OUT, BASE]) {
      const h = make({ id: by })
      await ready(h)
      await endTurn(h, { result: result([fixed('PRRT_1', by)]) })
      expect(h.calls.writes).toEqual([])
      expect(h.pr()).toMatchObject({
        held: ['PRRT_1'],
        lastError: reasonFixBadResult('a by commit that is not in the pull request'),
      })
    }
    // An earlier commit of the PR is fine. No commit is needed.
    const h = make({ id: 'good' })
    await ready(h)
    await endTurn(h, { result: result([fixed('PRRT_1', BY)]) })
    expect(h.calls.commits).toEqual([])
    expect(h.ops('ReplyToThread')[0]?.vars.body).toBe('Fixed by eeeeeee')
    expect(h.pr().handled.PRRT_1).toBeDefined()
  })

  it(
    'a push conflict posts the other replies, ' + 'holds the fixed items and shows the error',
    async () => {
      const h = make({ hub: hubOf({ threads: [thread('PRRT_1'), thread('PRRT_2')] }) })
      h.fake.push = () => ({ message: REASON_PUSH_CONFLICT, ok: false, reason: 'conflict' })
      await ready(h)
      await endTurn(h, { result: result([fixed('PRRT_1'), noFix('PRRT_2')], { commit: COMMIT }) })
      expect(h.calls.pushes).toHaveLength(1)
      expect(h.calls.writes.map(w => [w.op, w.vars.thread])).toEqual([
        ['ReplyToThread', 'PRRT_2'],
        ['ResolveThread', 'PRRT_2'],
      ])
      expect(h.pr()).toMatchObject({
        held: ['PRRT_1'],
        lastError: REASON_PUSH_CONFLICT,
        outbox: null,
        round: null,
      })
      expect(Object.keys(h.pr().handled)).toEqual(['PRRT_2'])
      // The reply that went is in the posted comments.
      expect(h.state().posted.map(p => p.body)).toEqual([
        'We keep this, because the old name is in the API.',
      ])
      expect(h.calls.notices).toEqual([])
      expect(h.runner.mine(KEY)).toMatchObject({ claude: 'error', error: REASON_PUSH_CONFLICT })
    },
  )

  it(
    'files outside commit.paths are discarded, and a ' +
      'workflow change fails the round with nothing posted',
    async () => {
      const h = make()
      h.fake.changed = ['src/a.ts', 'notes.txt']
      await ready(h)
      await endTurn(h, { result: result([fixed('PRRT_1')], { commit: COMMIT }) })
      expect(h.calls.commits.map(c => c.paths)).toEqual([['src/a.ts']])
      // The clean at the fix commit discards notes.txt.
      expect(h.calls.cleaned).toEqual([{ head: FIX, number: 9 }])
      expect(h.calls.pushes.map(p => p.fix)).toEqual([FIX])
      // A workflow file: the commit refuses it, and nothing goes to GitHub.
      const g = make({ id: 'b' })
      g.fake.changed = ['.github/workflows/ci.yml']
      g.fake.commitRule = 'workflow'
      await ready(g)
      const commit = { message: 'ci: fix', paths: ['.github/workflows/ci.yml'] }
      await endTurn(g, { result: result([fixed('PRRT_1')], { commit }) })
      expect(g.calls.pushes).toEqual([])
      expect(g.calls.writes).toEqual([])
      expect(g.calls.cleaned).toEqual([{ head: HEAD, number: 9 }])
      expect(g.pr()).toMatchObject({
        held: ['PRRT_1'],
        lastError: reasonUnsafeChange('workflow'),
        outbox: null,
        round: null,
      })
    },
  )

  it('a git error of the commit shows a fixed text and logs the masked git line', async () => {
    const h = make()
    const token = `ghp_${'D'.repeat(24)}`
    const message = reasonCommitFailed(REASON_PUSH_GIT_FAILED)
    h.fake.commitError = new CommitError(message, `fatal: bad config ${token}`)
    await ready(h)
    await endTurn(h, { result: result([fixed('PRRT_1')], { commit: COMMIT }) })
    expect(h.pr()).toMatchObject({ held: ['PRRT_1'], lastError: message, outbox: null })
    expect(h.calls.events).toEqual([
      `Reviews: the fix commit of ${KEY} failed. git said: fatal: bad config ***`,
    ])
  })

  it('a commit error shows its text one time, drops the outbox and holds the items', async () => {
    const h = make()
    h.fake.commitError = new Error(reasonCommitFailed('git took too long.'))
    await ready(h)
    await endTurn(h, { result: result([fixed('PRRT_1')], { commit: COMMIT }) })
    expect(h.pr()).toMatchObject({
      held: ['PRRT_1'],
      lastError: reasonCommitFailed('git took too long.'),
      outbox: null,
    })
    expect(h.calls.writes).toEqual([])
    // An error that can hold a path gives a fixed text. The log gets the error.
    const g = make({ id: 'b' })
    g.fake.commitError = new Error('EACCES: /Users/someone/secret')
    await ready(g)
    await endTurn(g, { result: result([fixed('PRRT_1')], { commit: COMMIT }) })
    expect(g.pr()).toMatchObject({ held: ['PRRT_1'], lastError: REASON_COMMIT_ERROR, outbox: null })
    expect(g.calls.logs.some(l => l.includes('EACCES'))).toBe(true)
  })

  it('a cut context at the posts drops an unsent outbox and holds its items', async () => {
    const h = make()
    await ready(h)
    h.hub.truncated = true
    await endTurn(h, { result: result([fixed('PRRT_1')], { commit: COMMIT }) })
    expect(h.calls.commits).toEqual([])
    expect(h.calls.pushes).toEqual([])
    expect(h.calls.writes).toEqual([])
    expect(h.calls.cleaned).toEqual([{ head: HEAD, number: 9 }])
    expect(h.pr()).toMatchObject({
      held: ['PRRT_1'],
      lastError: REASON_TOO_MANY_COMMENTS,
      outbox: null,
      round: null,
    })
  })

  it('a push that GitHub surely refused drops the outbox and holds the items', async () => {
    const message = reasonPushFailed('remote: GH013: Repository rule violations found')
    const h = make()
    h.fake.push = () => ({ message, ok: false, reason: 'not-landed' })
    await ready(h)
    await endTurn(h, { result: result([fixed('PRRT_1')], { commit: COMMIT }) })
    expect(h.calls.pushes).toHaveLength(1)
    expect(h.calls.writes).toEqual([])
    expect(h.calls.cleaned).toEqual([
      { head: FIX, number: 9 },
      { head: HEAD, number: 9 },
    ])
    expect(h.pr()).toMatchObject({ held: ['PRRT_1'], lastError: message, outbox: null })
    // A push with an unknown outcome keeps the outbox for Try again.
    const g = make({ id: 'b' })
    g.fake.push = () => ({ message, ok: false, reason: 'refused' })
    await ready(g)
    await endTurn(g, { result: result([fixed('PRRT_1')], { commit: COMMIT }) })
    expect(g.pr()).toMatchObject({ held: [], lastError: message })
    expect(g.pr().outbox).not.toBeNull()
  })

  it('with Sign commits through GitHub on, the fix goes through GitHub', async () => {
    const h = make({ hub: hubOf({ threads: [thread('PRRT_1')] }), signed: true })
    const saved: Post[] = []
    h.fake.signedPush = () => {
      const push = h.pr().outbox?.posts.find(post => post.kind === 'push')
      if (push !== undefined) saved.push(structuredClone(push))
      return { already: false, merged: false, ok: true, sha: SIGNED }
    }
    await ready(h)
    await endTurn(h, { result: result([fixed('PRRT_1')], { commit: COMMIT }) })
    expect(h.calls.pushes).toEqual([])
    expect(h.calls.signedPushes).toEqual([
      {
        baseRef: 'main',
        clone: h.clone,
        crossRepository: false,
        defaultBranch: 'main',
        fix: FIX,
        headRef: 'feature',
        number: 9,
        owner: 'acme',
        repo: 'api',
      },
    ])
    // The outbox saved the method before the push.
    expect(saved).toEqual([{ id: 'push', kind: 'push', signed: true, state: 'sending' }])
    // The reply names the commit that GitHub made, not the local fix commit.
    expect(h.ops('ReplyToThread')[0]?.vars.body).toBe(`Fixed by ${SIGNED.slice(0, 7)}`)
    expect(h.pr()).toMatchObject({ lastError: null, outbox: null, round: null })
  })

  it('a resume uses the saved method, not the current setting (ruling S24)', async () => {
    const posting = (outbox: Outbox): Partial<ReviewsState> => ({
      prs: {
        [KEY]: {
          ...emptyPrState(),
          outbox,
          round: {
            at: ASKED,
            baseSha: BASE,
            headSha: HEAD,
            items: { PRRT_1: ASKED },
            kind: 'request',
            phase: 'posting',
            sessionId: null,
            shortId: null,
            startedAt: ASKED,
            stoppedByUser: false,
          },
        },
      },
    })
    const outbox = (signed: boolean): Outbox => ({
      headSha: HEAD,
      mergeBase: BASE,
      posts: [
        {
          id: 'commit',
          kind: 'commit',
          message: 'fix: x',
          paths: ['src/a.ts'],
          sha: FIX,
          state: 'done',
        },
        { id: 'push', kind: 'push', state: 'sending', ...(signed ? { signed: true } : {}) },
        { id: 'reply:PRRT_1', itemId: 'PRRT_1', kind: 'reply', state: 'todo', text: null },
      ],
      seen: { PRRT_1: ASKED },
      startedAt: ASKED,
    })
    // Bifrost quit during a signed push. The user then turned the setting off.
    const h = make({ signed: false, state: posting(outbox(true)) })
    h.runner.start()
    await h.runner.settled()
    await h.poll()
    expect(h.calls.pushes).toEqual([])
    expect(h.calls.signedPushes.map(p => p.fix)).toEqual([FIX])
    expect(h.ops('ReplyToThread')[0]?.vars.body).toBe(`Fixed by ${SIGNED.slice(0, 7)}`)
    expect(h.pr()).toMatchObject({ lastError: null, outbox: null, round: null })
    // Bifrost quit during a git push. The user then turned the setting on.
    const g = make({ id: 'b', signed: true, state: posting(outbox(false)) })
    g.runner.start()
    await g.runner.settled()
    await g.poll()
    expect(g.calls.signedPushes).toEqual([])
    expect(g.calls.pushes.map(p => p.fix)).toEqual([FIX])
    expect(g.ops('ReplyToThread')[0]?.vars.body).toBe(`Fixed by ${FIX.slice(0, 7)}`)
  })

  it('with signed commits on, commitFix still refuses a link or a submodule', async () => {
    for (const rule of ['link', 'submodule'] as const) {
      const h = make({ id: rule, signed: true })
      h.fake.commitRule = rule
      await ready(h)
      await endTurn(h, { result: result([fixed('PRRT_1')], { commit: COMMIT }) })
      expect(h.calls.pushes).toEqual([])
      expect(h.calls.signedPushes).toEqual([])
      expect(h.calls.writes).toEqual([])
      expect(h.pr()).toMatchObject({
        held: ['PRRT_1'],
        lastError: reasonUnsafeChange(rule),
        outbox: null,
      })
    }
  })

  it('a signed fix that GitHub cannot take drops the outbox and holds the items', async () => {
    const h = make({ signed: true })
    h.fake.signedPush = () => ({
      message: REASON_SIGNED_EXECUTABLE,
      ok: false,
      reason: 'not-landed',
    })
    await ready(h)
    await endTurn(h, { result: result([fixed('PRRT_1')], { commit: COMMIT }) })
    expect(h.calls.signedPushes).toHaveLength(1)
    expect(h.calls.writes).toEqual([])
    expect(h.pr()).toMatchObject({
      held: ['PRRT_1'],
      lastError: REASON_SIGNED_EXECUTABLE,
      outbox: null,
    })
  })

  it('a failed read after a cut-off commit keeps the outbox for Try again', async () => {
    const outbox: Outbox = {
      headSha: HEAD,
      mergeBase: BASE,
      posts: [
        { id: 'commit', kind: 'commit', message: 'fix: x', paths: ['src/a.ts'], state: 'sending' },
        { id: 'push', kind: 'push', state: 'todo' },
        { id: 'reply:PRRT_1', itemId: 'PRRT_1', kind: 'reply', state: 'todo', text: null },
      ],
      seen: { PRRT_1: ASKED },
      startedAt: ASKED,
    }
    const h = make({ state: { prs: { [KEY]: { ...emptyPrState(), lastError: 'Old.', outbox } } } })
    await ready(h)
    expect(h.calls.starts).toEqual([])
    h.fake.contextFails = true
    await h.runner.retry(KEY)
    await h.runner.settled()
    expect(h.calls.commits).toEqual([])
    expect(h.pr().outbox?.posts.map(p => p.state)).toEqual(['sending', 'todo', 'todo'])
    expect(h.pr().held).toEqual([])
    expect(h.pr().lastError).toBe(reasonPostsStopped(0, 2, REASON_POSTS_READ_FAILED))
    expect(h.calls.events).toEqual([
      `Reviews: GitHub stopped the updates of ${KEY}. It said: gh: Server Error (HTTP 502)`,
    ])
  })

  it('a failed read at the start of a round writes the detail to the Event log', async () => {
    const h = make()
    h.fake.contextFails = true
    await ready(h)
    expect(h.calls.starts).toEqual([])
    expect(h.pr()).toMatchObject({ lastError: REASON_PR_READ_FAILED, round: null })
    expect(h.calls.events).toEqual([
      `Reviews: GitHub couldn't load ${KEY}. It said: gh: Server Error (HTTP 502)`,
    ])
  })

  it('a failed read at the end of a round holds its items and logs the detail', async () => {
    const h = make()
    await ready(h)
    h.fake.contextFails = true
    await endTurn(h, { result: result([noFix('PRRT_1')]) })
    expect(h.pr()).toMatchObject({
      held: ['PRRT_1'],
      lastError: REASON_PR_READ_FAILED,
      outbox: null,
      round: null,
    })
    expect(h.ops('ReplyToThread')).toEqual([])
    expect(h.calls.events).toEqual([
      `Reviews: GitHub couldn't load ${KEY}. It said: gh: Server Error (HTTP 502)`,
    ])
  })

  it('Cancel on an error row drops the outbox and holds its open items', async () => {
    const h = make()
    h.fake.writeFails = w =>
      w.op === 'ResolveThread'
        ? { code: 1, stderr: 'gh: Not allowed (HTTP 403)', stdout: '' }
        : undefined
    await ready(h)
    await endTurn(h, { result: result([noFix('PRRT_1')]) })
    expect(h.pr().outbox).not.toBeNull()
    expect(h.runner.mine(KEY).claude).toBe('error')
    await h.runner.cancel(KEY)
    expect(h.pr()).toMatchObject({ held: ['PRRT_1'], lastError: null, outbox: null })
    expect(h.runner.mine(KEY).claude).toBe('waiting')
    // Nothing more goes to GitHub, and a poll starts no round for the held item.
    await h.poll()
    expect(h.calls.writes.map(w => w.op)).toEqual(['ReplyToThread', 'ResolveThread'])
    expect(h.calls.starts).toHaveLength(1)
  })

  it('Stop session in the posting phase stops before the next write', async () => {
    const h = make()
    const posting = gate()
    h.fake.hold = w => {
      if (w.op !== 'ReplyToThread') return null
      posting.reach()
      return posting.wait
    }
    await ready(h)
    const ended = endTurn(h, { result: result([noFix('PRRT_1')]) })
    await posting.reached
    expect(h.pr().round?.phase).toBe('posting')
    await h.runner.stopSession(KEY)
    posting.open()
    await ended
    expect(h.calls.writes.map(w => w.op)).toEqual(['ReplyToThread'])
    expect(h.pr()).toMatchObject({ lastError: reasonUserStoppedPosts(1, 3), round: null })
    expect(h.pr().outbox).not.toBeNull()
    // Try again sends the rest.
    h.fake.hold = () => null
    await h.runner.retry(KEY)
    await h.runner.settled()
    expect(h.calls.writes.map(w => w.op)).toEqual(['ReplyToThread', 'ResolveThread'])
    expect(h.pr()).toMatchObject({ lastError: null, outbox: null })
  })

  it('a failed save during the posts stops before the write and shows an error', async () => {
    const h = make()
    await ready(h)
    h.hooks.failIf = s =>
      s.prs[KEY]?.outbox?.posts.some(p => p.kind === 'reply' && p.state === 'sending') === true
    await endTurn(h, { result: result([noFix('PRRT_1')]) })
    expect(h.calls.writes).toEqual([])
    expect(h.pr()).toMatchObject({ lastError: REASON_FIX_END_FAILED, round: null })
    expect(h.pr().outbox?.posts.map(p => [p.id, p.state])).toEqual([
      ['reply:PRRT_1', 'todo'],
      ['resolve:PRRT_1', 'todo'],
      ['rerequest', 'todo'],
    ])
    // Try again sends the posts.
    await h.runner.retry(KEY)
    await h.runner.settled()
    expect(h.calls.writes.map(w => w.op)).toEqual(['ReplyToThread', 'ResolveThread'])
    expect(h.pr()).toMatchObject({ lastError: null, outbox: null })
  })

  it('a reviewer with an open item, also a review body, gets no new review request', async () => {
    const hub = hubOf({
      decisions: [
        { login: 'ravi', state: 'CHANGES_REQUESTED', userId: 'U_ravi' },
        { login: 'mia', state: 'CHANGES_REQUESTED', userId: 'U_mia' },
      ],
      reviews: [
        {
          at: ASKED + 1,
          body: 'Split this PR.',
          by: MIA,
          id: 'PRR_mia',
          state: 'CHANGES_REQUESTED',
        },
      ],
      threads: [thread('PRRT_1')],
    })
    const h = make({ hub })
    await ready(h)
    await endTurn(h, { result: result([noFix('PRRT_1'), needsYou('PRR_mia')]) })
    expect(h.ops('RequestReviewer').map(w => w.vars.user)).toEqual(['U_ravi'])
    expect(h.pr().rerequested).toEqual({ ravi: HEAD })
  })

  it('a trusted comment on a handled thread starts a new round for that thread only', async () => {
    const h = make({ hub: hubOf({ threads: [thread('PRRT_1'), thread('PRRT_2')] }) })
    await ready(h)
    await endTurn(h, { result: result([noFix('PRRT_1'), noFix('PRRT_2')]) })
    expect(Object.keys(h.pr().handled).sort()).toEqual(['PRRT_1', 'PRRT_2'])
    // The reviewer opens both threads again, and comments on one of them.
    for (const t of h.hub.threads) t.resolved = false
    await h.poll()
    expect(h.state().queue).toEqual([])
    h.hub.threads[0]?.notes.push(note('PRRT_1_c9', RAVI, Date.now(), 'Still wrong.'))
    await h.poll()
    expect(h.calls.starts).toHaveLength(2)
    expect(roundItems(h)).toEqual(['PRRT_1'])
  })
})

describe('the answers', () => {
  it(
    'an answer starts a round with the answer in the ' +
      'input, and a null answer marks the item handled',
    async () => {
      const hub = hubOf({ threads: [thread('PRRT_1'), thread('PRRT_2')] })
      const state = {
        prs: {
          [KEY]: {
            ...emptyPrState(),
            held: ['PRRT_1'],
            questions: { PRRT_1: question(), PRRT_2: question({ seenUntil: ASKED + 5 }) },
          },
        },
      }
      const h = make({ hub, state })
      await ready(h)
      expect(h.state().queue).toEqual([])
      await expect(h.runner.answer(KEY, [{ id: 'PRRT_9', text: 'Yes.' }])).rejects.toThrow(
        REFUSED_UNKNOWN_QUESTION,
      )
      await expect(h.runner.answer(KEY, [{ id: 'PRRT_1', text: '   ' }])).rejects.toThrow(
        REFUSED_BAD_ANSWER,
      )
      await expect(
        h.runner.answer(KEY, [{ id: 'PRRT_1', text: 'x'.repeat(MAX_ANSWER + 1) }]),
      ).rejects.toThrow(REFUSED_BAD_ANSWER)
      expect(h.pr().questions.PRRT_1?.answer).toBeNull()
      // A null answer: the user handles the item.
      await h.runner.answer(KEY, [{ id: 'PRRT_2', text: null }])
      await h.runner.settled()
      expect(h.pr().questions.PRRT_2).toBeUndefined()
      expect(h.pr().handled.PRRT_2).toEqual({ at: Date.now(), lastReplyAt: ASKED + 5 })
      expect(h.state().queue).toEqual([])
      // A text: the item leaves held and the round starts with the answer.
      await h.runner.answer(KEY, [{ id: 'PRRT_1', text: '  Use the new name.  ' }])
      await h.runner.settled()
      expect(h.calls.starts).toHaveLength(1)
      expect(roundItems(h)).toEqual(['PRRT_1'])
      const items = await h.inputItems()
      expect(items.map(i => [i.id, i.question, i.answer])).toEqual([
        ['PRRT_1', 'Which name do you want?', 'Use the new name.'],
      ])
      await expect(h.runner.answer(KEY, [{ id: 'PRRT_1', text: 'Again.' }])).rejects.toThrow(
        REFUSED_UNKNOWN_QUESTION,
      )
      // A new outcome of the answered item removes its question.
      await endTurn(h, { result: result([noFix('PRRT_1')]) })
      expect(h.pr().questions).toEqual({})
      expect(h.pr().held).toEqual([])
    },
  )

  it(
    'with Handle comments automatically off, a round that ' +
      'an answer starts handles only the answered item',
    async () => {
      const hub = hubOf({
        reviews: [
          { at: ASKED - 9, body: '', by: COPILOT, id: 'PRR_c1', state: 'COMMENTED' },
          { at: ASKED - 5, body: '', by: COPILOT, id: 'PRR_c2', state: 'COMMENTED' },
        ],
        threads: [
          thread('PRRT_1'),
          thread('PRRT_2', RAVI, ASKED + 1),
          thread('PRRT_cop', COPILOT, ASKED + 2, { review: 'PRR_c2' }),
        ],
      })
      const state = { prs: { [KEY]: { ...emptyPrState(), questions: { PRRT_1: question() } } } }
      const h = make({ autoFix: false, hub, state })
      await ready(h)
      await h.runner.answer(KEY, [{ id: 'PRRT_1', text: 'Use the new name.' }])
      await h.runner.settled()
      expect(roundItems(h)).toEqual(['PRRT_1'])
      await endTurn(h, { result: result([noFix('PRRT_1')]) })
      // Handle Copilot comments takes the later Copilot item, and no other new item.
      await h.runner.handle(KEY, 'copilot')
      await h.runner.settled()
      expect(roundItems(h)).toEqual(['PRRT_cop'])
    },
  )
})

describe('the drop and the restart', () => {
  it(
    'the PR merges during the round: the round stops, ' +
      'the session and the worktree go, nothing is posted',
    async () => {
      const h = make()
      await ready(h)
      await h.rowsNow([row(1)])
      await h.writeResult(result([noFix('PRRT_1')]))
      h.hub.state = 'MERGED'
      await h.poll(pollOf([]))
      expect(h.calls.removes).toEqual([
        { name: 'api-9-request', sessionId: 'sess-1', shortId: short(1) },
      ])
      expect(h.calls.worktreesRemoved).toEqual([9])
      expect(h.pr()).toMatchObject({ outbox: null, request: null, round: null })
      await h.rowsNow([row(1, IDLE)])
      await h.tick(END_SETTLE_MS + PASS_MS)
      expect(h.calls.writes).toEqual([])
      expect(h.calls.pushes).toEqual([])
    },
  )

  it('the PR merges while queued: the entry goes', async () => {
    const h = make({
      state: {
        prs: {
          [KEY]: {
            ...emptyPrState(),
            handled: { PRRT_0: { at: 1, lastReplyAt: 1 } },
            held: ['PRRT_1'],
            lastError: 'An old error.',
            questions: { PRRT_2: question() },
            rerequested: { ravi: HEAD },
          },
        },
      },
    })
    // The clone is not trusted, so the entry waits.
    await h.preClone()
    h.runner.start()
    await h.runner.settled()
    await h.poll(pollOf([polled(h.hub, { truncatedThreads: true, updatedAt: ASKED })]))
    expect(h.state().queue).toEqual([{ at: Date.now(), key: KEY, kind: 'request' }])
    expect(h.runner.mine(KEY).claude).toBe('trust-needed')
    await h.poll(pollOf([]))
    expect(h.state().queue).toEqual([])
    expect(h.pr()).toMatchObject({
      handled: { PRRT_0: { at: 1, lastReplyAt: 1 } },
      held: [],
      lastError: null,
      questions: {},
      rerequested: { ravi: HEAD },
    })
  })

  it('a partial poll drops nothing', async () => {
    const h = make()
    await ready(h)
    expect(h.pr().round?.phase).toBe('running')
    for (const over of [{ mineHasMore: true }, { errors: ['a timeout'] }]) {
      await h.poll(pollOf([], over))
      expect(h.calls.removes).toEqual([])
      expect(h.pr().round?.phase).toBe('running')
    }
  })

  it('a restart in the posting phase goes on and sends no reply twice', async () => {
    const h = make({ hub: hubOf({ threads: [thread('PRRT_1'), thread('PRRT_2')] }) })
    // Bifrost quits while the second reply is on its way, after GitHub saved it.
    const quit = gate()
    let replies = 0
    h.fake.hold = w => {
      if (w.op !== 'ReplyToThread' || ++replies < 2) return null
      quit.reach()
      return quit.wait
    }
    await ready(h)
    void endTurn(h, { result: result([noFix('PRRT_1'), noFix('PRRT_2')]) })
    await quit.reached
    expect(h.ops('ReplyToThread').map(w => w.vars.thread)).toEqual(['PRRT_1', 'PRRT_2'])
    expect(h.ops('ResolveThread').map(w => w.vars.thread)).toEqual(['PRRT_1'])
    const saved = structuredClone(h.state())
    expect(saved.prs[KEY]?.round?.phase).toBe('posting')
    h.runner.stop()

    const g = make({ hub: h.hub, id: 'b', state: saved })
    g.runner.start()
    await g.runner.settled()
    // No post before a poll gives the viewer and shows the PR as open.
    expect(g.calls.gh).toEqual([])
    await g.poll(pollOf([], { mineHasMore: true }))
    expect(g.calls.gh).toEqual([])
    expect(g.runner.mine(KEY).claude).toBe('fixing')
    await g.poll()
    expect(g.ops('ReplyToThread')).toEqual([])
    expect(g.ops('ResolveThread').map(w => w.vars.thread)).toEqual(['PRRT_2'])
    expect(g.pr()).toMatchObject({ lastError: null, outbox: null, round: null })
    expect(Object.keys(g.pr().handled).sort()).toEqual(['PRRT_1', 'PRRT_2'])
  })

  it('removeClones drops an outbox whose push was not sent and holds its items', async () => {
    const outbox = (posts: Post[]): Outbox => ({
      headSha: HEAD,
      mergeBase: BASE,
      posts,
      seen: { PRRT_1: ASKED, PRRT_2: ASKED },
      startedAt: ASKED,
    })
    const unsent = outbox([
      { id: 'commit', kind: 'commit', message: 'fix: x', paths: ['src/a.ts'], state: 'todo' },
      { id: 'push', kind: 'push', state: 'todo' },
      { id: 'reply:PRRT_1', itemId: 'PRRT_1', kind: 'reply', state: 'todo', text: null },
      { id: 'reply:PRRT_2', itemId: 'PRRT_2', kind: 'reply', state: 'todo', text: 'No.' },
    ])
    const sent = outbox([
      {
        id: 'commit',
        kind: 'commit',
        message: 'fix: x',
        paths: ['src/a.ts'],
        sha: FIX,
        state: 'done',
      },
      { id: 'push', kind: 'push', sha: FIX, state: 'done' },
      { id: 'reply:PRRT_1', itemId: 'PRRT_1', kind: 'reply', state: 'todo', text: null },
    ])
    const other = 'acme/api#10'
    const h = make({
      state: {
        prs: {
          [KEY]: { ...emptyPrState(), held: ['PRRT_0'], outbox: unsent },
          [other]: { ...emptyPrState(), outbox: sent },
        },
      },
    })
    await h.runner.removeClones()
    expect(h.pr()).toMatchObject({
      held: ['PRRT_0', 'PRRT_1', 'PRRT_2'],
      lastError: null,
      outbox: null,
    })
    // The outbox whose push went stays, and its row tells the user to choose Try again.
    expect(h.state().prs[other]?.outbox).toEqual(sent)
    expect(h.state().prs[other]?.lastError).toBe(REASON_REPLIES_WAITING)
    expect(REASON_REPLIES_WAITING).toBe(
      'Bifrost removed its copies of your repositories before it posted every reply. ' +
        'Choose Try again to post the rest.',
    )
  })
})

describe('the runner methods', () => {
  it('review and request rounds share reviewsMaxSessions', async () => {
    const h = make({ max: 1 })
    await h.preClone('acme', 'web')
    await h.preClone()
    await h.trust(h.clone, h.cloneOf('acme', 'web'))
    h.runner.start()
    await h.runner.settled()
    await h.poll(pollOf([polled(h.hub)], { toReview: [toReview(7)] }))
    expect(h.pr().round?.kind).toBe('request')
    await h.runner.review('acme/web#7')
    await h.runner.settled()
    // The review waits for the slot of the request round.
    expect(h.runner.session('acme/web#7')).toBe('queued')
    expect(h.calls.gh).not.toContain('ReviewContext')
    // A request round that posts has no session that works, so the review round starts.
    const posting = gate()
    h.fake.hold = w => {
      if (w.op !== 'ReplyToThread') return null
      posting.reach()
      return posting.wait
    }
    const ended = endTurn(h, { result: result([noFix('PRRT_1')]) })
    await posting.reached
    expect(h.pr().round?.phase).toBe('posting')
    h.runner.onRows([])
    for (let i = 0; i < 200 && !h.calls.gh.includes('ReviewContext'); i++) await Promise.resolve()
    expect(h.calls.gh).toContain('ReviewContext')
    posting.open()
    await ended
    expect(h.pr()).toMatchObject({ lastError: null, outbox: null, round: null })
  })

  it(
    'Try again with an outbox sends only the rest, ' +
      'and with no outbox it handles the held items',
    async () => {
      const h = make({ max: 1 })
      let resolves = 0
      h.fake.writeFails = w =>
        w.op === 'ResolveThread' && resolves++ === 0
          ? { code: 1, stderr: 'gh: Not allowed (HTTP 403)', stdout: '' }
          : undefined
      await ready(h)
      await endTurn(h, { result: result([noFix('PRRT_1')]) })
      // The row gets a fixed text. The line of gh goes only to the Event log.
      expect(h.pr().lastError).toBe(reasonPostsStopped(1, 3, REASON_WRITE_FAILED))
      expect(h.calls.events).toEqual([
        `Reviews: GitHub stopped the updates of ${KEY}. It said: gh: Not allowed (HTTP 403)`,
      ])
      // A busy slot does not stop the posts of Try again, and no session starts.
      h.hub.threads.push(thread('PRRT_x', RAVI, Date.now()))
      h.settings.reviewsMaxSessions = 0
      await h.runner.retry(KEY)
      await h.runner.settled()
      expect(h.ops('ReplyToThread')).toHaveLength(1)
      expect(h.ops('ResolveThread')).toHaveLength(2)
      expect(h.calls.starts).toHaveLength(1)
      expect(h.pr()).toMatchObject({ lastError: null, outbox: null, round: null })
      // With no outbox: a failed round holds its item, and Try again handles it.
      h.settings.reviewsMaxSessions = 1
      await h.poll()
      expect(roundItems(h)).toEqual(['PRRT_x'])
      await endTurn(h, { n: 2 })
      expect(h.pr()).toMatchObject({ held: ['PRRT_x'], lastError: REASON_FIX_NO_RESULT })
      await h.runner.retry(KEY)
      await h.runner.settled()
      expect(h.calls.starts).toHaveLength(3)
      expect(roundItems(h)).toEqual(['PRRT_x'])
    },
  )

  it('a failed read after the waiting updates says that Bifrost sent them', async () => {
    const h = make()
    let resolves = 0
    h.fake.writeFails = w =>
      w.op === 'ResolveThread' && resolves++ === 0
        ? { code: 1, stderr: 'gh: Not allowed (HTTP 403)', stdout: '' }
        : undefined
    await ready(h)
    await endTurn(h, { result: result([noFix('PRRT_1')]) })
    expect(h.pr().outbox).not.toBeNull()
    // Ruling P6: Handle now sends the waiting updates first. Only the read after them fails.
    h.fake.contextFails = () => h.pr().outbox === null
    await h.runner.handle(KEY, 'all')
    await h.runner.settled()
    expect(h.ops('ResolveThread')).toHaveLength(2)
    expect(h.pr()).toMatchObject({ lastError: REASON_READ_AFTER_POSTS, outbox: null, round: null })
    expect(h.calls.events.filter(line => line.includes("couldn't load"))).toEqual([
      `Reviews: GitHub couldn't load ${KEY}. It said: gh: Server Error (HTTP 502)`,
    ])
    expect(h.calls.starts).toHaveLength(1)
  })

  it('mine(key) gives each Claude state', async () => {
    const pr = (over: Partial<PrState>) => ({ [KEY]: { ...emptyPrState(), ...over } })
    const running = {
      at: 1,
      headSha: HEAD,
      items: { PRRT_1: 1, PRRT_2: 2 },
      kind: 'request' as const,
      phase: 'running' as const,
      sessionId: 'sess-1',
      shortId: short(1),
      startedAt: Date.now(),
      stoppedByUser: false,
    }
    const cases: [string, Partial<ReviewsState>, string, string | null][] = [
      ['waiting', {}, 'waiting', null],
      ['fixing', { prs: pr({ round: running }) }, 'fixing', null],
      ['queued', { queue: [{ at: 1, key: KEY, kind: 'request' }] }, 'queued', null],
      [
        'needs-you',
        { prs: pr({ lastError: 'Old.', questions: { PRRT_1: question() } }) },
        'needs-you',
        null,
      ],
      ['error', { prs: pr({ lastError: 'It failed.' }) }, 'error', 'It failed.'],
    ]
    for (const [id, state, claude, error] of cases) {
      const h = make({ id, state })
      await h.preClone()
      await h.trust(h.clone)
      h.runner.start()
      await h.runner.settled()
      h.setPoll(pollOf([polled(h.hub)]))
      expect(h.runner.mine(KEY), id).toMatchObject({ claude, error })
    }
    const f = make({
      id: 'fixing2',
      state: { prs: pr({ request: { name: 'n', sessionId: 'sess-1' }, round: running }) },
    })
    f.setRows([row(1)])
    expect(f.runner.mine(KEY)).toEqual({
      claude: 'fixing',
      error: null,
      fixing: 2,
      sessionId: 'sess-1',
    })
    f.setRows([row(1, { state: 'parked', status: 'stopped' })])
    expect(f.runner.mine(KEY).sessionId).toBeNull()
    // trust-needed: the clone is not trusted.
    const t = make({ id: 'trust', state: { queue: [{ at: 1, key: KEY, kind: 'request' }] } })
    await t.preClone()
    expect(t.runner.mine(KEY).claude).toBe('trust-needed')
    // cloning: no clone, the clone runs, and the entry waits for a slot.
    const c = make({ id: 'cloning', max: 0 })
    let open = (): void => {}
    c.fake.cloneGate = new Promise<void>(resolve => {
      open = resolve
    })
    c.runner.start()
    await c.runner.settled()
    const data = pollOf([polled(c.hub)])
    c.setPoll(data)
    c.runner.afterPoll(data)
    await vi.advanceTimersByTimeAsync(0)
    expect(c.runner.mine(KEY).claude).toBe('cloning')
    open()
    await c.runner.settled()
  })

  it('cancel removes a request entry, and stopSession stops a request round', async () => {
    const h = make({ autoFix: false, max: 0 })
    await ready(h)
    await h.runner.handle(KEY, 'all')
    await h.runner.settled()
    expect(h.runner.mine(KEY).claude).toBe('queued')
    await expect(h.runner.handle(KEY, 'all')).rejects.toThrow(REFUSED_NOT_HANDLEABLE)
    await h.runner.cancel(KEY)
    expect(h.state().queue).toEqual([])
    expect(h.pr().handleOlder).toBe(false)
    // A running request round: cancel refuses, and stopSession stops it.
    h.settings.reviewsMaxSessions = 1
    await h.runner.handle(KEY, 'all')
    await h.runner.settled()
    expect(h.pr().round?.phase).toBe('running')
    await expect(h.runner.cancel(KEY)).rejects.toThrow(REFUSED_NOT_HANDLEABLE)
    await h.rowsNow([row(1)])
    await h.runner.stopSession(KEY)
    expect(h.calls.stops).toEqual([short(1)])
    expect(h.pr().round?.stoppedByUser).toBe(true)
    await h.rowsNow([row(1, IDLE)])
    await h.tick(END_SETTLE_MS + PASS_MS)
    expect(h.pr()).toMatchObject({ lastError: REASON_FIX_STOPPED, round: null })
    // With no round, stopSession stops the request session of the PR.
    await h.runner.stopSession(KEY)
    expect(h.calls.stops).toEqual([short(1), short(1)])
  })

  it('watchTurnedOn sets fixFrom to now after an old fixFrom, and keeps the queue', async () => {
    const h = make({
      state: { fixFrom: 5, queue: [{ at: 1, key: KEY, kind: 'request' }] },
    })
    await h.runner.watchTurnedOn()
    expect(h.state().fixFrom).toBe(Date.now())
    expect(h.state().queue).toEqual([{ at: 1, key: KEY, kind: 'request' }])
  })

  it(
    'autoFixChanged(true) saves fixFrom, and ' +
      'autoFixChanged(false) removes the request entries',
    async () => {
      const h = make({
        state: {
          fixFrom: null,
          queue: [
            { at: 1, key: KEY, kind: 'request' },
            { at: 2, key: 'acme/web#7', kind: 'review' },
          ],
        },
      })
      await h.runner.autoFixChanged(true)
      expect(h.state().fixFrom).toBe(Date.now())
      await h.runner.autoFixChanged(false)
      expect(h.state().queue).toEqual([{ at: 2, key: 'acme/web#7', kind: 'review' }])
      // A running round goes on.
      const g = make({ id: 'b' })
      await ready(g)
      expect(g.pr().round?.phase).toBe('running')
      g.settings.reviewsAutoFix = false
      await g.runner.autoFixChanged(false)
      await endTurn(g, { result: result([noFix('PRRT_1')]) })
      expect(g.ops('ReplyToThread')).toHaveLength(1)
    },
  )

  it('autoFixChanged(false) also clears the clicks of the request entries that go', async () => {
    const other = 'acme/api#10'
    const clicked = { ...emptyPrState(), handleCopilot: true, handleOlder: true }
    const h = make({
      state: {
        prs: { [KEY]: clicked, [other]: clicked },
        queue: [{ at: 1, key: KEY, kind: 'request' }],
      },
    })
    await h.runner.autoFixChanged(false)
    expect(h.state().queue).toEqual([])
    expect(h.pr()).toMatchObject({ handleCopilot: false, handleOlder: false })
    // A PR with no entry keeps its clicks.
    expect(h.state().prs[other]).toMatchObject({ handleCopilot: true, handleOlder: true })
  })
})
