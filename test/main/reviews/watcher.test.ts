import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'
import type { ExecResult } from '../../../src/main/claude/cli'
import type { HealthEvents } from '../../../src/main/performance/health-log'
import type { Gh } from '../../../src/main/reviews/gh'
import { pollArgs } from '../../../src/main/reviews/query'
import { EMPTY_STATE, type ReviewsState } from '../../../src/main/reviews/state'
import type { ReviewsStateStore } from '../../../src/main/reviews/state-store'
import {
  checkPrKey,
  createReviewsWatcher,
  POLL_DEADLINE_MS,
  REFRESH_GAP_MS,
  REFUSED_REVIEWS_OFF,
  REFUSED_UNKNOWN_PR,
  type RequestNotice,
  type ReviewsWatcher,
  requestNotice,
  requestNotices,
  urlToOpen,
  whileOn,
} from '../../../src/main/reviews/watcher'
import {
  EMPTY_REVIEWS,
  REASON_GH_FAILED,
  REASON_GH_LOGGED_OUT,
  REASON_GH_MISSING,
  REASON_GH_TIMEOUT,
  type ReviewsSnapshot,
  type ToReviewRow,
} from '../../../src/shared/reviews'

const MIN = 60_000
const VIEWER = 'dev-user'

// One PR of a fake GraphQL answer. A To review PR is a direct request to the viewer.
interface FakePr {
  number: number
  repo?: string
  title?: string
  author?: string
  url?: string
  team?: boolean
  // The ID of one top-level comment of a trusted human. Only for a My PR.
  comment?: string
  // The time of the request event for the viewer (ISO). Without it, the request time is the
  // creation time of the PR, which is before the start of each test.
  asked?: string
}

// A request time after the first poll of a test (10:00) and before the second poll (10:02).
const ASKED = '2026-11-09T10:01:00Z'

function prNode(pr: FakePr): Record<string, unknown> {
  const repo = pr.repo ?? 'web'
  return {
    additions: 10,
    author: { login: pr.author ?? 'alice' },
    comments: {
      nodes: pr.comment
        ? [
            {
              author: { __typename: 'User', login: 'erin' },
              authorAssociation: 'MEMBER',
              body: 'Please rename this.',
              createdAt: '2026-11-07T08:00:00Z',
              databaseId: 1,
              id: pr.comment,
            },
          ]
        : [],
    },
    createdAt: '2026-11-01T09:00:00Z',
    deletions: 2,
    isDraft: false,
    number: pr.number,
    pendingReviews: { nodes: [] },
    repository: { name: repo, owner: { login: 'acme' } },
    reviewDecision: null,
    reviewRequests: {
      nodes: [
        {
          requestedReviewer: pr.team
            ? { __typename: 'Team', slug: 'web-team' }
            : { __typename: 'User', login: VIEWER },
        },
      ],
    },
    timelineItems: {
      nodes: pr.asked
        ? [{ createdAt: pr.asked, requestedReviewer: { __typename: 'User', login: VIEWER } }]
        : [],
    },
    title: pr.title ?? `Change ${pr.number}`,
    updatedAt: '2026-11-08T09:00:00Z',
    url: pr.url ?? `https://github.com/acme/${repo}/pull/${pr.number}`,
  }
}

// A good gh answer: the To review list and the My PRs list. more says that GitHub has more
// requests than the first page.
function answer(toReview: FakePr[], mine: FakePr[] = [], more = false): ExecResult {
  const data = {
    mine: { nodes: mine.map(prNode), pageInfo: { hasNextPage: false } },
    toReview: { nodes: toReview.map(prNode), pageInfo: { hasNextPage: more } },
    viewer: { login: VIEWER },
  }
  return { code: 0, stderr: '', stdout: JSON.stringify({ data }) }
}

// A partial answer: gh exits with code 1 when GitHub gives errors next to the data.
function partial(toReview: FakePr[], messages: string[], nulls = 0): ExecResult {
  const good = JSON.parse(answer(toReview).stdout)
  for (let i = 0; i < nulls; i++) good.data.toReview.nodes.push(null)
  good.errors = messages.map(message => ({ message, path: ['toReview', 'nodes', 1] }))
  return { code: 1, stderr: `gh: ${messages[0]}`, stdout: JSON.stringify(good) }
}

const LOGGED_OUT: ExecResult = {
  code: 4,
  stderr: 'To get started with GitHub CLI, please run:  gh auth login',
  stdout: '',
}
const TIMED_OUT: ExecResult = { code: 1, stderr: '', stdout: '', timedOut: true }

function deferred(): { promise: Promise<ExecResult>; resolve(r: ExecResult): void } {
  let resolve: (r: ExecResult) => void = () => {}
  const promise = new Promise<ExecResult>(r => {
    resolve = r
  })
  return { promise, resolve }
}

// A reply is an answer, or a promise for a late answer. The last reply repeats.
type Reply = ExecResult | Promise<ExecResult>

// Freeze the state, so a change that edits the old object throws.
function frozen<T>(value: T): T {
  if (typeof value === 'object' && value !== null) {
    for (const child of Object.values(value)) frozen(child)
    Object.freeze(value)
  }
  return value
}

function memoryStore(initial: ReviewsState) {
  let current = frozen(structuredClone(initial))
  const change = vi.fn(async (fn: (s: ReviewsState) => ReviewsState) => {
    current = frozen(fn(current))
    return current
  })
  const store: ReviewsStateStore = { change, get: () => current }
  return { change, store }
}

function setup(
  opts: {
    replies?: Reply[]
    state?: Partial<ReviewsState>
    settings?: { reviewsIgnore?: string[]; reviewsPollMinutes?: number }
    health?: Pick<HealthEvents, 'poll' | 'stopped'>
  } = {},
) {
  const replies = [...(opts.replies ?? [answer([])])]
  let last = replies[0] as Reply
  const run = vi.fn<Gh['run']>(async () => {
    const next = replies.shift()
    if (next !== undefined) last = next
    return last
  })
  const { change, store } = memoryStore({ ...structuredClone(EMPTY_STATE), ...opts.state })
  const settings = {
    reviewsIgnore: [] as string[],
    reviewsPauseMinutes: 60,
    reviewsPollMinutes: 2,
    reviewsTeamRequests: true,
    ...opts.settings,
  }
  const emitted: ReviewsSnapshot[] = []
  const notified: RequestNotice[] = []
  const logs: string[] = []
  const watcher = createReviewsWatcher({
    emit: s => emitted.push(s),
    gh: { run },
    health: opts.health,
    log: m => logs.push(m),
    notify: notice => notified.push(notice),
    now: () => Date.now(),
    settings: () => settings,
    store,
  })
  return { change, emitted, logs, notified, replies, run, settings, store, watcher }
}

function row(watcher: ReviewsWatcher, key: string): ToReviewRow | undefined {
  return watcher.current().toReview.find(r => r.key === key)
}

const K101 = 'acme/web#101'
const K102 = 'acme/web#102'
const K103 = 'acme/web#103'
const K104 = 'acme/web#104'

beforeEach(() => {
  vi.useFakeTimers()
  vi.setSystemTime(new Date('2026-11-09T10:00:00Z'))
})
afterEach(() => {
  vi.useRealTimers()
})

describe('createReviewsWatcher', () => {
  test('the first poll writes the baseline and nothing flashes', async () => {
    const t = setup({
      replies: [answer([{ number: 101 }, { number: 102 }], [{ comment: 'C_1', number: 90 }])],
    })
    t.watcher.start()
    expect(t.emitted[0]).toEqual({ ...EMPTY_REVIEWS, availability: 'starting' })
    await vi.advanceTimersByTimeAsync(0)
    const now = Date.now()
    expect(t.run).toHaveBeenCalledTimes(1)
    expect(t.run).toHaveBeenCalledWith(pollArgs())
    expect(t.change).toHaveBeenCalledTimes(1)
    const state = t.store.get()
    expect(state.turnedOnAt).toBe(now)
    expect(state.baseline).toEqual(['C_1'])
    expect(state.requests).toEqual({
      [K101]: { baseline: true, firstSeen: now },
      [K102]: { baseline: true, firstSeen: now },
    })
    const snap = t.watcher.current()
    expect(snap.availability).toBe('ok')
    expect(snap.polledAt).toBe(now)
    expect(snap.toReview.map(r => [r.key, r.state, r.flash])).toEqual([
      [K101, 'waiting', false],
      [K102, 'waiting', false],
    ])
    expect(t.emitted.at(-1)).toEqual(snap)
    expect(t.notified).toEqual([])
    t.watcher.stop()
  })

  test('a new request after the baseline flashes and notifies once', async () => {
    const t = setup({
      replies: [
        answer([{ number: 101 }]),
        answer([{ number: 101 }, { asked: ASKED, number: 103 }]),
      ],
    })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    await vi.advanceTimersByTimeAsync(2 * MIN)
    expect(t.run).toHaveBeenCalledTimes(2)
    expect(row(t.watcher, K103)).toMatchObject({ flash: true, state: 'new' })
    expect(row(t.watcher, K101)).toMatchObject({ flash: false, state: 'waiting' })
    expect(t.store.get().requests[K103]).toEqual({ baseline: false, firstSeen: Date.now() })
    expect(t.notified.map(n => n.title)).toEqual(['web #103'])
    // The next poll has the same list. The row still flashes, with no second notification.
    await vi.advanceTimersByTimeAsync(2 * MIN)
    expect(t.run).toHaveBeenCalledTimes(3)
    expect(row(t.watcher, K103)?.flash).toBe(true)
    expect(t.notified).toHaveLength(1)
    t.watcher.stop()
  })

  test('a request that is known after a restart does not flash', async () => {
    const before = Date.now() - 24 * 60 * MIN
    const t = setup({
      replies: [answer([{ number: 101 }, { asked: '2026-11-09T09:00:00Z', number: 104 }])],
      state: { requests: { [K101]: { baseline: true, firstSeen: before } }, turnedOnAt: before },
    })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(row(t.watcher, K101)).toMatchObject({ flash: false, state: 'waiting' })
    // A request that arrived while Bifrost was closed flashes and notifies.
    expect(row(t.watcher, K104)).toMatchObject({ flash: true, state: 'new' })
    expect(t.notified.map(n => n.title)).toEqual(['web #104'])
    const state = t.store.get()
    expect(state.turnedOnAt).toBe(before)
    expect(state.requests[K101]).toEqual({ baseline: true, firstSeen: before })
    t.watcher.stop()
  })

  test('a new request that is still open after a restart flashes and does not notify again', async () => {
    const before = Date.now() - 60 * MIN
    const t = setup({
      replies: [answer([{ number: 103 }])],
      state: { requests: { [K103]: { baseline: false, firstSeen: before } }, turnedOnAt: before },
    })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(row(t.watcher, K103)).toMatchObject({ flash: true, state: 'new' })
    expect(t.notified).toEqual([])
    // Nothing changed, so the watcher does not write the state.
    expect(t.change).not.toHaveBeenCalled()
    t.watcher.stop()
  })

  test('a request that comes back flashes and notifies', async () => {
    const t = setup({
      replies: [
        answer([{ number: 101 }]),
        answer([]),
        answer([{ asked: '2026-11-09T10:03:00Z', number: 101 }]),
      ],
    })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(row(t.watcher, K101)?.state).toBe('waiting')
    // The review is in, so GitHub no longer requests it.
    await vi.advanceTimersByTimeAsync(2 * MIN)
    expect(t.watcher.current().toReview).toEqual([])
    expect(t.store.get().requests).toEqual({})
    // The author asks again.
    await vi.advanceTimersByTimeAsync(2 * MIN)
    expect(row(t.watcher, K101)).toMatchObject({ flash: true, state: 'new' })
    expect(t.store.get().requests[K101]).toEqual({ baseline: false, firstSeen: Date.now() })
    expect(t.notified.map(n => n.title)).toEqual(['web #101'])
    t.watcher.stop()
  })

  test('pause stops the flash and the end of the pause brings it back', async () => {
    const t = setup({
      replies: [
        answer([{ number: 101 }]),
        answer([{ number: 101 }, { asked: ASKED, number: 103 }]),
      ],
    })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    await vi.advanceTimersByTimeAsync(2 * MIN)
    expect(row(t.watcher, K103)?.flash).toBe(true)
    const until = Date.now() + 60 * MIN
    await t.watcher.pause(K103)
    expect(t.store.get().pauses).toEqual({ [K103]: until })
    expect(row(t.watcher, K103)).toMatchObject({
      flash: false,
      pauseEndsAt: until,
      state: 'paused',
    })
    expect(t.emitted.at(-1)).toEqual(t.watcher.current())
    // The polls during the pause keep the pause.
    await vi.advanceTimersByTimeAsync(30 * MIN)
    expect(row(t.watcher, K103)?.state).toBe('paused')
    expect(t.store.get().pauses).toEqual({ [K103]: until })
    await vi.advanceTimersByTimeAsync(30 * MIN)
    expect(row(t.watcher, K103)).toMatchObject({ flash: true, pauseEndsAt: null, state: 'new' })
    // A poll after the end removes the ended pause.
    await vi.advanceTimersByTimeAsync(2 * MIN)
    expect(t.store.get().pauses).toEqual({})
    expect(t.notified.map(n => n.title)).toEqual(['web #103'])
    t.watcher.stop()
  })

  test('the flash comes back at the end of the pause, before the next poll', async () => {
    const t = setup({
      replies: [
        answer([{ number: 101 }]),
        answer([{ number: 101 }, { asked: ASKED, number: 103 }]),
      ],
      settings: { reviewsPollMinutes: 10 },
    })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    await vi.advanceTimersByTimeAsync(10 * MIN)
    t.settings.reviewsPauseMinutes = 15
    await t.watcher.pause(K103)
    await vi.advanceTimersByTimeAsync(15 * MIN - 1)
    expect(row(t.watcher, K103)?.state).toBe('paused')
    await vi.advanceTimersByTimeAsync(1)
    expect(row(t.watcher, K103)).toMatchObject({ flash: true, state: 'new' })
    // The polls ran at 0, 10 and 20 minutes. The end of the pause made no gh call.
    expect(t.run).toHaveBeenCalledTimes(3)
    t.watcher.stop()
  })

  test('stop during a pause clears all timers', async () => {
    const t = setup({
      replies: [
        answer([{ number: 101 }]),
        answer([{ number: 101 }, { asked: ASKED, number: 103 }]),
      ],
    })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    await vi.advanceTimersByTimeAsync(2 * MIN)
    await t.watcher.pause(K103)
    expect(vi.getTimerCount()).toBe(2)
    t.watcher.stop()
    expect(vi.getTimerCount()).toBe(0)
    // The pause stays in the state for the next start.
    expect(Object.keys(t.store.get().pauses)).toEqual([K103])
  })

  test('endPause brings the flash back at once', async () => {
    const t = setup({
      replies: [
        answer([{ number: 101 }]),
        answer([{ number: 101 }, { asked: ASKED, number: 103 }]),
      ],
    })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    await vi.advanceTimersByTimeAsync(2 * MIN)
    await t.watcher.pause(K103)
    expect(row(t.watcher, K103)?.state).toBe('paused')
    await t.watcher.endPause(K103)
    expect(t.store.get().pauses).toEqual({})
    expect(row(t.watcher, K103)).toMatchObject({ flash: true, state: 'new' })
    expect(t.notified).toHaveLength(1)
    t.watcher.stop()
  })

  test('an ended pause flashes again without a notification', async () => {
    const before = Date.now() - 2 * 60 * MIN
    const t = setup({
      replies: [answer([{ number: 103 }])],
      state: {
        pauses: { [K103]: Date.now() - MIN },
        requests: { [K103]: { baseline: false, firstSeen: before } },
        turnedOnAt: before,
      },
    })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(row(t.watcher, K103)).toMatchObject({ flash: true, pauseEndsAt: null, state: 'new' })
    expect(t.notified).toEqual([])
    expect(t.store.get().pauses).toEqual({})
    t.watcher.stop()
  })

  test('removes the pause of a request that goes', async () => {
    const before = Date.now() - 60 * MIN
    const t = setup({
      replies: [answer([])],
      state: {
        pauses: { [K103]: Date.now() + 30 * MIN },
        requests: { [K103]: { baseline: false, firstSeen: before } },
        turnedOnAt: before,
      },
    })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(t.store.get().pauses).toEqual({})
    expect(t.store.get().requests).toEqual({})
    t.watcher.stop()
  })

  test('a request from before the turn-on that shows later does not flash', async () => {
    // At the turn-on, GitHub had more than 50 requests. K104 was beyond the first page.
    const t = setup({
      replies: [answer([{ number: 101 }], [], true), answer([{ number: 101 }, { number: 104 }])],
    })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    const turnedOnAt = Date.now()
    await vi.advanceTimersByTimeAsync(2 * MIN)
    expect(row(t.watcher, K104)).toMatchObject({ flash: false, state: 'waiting' })
    expect(t.store.get().requests[K104]).toEqual({ baseline: true, firstSeen: Date.now() })
    expect(t.store.get().turnedOnAt).toBe(turnedOnAt)
    expect(t.notified).toEqual([])
    t.watcher.stop()
  })

  test('while GitHub has more requests, a missing request keeps its entry and its pause', async () => {
    const before = Date.now() - 60 * MIN
    const until = Date.now() + 30 * MIN
    const t = setup({
      replies: [answer([{ number: 101 }], [], true), answer([{ number: 101 }])],
      state: {
        pauses: { [K103]: until },
        requests: {
          [K101]: { baseline: true, firstSeen: before },
          [K103]: { baseline: false, firstSeen: before },
        },
        turnedOnAt: before,
      },
    })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    // K103 is not in the first page, but it can still be open.
    expect(t.store.get().requests[K103]).toEqual({ baseline: false, firstSeen: before })
    expect(t.store.get().pauses).toEqual({ [K103]: until })
    expect(row(t.watcher, K103)).toBeUndefined()
    // All requests fit in one page again, so K103 is gone.
    await vi.advanceTimersByTimeAsync(2 * MIN)
    expect(Object.keys(t.store.get().requests)).toEqual([K101])
    expect(t.store.get().pauses).toEqual({})
    t.watcher.stop()
  })

  test('a known request with a newer request event is new again and notifies once', async () => {
    const t = setup({
      replies: [
        answer([{ number: 101 }]),
        answer([{ number: 101 }]),
        answer([{ asked: '2026-11-09T10:03:00Z', number: 101 }]),
      ],
    })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    await vi.advanceTimersByTimeAsync(2 * MIN)
    expect(row(t.watcher, K101)).toMatchObject({ flash: false, state: 'waiting' })
    // The author asks again while the request is still open.
    await vi.advanceTimersByTimeAsync(2 * MIN)
    expect(row(t.watcher, K101)).toMatchObject({ flash: true, state: 'new' })
    expect(t.store.get().requests[K101]).toEqual({ baseline: false, firstSeen: Date.now() })
    expect(t.notified.map(n => n.title)).toEqual(['web #101'])
    // The next poll has the same request event. It does not notify again.
    await vi.advanceTimersByTimeAsync(2 * MIN)
    expect(row(t.watcher, K101)?.state).toBe('new')
    expect(t.notified).toHaveLength(1)
    t.watcher.stop()
  })

  test('a re-request ends the pause of the request', async () => {
    const before = Date.now() - 60 * MIN
    const t = setup({
      replies: [answer([{ asked: '2026-11-09T09:59:00Z', number: 103 }])],
      state: {
        pauses: { [K103]: Date.now() + 30 * MIN },
        requests: { [K103]: { baseline: false, firstSeen: before } },
        turnedOnAt: before,
      },
    })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(row(t.watcher, K103)).toMatchObject({ flash: true, state: 'new' })
    expect(t.store.get().pauses).toEqual({})
    expect(t.notified.map(n => n.title)).toEqual(['web #103'])
    t.watcher.stop()
  })

  test('a new team request event does not end the pause of a team row', async () => {
    const before = Date.now() - 60 * MIN
    const entry = { baseline: false, firstSeen: before }
    const t = setup({
      replies: [answer([{ asked: '2026-11-09T09:59:00Z', number: 103, team: true }])],
      state: {
        pauses: { [K103]: Date.now() + 30 * MIN },
        requests: { [K103]: entry },
        turnedOnAt: before,
      },
    })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(row(t.watcher, K103)).toMatchObject({ flash: false, state: 'paused' })
    expect(t.store.get().pauses[K103]).toBeGreaterThan(Date.now())
    expect(t.store.get().requests[K103]).toEqual(entry)
    expect(t.notified).toEqual([])
    t.watcher.stop()
  })

  test('a request time after the local clock notifies only once', async () => {
    // The clock of this Mac is late, so the request time is in the future.
    const asked = '2026-11-09T11:00:00Z'
    const t = setup({
      replies: [answer([{ number: 101 }]), answer([{ number: 101 }, { asked, number: 103 }])],
    })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    await vi.advanceTimersByTimeAsync(2 * MIN)
    expect(row(t.watcher, K103)?.state).toBe('new')
    expect(t.store.get().requests[K103]).toEqual({ baseline: false, firstSeen: Date.parse(asked) })
    await vi.advanceTimersByTimeAsync(4 * MIN)
    expect(t.notified.map(n => n.title)).toEqual(['web #103'])
    t.watcher.stop()
  })

  test('keeps the last snapshot when a poll fails', async () => {
    const t = setup({
      replies: [answer([{ number: 101 }]), LOGGED_OUT, TIMED_OUT, answer([{ number: 101 }])],
    })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    const good = t.watcher.current()
    const state = JSON.stringify(t.store.get())
    expect(t.change).toHaveBeenCalledTimes(1)

    await vi.advanceTimersByTimeAsync(2 * MIN)
    expect(t.emitted.at(-1)).toEqual({
      ...good,
      availability: 'logged-out',
      message: REASON_GH_LOGGED_OUT,
    })
    await vi.advanceTimersByTimeAsync(2 * MIN)
    expect(t.emitted.at(-1)).toEqual({
      ...good,
      availability: 'error',
      message: REASON_GH_TIMEOUT,
    })
    expect(JSON.stringify(t.store.get())).toBe(state)
    expect(t.change).toHaveBeenCalledTimes(1)
    expect(t.notified).toEqual([])

    // The next good poll clears the message.
    await vi.advanceTimersByTimeAsync(2 * MIN)
    expect(t.watcher.current()).toMatchObject({ availability: 'ok', message: null })
    expect(t.watcher.current().polledAt).toBe(Date.now())
    t.watcher.stop()
  })

  test('a partial answer keeps its data and logs the same errors once', async () => {
    const message = 'Something went wrong while executing your query.'
    const t = setup({ replies: [partial([{ number: 101 }], [message, message], 1)] })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(t.watcher.current()).toMatchObject({ availability: 'ok', message: null })
    expect(t.watcher.current().toReview.map(r => r.key)).toEqual([K101])
    const lines = (): string[] => t.logs.filter(m => m.includes(message))
    expect(lines()).toEqual([`GitHub gave errors with the Reviews poll: ${message}`])
    await vi.advanceTimersByTimeAsync(2 * MIN)
    expect(lines()).toHaveLength(1)
    t.watcher.stop()
  })

  test('logs the same partial error once and logs a new one', async () => {
    const t = setup({
      replies: [
        partial([{ number: 101 }], ['Error A'], 1),
        partial([{ number: 101 }], ['Error A'], 1),
        partial([{ number: 101 }], ['Error B'], 1),
      ],
    })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    await vi.advanceTimersByTimeAsync(2 * MIN)
    await vi.advanceTimersByTimeAsync(2 * MIN)
    expect(t.run).toHaveBeenCalledTimes(3)
    const lines = t.logs.filter(m => m.startsWith('GitHub gave errors'))
    expect(lines).toEqual([
      'GitHub gave errors with the Reviews poll: Error A',
      'GitHub gave errors with the Reviews poll: Error B',
    ])
    t.watcher.stop()
  })

  test('logs error A again after a poll with no errors', async () => {
    const t = setup({
      replies: [
        partial([{ number: 101 }], ['Error A'], 1),
        answer([{ number: 101 }]),
        partial([{ number: 101 }], ['Error A'], 1),
      ],
    })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    await vi.advanceTimersByTimeAsync(2 * MIN)
    await vi.advanceTimersByTimeAsync(2 * MIN)
    expect(t.run).toHaveBeenCalledTimes(3)
    expect(t.logs.filter(m => m.includes('Error A'))).toHaveLength(2)
    t.watcher.stop()
  })

  test('logs error A again after stop and a new start', async () => {
    const t = setup({ replies: [partial([{ number: 101 }], ['Error A'], 1)] })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    t.watcher.stop()
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(t.run).toHaveBeenCalledTimes(2)
    expect(t.logs.filter(m => m.includes('Error A'))).toHaveLength(2)
    t.watcher.stop()
  })

  test('a partial answer keeps a request that it does not show', async () => {
    const before = Date.now() - 60 * MIN
    const t = setup({
      replies: [partial([{ number: 101 }], ['Not accessible'], 1)],
      state: {
        requests: {
          [K101]: { baseline: true, firstSeen: before },
          [K103]: { baseline: false, firstSeen: before },
        },
        turnedOnAt: before,
      },
    })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(t.watcher.current().availability).toBe('ok')
    expect(Object.keys(t.store.get().requests).sort()).toEqual([K101, K103])
    t.watcher.stop()
  })

  test('gh output with errors and no data fails the poll', async () => {
    const t = setup({
      replies: [
        {
          code: 1,
          stderr: 'gh: Bad query',
          stdout: JSON.stringify({ errors: [{ message: 'Bad query' }] }),
        },
      ],
    })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(t.watcher.current()).toMatchObject({ availability: 'error', message: 'gh: Bad query' })
    expect(t.change).not.toHaveBeenCalled()
    t.watcher.stop()
  })

  test('a failed first poll gives the message and no rows', async () => {
    const t = setup({ replies: [{ code: 1, stderr: 'spawn gh ENOENT', stdout: '' }] })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(t.watcher.current()).toEqual({
      ...EMPTY_REVIEWS,
      availability: 'no-gh',
      message: REASON_GH_MISSING,
    })
    expect(t.change).not.toHaveBeenCalled()
    t.watcher.stop()
  })

  test('an answer that Bifrost cannot read is an error', async () => {
    const t = setup({ replies: [{ code: 0, stderr: '', stdout: 'not json' }] })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(t.watcher.current()).toMatchObject({
      availability: 'error',
      message: "GitHub gave an answer that Bifrost can't read.",
    })
    t.watcher.stop()
  })

  test('a hung poll ends at the deadline', async () => {
    const late = deferred()
    const t = setup({ replies: [late.promise, answer([{ number: 101 }])] })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(POLL_DEADLINE_MS - 1)
    expect(t.watcher.current().availability).toBe('starting')
    await vi.advanceTimersByTimeAsync(1)
    expect(t.watcher.current()).toMatchObject({ availability: 'error', message: REASON_GH_TIMEOUT })
    // The late answer of the ended poll changes nothing.
    late.resolve(answer([{ number: 102 }]))
    await vi.advanceTimersByTimeAsync(0)
    expect(t.change).not.toHaveBeenCalled()
    expect(t.watcher.current().availability).toBe('error')
    // The next poll comes the poll interval after the end of the hung poll.
    await vi.advanceTimersByTimeAsync(2 * MIN)
    expect(t.run).toHaveBeenCalledTimes(2)
    expect(t.watcher.current().toReview.map(r => r.key)).toEqual([K101])
    t.watcher.stop()
  })

  test('stop clears the timer and a late answer of an old generation emits nothing', async () => {
    const first = deferred()
    const second = deferred()
    const t = setup({ replies: [first.promise, second.promise] })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(t.run).toHaveBeenCalledTimes(1)
    t.watcher.stop()
    expect(t.emitted.at(-1)).toEqual(EMPTY_REVIEWS)
    expect(t.watcher.current()).toEqual(EMPTY_REVIEWS)
    await vi.advanceTimersByTimeAsync(0)
    expect(vi.getTimerCount()).toBe(0)

    // A new start polls at once with a new generation.
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(t.run).toHaveBeenCalledTimes(2)
    const count = t.emitted.length
    first.resolve(answer([{ number: 101 }]))
    await vi.advanceTimersByTimeAsync(0)
    expect(t.emitted).toHaveLength(count)
    expect(t.change).not.toHaveBeenCalled()
    second.resolve(answer([{ number: 102 }]))
    await vi.advanceTimersByTimeAsync(0)
    expect(t.watcher.current().toReview.map(r => r.key)).toEqual([K102])

    t.watcher.stop()
    await vi.advanceTimersByTimeAsync(10 * MIN)
    expect(t.run).toHaveBeenCalledTimes(2)
    expect(vi.getTimerCount()).toBe(0)
  })

  test('a stop during the save emits nothing and notifies nothing', async () => {
    const t = setup({
      replies: [
        answer([{ number: 101 }]),
        answer([{ number: 101 }, { asked: ASKED, number: 103 }]),
      ],
    })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    let finish: () => void = () => {}
    const write = new Promise<void>(resolve => {
      finish = resolve
    })
    const memory = t.change.getMockImplementation()
    t.change.mockImplementationOnce(async fn => {
      await write
      return (memory as NonNullable<typeof memory>)(fn)
    })
    await vi.advanceTimersByTimeAsync(2 * MIN)
    t.watcher.stop()
    const count = t.emitted.length
    finish()
    await vi.advanceTimersByTimeAsync(0)
    expect(t.emitted).toHaveLength(count)
    expect(t.watcher.current()).toEqual(EMPTY_REVIEWS)
    expect(t.notified).toEqual([])
    expect(vi.getTimerCount()).toBe(0)
  })

  test('the next poll comes the poll interval after the end of a poll', async () => {
    const t = setup({ replies: [answer([{ number: 101 }])], settings: { reviewsPollMinutes: 5 } })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    await vi.advanceTimersByTimeAsync(5 * MIN - 1)
    expect(t.run).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(1)
    expect(t.run).toHaveBeenCalledTimes(2)
    // Without reschedule, a change of the setting applies from the next poll.
    t.settings.reviewsPollMinutes = 1
    await vi.advanceTimersByTimeAsync(5 * MIN)
    expect(t.run).toHaveBeenCalledTimes(3)
    await vi.advanceTimersByTimeAsync(MIN)
    expect(t.run).toHaveBeenCalledTimes(4)
    t.watcher.stop()
  })

  test('a change of the poll interval reschedules the next poll', async () => {
    const t = setup({ replies: [answer([{ number: 101 }])], settings: { reviewsPollMinutes: 10 } })
    t.watcher.reschedule()
    await vi.advanceTimersByTimeAsync(0)
    expect(t.run).not.toHaveBeenCalled()
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    await vi.advanceTimersByTimeAsync(3 * MIN)
    expect(t.run).toHaveBeenCalledTimes(1)
    // A shorter interval: the next poll was due 1 minute after the end of the last poll, so it
    // runs at once.
    t.settings.reviewsPollMinutes = 1
    t.watcher.reschedule()
    await vi.advanceTimersByTimeAsync(0)
    expect(t.run).toHaveBeenCalledTimes(2)
    await vi.advanceTimersByTimeAsync(MIN - 1)
    expect(t.run).toHaveBeenCalledTimes(2)
    await vi.advanceTimersByTimeAsync(1)
    expect(t.run).toHaveBeenCalledTimes(3)
    // A longer interval moves the next poll later.
    t.settings.reviewsPollMinutes = 10
    t.watcher.reschedule()
    await vi.advanceTimersByTimeAsync(10 * MIN - 1)
    expect(t.run).toHaveBeenCalledTimes(3)
    await vi.advanceTimersByTimeAsync(1)
    expect(t.run).toHaveBeenCalledTimes(4)
    t.watcher.stop()
  })

  test('the pause-end timer waits at most the poll interval', async () => {
    const before = Date.now() - 60 * MIN
    const t = setup({
      replies: [answer([{ number: 103 }])],
      state: {
        // 100 days is more than the largest timer delay (2^31 - 1 ms).
        pauses: { [K103]: Date.now() + 100 * 24 * 60 * MIN },
        requests: { [K103]: { baseline: false, firstSeen: before } },
        turnedOnAt: before,
      },
    })
    const spy = vi.spyOn(globalThis, 'setTimeout')
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(row(t.watcher, K103)?.state).toBe('paused')
    const count = t.emitted.length
    await vi.advanceTimersByTimeAsync(MIN)
    expect(t.emitted).toHaveLength(count)
    const delays = spy.mock.calls.map(call => Number(call[1] ?? 0))
    expect(Math.max(...delays)).toBeLessThanOrEqual(2 * MIN)
    spy.mockRestore()
    t.watcher.stop()
  })

  test('a second start does nothing', async () => {
    const t = setup({ replies: [answer([{ number: 101 }])] })
    t.watcher.start()
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(t.run).toHaveBeenCalledTimes(1)
    expect(t.emitted.filter(s => s.availability === 'starting')).toHaveLength(1)
    t.watcher.stop()
  })

  test('requestPoll polls at once, but not within the refresh gap', async () => {
    const t = setup({ replies: [answer([{ number: 101 }])] })
    t.watcher.requestPoll()
    await vi.advanceTimersByTimeAsync(0)
    expect(t.run).not.toHaveBeenCalled()
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    t.watcher.requestPoll()
    await vi.advanceTimersByTimeAsync(0)
    expect(t.run).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(REFRESH_GAP_MS)
    t.watcher.requestPoll()
    await vi.advanceTimersByTimeAsync(0)
    expect(t.run).toHaveBeenCalledTimes(2)
    // The timer starts again after the refresh.
    await vi.advanceTimersByTimeAsync(2 * MIN - 1)
    expect(t.run).toHaveBeenCalledTimes(2)
    await vi.advanceTimersByTimeAsync(1)
    expect(t.run).toHaveBeenCalledTimes(3)
    t.watcher.stop()
  })

  test('rebuild applies the ignore list with no gh call', async () => {
    const t = setup({ replies: [answer([{ number: 101 }, { number: 7, repo: 'api' }])] })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(t.watcher.current().toReview).toHaveLength(2)
    t.settings.reviewsIgnore = ['acme/api']
    t.watcher.rebuild()
    expect(t.watcher.current().toReview.map(r => r.key)).toEqual([K101])
    expect(t.emitted.at(-1)).toEqual(t.watcher.current())
    expect(t.run).toHaveBeenCalledTimes(1)
    t.watcher.stop()
  })

  test('rebuild keeps the message of a failed poll', async () => {
    const t = setup({ replies: [answer([{ number: 101 }]), LOGGED_OUT] })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    await vi.advanceTimersByTimeAsync(2 * MIN)
    t.watcher.rebuild()
    expect(t.watcher.current()).toMatchObject({
      availability: 'logged-out',
      message: REASON_GH_LOGGED_OUT,
    })
    expect(t.watcher.current().toReview).toHaveLength(1)
    t.watcher.stop()
  })

  test('a failed save logs, shows the rows and does not notify', async () => {
    const t = setup({
      replies: [
        answer([{ number: 101 }]),
        answer([{ number: 101 }, { asked: ASKED, number: 103 }]),
      ],
    })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    t.change.mockRejectedValueOnce(new Error('disk full'))
    await vi.advanceTimersByTimeAsync(2 * MIN)
    expect(t.logs.some(m => m.includes('disk full'))).toBe(true)
    expect(row(t.watcher, K103)?.state).toBe('new')
    expect(t.notified).toEqual([])
    t.watcher.stop()
  })

  test('a failed save keeps the computed rows and logs once until a save works', async () => {
    const both = [{ number: 101 }, { number: 102 }]
    const t = setup({
      replies: [
        answer(both),
        answer(both),
        answer(both),
        answer([...both, { asked: '2026-11-09T10:05:00Z', number: 103 }]),
      ],
    })
    const memory = t.change.getMockImplementation() as NonNullable<
      ReturnType<typeof t.change.getMockImplementation>
    >
    const broken = async (): Promise<ReviewsState> => {
      throw new Error('disk full')
    }
    const saveLogs = (): string[] => t.logs.filter(m => m.includes('disk full'))
    t.change.mockImplementation(broken)
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    // The first poll did not save, but its rows are the baseline rows. Nothing flashes.
    expect(t.store.get().turnedOnAt).toBeNull()
    expect(t.watcher.current().toReview.map(r => [r.key, r.state, r.flash])).toEqual([
      [K101, 'waiting', false],
      [K102, 'waiting', false],
    ])
    expect(saveLogs()).toHaveLength(1)
    await vi.advanceTimersByTimeAsync(2 * MIN)
    expect(row(t.watcher, K101)?.flash).toBe(false)
    expect(saveLogs()).toHaveLength(1)
    // The save works again.
    t.change.mockImplementation(memory)
    await vi.advanceTimersByTimeAsync(2 * MIN)
    expect(t.store.get().turnedOnAt).toBe(Date.now())
    // It fails again: one new log line. The new request shows, with no notification.
    t.change.mockImplementation(broken)
    await vi.advanceTimersByTimeAsync(2 * MIN)
    expect(saveLogs()).toHaveLength(2)
    expect(row(t.watcher, K103)).toMatchObject({ flash: true, state: 'new' })
    expect(row(t.watcher, K101)?.flash).toBe(false)
    expect(t.notified).toEqual([])
    t.watcher.stop()
  })

  test('a pause after a failed save keeps the computed rows', async () => {
    const t = setup({ replies: [answer([{ number: 101 }, { number: 102 }])] })
    const memory = t.change.getMockImplementation() as NonNullable<
      ReturnType<typeof t.change.getMockImplementation>
    >
    t.change.mockImplementation(async () => {
      throw new Error('disk full')
    })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    t.change.mockImplementation(memory)
    await t.watcher.pause(K101)
    expect(row(t.watcher, K101)?.state).toBe('paused')
    expect(row(t.watcher, K102)).toMatchObject({ flash: false, state: 'waiting' })
    t.watcher.stop()
  })

  test('a gh run that throws is an error', async () => {
    const t = setup()
    t.run.mockImplementationOnce(async () => {
      throw new Error('boom')
    })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(t.watcher.current()).toMatchObject({ availability: 'error', message: REASON_GH_FAILED })
    t.watcher.stop()
  })

  test('the health log gets each poll: an error fails, no gh and logged out give no data', async () => {
    const poll = vi.fn()
    const t = setup({
      health: { poll, stopped: () => {} },
      replies: [
        answer([]),
        LOGGED_OUT,
        { code: 1, stderr: 'spawn gh ENOENT', stdout: '' },
        TIMED_OUT,
        { code: 1, stderr: 'HTTP 502', stdout: '' },
        answer([]),
      ],
    })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    for (let i = 0; i < 5; i++) await vi.advanceTimersByTimeAsync(2 * MIN)
    // A gh run that throws is an error too.
    t.run.mockImplementationOnce(async () => {
      throw new Error('boom')
    })
    await vi.advanceTimersByTimeAsync(2 * MIN)
    expect(poll.mock.calls).toEqual([
      ['reviews', 'ok'],
      ['reviews', 'no-data'],
      ['reviews', 'no-data'],
      ['reviews', 'failed'],
      ['reviews', 'failed'],
      ['reviews', 'ok'],
      ['reviews', 'failed'],
    ])
    t.watcher.stop()
  })

  test('stop tells the health log that Reviews stopped', async () => {
    const stopped = vi.fn()
    const t = setup({ health: { poll: () => {}, stopped }, replies: [LOGGED_OUT] })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(stopped).not.toHaveBeenCalled()
    t.watcher.stop()
    expect(stopped.mock.calls).toEqual([['reviews']])
  })

  test('rateLimit() gives the last value and null after stop', async () => {
    const RESET = '2026-11-09T11:00:00Z'
    // A good answer with the rate limit of the poll.
    const limited = (remaining: number): ExecResult => {
      const good = JSON.parse(answer([]).stdout)
      good.data.rateLimit = { cost: 1, limit: 5000, remaining, resetAt: RESET }
      return { code: 0, stderr: '', stdout: JSON.stringify(good) }
    }
    const failed: ExecResult = { code: 1, stderr: 'gh: HTTP 502', stdout: '' }
    const t = setup({ replies: [limited(4930), failed, limited(4900), answer([])] })
    expect(t.watcher.rateLimit()).toBeNull()
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(t.watcher.rateLimit()).toEqual({
      cost: 1,
      limit: 5000,
      remaining: 4930,
      resetAt: Date.parse(RESET),
    })
    // A failed poll keeps the value of the last good poll.
    await vi.advanceTimersByTimeAsync(2 * MIN)
    expect(t.run).toHaveBeenCalledTimes(2)
    expect(t.watcher.rateLimit()?.remaining).toBe(4930)
    await vi.advanceTimersByTimeAsync(2 * MIN)
    expect(t.watcher.rateLimit()?.remaining).toBe(4900)
    // A good answer with no rate limit gives null.
    await vi.advanceTimersByTimeAsync(2 * MIN)
    expect(t.run).toHaveBeenCalledTimes(4)
    expect(t.watcher.rateLimit()).toBeNull()
    t.replies.push(limited(4800))
    await vi.advanceTimersByTimeAsync(2 * MIN)
    expect(t.watcher.rateLimit()?.remaining).toBe(4800)
    t.watcher.stop()
    expect(t.watcher.rateLimit()).toBeNull()
  })

  test('four new requests in one poll give one summary notification', async () => {
    const t = setup({
      replies: [
        answer([{ number: 101 }]),
        answer([
          { number: 101 },
          ...[103, 104, 105, 106].map(number => ({ asked: ASKED, number })),
        ]),
      ],
    })
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    await vi.advanceTimersByTimeAsync(2 * MIN)
    expect(t.notified).toEqual([{ body: '4 new review requests', title: 'Reviews' }])
    t.watcher.stop()
  })

  test('pause refuses an unknown key', async () => {
    const t = setup({ replies: [answer([{ number: 101 }], [{ number: 90, repo: 'api' }])] })
    await expect(t.watcher.pause(K101)).rejects.toThrow(REFUSED_UNKNOWN_PR)
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    const writes = t.change.mock.calls.length
    await expect(t.watcher.pause('acme/web#999')).rejects.toThrow(REFUSED_UNKNOWN_PR)
    // A My PR is not a request, so it has no pause.
    await expect(t.watcher.pause('acme/api#90')).rejects.toThrow(REFUSED_UNKNOWN_PR)
    await expect(t.watcher.endPause('acme/web#999')).rejects.toThrow(REFUSED_UNKNOWN_PR)
    expect(t.change).toHaveBeenCalledTimes(writes)
    expect(t.store.get().pauses).toEqual({})
    t.watcher.stop()
  })

  test('urlOf gives only https://github.com/ URLs', async () => {
    const t = setup({
      replies: [
        answer(
          [
            { number: 101 },
            { number: 102, url: 'https://evil.example/acme/web/pull/102' },
            { number: 103, url: 'http://github.com/acme/web/pull/103' },
            { number: 104, url: 'https://github.com.evil.example/acme/web/pull/104' },
          ],
          [{ number: 90, repo: 'api' }],
        ),
      ],
    })
    expect(t.watcher.urlOf(K101)).toBeNull()
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(t.watcher.urlOf(K101)).toBe('https://github.com/acme/web/pull/101')
    expect(t.watcher.urlOf('acme/api#90')).toBe('https://github.com/acme/api/pull/90')
    expect(t.watcher.urlOf(K102)).toBeNull()
    expect(t.watcher.urlOf(K103)).toBeNull()
    expect(t.watcher.urlOf(K104)).toBeNull()
    expect(t.watcher.urlOf('acme/web#999')).toBeNull()
    t.watcher.stop()
    expect(t.watcher.urlOf(K101)).toBeNull()
  })
})

describe('IPC helpers', () => {
  test('checkPrKey takes only a PR key', () => {
    expect(checkPrKey(K101)).toBe(K101)
    for (const bad of [
      42,
      null,
      undefined,
      '',
      'acme/web',
      '../etc#1',
      'https://github.com/a/b#1',
    ]) {
      expect(() => checkPrKey(bad)).toThrow(REFUSED_UNKNOWN_PR)
    }
  })

  test('whileOn refuses while the watcher is off', async () => {
    const t = setup({ replies: [answer([{ number: 101 }])] })
    expect(() => whileOn(null)).toThrow(REFUSED_REVIEWS_OFF)
    expect(() => whileOn(t.watcher)).toThrow(REFUSED_REVIEWS_OFF)
    t.watcher.start()
    expect(whileOn(t.watcher)).toBe(t.watcher)
    await vi.advanceTimersByTimeAsync(0)
    expect(whileOn(t.watcher)).toBe(t.watcher)
    t.watcher.stop()
    expect(() => whileOn(t.watcher)).toThrow(REFUSED_REVIEWS_OFF)
  })

  test('urlToOpen checks the watcher, the key and the URL', async () => {
    const t = setup({
      replies: [answer([{ number: 101 }, { number: 102, url: 'https://evil.example/x' }])],
    })
    expect(() => urlToOpen(t.watcher, K101)).toThrow(REFUSED_REVIEWS_OFF)
    t.watcher.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(urlToOpen(t.watcher, K101)).toBe('https://github.com/acme/web/pull/101')
    expect(() => urlToOpen(t.watcher, K102)).toThrow(REFUSED_UNKNOWN_PR)
    expect(() => urlToOpen(t.watcher, 'acme/web#999')).toThrow(REFUSED_UNKNOWN_PR)
    expect(() => urlToOpen(t.watcher, { key: K101 })).toThrow(REFUSED_UNKNOWN_PR)
    t.watcher.stop()
  })

  test('requestNotice gives the title and the body of the notification', () => {
    const notice = requestNotice({
      additions: 1,
      author: 'alice',
      deletions: 1,
      flash: true,
      key: K101,
      number: 101,
      owner: 'acme',
      pauseEndsAt: null,
      repo: 'web',
      requestedAt: 0,
      sessionId: null,
      state: 'new',
      team: false,
      title: 'Add search box',
    })
    expect(notice).toEqual({
      body: 'alice asked for your review: Add search box',
      title: 'web #101',
    })
  })
})

describe('requestNotices', () => {
  const rows = (count: number): ToReviewRow[] =>
    Array.from({ length: count }, (_, i) => ({
      additions: 1,
      author: 'alice',
      deletions: 1,
      flash: true,
      key: `acme/web#${i + 1}`,
      number: i + 1,
      owner: 'acme',
      pauseEndsAt: null,
      repo: 'web',
      requestedAt: 0,
      sessionId: null,
      state: 'new',
      team: false,
      title: `Change ${i + 1}`,
    }))

  test('3 requests give 3 single notifications', () => {
    expect(requestNotices(rows(3))).toEqual([
      { body: 'alice asked for your review: Change 1', title: 'web #1' },
      { body: 'alice asked for your review: Change 2', title: 'web #2' },
      { body: 'alice asked for your review: Change 3', title: 'web #3' },
    ])
  })

  test('4 requests give one summary', () => {
    expect(requestNotices(rows(4))).toEqual([{ body: '4 new review requests', title: 'Reviews' }])
  })

  test('no request gives no notification', () => {
    expect(requestNotices([])).toEqual([])
  })
})
