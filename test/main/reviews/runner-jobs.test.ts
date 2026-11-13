// The shared runner core with two fake jobs. The core picks the job of a queue entry by its kind,
// and the job of a round by the kind of the round. The jobs share the slots.

import { mkdtemp, realpath, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { Gh } from '../../../src/main/reviews/gh'
import type { Job, JobContext, Recovery } from '../../../src/main/reviews/jobs'
import type { PollData, PrData } from '../../../src/main/reviews/pr-data'
import { clonePath } from '../../../src/main/reviews/repo-paths'
import type { RepoStore } from '../../../src/main/reviews/repo-store'
import type { ReviewSessions } from '../../../src/main/reviews/review-session'
import {
  createReviewRunner,
  END_SETTLE_MS,
  IDLE_STOP_MS,
  PASS_MS,
} from '../../../src/main/reviews/rounds'
import {
  type ActiveRound,
  EMPTY_STATE,
  emptyPrState,
  type JobKind,
  type PrState,
  type ReviewsState,
  type SessionRef,
} from '../../../src/main/reviews/state'
import type { ReviewsStateStore } from '../../../src/main/reviews/state-store'
import { prKey } from '../../../src/shared/reviews'
import type { SessionRow } from '../../../src/shared/types'

const T0 = new Date('2026-11-12T10:00:00Z')
const VIEWER = 'me'
const key = (n: number): string => `acme/web#${n}`
const short = (n: number): string => n.toString(16).padStart(8, '0')

let dir: string

// stats counts the saves. With failNext, the next save fails.
interface StoreStats {
  changes: number
  failNext: boolean
}

function memoryStore(initial: ReviewsState, stats: StoreStats): ReviewsStateStore {
  let current = structuredClone(initial)
  let queue: Promise<unknown> = Promise.resolve()
  return {
    change(fn) {
      const run = queue.then(() => {
        if (stats.failNext) {
          stats.failNext = false
          throw new Error('the disk is full')
        }
        stats.changes++
        current = fn(current)
        return current
      })
      queue = run.catch(() => {})
      return run
    },
    get: () => current,
  }
}

function pr(number: number, repo = 'web'): PrData {
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
    headSha: 'a'.repeat(40),
    isCrossRepository: false,
    isDraft: false,
    key: prKey('acme', repo, number),
    number,
    owner: 'acme',
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
    url: `https://github.com/acme/${repo}/pull/${number}`,
    viewerPendingReviewId: null,
  }
}

function pollOf(toReview: PrData[] = []): PollData {
  return {
    errors: [],
    mine: [],
    mineHasMore: false,
    rateLimit: null,
    toReview,
    toReviewHasMore: false,
    viewer: VIEWER,
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

function round(over: Partial<ActiveRound> = {}): ActiveRound {
  return {
    at: 1,
    headSha: null,
    phase: 'preparing',
    sessionId: null,
    shortId: null,
    startedAt: T0.getTime(),
    stoppedByUser: false,
    ...over,
  }
}

const prState = (over: Partial<PrState>): PrState => ({ ...emptyPrState(), ...over })

const ref = (n: number, kind: JobKind): SessionRef => ({
  name: `web-${n}-${kind}`,
  sessionId: `sess-${n}`,
  shortId: short(n),
})

// A fake job. It records each call. Its round stays until the test ends it, or until its end.
interface FakeJob extends Job {
  ctx: JobContext | null
  // The drop of these keys throws.
  dropFails: Set<string>
  open: ReadonlySet<string> | null
  runs: string[]
  recovered: string[]
  resumed: string[]
  // The resume of these keys throws.
  resumeFails: Set<string>
  tokens: Map<string, number>
}

function fakeJob(kind: JobKind, events: string[]): FakeJob {
  const job: FakeJob = {
    async afterPoll(ctx) {
      job.ctx = ctx
      events.push(`afterPoll ${kind}`)
    },
    ctx: null,
    async drop(ctx, k) {
      events.push(`drop ${kind} ${k}`)
      if (job.dropFails.has(k)) throw new Error(`the drop of ${k} failed`)
      ctx.forget(k)
      await ctx.store.change(s => {
        const p = s.prs[k]
        return {
          ...s,
          prs: p === undefined ? s.prs : { ...s.prs, [k]: { ...p, [kind]: null, round: null } },
          queue: s.queue.filter(e => !(e.key === k && e.kind === kind)),
        }
      })
    },
    dropFails: new Set(),
    async end(ctx, k, token, check) {
      events.push(`end ${kind} ${k} ${check}`)
      await ctx.succeed(k, token, p => p)
    },
    kind,
    open: null,
    openKeys: () => job.open,
    recover(ctx, k, r): Recovery {
      job.ctx = ctx
      job.recovered.push(k)
      if (r.stoppedByUser) return { fail: `${kind} stopped` }
      if (r.phase === 'preparing') return 'queue'
      return r.phase === 'running' ? 'wait' : 'resume'
    },
    recovered: [],
    ref: kind,
    async resume(ctx, k, token) {
      job.ctx = ctx
      job.tokens.set(k, token)
      job.resumed.push(k)
      events.push(`resume ${kind} ${k}`)
      if (job.resumeFails.has(k)) throw new Error(`the resume of ${k} failed`)
    },
    resumed: [],
    resumeFails: new Set(),
    async run(ctx, k, token) {
      job.ctx = ctx
      job.tokens.set(k, token)
      job.runs.push(k)
      events.push(`run ${kind} ${k}`)
    },
    runs: [],
    tokens: new Map(),
  }
  return job
}

function ctxOf(job: FakeJob): JobContext {
  if (job.ctx === null) throw new Error(`the ${job.kind} job got no context`)
  return job.ctx
}

interface Options {
  state?: Partial<ReviewsState>
  max?: number
  // Only the review job.
  reviewOnly?: boolean
  // The first save fails.
  failFirstSave?: boolean
}

function make(o: Options = {}) {
  const home = join(dir, 'home')
  const events: string[] = []
  const review = fakeJob('review', events)
  const request = fakeJob('request', events)
  const stats: StoreStats = { changes: 0, failNext: o.failFirstSave ?? false }
  const store = memoryStore({ ...EMPTY_STATE, setUpAt: 1, ...o.state }, stats)
  const calls = {
    clones: [] as string[],
    logs: [] as string[],
    removeAll: 0,
    removes: [] as { shortId: string; sessionId: string; name: string }[],
    stops: [] as string[],
  }
  const fake = { cloneGate: null as Promise<void> | null }
  let rows: SessionRow[] = []
  let viewer: string | null = null
  // The fake has no clone, so each entry is ready.
  const repos = {
    cloneOf: () => null,
    async ensureClone(owner: string, repo: string) {
      calls.clones.push(`${owner}/${repo}`)
      if (fake.cloneGate) await fake.cloneGate
      return clonePath(home, owner, repo)
    },
    async removeAll() {
      calls.removeAll++
    },
    async removeWorktree() {},
  } as unknown as RepoStore
  const gh: Gh = { run: async () => ({ code: 1, stderr: 'no gh in this test', stdout: '' }) }
  const sessions: ReviewSessions = {
    async remove(r) {
      calls.removes.push(r)
    },
    async start() {
      throw new Error('no start in this test')
    },
    async stop(shortId) {
      calls.stops.push(shortId)
    },
  }
  const runner = createReviewRunner({
    bifrostHome: home,
    changed: () => {},
    claudeJson: join(dir, 'claude.json'),
    claudeSettings: join(dir, 'settings.json'),
    eventNotice: () => {},
    gh,
    jobs: o.reviewOnly ? [review] : [review, request],
    log: m => calls.logs.push(m),
    minePr: () => null,
    notify: () => {},
    now: () => Date.now(),
    repos,
    requestPoll: () => {},
    rows: () => rows,
    sessions,
    settings: () => ({
      reviewsAutoFix: false,
      reviewsIgnore: [],
      reviewsMaxSessions: o.max ?? 3,
      reviewsRequestModel: '',
      reviewsReviewModel: '',
      reviewsSignedCommits: false,
    }),
    skillsDir: join(dir, 'skills'),
    store,
    testHome: false,
    toReviewPr: () => null,
    viewer: () => viewer,
  })
  return {
    calls,
    events,
    fake,
    async poll(data: PollData = pollOf()) {
      viewer = data.viewer
      runner.afterPoll(data)
      await runner.settled()
    },
    pr: (n: number) => store.get().prs[key(n)],
    request,
    review,
    async rowsNow(next: SessionRow[]) {
      rows = next
      runner.onRows(next)
      await runner.settled()
    },
    runner,
    setRows(next: SessionRow[]) {
      rows = next
    },
    async start() {
      runner.start()
      await runner.settled()
    },
    state: () => store.get(),
    stats,
    // The fake job ends its round well.
    async succeed(job: FakeJob, k: string) {
      const token = job.tokens.get(k)
      if (token === undefined) throw new Error(`no token for ${k}`)
      await ctxOf(job).succeed(k, token, p => p)
      await runner.settled()
    },
    async tick(ms: number) {
      await vi.advanceTimersByTimeAsync(ms)
      await runner.settled()
    },
  }
}

beforeEach(async () => {
  vi.useFakeTimers()
  vi.setSystemTime(T0)
  dir = await realpath(await mkdtemp(join(tmpdir(), 'bifrost-runner-jobs-')))
})

afterEach(async () => {
  vi.useRealTimers()
  await rm(dir, { force: true, recursive: true })
})

describe('the shared runner core', () => {
  it('rounds of two kinds share reviewsMaxSessions', async () => {
    const h = make({
      max: 2,
      state: {
        queue: [
          { at: 1, key: key(1), kind: 'review' },
          { at: 2, key: key(2), kind: 'request' },
          { at: 3, key: key(3), kind: 'review' },
          { at: 4, key: key(4), kind: 'request' },
        ],
      },
    })
    await h.start()
    await h.poll()
    expect(h.review.runs).toEqual([key(1)])
    expect(h.request.runs).toEqual([key(2)])
    expect(h.pr(1)?.round).toMatchObject({ kind: 'review', phase: 'preparing' })
    expect(h.pr(2)?.round).toMatchObject({ kind: 'request', phase: 'preparing' })
    expect(h.state().queue.map(e => e.key)).toEqual([key(3), key(4)])
    // The end of the request round frees one slot. The oldest entry starts.
    await h.succeed(h.request, key(2))
    expect(h.pr(2)?.round).toBeNull()
    expect(h.review.runs).toEqual([key(1), key(3)])
    expect(h.request.runs).toEqual([key(2)])
    expect(h.state().queue.map(e => e.key)).toEqual([key(4)])
    // The end of a review round lets the request entry start.
    await h.succeed(h.review, key(1))
    expect(h.request.runs).toEqual([key(2), key(4)])
    expect(h.state().queue).toEqual([])
  })

  it('a key with a round is not ready for a second round', async () => {
    const running = round({
      kind: 'request',
      phase: 'running',
      sessionId: 'sess-1',
      shortId: short(1),
    })
    const h = make({
      state: {
        prs: { [key(1)]: prState({ round: running }) },
        queue: [
          { at: 1, key: key(1), kind: 'review' },
          { at: 2, key: key(2), kind: 'review' },
        ],
      },
    })
    await h.start()
    await h.poll()
    // The entry of the key waits and blocks nothing.
    expect(h.review.runs).toEqual([key(2)])
    expect(h.state().queue).toEqual([{ at: 1, key: key(1), kind: 'review' }])
    // The request job ends its round at the end check. Then the entry starts.
    await h.rowsNow([row(1)])
    await h.rowsNow([row(1, IDLE)])
    await h.tick(END_SETTLE_MS + PASS_MS)
    expect(h.events).toContain(`end request ${key(1)} ended`)
    expect(h.pr(1)?.round).toMatchObject({ kind: 'review', phase: 'preparing' })
    expect(h.review.runs).toEqual([key(2), key(1)])
    expect(h.state().queue).toEqual([])
  })

  it('afterPoll drops only the keys of a job whose list is complete', async () => {
    const h = make({
      state: {
        prs: {
          [key(1)]: prState({ request: ref(1, 'request') }),
          [key(2)]: prState({
            round: round({ kind: 'request', phase: 'running', sessionId: 'sess-2' }),
          }),
          [key(3)]: prState({
            review: ref(3, 'review'),
            round: round({ phase: 'running', sessionId: 'sess-3', shortId: short(3) }),
          }),
        },
        queue: [
          { at: 1, key: key(4), kind: 'request' },
          { at: 2, key: key(5), kind: 'review' },
        ],
      },
    })
    await h.start()
    // Only the request list is complete. The drops come first, then the hooks, then the pump.
    h.request.open = new Set([key(2)])
    h.events.length = 0
    await h.poll()
    expect(h.events).toEqual([
      `drop request ${key(1)}`,
      `drop request ${key(4)}`,
      'afterPoll review',
      'afterPoll request',
      `run review ${key(5)}`,
    ])
    expect(h.pr(1)?.request).toBeNull()
    expect(h.pr(2)?.round?.kind).toBe('request')
    expect(h.pr(3)?.round).not.toBeNull()
    // Now only the review list is complete.
    h.request.open = null
    h.review.open = new Set([key(5)])
    h.events.length = 0
    await h.poll()
    expect(h.events).toEqual([`drop review ${key(3)}`, 'afterPoll review', 'afterPoll request'])
    expect(h.pr(3)).toMatchObject({ review: null, round: null })
    expect(h.pr(2)?.round?.kind).toBe('request')
    expect(h.pr(5)?.round?.kind).toBe('review')
  })

  it('start recovers each round by its kind', async () => {
    const h = make({
      state: {
        prs: {
          // A round from R2 has no kind: it is a review round.
          [key(1)]: prState({ round: round({ at: 100 }) }),
          [key(2)]: prState({ round: round({ kind: 'request', phase: 'posting' }) }),
          [key(3)]: prState({ round: round({ kind: 'request', stoppedByUser: true }) }),
          [key(4)]: prState({
            round: round({ kind: 'review', phase: 'running', sessionId: 'sess-4' }),
          }),
        },
      },
    })
    await h.start()
    expect(h.review.recovered).toEqual([key(1), key(4)])
    expect(h.request.recovered).toEqual([key(2), key(3)])
    // queue: the entry goes back with its first time and the kind of its job.
    expect(h.pr(1)?.round).toBeNull()
    expect(h.state().queue).toEqual([{ at: 100, key: key(1), kind: 'review' }])
    // fail: the reason of the job.
    expect(h.pr(3)).toMatchObject({ lastError: 'request stopped', round: null })
    // resume: the job goes on with a live token, after a poll that lists the PR.
    expect(h.request.resumed).toEqual([])
    await h.poll(pollOf([pr(2)]))
    expect(h.request.resumed).toEqual([key(2)])
    expect(h.pr(2)?.round?.phase).toBe('posting')
    await h.succeed(h.request, key(2))
    expect(h.pr(2)?.round).toBeNull()
    // wait: the end check of the job ends the round.
    await h.poll()
    expect(h.review.runs).toEqual([key(1)])
    await h.rowsNow([row(4)])
    await h.rowsNow([row(4, IDLE)])
    await h.tick(END_SETTLE_MS + PASS_MS)
    expect(h.events).toContain(`end review ${key(4)} ended`)
    expect(h.pr(4)?.round).toBeNull()
    expect(h.request.runs).toEqual([])
  })

  it(
    'a resume waits for a poll with the viewer that ' +
      'lists the PR, and a throw releases the round',
    async () => {
      const posting = round({ kind: 'request', phase: 'posting' })
      const h = make({ state: { prs: { [key(1)]: prState({ round: posting }) } } })
      h.request.resumeFails.add(key(1))
      await h.start()
      expect(h.request.resumed).toEqual([])
      // A poll that does not list the PR, for example a partial one, does not start it.
      await h.poll(pollOf([pr(2)]))
      expect(h.request.resumed).toEqual([])
      await h.poll(pollOf([pr(1)]))
      expect(h.request.resumed).toEqual([key(1)])
      expect(h.calls.logs.some(line => line.includes(`the resume of ${key(1)} failed`))).toBe(true)
      // A later poll does not start it again, and the round no longer blocks removeClones.
      await h.poll(pollOf([pr(1)]))
      expect(h.request.resumed).toEqual([key(1)])
      h.runner.stop()
      await h.runner.removeClones()
      expect(h.pr(1)?.round).toBeNull()
    },
  )

  it('a queue entry with no job starts nothing and blocks nothing', async () => {
    const h = make({
      max: 1,
      reviewOnly: true,
      state: {
        queue: [
          { at: 1, key: key(1), kind: 'request' },
          { at: 2, key: key(2), kind: 'review' },
        ],
      },
    })
    h.review.open = new Set([key(2)])
    await h.start()
    await h.poll()
    expect(h.review.runs).toEqual([key(2)])
    expect(h.request.runs).toEqual([])
    // The entry stays. No job drops it.
    expect(h.state().queue).toEqual([{ at: 1, key: key(1), kind: 'request' }])
    expect(h.pr(1)).toBeUndefined()
  })

  it('the idle stop and removeClones act on request sessions too', async () => {
    const h = make({
      state: {
        prs: {
          [key(1)]: prState({ request: ref(1, 'request') }),
          [key(2)]: prState({ review: ref(2, 'review') }),
        },
      },
    })
    await h.start()
    const since = Date.now()
    h.setRows([row(1, { ...IDLE, lastActivity: since }), row(2, { ...IDLE, lastActivity: since })])
    await h.tick(IDLE_STOP_MS - PASS_MS)
    expect(h.calls.stops).toEqual([])
    await h.tick(2 * PASS_MS)
    expect([...h.calls.stops].sort()).toEqual([short(1), short(2)])
    h.runner.stop()
    await h.runner.removeClones()
    expect(h.calls.removes).toEqual([ref(1, 'request'), ref(2, 'review')])
    expect(h.pr(1)?.request).toBeNull()
    expect(h.pr(2)?.review).toBeNull()
    expect(h.calls.removeAll).toBe(1)
    // A request round with no busy session goes too, while the runner is stopped.
    const g = make({
      state: {
        prs: {
          [key(3)]: prState({
            request: ref(3, 'request'),
            round: round({ kind: 'request', phase: 'running', sessionId: 'sess-3' }),
          }),
        },
      },
    })
    await g.runner.removeClones()
    expect(g.calls.removes).toEqual([ref(3, 'request')])
    expect(g.pr(3)).toMatchObject({ request: null, round: null })
  })

  it('a late request session gets its row and one stop, and sessionOf finds it', async () => {
    const late: SessionRef = { name: 'web-1-request', sessionId: '' }
    const h = make({ state: { prs: { [key(1)]: prState({ request: late }) } } })
    await h.start()
    await h.poll()
    // No new session gets the name of a late session.
    expect(ctxOf(h.review).namesInUse().has('web-1-request')).toBe(true)
    expect(h.runner.sessionOf(key(1))).toBeNull()
    await h.rowsNow([row(1, { ...IDLE, claudeName: 'web-1-request', name: 'web-1-request' })])
    expect(h.pr(1)?.request).toEqual({
      name: 'web-1-request',
      sessionId: 'sess-1',
      shortId: short(1),
    })
    expect(h.calls.stops).toEqual([short(1)])
    expect(h.runner.sessionOf(key(1))).toBe('sess-1')
  })

  it('isCloning is true while the clone order holds the repository or its clone runs', async () => {
    const h = make()
    let open = (): void => {}
    h.fake.cloneGate = new Promise<void>(resolve => {
      open = resolve
    })
    await h.start()
    h.runner.afterPoll(pollOf([pr(1, 'web'), pr(2, 'api')]))
    await vi.advanceTimersByTimeAsync(0)
    const ctx = ctxOf(h.review)
    expect(h.calls.clones).toEqual(['acme/web'])
    expect(ctx.isCloning('acme/web')).toBe(true)
    expect(ctx.isCloning('acme/api')).toBe(true)
    expect(ctx.isCloning('acme/other')).toBe(false)
    open()
    await h.runner.settled()
    expect(h.calls.clones).toEqual(['acme/web', 'acme/api'])
    expect(ctx.isCloning('acme/web')).toBe(false)
    expect(ctx.isCloning('acme/api')).toBe(false)
  })

  it('the start saves nothing when each saved round is running', async () => {
    const h = make({
      state: {
        prs: {
          [key(1)]: prState({ round: round({ phase: 'running', sessionId: 'sess-1' }) }),
          [key(2)]: prState({
            round: round({ kind: 'request', phase: 'running', sessionId: 'sess-2' }),
          }),
        },
      },
    })
    await h.start()
    expect(h.stats.changes).toBe(0)
    expect(h.review.recovered).toEqual([key(1)])
    expect(h.request.recovered).toEqual([key(2)])
    // Each round has a token, so its end check ends it.
    await h.poll()
    await h.rowsNow([row(1), row(2)])
    await h.rowsNow([row(1, IDLE), row(2, IDLE)])
    await h.tick(END_SETTLE_MS + PASS_MS)
    expect(h.pr(1)?.round).toBeNull()
    expect(h.pr(2)?.round).toBeNull()
  })

  it('a failed save at the start still lets each running round end', async () => {
    const h = make({
      failFirstSave: true,
      state: {
        prs: {
          [key(1)]: prState({ round: round({ at: 100 }) }),
          [key(2)]: prState({
            round: round({ kind: 'request', phase: 'running', sessionId: 'sess-2' }),
          }),
        },
      },
    })
    await h.start()
    expect(h.calls.logs.some(line => line.includes('the disk is full'))).toBe(true)
    // The round to queue stays as it was until the next start.
    expect(h.pr(1)?.round).toMatchObject({ at: 100, phase: 'preparing' })
    expect(h.state().queue).toEqual([])
    await h.poll()
    await h.rowsNow([row(2)])
    await h.rowsNow([row(2, IDLE)])
    await h.tick(END_SETTLE_MS + PASS_MS)
    expect(h.events).toContain(`end request ${key(2)} ended`)
    expect(h.pr(2)?.round).toBeNull()
  })

  it('the start keeps a round with no job as it is', async () => {
    const preparing = round({ at: 100, kind: 'request' })
    const running = round({ kind: 'request', phase: 'running', sessionId: 'sess-2' })
    const h = make({
      reviewOnly: true,
      state: {
        prs: {
          [key(1)]: prState({ round: preparing }),
          [key(2)]: prState({ round: running }),
        },
      },
    })
    await h.start()
    expect(h.stats.changes).toBe(0)
    expect(h.review.recovered).toEqual([])
    expect(h.request.recovered).toEqual([])
    // No end check ends it either.
    await h.poll()
    await h.rowsNow([row(2)])
    await h.rowsNow([row(2, IDLE)])
    await h.tick(END_SETTLE_MS + PASS_MS)
    expect(h.pr(1)).toEqual(prState({ round: preparing }))
    expect(h.pr(2)).toEqual(prState({ round: running }))
    expect(h.state().queue).toEqual([])
    expect(h.events).toEqual(['afterPoll review'])
  })

  const throwing =
    'a drop that throws does not stop the drops of the other job, the hooks or the pump'
  it(throwing, async () => {
    const h = make({
      state: {
        prs: {
          [key(1)]: prState({ review: ref(1, 'review') }),
          [key(2)]: prState({ request: ref(2, 'request') }),
        },
        queue: [{ at: 1, key: key(4), kind: 'request' }],
      },
    })
    h.review.dropFails.add(key(1))
    h.review.open = new Set()
    h.request.open = new Set([key(4)])
    await h.start()
    await h.poll()
    expect(h.events).toEqual([
      `drop review ${key(1)}`,
      `drop request ${key(2)}`,
      'afterPoll review',
      'afterPoll request',
      `run request ${key(4)}`,
    ])
    expect(h.calls.logs.some(line => line.includes(`the drop of ${key(1)} failed`))).toBe(true)
    expect(h.pr(2)?.request).toBeNull()
  })
})
