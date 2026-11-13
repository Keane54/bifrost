import { describe, expect, it } from 'vitest'
import type { ExecResult } from '../../../src/main/claude/cli'
import { type ApproverDeps, createApprover, prKeyOfUrl } from '../../../src/main/reviews/approve'
import type { Gh } from '../../../src/main/reviews/gh'
import type { PrData } from '../../../src/main/reviews/pr-data'
import {
  REASON_APPROVE_CHANGED,
  REASON_APPROVE_CI_FAILING,
  REASON_APPROVE_CI_RUNNING,
  REASON_APPROVE_CLOSED,
  REASON_APPROVE_DONE,
  REASON_APPROVE_DRAFT_COMMIT,
  REASON_APPROVE_FAILED,
  REASON_APPROVE_NO_DRAFT,
  REASON_APPROVE_NOT_SUGGESTED,
  REASON_APPROVE_OWN,
  REASON_APPROVE_PENDING,
  REASON_APPROVE_REFUSED,
  REASON_APPROVE_UNKNOWN,
  REASON_PR_READ_FAILED,
} from '../../../src/main/reviews/round-text'
import {
  EMPTY_STATE,
  emptyPrState,
  type RecommendationMark,
  type ReviewsState,
} from '../../../src/main/reviews/state'
import {
  approveKey,
  REFUSED_UNKNOWN_PR,
  type ReviewsWatcher,
} from '../../../src/main/reviews/watcher'
import { EMPTY_REVIEWS, type ToReviewRow } from '../../../src/shared/reviews'

const KEY = 'acme/api#7'
const HEAD = 'a'.repeat(40)
const OTHER = 'b'.repeat(40)
const VIEWER = 'dev-user'
const REFUSED = 'refused: this pull request cannot be approved now'
const TOKEN = `ghp_${'x'.repeat(36)}`

function pr(over: Partial<PrData> = {}): PrData {
  return {
    additions: 1,
    approvals: 0,
    author: 'bob',
    baseRef: 'main',
    ci: null,
    comments: [],
    createdAt: 1,
    decisions: [],
    deletions: 1,
    failedChecks: 0,
    headRef: 'f',
    headSha: HEAD,
    isCrossRepository: false,
    isDraft: false,
    key: KEY,
    number: 7,
    owner: 'acme',
    repo: 'api',
    requestedAt: 1,
    requestedTeams: [],
    requestedUsers: [VIEWER],
    reviewDecision: null,
    reviews: [],
    threads: [],
    title: 't',
    truncatedChecks: false,
    truncatedComments: false,
    truncatedReviews: false,
    truncatedThreads: false,
    updatedAt: 5,
    url: 'https://github.com/acme/api/pull/7',
    viewerPendingReviewId: null,
    viewerReviews: [],
    ...over,
  }
}

const mark = (over: Partial<RecommendationMark> = {}): RecommendationMark => ({
  at: 500,
  headSha: HEAD,
  reviewId: null,
  value: 'approve',
  why: 'Small and safe.',
  ...over,
})

const stateWith = (
  m: RecommendationMark | null,
  extra: Partial<ReviewsState> = {},
): ReviewsState => ({
  ...EMPTY_STATE,
  prs: { [KEY]: { ...emptyPrState(), recommendation: m } },
  ...extra,
})

interface ContextOver {
  // The state of the rollup of the head commit. Null is a PR with no CI.
  ci?: string | null
  ciCommit?: string
  state?: string
  author?: string
  head?: string
  pending?: { id: string; commit: string } | null
  reviews?: { state: string; commit: string; submittedAt: string }[]
  url?: string
}

// The answer of the ReviewContext query of the fresh read.
function context(over: ContextOver = {}): ExecResult {
  const pending = over.pending ?? null
  const pullRequest = {
    author: { login: over.author ?? 'bob' },
    baseRefName: 'main',
    baseRefOid: 'c'.repeat(40),
    body: 'Raise the limit.',
    commits: {
      nodes: [
        {
          commit: {
            oid: over.ciCommit ?? over.head ?? HEAD,
            statusCheckRollup: over.ci == null ? null : { state: over.ci },
          },
        },
      ],
    },
    headRefName: 'raise-limit',
    headRefOid: over.head ?? HEAD,
    id: 'PR_7',
    pending: {
      nodes:
        pending === null
          ? []
          : [
              {
                body: 'Claude says it looks good.',
                commit: { oid: pending.commit },
                id: pending.id,
                viewerDidAuthor: true,
              },
            ],
    },
    reviews: {
      nodes: (over.reviews ?? []).map(r => ({
        body: '',
        comments: { nodes: [] },
        commit: { oid: r.commit },
        state: r.state,
        submittedAt: r.submittedAt,
        url: 'https://github.com/acme/api/pull/7#r',
      })),
      pageInfo: { endCursor: null, hasNextPage: false },
    },
    state: over.state ?? 'OPEN',
    title: 'Raise the limit',
    url: over.url ?? 'https://github.com/acme/api/pull/7',
  }
  return { code: 0, stderr: '', stdout: JSON.stringify({ data: { repository: { pullRequest } } }) }
}

const THREADS: ExecResult = {
  code: 0,
  stderr: '',
  stdout: JSON.stringify({
    data: {
      repository: {
        pullRequest: {
          reviewThreads: { nodes: [], pageInfo: { endCursor: null, hasNextPage: false } },
        },
      },
    },
  }),
}

const answer = (field: string, state = 'APPROVED'): ExecResult => ({
  code: 0,
  stderr: '',
  stdout: JSON.stringify({ data: { [field]: { pullRequestReview: { id: 'PRR_x', state } } } }),
})

type Op = 'ReviewContext' | 'ReviewThreads' | 'ApproveHead' | 'ApproveDraft'
// The key of the answer of each operation in the harness.
const KEYS: Record<Op, 'context' | 'threads' | 'head' | 'draft'> = {
  ApproveDraft: 'draft',
  ApproveHead: 'head',
  ReviewContext: 'context',
  ReviewThreads: 'threads',
}
type Answers = Partial<
  Record<
    'context' | 'threads' | 'head' | 'draft',
    (args: string[]) => ExecResult | Promise<ExecResult>
  >
>

const opOf = (args: string[]): Op | 'other' => {
  const query = args.find(a => a.startsWith('query=')) ?? ''
  const name = /^query=(?:query|mutation) (\w+)/.exec(query)?.[1] ?? ''
  return Object.hasOwn(KEYS, name) ? (name as Op) : 'other'
}

// The -f and -F fields of one call, without the query.
function fields(args: string[]): Record<string, string> {
  const out: Record<string, string> = {}
  for (let i = 0; i < args.length; i++) {
    if ((args[i] === '-f' || args[i] === '-F') && !args[i + 1]?.startsWith('query=')) {
      const [k = '', ...v] = (args[i + 1] ?? '').split('=')
      out[k] = v.join('=')
    }
  }
  return out
}

interface Harness {
  deps: ApproverDeps
  calls: string[][]
  events: string[]
  polls: () => number
  ops: () => (Op | 'other')[]
  set(next: ReviewsState): void
  setPollStart(at: number): void
  setNow(at: number): void
}

// A harness with a fake gh. answers gives the answer of each operation. It never calls GitHub.
function harness(state: ReviewsState, answers: Answers, poll: PrData | null = pr()): Harness {
  let s = state
  let pollStart = 0
  let now = 1_000
  let polls = 0
  const calls: string[][] = []
  const events: string[] = []
  const gh: Gh = {
    async run(args, opts) {
      if (opts?.input !== undefined) throw new Error('no stdin')
      calls.push(args)
      const op = opOf(args)
      if (op === 'ReviewThreads' && answers.threads === undefined) return THREADS
      const fn = op === 'other' ? undefined : answers[KEYS[op]]
      if (fn === undefined) throw new Error(`no answer for ${op}`)
      return await fn(args)
    },
  }
  const deps: ApproverDeps = {
    changed: () => undefined,
    eventNotice: text => events.push(text),
    gh,
    log: () => undefined,
    now: () => now,
    pollStartedAt: () => pollStart,
    requestPoll: () => {
      polls++
    },
    store: { get: () => s },
    toReviewPr: key => (key === KEY ? poll : null),
    viewer: () => VIEWER,
  }
  return {
    calls,
    deps,
    events,
    ops: () => calls.map(opOf),
    polls: () => polls,
    set: next => {
      s = next
    },
    setNow: at => {
      now = at
    },
    setPollStart: at => {
      pollStart = at
    },
  }
}

describe('the Approve click with no draft', () => {
  it('approves the reviewed commit with no text, then asks for a poll', async () => {
    const h = harness(stateWith(mark()), {
      context: () => context(),
      head: () => answer('addPullRequestReview'),
    })
    const approver = createApprover(h.deps)
    await approver.approve(KEY)
    expect(h.ops()).toEqual(['ReviewContext', 'ApproveHead'])
    expect(fields(h.calls[1] ?? [])).toEqual({ commit: HEAD, pr: 'PR_7' })
    expect(approver.entry(KEY)?.phase).toBe('approved')
    expect(h.polls()).toBe(1)
  })
})

describe('the Approve click after Approve instead', () => {
  const deleted = (): RecommendationMark =>
    mark({ deleted: true, reviewId: null, value: 'comment' })

  it('writes the approval on the head when no pending review is left', async () => {
    const h = harness(stateWith(deleted()), {
      context: () => context(),
      head: () => answer('addPullRequestReview'),
    })
    const approver = createApprover(h.deps)
    await approver.approve(KEY)
    expect(h.ops()).toEqual(['ReviewContext', 'ApproveHead'])
    expect(approver.entry(KEY)?.phase).toBe('approved')
  })

  it('refuses when a pending review is there', async () => {
    const h = harness(stateWith(deleted()), {
      context: () => context({ pending: { commit: HEAD, id: 'PRR_other' } }),
    })
    const approver = createApprover(h.deps)
    await approver.approve(KEY).catch(() => undefined)
    expect(h.ops()).toEqual(['ReviewContext'])
    expect(approver.entry(KEY)).toMatchObject({ message: REASON_APPROVE_PENDING, phase: 'failed' })
  })
})

describe('the Approve click with a draft', () => {
  it('submits the draft review of the mark as an approval', async () => {
    const h = harness(stateWith(mark({ reviewId: 'PRR_draft' })), {
      context: () => context({ pending: { commit: HEAD, id: 'PRR_draft' } }),
      draft: () => answer('submitPullRequestReview'),
    })
    const approver = createApprover(h.deps)
    await approver.approve(KEY)
    expect(h.ops()).toEqual(['ReviewContext', 'ApproveDraft'])
    expect(fields(h.calls[1] ?? [])).toEqual({ review: 'PRR_draft' })
    expect(approver.entry(KEY)?.phase).toBe('approved')
  })
})

describe('the fresh check before the write (ruling A2)', () => {
  const approved = [{ commit: HEAD, state: 'APPROVED', submittedAt: '2026-11-13T09:00:00Z' }]
  const cases: [string, RecommendationMark, ContextOver, string][] = [
    ['the PR head is not the head of the mark', mark(), { head: OTHER }, REASON_APPROVE_CHANGED],
    ['the PR is closed', mark(), { state: 'CLOSED' }, REASON_APPROVE_CLOSED],
    ['the PR is merged', mark(), { state: 'MERGED' }, REASON_APPROVE_CLOSED],
    ['the viewer is the author', mark(), { author: 'Dev-User' }, REASON_APPROVE_OWN],
    ['the viewer approved this commit already', mark(), { reviews: approved }, REASON_APPROVE_DONE],
    ['CI is failing (FAILURE)', mark(), { ci: 'FAILURE' }, REASON_APPROVE_CI_FAILING],
    ['CI is failing (ERROR)', mark(), { ci: 'ERROR' }, REASON_APPROVE_CI_FAILING],
    ['CI is running (PENDING)', mark(), { ci: 'PENDING' }, REASON_APPROVE_CI_RUNNING],
    ['CI is running (EXPECTED)', mark(), { ci: 'EXPECTED' }, REASON_APPROVE_CI_RUNNING],
    [
      'CI of another commit than the head counts as running',
      mark(),
      { ci: 'SUCCESS', ciCommit: OTHER },
      REASON_APPROVE_CI_RUNNING,
    ],
    [
      'draft: CI is failing',
      mark({ reviewId: 'PRR_draft' }),
      { ci: 'FAILURE', pending: { commit: HEAD, id: 'PRR_draft' } },
      REASON_APPROVE_CI_FAILING,
    ],
    [
      'no draft: the viewer has a pending review',
      mark(),
      { pending: { commit: HEAD, id: 'PRR_mine' } },
      REASON_APPROVE_PENDING,
    ],
    [
      'draft: the viewer has no pending review',
      mark({ reviewId: 'PRR_draft' }),
      { pending: null },
      REASON_APPROVE_NO_DRAFT,
    ],
    [
      'draft: the pending review is not the review of the mark',
      mark({ reviewId: 'PRR_draft' }),
      { pending: { commit: HEAD, id: 'PRR_mine' } },
      REASON_APPROVE_NO_DRAFT,
    ],
    [
      'draft: the pending review is on another commit',
      mark({ reviewId: 'PRR_draft' }),
      { pending: { commit: OTHER, id: 'PRR_draft' } },
      REASON_APPROVE_DRAFT_COMMIT,
    ],
  ]
  it.each(cases)('%s: writes nothing and gives a friendly text', async (_name, m, over, text) => {
    const h = harness(stateWith(m), {
      context: () => context(over),
      draft: () => answer('submitPullRequestReview'),
      head: () => answer('addPullRequestReview'),
    })
    const approver = createApprover(h.deps)
    await approver.approve(KEY)
    expect(h.ops().filter(op => op === 'ApproveHead' || op === 'ApproveDraft')).toEqual([])
    expect(approver.entry(KEY)).toMatchObject({ message: text, phase: 'failed' })
  })

  it('approves when CI passed or when the PR has no CI', async () => {
    for (const ci of ['SUCCESS', null]) {
      const h = harness(stateWith(mark()), {
        context: () => context({ ci }),
        head: () => answer('addPullRequestReview'),
      })
      const approver = createApprover(h.deps)
      await approver.approve(KEY)
      expect(h.ops()).toContain('ApproveHead')
      expect(approver.entry(KEY)?.phase).toBe('approved')
    }
  })

  it('the texts for CI are friendly', () => {
    expect(REASON_APPROVE_CI_FAILING).toBe(
      "CI is failing on this pull request, so Bifrost didn't approve it.",
    )
    expect(REASON_APPROVE_CI_RUNNING).toBe('CI is still running. Approve when it has passed.')
  })

  it('a later comment of the viewer on the head does not end the approval', async () => {
    const reviews = [
      { commit: HEAD, state: 'APPROVED', submittedAt: '2026-11-13T09:00:00Z' },
      { commit: HEAD, state: 'COMMENTED', submittedAt: '2026-11-13T10:00:00Z' },
    ]
    const h = harness(stateWith(mark()), {
      context: () => context({ reviews }),
      head: () => answer('addPullRequestReview'),
    })
    const approver = createApprover(h.deps)
    await approver.approve(KEY)
    expect(h.ops()).toEqual(['ReviewContext', 'ReviewThreads'])
    expect(approver.entry(KEY)).toMatchObject({ message: REASON_APPROVE_DONE, phase: 'failed' })
  })

  it('a later decision of the viewer on the commit is not an approval', async () => {
    const reviews = [
      { commit: HEAD, state: 'APPROVED', submittedAt: '2026-11-13T09:00:00Z' },
      { commit: HEAD, state: 'CHANGES_REQUESTED', submittedAt: '2026-11-13T10:00:00Z' },
    ]
    const h = harness(stateWith(mark()), {
      context: () => context({ reviews }),
      head: () => answer('addPullRequestReview'),
    })
    const approver = createApprover(h.deps)
    await approver.approve(KEY)
    expect(h.ops()).toContain('ApproveHead')
  })

  it('a mark that is not Approve any more after the read writes nothing', async () => {
    const h = harness(stateWith(mark()), {
      context: () => {
        h.set(stateWith(mark({ value: 'comment' })))
        return context()
      },
      head: () => answer('addPullRequestReview'),
    })
    const approver = createApprover(h.deps)
    await approver.approve(KEY)
    expect(h.ops()).toEqual(['ReviewContext'])
    expect(approver.entry(KEY)).toMatchObject({ message: REASON_APPROVE_NOT_SUGGESTED })
  })

  it('a failed read writes nothing, and the masked raw line goes to the Event log', async () => {
    const failed: ExecResult = { code: 1, stderr: `HTTP 502 for ${TOKEN}`, stdout: '' }
    const h = harness(stateWith(mark()), { context: () => failed })
    const approver = createApprover(h.deps)
    await approver.approve(KEY)
    expect(h.ops()).toEqual(['ReviewContext'])
    expect(approver.entry(KEY)).toMatchObject({ message: REASON_PR_READ_FAILED, phase: 'failed' })
    expect(h.events.join('\n')).not.toContain(TOKEN)
    expect(h.events.join('\n')).toContain('HTTP 502 for ***')
  })
})

describe('the guard ties the write to the PR of the row (fix round 1)', () => {
  const others = [
    'https://github.com/acme/api/pull/8',
    'https://github.com/other/api/pull/7',
    'https://github.com/acme/web/pull/7',
    'https://example.com/acme/api/pull/7',
    '',
  ]
  it.each(others)('a fresh read that gives the PR %j writes nothing', async url => {
    for (const m of [mark(), mark({ reviewId: 'PRR_draft' })]) {
      const h = harness(stateWith(m), {
        context: () =>
          context({ pending: m.reviewId === null ? null : { commit: HEAD, id: 'PRR_draft' }, url }),
        draft: () => answer('submitPullRequestReview'),
        head: () => answer('addPullRequestReview'),
      })
      const approver = createApprover(h.deps)
      await approver.approve(KEY)
      expect(h.ops()).toEqual(['ReviewContext'])
      expect(approver.entry(KEY)).toMatchObject({
        message: REASON_APPROVE_REFUSED,
        phase: 'failed',
      })
    }
  })

  it('prKeyOfUrl reads the PR key from a GitHub PR link only', () => {
    expect(prKeyOfUrl('https://github.com/acme/api/pull/7')).toBe(KEY)
    expect(prKeyOfUrl('https://github.com/Acme/my.repo/pull/12')).toBe('Acme/my.repo#12')
    for (const bad of [
      '',
      'https://github.com/acme/api/pull/7/files',
      'https://github.com/acme/api/issues/7',
      'http://github.com/acme/api/pull/7',
      'https://github.com.evil/acme/api/pull/7',
      'https://github.com/acme/../pull/7',
      'https://github.com/acme/api/pull/0',
    ]) {
      expect(prKeyOfUrl(bad)).toBe('')
    }
  })
})

describe('the refusal of a click that comes anyway', () => {
  const cases: [string, ReviewsState, PrData | null][] = [
    ['no mark', stateWith(null), pr()],
    ['a Comment mark', stateWith(mark({ value: 'comment' })), pr()],
    ['a Request changes mark', stateWith(mark({ value: 'request-changes' })), pr()],
    ['a mark on an older head', stateWith(mark({ headSha: OTHER })), pr()],
    [
      'an approval of the viewer on the head in the poll',
      stateWith(mark()),
      pr({ viewerReviews: [{ commit: HEAD, state: 'APPROVED', submittedAt: 900 }] }),
    ],
    ['a PR that the poll does not list', stateWith(mark()), null],
    ['a queued review', stateWith(mark(), { queue: [{ at: 1, key: KEY, kind: 'review' }] }), pr()],
  ]
  it.each(cases)('%s: refuses and calls no gh', async (_name, state, poll) => {
    const h = harness(state, { context: () => context() }, poll)
    const approver = createApprover(h.deps)
    await expect(approver.approve(KEY)).rejects.toThrow(REFUSED)
    expect(h.calls).toEqual([])
    expect(approver.entry(KEY)).toBeNull()
  })

  it('a bad key is refused', async () => {
    const h = harness(stateWith(mark()), {})
    const approver = createApprover(h.deps)
    await expect(approver.approve('acme/..#7')).rejects.toThrow(REFUSED)
    expect(h.calls).toEqual([])
  })
})

describe('the write that runs (ruling A4)', () => {
  it('shows running while the write runs, and refuses a second click', async () => {
    let release: (r: ExecResult) => void = () => undefined
    const h = harness(stateWith(mark()), {
      context: () => context(),
      head: () =>
        new Promise<ExecResult>(resolve => {
          release = resolve
        }),
    })
    const approver = createApprover(h.deps)
    const first = approver.approve(KEY)
    for (let i = 0; i < 50 && !h.ops().includes('ApproveHead'); i++) await Promise.resolve()
    expect(approver.entry(KEY)?.phase).toBe('running')
    await expect(approver.approve(KEY)).rejects.toThrow(REFUSED)
    release(answer('addPullRequestReview'))
    await first
    expect(h.ops().filter(op => op === 'ApproveHead')).toHaveLength(1)
  })

  it('an unknown result is never tried again by itself, and waits for the next poll', async () => {
    const timeout: ExecResult = { code: 1, stderr: '', stdout: '', timedOut: true }
    const results = [timeout, answer('addPullRequestReview')]
    const h = harness(stateWith(mark()), {
      context: () => context(),
      head: () => results.shift() ?? timeout,
    })
    const approver = createApprover(h.deps)
    h.setNow(2_000)
    await approver.approve(KEY)
    expect(h.ops()).toEqual(['ReviewContext', 'ApproveHead'])
    expect(approver.entry(KEY)).toMatchObject({ message: REASON_APPROVE_UNKNOWN, phase: 'unknown' })
    expect(h.polls()).toBe(1)
    // A click before the next poll gets a refusal, and no call.
    await expect(approver.approve(KEY)).rejects.toThrow(REFUSED)
    expect(h.calls).toHaveLength(2)
    // A poll that started before the end of the write shows nothing new.
    h.setPollStart(1_500)
    await expect(approver.approve(KEY)).rejects.toThrow(REFUSED)
    // The next poll shows no approval, so the user can click again.
    h.setPollStart(2_500)
    expect(approver.entry(KEY)).toBeNull()
    h.setNow(3_000)
    await approver.approve(KEY)
    expect(h.ops().filter(op => op === 'ApproveHead')).toHaveLength(2)
    expect(approver.entry(KEY)?.phase).toBe('approved')
  })

  it('an approval waits for the next poll too, so a second click is refused', async () => {
    const h = harness(stateWith(mark()), {
      context: () => context(),
      head: () => answer('addPullRequestReview'),
    })
    const approver = createApprover(h.deps)
    await approver.approve(KEY)
    await expect(approver.approve(KEY)).rejects.toThrow(REFUSED)
    expect(h.ops().filter(op => op === 'ApproveHead')).toHaveLength(1)
  })

  it('an unknown result says in the Event log that Bifrost cannot tell if it worked', async () => {
    const reset: ExecResult = { code: 1, stderr: `connection reset ${TOKEN}`, stdout: '' }
    const h = harness(stateWith(mark()), { context: () => context(), head: () => reset })
    const approver = createApprover(h.deps)
    await approver.approve(KEY)
    expect(approver.entry(KEY)).toMatchObject({ message: REASON_APPROVE_UNKNOWN, phase: 'unknown' })
    expect(h.events).toHaveLength(1)
    expect(h.events[0]).toContain(
      "Bifrost couldn't tell if GitHub saved the approval of acme/api#7",
    )
    expect(h.events[0]).toContain('connection reset ***')
    expect(h.events[0]).not.toContain("didn't take")
  })

  it('a refusal of GitHub gives a friendly text, and the raw line goes to the log', async () => {
    const refused: ExecResult = { code: 1, stderr: `Bad token ${TOKEN} (HTTP 422)`, stdout: '' }
    const h = harness(stateWith(mark()), {
      context: () => context(),
      head: () => refused,
    })
    const approver = createApprover(h.deps)
    await approver.approve(KEY)
    expect(approver.entry(KEY)).toMatchObject({ message: REASON_APPROVE_FAILED, phase: 'failed' })
    expect(h.events).toHaveLength(1)
    expect(h.events[0]).toContain('Bad token *** (HTTP 422)')
    expect(h.events[0]).not.toContain(TOKEN)
    // A known failure wrote nothing, so the user can click again at once.
    await approver.approve(KEY)
    expect(h.ops().filter(op => op === 'ApproveHead')).toHaveLength(2)
  })
})

describe('approveKey (the check of reviews:approve)', () => {
  const row = { key: KEY } as ToReviewRow
  const watcher = {
    current: () => ({ ...EMPTY_REVIEWS, availability: 'ok', toReview: [row] }),
  } as unknown as ReviewsWatcher

  it('takes one PR key of a To review row', () => {
    expect(approveKey(watcher, [KEY])).toBe(KEY)
  })

  it('refuses a bad key, a key that is not a row, and more or less than one value', () => {
    const bad: unknown[][] = [
      [],
      [KEY, 'extra'],
      [KEY, undefined],
      [42],
      [null],
      [{ key: KEY }],
      ['acme/api#8'],
      ['acme/..#7'],
      [`${KEY} `],
      ['https://github.com/acme/api/pull/7'],
    ]
    for (const args of bad) expect(() => approveKey(watcher, args)).toThrow(REFUSED_UNKNOWN_PR)
  })
})
