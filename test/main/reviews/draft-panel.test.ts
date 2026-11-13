// The flow of the Review panel (rulings B4 to B9). The fake gh never calls GitHub.
import { describe, expect, it } from 'vitest'
import type { ExecResult } from '../../../src/main/claude/cli'
import {
  checkDraftEdits,
  createDraftEditor,
  type DraftDeps,
  type DraftEditor,
  REFUSED_BAD_EDITS,
  REFUSED_NO_DRAFT,
} from '../../../src/main/reviews/draft-panel'
import type { Gh } from '../../../src/main/reviews/gh'
import type { ApproveEntry } from '../../../src/main/reviews/model'
import type { PrData } from '../../../src/main/reviews/pr-data'
import {
  REASON_APPROVE_CI_FAILING,
  REASON_APPROVE_CI_RUNNING,
  REASON_APPROVE_DONE,
  REASON_DISCARD_FAILED,
  REASON_DRAFT_BLANK,
  REASON_DRAFT_CHANGED,
  REASON_DRAFT_CLOSED,
  REASON_DRAFT_COMMIT,
  REASON_DRAFT_EDIT_FAILED,
  REASON_DRAFT_EDITED,
  REASON_DRAFT_EMPTY,
  REASON_DRAFT_GONE,
  REASON_DRAFT_NEEDS_SUMMARY,
  REASON_DRAFT_TOO_MANY,
  REASON_INSTEAD_FAILED,
  REASON_INSTEAD_UNKNOWN,
  REASON_SEND_UNKNOWN,
} from '../../../src/main/reviews/round-text'
import {
  type DraftComment,
  EMPTY_STATE,
  emptyPrState,
  type RecommendationMark,
  type ReviewsState,
} from '../../../src/main/reviews/state'
import type { ReviewsStateStore } from '../../../src/main/reviews/state-store'
import { type DraftEdits, MAX_DRAFT_COMMENTS, MAX_REVIEW_TEXT } from '../../../src/shared/reviews'

const KEY = 'acme/api#7'
const HEAD = 'a'.repeat(40)
const OTHER = 'b'.repeat(40)
const VIEWER = 'dev-user'
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
    viewerPendingReviewId: 'PRR_draft',
    viewerReviews: [],
    ...over,
  }
}

const mark = (over: Partial<RecommendationMark> = {}): RecommendationMark => ({
  at: 500,
  headSha: HEAD,
  reviewId: 'PRR_draft',
  value: 'request-changes',
  why: 'The token leaks.',
  ...over,
})

const drafted = (path: string, line: number, body: string): DraftComment => ({
  at: 400,
  body,
  line,
  path,
  prKey: KEY,
  reviewId: 'PRR_draft',
})

const stateWith = (
  m: RecommendationMark | null,
  extra: Partial<ReviewsState> = {},
): ReviewsState => ({
  ...EMPTY_STATE,
  drafts: [drafted('src/a.ts', 3, 'Claude 1'), drafted('', 0, 'Summary of Claude')],
  prs: { [KEY]: { ...emptyPrState(), recommendation: m } },
  ...extra,
})

interface ContextOver {
  // The state of the rollup of the head commit. Null or no value is a PR with no CI.
  ci?: string | null
  state?: string
  author?: string
  head?: string
  pending?: { id: string; commit: string } | null
  url?: string
  // The submitted reviews of the viewer.
  reviews?: { state: string; commit: string; submittedAt: string }[]
}

// The answer of the ReviewContext query of the fresh read.
function context(over: ContextOver = {}): ExecResult {
  const pending = over.pending === undefined ? { commit: HEAD, id: 'PRR_draft' } : over.pending
  const pullRequest = {
    author: { login: over.author ?? 'bob' },
    baseRefName: 'main',
    baseRefOid: 'c'.repeat(40),
    body: 'Keep the token.',
    commits: {
      nodes: [
        {
          commit: {
            oid: over.head ?? HEAD,
            statusCheckRollup: over.ci == null ? null : { state: over.ci },
          },
        },
      ],
    },
    headRefName: 'token',
    headRefOid: over.head ?? HEAD,
    id: 'PR_7',
    pending: {
      nodes:
        pending === null
          ? []
          : [{ body: 'x', commit: { oid: pending.commit }, id: pending.id, viewerDidAuthor: true }],
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
    title: 'Keep the token',
    url: over.url ?? 'https://github.com/acme/api/pull/7',
  }
  return { code: 0, stderr: '', stdout: JSON.stringify({ data: { repository: { pullRequest } } }) }
}

interface DraftOver {
  state?: string
  mine?: boolean
  commit?: string
  body?: string
  comments?: Record<string, unknown>[]
  more?: boolean
}

const COMMENT_1 = {
  body: 'Claude 1',
  diffHunk: '@@ -1,5 +1,5 @@\n one\n two\n-three\n+THREE\n four\n five',
  id: 'PRRC_1',
  line: 3,
  path: 'src/a.ts',
  startLine: null,
}
const COMMENT_2 = {
  body: 'Mine <img src=x onerror=alert(1)>',
  diffHunk: '@@ -7,2 +7,3 @@\n seven\n+eight\n nine',
  id: 'PRRC_2',
  line: 9,
  path: 'src/b.ts',
  startLine: 7,
}

// The answer of the DraftReview query: the pending review of the mark, read by its node ID.
function draftRead(over: DraftOver = {}): ExecResult {
  const node = {
    body: over.body ?? 'Summary of Claude',
    comments: {
      nodes: over.comments ?? [COMMENT_1, COMMENT_2],
      pageInfo: { endCursor: over.more ? 'c1' : null, hasNextPage: over.more === true },
    },
    commit: { oid: over.commit ?? HEAD },
    id: 'PRR_draft',
    state: over.state ?? 'PENDING',
    viewerDidAuthor: over.mine ?? true,
  }
  return { code: 0, stderr: '', stdout: JSON.stringify({ data: { node } }) }
}

const ok = (field: string, inner: Record<string, unknown>): ExecResult => ({
  code: 0,
  stderr: '',
  stdout: JSON.stringify({ data: { [field]: inner } }),
})
const REVIEW = { pullRequestReview: { id: 'PRR_draft', state: 'PENDING' } }
const EDITED = ok('updatePullRequestReview', REVIEW)
const COMMENT_EDITED = ok('updatePullRequestReviewComment', {
  pullRequestReviewComment: { id: 'PRRC_1' },
})
const REMOVED = ok('deletePullRequestReviewComment', { pullRequestReview: { id: 'PRR_draft' } })
const DISCARDED = ok('deletePullRequestReview', { pullRequestReview: { id: 'PRR_draft' } })
const sentAs = (state: string): ExecResult =>
  ok('submitPullRequestReview', { pullRequestReview: { id: 'PRR_draft', state } })
const NOT_FOUND: ExecResult = {
  code: 1,
  stderr: 'gh: Could not resolve to a node',
  stdout: JSON.stringify({
    data: { x: null },
    errors: [
      { message: "Could not resolve to a node with the global id of 'PRRC_2'", type: 'NOT_FOUND' },
    ],
  }),
}
const failedWith = (message: string): ExecResult => ({
  code: 1,
  stderr: `gh: ${message}`,
  stdout: JSON.stringify({ data: { x: null }, errors: [{ message }] }),
})
const TIMED_OUT: ExecResult = { code: 1, stderr: '', stdout: '', timedOut: true }

const OPS = [
  'ReviewContext',
  'ReviewThreads',
  'DraftReview',
  'EditBody',
  'EditComment',
  'RemoveComment',
  'DiscardDraft',
  'SendComment',
  'SendChanges',
] as const
type Op = (typeof OPS)[number]
const WRITES: readonly Op[] = [
  'EditBody',
  'EditComment',
  'RemoveComment',
  'DiscardDraft',
  'SendComment',
  'SendChanges',
]

const opOf = (args: string[]): Op | 'other' => {
  const query = args.find(a => a.startsWith('query=')) ?? ''
  const name = /^query=(?:query|mutation) (\w+)/.exec(query)?.[1] ?? ''
  return (OPS as readonly string[]).includes(name) ? (name as Op) : 'other'
}

// The -f fields of one call, without the query.
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

// An answer that comes when the promise resolves, and an answer that throws.
const later =
  (p: Promise<ExecResult>): (() => Promise<ExecResult>) =>
  () =>
    p
const throwing = (): (() => ExecResult) => () => {
  throw new Error('boom')
}

type Answers = Partial<Record<Op, ExecResult[] | (() => ExecResult | Promise<ExecResult>)>>

const NO_THREADS: ExecResult = {
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

function harness(state: ReviewsState, answers: Answers, poll: PrData | null = pr()) {
  let s = state
  let pollStart = 0
  let now = 1_000
  let polls = 0
  const calls: string[][] = []
  const events: string[] = []
  // The answers of the open of the panel. They come before the answers of the test.
  const pre: { ReviewContext: ExecResult[]; DraftReview: ExecResult[] } = {
    DraftReview: [],
    ReviewContext: [],
  }
  const gh: Gh = {
    async run(args, opts) {
      if (opts?.input !== undefined) throw new Error('no stdin')
      calls.push(args)
      const op = opOf(args)
      if (op === 'other') throw new Error('an unknown call')
      if (op === 'ReviewContext' || op === 'DraftReview') {
        const first = pre[op].shift()
        if (first !== undefined) return first
      }
      const answer = answers[op]
      if (op === 'ReviewThreads' && answer === undefined) return NO_THREADS
      if (typeof answer === 'function') return await answer()
      const next = answer?.shift()
      if (next === undefined) throw new Error(`no answer for ${op}`)
      return next
    },
  }
  const store: Pick<ReviewsStateStore, 'get' | 'change'> = {
    change: async fn => {
      s = fn(s)
      return s
    },
    get: () => s,
  }
  const deps: DraftDeps = {
    changed: () => undefined,
    eventNotice: text => events.push(text),
    gh,
    log: () => undefined,
    now: () => now,
    pollStartedAt: () => pollStart,
    requestPoll: () => {
      polls++
    },
    store,
    toReviewPr: key => (key === KEY ? poll : null),
    viewer: () => VIEWER,
  }
  return {
    calls,
    deps,
    events,
    ops: () => calls.map(opOf),
    polls: () => polls,
    pre,
    setNow: (at: number) => {
      now = at
    },
    setPollStart: (at: number) => {
      pollStart = at
    },
    state: () => s,
    writes: () => calls.map(opOf).filter(op => (WRITES as readonly string[]).includes(op)),
  }
}

// Open the panel first with a good read, as the user does. Then forget the calls of the open.
async function openedEditor(h: ReturnType<typeof harness>): Promise<DraftEditor> {
  h.pre.ReviewContext.push(context())
  h.pre.DraftReview.push(draftRead())
  const editor = createDraftEditor(h.deps)
  const open = await editor.open(KEY)
  if (!open.ok) throw new Error(open.message)
  h.calls.length = 0
  return editor
}

const edits = (over: Partial<DraftEdits> = {}): DraftEdits => ({
  body: 'Summary of Claude',
  comments: [
    { body: 'Claude 1', id: 'PRRC_1' },
    { body: COMMENT_2.body, id: 'PRRC_2' },
  ],
  verdict: 'request-changes',
  ...over,
})

describe('the Review panel opens (ruling B4)', () => {
  it("gives Claude's recommendation, the summary and each comment of the draft", async () => {
    const h = harness(stateWith(mark()), { DraftReview: [draftRead()], ReviewContext: [context()] })
    const editor = createDraftEditor(h.deps)
    const open = await editor.open(KEY)
    expect(h.ops()).toEqual(['ReviewContext', 'DraftReview'])
    expect(fields(h.calls[1] ?? [])).toEqual({ id: 'PRR_draft' })
    expect(h.writes()).toEqual([])
    expect(open).toEqual({
      draft: {
        body: 'Summary of Claude',
        changed: false,
        comments: [
          {
            body: 'Claude 1',
            hunk: ['-three', '+THREE', ' four', ' five'],
            id: 'PRRC_1',
            line: 3,
            path: 'src/a.ts',
            startLine: null,
            yours: false,
          },
          {
            body: COMMENT_2.body,
            hunk: ['@@ -7,2 +7,3 @@', ' seven', '+eight', ' nine'],
            id: 'PRRC_2',
            line: 9,
            path: 'src/b.ts',
            startLine: 7,
            yours: true,
          },
        ],
        key: KEY,
        recommendation: 'request-changes',
        why: 'The token leaks.',
      },
      ok: true,
    })
  })

  it('says when the PR changed after the review, and still shows the draft', async () => {
    const h = harness(stateWith(mark()), {
      DraftReview: [draftRead()],
      ReviewContext: [context({ head: OTHER })],
    })
    const open = await createDraftEditor(h.deps).open(KEY)
    expect(open.ok && open.draft.changed).toBe(true)
  })

  it('reads the next page of comments, up to the cap', async () => {
    const many = (n: number, from: number) =>
      Array.from({ length: n }, (_, i) => ({ ...COMMENT_1, id: `PRRC_${from + i}` }))
    const pages = [
      draftRead({ comments: many(100, 0), more: true }),
      draftRead({ comments: many(2, 100) }),
    ]
    const h = harness(stateWith(mark()), { DraftReview: pages, ReviewContext: [context()] })
    const open = await createDraftEditor(h.deps).open(KEY)
    expect(open.ok && open.draft.comments).toHaveLength(102)
    expect(fields(h.calls[2] ?? [])).toEqual({ after: 'c1', id: 'PRR_draft' })
  })

  it('refuses a draft with more comments than the cap', async () => {
    const pages = Array.from({ length: 4 }, () => draftRead({ more: true }))
    const h = harness(stateWith(mark()), { DraftReview: pages, ReviewContext: [context()] })
    expect(await createDraftEditor(h.deps).open(KEY)).toEqual({
      message: REASON_DRAFT_TOO_MANY,
      ok: false,
    })
  })

  const refusals: [string, Answers, string][] = [
    ['the PR is closed', { ReviewContext: [context({ state: 'CLOSED' })] }, REASON_DRAFT_CLOSED],
    ['the PR is merged', { ReviewContext: [context({ state: 'MERGED' })] }, REASON_DRAFT_CLOSED],
    ['no pending review', { ReviewContext: [context({ pending: null })] }, REASON_DRAFT_GONE],
    [
      'another pending review',
      { ReviewContext: [context({ pending: { commit: HEAD, id: 'PRR_mine' } })] },
      REASON_DRAFT_GONE,
    ],
    [
      'a draft on another commit',
      { ReviewContext: [context({ pending: { commit: OTHER, id: 'PRR_draft' } })] },
      REASON_DRAFT_COMMIT,
    ],
    [
      'a review that is not pending',
      { DraftReview: [draftRead({ state: 'COMMENTED' })], ReviewContext: [context()] },
      REASON_DRAFT_GONE,
    ],
    [
      'a review of another user',
      { DraftReview: [draftRead({ mine: false })], ReviewContext: [context()] },
      REASON_DRAFT_GONE,
    ],
  ]
  it.each(refusals)('%s: gives a friendly text and writes nothing', async (_n, answers, text) => {
    const h = harness(stateWith(mark()), answers)
    expect(await createDraftEditor(h.deps).open(KEY)).toEqual({ message: text, ok: false })
    expect(h.writes()).toEqual([])
  })

  it('refuses a row with no draft of Claude and calls nothing', async () => {
    const states = [
      stateWith(null),
      stateWith(mark({ reviewId: null })),
      stateWith(mark({ value: 'approve' })),
      stateWith(mark(), { queue: [{ at: 1, key: KEY, kind: 'review' }] }),
    ]
    for (const s of states) {
      const h = harness(s, {})
      await expect(createDraftEditor(h.deps).open(KEY)).rejects.toThrow(REFUSED_NO_DRAFT)
      expect(h.calls).toEqual([])
    }
    const h = harness(stateWith(mark()), {}, null)
    await expect(createDraftEditor(h.deps).open(KEY)).rejects.toThrow(REFUSED_NO_DRAFT)
    await expect(createDraftEditor(h.deps).open('not a key')).rejects.toThrow(REFUSED_NO_DRAFT)
  })

  it('a failed read puts the raw line, with the token masked, in the Event log only', async () => {
    const h = harness(stateWith(mark()), {
      ReviewContext: [{ code: 1, stderr: `gh: bad ${TOKEN}`, stdout: '' }],
    })
    const open = await createDraftEditor(h.deps).open(KEY)
    expect(open.ok).toBe(false)
    expect(open.ok ? '' : open.message).not.toContain(TOKEN)
    expect(h.events).toHaveLength(1)
    expect(h.events[0]).toContain(KEY)
    expect(h.events[0]).not.toContain(TOKEN)
  })
})

describe('Send review (ruling B7)', () => {
  it('applies each edit to the draft, then submits with the event of the switch', async () => {
    const h = harness(stateWith(mark()), {
      DraftReview: [draftRead()],
      EditBody: [EDITED],
      EditComment: [COMMENT_EDITED],
      RemoveComment: [REMOVED],
      ReviewContext: [context()],
      SendComment: [sentAs('COMMENTED')],
    })
    const editor = await openedEditor(h)
    const result = await editor.send(
      KEY,
      edits({
        body: 'A new summary',
        comments: [
          { body: 'A better comment', id: 'PRRC_1' },
          { body: null, id: 'PRRC_2' },
        ],
        verdict: 'comment',
      }),
    )
    expect(result).toEqual({ ok: true })
    expect(h.ops()).toEqual([
      'ReviewContext',
      'DraftReview',
      'EditBody',
      'EditComment',
      'RemoveComment',
      'SendComment',
    ])
    expect(fields(h.calls[2] ?? [])).toEqual({ body: 'A new summary', review: 'PRR_draft' })
    expect(fields(h.calls[3] ?? [])).toEqual({ body: 'A better comment', comment: 'PRRC_1' })
    expect(fields(h.calls[4] ?? [])).toEqual({ comment: 'PRRC_2' })
    expect(fields(h.calls[5] ?? [])).toEqual({ review: 'PRR_draft' })
    expect(editor.entry(KEY)).toMatchObject({ gone: 'PRR_draft', phase: 'sent' })
    // The draft is no longer a draft, so the mark goes.
    expect(h.state().prs[KEY]?.recommendation).toBeNull()
    expect(h.polls()).toBe(1)
  })

  it('sends only what changed', async () => {
    const h = harness(stateWith(mark()), {
      DraftReview: [draftRead()],
      ReviewContext: [context()],
      SendChanges: [sentAs('CHANGES_REQUESTED')],
    })
    expect(await (await openedEditor(h)).send(KEY, edits())).toEqual({ ok: true })
    expect(h.writes()).toEqual(['SendChanges'])
  })

  const refusals: [string, Answers, DraftEdits, string][] = [
    [
      'the PR is closed',
      { ReviewContext: [context({ state: 'CLOSED' })] },
      edits(),
      REASON_DRAFT_CLOSED,
    ],
    [
      'the PR changed after the review',
      { DraftReview: [draftRead()], ReviewContext: [context({ head: OTHER })] },
      edits(),
      REASON_DRAFT_CHANGED,
    ],
    [
      'the draft is gone',
      { ReviewContext: [context({ pending: null })] },
      edits(),
      REASON_DRAFT_GONE,
    ],
    [
      'the draft is on another commit',
      { ReviewContext: [context({ pending: { commit: OTHER, id: 'PRR_draft' } })] },
      edits(),
      REASON_DRAFT_COMMIT,
    ],
    [
      'the review is not pending',
      { DraftReview: [draftRead({ state: 'COMMENTED' })], ReviewContext: [context()] },
      edits(),
      REASON_DRAFT_GONE,
    ],
    [
      'the user added a comment on GitHub after the open',
      {
        DraftReview: [
          draftRead({ comments: [COMMENT_1, COMMENT_2, { ...COMMENT_1, id: 'PRRC_3' }] }),
        ],
        ReviewContext: [context()],
      },
      edits(),
      REASON_DRAFT_EDITED,
    ],
    [
      'a kept comment is gone on GitHub',
      { DraftReview: [draftRead({ comments: [COMMENT_1] })], ReviewContext: [context()] },
      edits(),
      REASON_DRAFT_EDITED,
    ],
    [
      'nothing is left to send',
      { DraftReview: [draftRead()], ReviewContext: [context()] },
      edits({
        body: '  ',
        comments: [
          { body: null, id: 'PRRC_1' },
          { body: null, id: 'PRRC_2' },
        ],
        verdict: 'comment',
      }),
      REASON_DRAFT_EMPTY,
    ],
    [
      'request changes with no summary',
      { DraftReview: [draftRead()], ReviewContext: [context()] },
      edits({ body: '' }),
      REASON_DRAFT_NEEDS_SUMMARY,
    ],
    [
      'a kept comment with no text',
      { DraftReview: [draftRead()], ReviewContext: [context()] },
      edits({
        comments: [
          { body: ' ', id: 'PRRC_1' },
          { body: 'x', id: 'PRRC_2' },
        ],
      }),
      REASON_DRAFT_BLANK,
    ],
  ]
  it.each(refusals)('%s: writes nothing and keeps the draft', async (_n, answers, e, text) => {
    const h = harness(stateWith(mark()), answers)
    const editor = await openedEditor(h)
    expect(await editor.send(KEY, e)).toEqual({ message: text, ok: false })
    expect(h.writes()).toEqual([])
    expect(h.state().prs[KEY]?.recommendation).toEqual(mark())
    expect(editor.entry(KEY)).toMatchObject({ message: text, phase: 'failed' })
  })

  it('a failure in the middle leaves the review pending, and Send can run again', async () => {
    const h = harness(stateWith(mark()), {
      // GitHub keeps the summary that the first Send wrote.
      DraftReview: [draftRead(), draftRead({ body: 'New', comments: [COMMENT_1, COMMENT_2] })],
      EditBody: [EDITED],
      EditComment: [failedWith(`Body is too long ${TOKEN}`), COMMENT_EDITED],
      RemoveComment: [NOT_FOUND],
      ReviewContext: [context(), context()],
      SendChanges: [sentAs('CHANGES_REQUESTED')],
    })
    const editor = await openedEditor(h)
    const e = edits({
      body: 'New',
      comments: [
        { body: 'New 1', id: 'PRRC_1' },
        { body: null, id: 'PRRC_2' },
      ],
    })
    expect(await editor.send(KEY, e)).toEqual({ message: REASON_DRAFT_EDIT_FAILED, ok: false })
    expect(h.writes()).toEqual(['EditBody', 'EditComment'])
    expect(h.state().prs[KEY]?.recommendation).toEqual(mark())
    expect(editor.entry(KEY)?.phase).toBe('failed')
    expect(h.events).toHaveLength(1)
    expect(h.events[0]).toContain('Body is too long')
    expect(h.events[0]).not.toContain(TOKEN)
    // The second Send reads the draft again. A comment that is gone counts as removed.
    expect(await editor.send(KEY, e)).toEqual({ ok: true })
    expect(h.writes()).toEqual([
      'EditBody',
      'EditComment',
      'EditComment',
      'RemoveComment',
      'SendChanges',
    ])
  })

  it('an unknown result of the submit is never sent again by itself', async () => {
    const h = harness(stateWith(mark()), {
      DraftReview: [draftRead()],
      ReviewContext: [context()],
      SendChanges: [TIMED_OUT],
    })
    const editor = await openedEditor(h)
    expect(await editor.send(KEY, edits())).toEqual({ message: REASON_SEND_UNKNOWN, ok: false })
    expect(editor.entry(KEY)?.phase).toBe('unknown')
    expect(h.polls()).toBe(1)
    // GitHub can have sent the review, so the mark stays until the poll shows the truth.
    expect(h.state().prs[KEY]?.recommendation).toEqual(mark())
    const calls = h.calls.length
    await expect(editor.send(KEY, edits())).rejects.toThrow(REFUSED_NO_DRAFT)
    await expect(editor.open(KEY)).rejects.toThrow(REFUSED_NO_DRAFT)
    expect(h.calls).toHaveLength(calls)
    // A poll that starts after the end of the write ends the entry.
    h.setPollStart(5_000)
    expect(editor.entry(KEY)).toBeNull()
  })

  it('a submit saved in another state keeps the mark and is not sent again', async () => {
    const h = harness(stateWith(mark()), {
      DraftReview: [draftRead()],
      ReviewContext: [context()],
      SendChanges: [sentAs('COMMENTED')],
    })
    const editor = await openedEditor(h)
    expect((await editor.send(KEY, edits())).ok).toBe(false)
    expect(editor.entry(KEY)?.phase).toBe('unknown')
    await expect(editor.send(KEY, edits())).rejects.toThrow(REFUSED_NO_DRAFT)
  })

  it('a throw after the start of the submit gives an unknown result', async () => {
    const h = harness(stateWith(mark()), {
      DraftReview: [draftRead()],
      ReviewContext: [context()],
      SendChanges: throwing(),
    })
    const editor = await openedEditor(h)
    expect(await editor.send(KEY, edits())).toEqual({ message: REASON_SEND_UNKNOWN, ok: false })
    expect(editor.entry(KEY)?.phase).toBe('unknown')
  })

  it('a second Send while one runs is refused', async () => {
    let release: () => void = () => undefined
    const late = new Promise<ExecResult>(resolve => {
      release = () => resolve(context())
    })
    const h = harness(stateWith(mark()), {
      DraftReview: [draftRead()],
      ReviewContext: later(late),
      SendChanges: [sentAs('CHANGES_REQUESTED')],
    })
    const editor = await openedEditor(h)
    const first = editor.send(KEY, edits())
    expect(editor.entry(KEY)?.phase).toBe('running')
    await expect(editor.send(KEY, edits())).rejects.toThrow(REFUSED_NO_DRAFT)
    release()
    expect(await first).toEqual({ ok: true })
  })
})

describe('Discard draft (ruling B8)', () => {
  it('deletes the pending review of the mark, then clears the mark', async () => {
    const h = harness(stateWith(mark()), {
      DiscardDraft: [DISCARDED],
      DraftReview: [draftRead()],
      ReviewContext: [context()],
    })
    const editor = await openedEditor(h)
    expect(await editor.discard(KEY)).toEqual({ ok: true })
    expect(h.ops()).toEqual(['ReviewContext', 'DraftReview', 'DiscardDraft'])
    expect(fields(h.calls[2] ?? [])).toEqual({ review: 'PRR_draft' })
    expect(h.state().prs[KEY]?.recommendation).toBeNull()
    expect(editor.entry(KEY)).toMatchObject({ gone: 'PRR_draft', phase: 'discarded' })
    expect(h.polls()).toBe(1)
  })

  it('a moved head does not stop the discard, and a not found counts as done', async () => {
    const h = harness(stateWith(mark()), {
      DiscardDraft: [NOT_FOUND],
      DraftReview: [draftRead()],
      ReviewContext: [context({ head: OTHER })],
    })
    expect(await (await openedEditor(h)).discard(KEY)).toEqual({ ok: true })
    expect(h.state().prs[KEY]?.recommendation).toBeNull()
  })

  const refusals: [string, ContextOver, string][] = [
    ['the PR is closed', { state: 'CLOSED' }, REASON_DRAFT_CLOSED],
    ['the draft is gone', { pending: null }, REASON_DRAFT_GONE],
    [
      'the draft is another review',
      { pending: { commit: HEAD, id: 'PRR_mine' } },
      REASON_DRAFT_GONE,
    ],
    [
      'the draft is on another commit',
      { pending: { commit: OTHER, id: 'PRR_draft' } },
      REASON_DRAFT_COMMIT,
    ],
  ]
  it.each(refusals)('%s: deletes nothing', async (_n, over, text) => {
    const h = harness(stateWith(mark()), { ReviewContext: [context(over)] })
    expect(await (await openedEditor(h)).discard(KEY)).toEqual({ message: text, ok: false })
    expect(h.writes()).toEqual([])
    expect(h.state().prs[KEY]?.recommendation).toEqual(mark())
  })

  it('a failed delete keeps the mark', async () => {
    const h = harness(stateWith(mark()), {
      DiscardDraft: [failedWith('No')],
      DraftReview: [draftRead()],
      ReviewContext: [context()],
    })
    const editor = await openedEditor(h)
    expect(await editor.discard(KEY)).toEqual({ message: REASON_DISCARD_FAILED, ok: false })
    expect(h.state().prs[KEY]?.recommendation).toEqual(mark())
    expect(editor.entry(KEY)).toMatchObject({ message: REASON_DISCARD_FAILED, phase: 'failed' })
  })
})

describe('Approve instead (ruling B9)', () => {
  const approver = (result: ApproveEntry | null, fail?: Error) => {
    let runs = 0
    return {
      approver: {
        result: () => (runs > 0 ? result : null),
        run: async () => {
          runs++
          if (fail) throw fail
        },
      },
      runs: () => runs,
    }
  }

  it('deletes the draft, marks it deleted, then approves with no text', async () => {
    const h = harness(stateWith(mark()), {
      DiscardDraft: [DISCARDED],
      DraftReview: [draftRead()],
      ReviewContext: [context()],
    })
    const a = approver({ at: 2_000, phase: 'approved' })
    const result = await (await openedEditor(h)).approveInstead(KEY, a.approver)
    expect(result).toEqual({ ok: true })
    expect(h.writes()).toEqual(['DiscardDraft'])
    expect(a.runs()).toBe(1)
    expect(h.state().prs[KEY]?.recommendation).toEqual({ ...mark(), deleted: true, reviewId: null })
  })

  it('an approval that fails after the delete says that the draft is gone', async () => {
    const cases: [ApproveEntry | null, Error | undefined, string][] = [
      [
        { at: 2_000, message: 'GitHub said no.', phase: 'failed' },
        undefined,
        REASON_INSTEAD_FAILED,
      ],
      [{ at: 2_000, message: 'Not known.', phase: 'unknown' }, undefined, REASON_INSTEAD_UNKNOWN],
      [null, new Error('refused: this pull request cannot be approved now'), REASON_INSTEAD_FAILED],
    ]
    for (const [entry, error, text] of cases) {
      const h = harness(stateWith(mark()), {
        DiscardDraft: [DISCARDED],
        DraftReview: [draftRead()],
        ReviewContext: [context()],
      })
      const a = approver(entry, error)
      expect(await (await openedEditor(h)).approveInstead(KEY, a.approver)).toEqual({
        message: text,
        ok: false,
      })
      // The row offers the Approve button again.
      expect(h.state().prs[KEY]?.recommendation).toMatchObject({ deleted: true, reviewId: null })
    }
  })

  it('an unknown delete result asks for a poll', async () => {
    const h = harness(stateWith(mark()), {
      DiscardDraft: [TIMED_OUT],
      DraftReview: [draftRead()],
      ReviewContext: [context()],
    })
    const a = approver({ at: 2_000, phase: 'approved' })
    const result = await (await openedEditor(h)).approveInstead(KEY, a.approver)
    expect(result.ok).toBe(false)
    expect(a.runs()).toBe(0)
    expect(h.polls()).toBe(1)
  })

  it('an approver that fails before its write asks for a poll after the delete', async () => {
    const h = harness(stateWith(mark()), {
      DiscardDraft: [DISCARDED],
      DraftReview: [draftRead()],
      ReviewContext: [context()],
    })
    const a = approver(null, new Error('refused: this pull request cannot be approved now'))
    await (await openedEditor(h)).approveInstead(KEY, a.approver)
    expect(h.polls()).toBe(1)
  })

  it('failing or running CI stops Approve instead before the delete', async () => {
    const cases: [string, string][] = [
      ['FAILURE', REASON_APPROVE_CI_FAILING],
      ['ERROR', REASON_APPROVE_CI_FAILING],
      ['PENDING', REASON_APPROVE_CI_RUNNING],
      ['EXPECTED', REASON_APPROVE_CI_RUNNING],
    ]
    for (const [ci, text] of cases) {
      const h = harness(stateWith(mark()), {
        DraftReview: [draftRead()],
        ReviewContext: [context({ ci })],
      })
      const a = approver({ at: 2_000, phase: 'approved' })
      expect(await (await openedEditor(h)).approveInstead(KEY, a.approver)).toEqual({
        message: text,
        ok: false,
      })
      expect(h.writes()).toEqual([])
      expect(a.runs()).toBe(0)
      expect(h.state().prs[KEY]?.recommendation).toEqual(mark())
    }
  })

  it('Approve instead goes on when CI passed', async () => {
    const h = harness(stateWith(mark()), {
      DiscardDraft: [DISCARDED],
      DraftReview: [draftRead()],
      ReviewContext: [context({ ci: 'SUCCESS' })],
    })
    const a = approver({ at: 2_000, phase: 'approved' })
    expect(await (await openedEditor(h)).approveInstead(KEY, a.approver)).toEqual({ ok: true })
    expect(h.writes()).toEqual(['DiscardDraft'])
  })

  it('Send as Request changes and Discard draft stay allowed when CI fails', async () => {
    const send = harness(stateWith(mark()), {
      DraftReview: [draftRead()],
      ReviewContext: [context({ ci: 'FAILURE' })],
      SendChanges: [sentAs('CHANGES_REQUESTED')],
    })
    expect(await (await openedEditor(send)).send(KEY, edits())).toEqual({ ok: true })
    expect(send.writes()).toEqual(['SendChanges'])
    const discard = harness(stateWith(mark()), {
      DiscardDraft: [DISCARDED],
      DraftReview: [draftRead()],
      ReviewContext: [context({ ci: 'FAILURE' })],
    })
    expect(await (await openedEditor(discard)).discard(KEY)).toEqual({ ok: true })
  })

  it('a PR that changed after the review stops before the delete', async () => {
    const h = harness(stateWith(mark()), { ReviewContext: [context({ head: OTHER })] })
    const a = approver({ at: 2_000, phase: 'approved' })
    expect(await (await openedEditor(h)).approveInstead(KEY, a.approver)).toEqual({
      message: REASON_DRAFT_CHANGED,
      ok: false,
    })
    expect(h.writes()).toEqual([])
    expect(a.runs()).toBe(0)
  })

  it('a failed delete does not approve', async () => {
    const h = harness(stateWith(mark()), {
      DiscardDraft: [failedWith('No')],
      DraftReview: [draftRead()],
      ReviewContext: [context()],
    })
    const a = approver({ at: 2_000, phase: 'approved' })
    expect(await (await openedEditor(h)).approveInstead(KEY, a.approver)).toEqual({
      message: REASON_DISCARD_FAILED,
      ok: false,
    })
    expect(a.runs()).toBe(0)
    expect(h.state().prs[KEY]?.recommendation).toEqual(mark())
  })
})

describe('the opened draft guards each write (fix round 1)', () => {
  const approver = () => {
    let runs = 0
    return {
      approver: {
        result: (): ApproveEntry | null => ({ at: 2_000, phase: 'approved' }),
        run: async () => {
          runs++
        },
      },
      runs: () => runs,
    }
  }

  it('Send refuses a summary that changed on GitHub after the open', async () => {
    const h = harness(stateWith(mark()), {
      DraftReview: [draftRead({ body: 'A newer summary on GitHub' })],
      ReviewContext: [context()],
    })
    const editor = await openedEditor(h)
    expect(await editor.send(KEY, edits({ body: 'My summary' }))).toEqual({
      message: REASON_DRAFT_EDITED,
      ok: false,
    })
    expect(h.writes()).toEqual([])
  })

  it('Send refuses a comment that changed on GitHub after the open, kept or removed', async () => {
    const changed = { ...COMMENT_1, body: 'A newer comment on GitHub' }
    const cases: DraftEdits[] = [
      // The user did not touch the comment: the old text must not go over the new one.
      edits(),
      edits({
        comments: [
          { body: 'My comment', id: 'PRRC_1' },
          { body: COMMENT_2.body, id: 'PRRC_2' },
        ],
      }),
      edits({
        comments: [
          { body: null, id: 'PRRC_1' },
          { body: COMMENT_2.body, id: 'PRRC_2' },
        ],
      }),
    ]
    for (const e of cases) {
      const h = harness(stateWith(mark()), {
        DraftReview: [draftRead({ comments: [changed, COMMENT_2] })],
        ReviewContext: [context()],
      })
      const editor = await openedEditor(h)
      expect(await editor.send(KEY, e)).toEqual({ message: REASON_DRAFT_EDITED, ok: false })
      expect(h.writes()).toEqual([])
    }
  })

  it('a second Send after a partial failure passes when GitHub has the first edits', async () => {
    const done = draftRead({ body: 'New', comments: [{ ...COMMENT_1, body: 'New 1' }, COMMENT_2] })
    const h = harness(stateWith(mark()), {
      DraftReview: [done],
      RemoveComment: [REMOVED],
      ReviewContext: [context()],
      SendChanges: [sentAs('CHANGES_REQUESTED')],
    })
    const editor = await openedEditor(h)
    const e = edits({
      body: 'New',
      comments: [
        { body: 'New 1', id: 'PRRC_1' },
        { body: null, id: 'PRRC_2' },
      ],
    })
    expect(await editor.send(KEY, e)).toEqual({ ok: true })
    expect(h.writes()).toEqual(['RemoveComment', 'SendChanges'])
  })

  it('a resend that changes a text that Bifrost wrote passes', async () => {
    const first = edits({
      body: 'New',
      comments: [
        { body: 'New 1', id: 'PRRC_1' },
        { body: 'New 2', id: 'PRRC_2' },
      ],
    })
    const onGithub = draftRead({
      body: 'New',
      comments: [{ ...COMMENT_1, body: 'New 1' }, COMMENT_2],
    })
    const h = harness(stateWith(mark()), {
      DraftReview: [draftRead(), onGithub],
      EditBody: [EDITED, EDITED],
      EditComment: [COMMENT_EDITED, failedWith('Body is too long'), COMMENT_EDITED, COMMENT_EDITED],
      ReviewContext: [context(), context()],
      SendChanges: [sentAs('CHANGES_REQUESTED')],
    })
    const editor = await openedEditor(h)
    expect(await editor.send(KEY, first)).toEqual({ message: REASON_DRAFT_EDIT_FAILED, ok: false })
    const again = edits({
      body: 'Newer',
      comments: [
        { body: 'Newer 1', id: 'PRRC_1' },
        { body: 'New 2', id: 'PRRC_2' },
      ],
    })
    expect(await editor.send(KEY, again)).toEqual({ ok: true })
  })

  it('a resend still refuses a text that changed on GitHub after a partial failure', async () => {
    const first = edits({
      body: 'New',
      comments: [
        { body: 'New 1', id: 'PRRC_1' },
        { body: 'New 2', id: 'PRRC_2' },
      ],
    })
    const h = harness(stateWith(mark()), {
      DraftReview: [
        draftRead(),
        draftRead({ body: 'Written on GitHub by the user', comments: [COMMENT_1, COMMENT_2] }),
      ],
      EditBody: [EDITED],
      EditComment: [failedWith('Body is too long')],
      ReviewContext: [context(), context()],
    })
    const editor = await openedEditor(h)
    expect(await editor.send(KEY, first)).toEqual({ message: REASON_DRAFT_EDIT_FAILED, ok: false })
    expect(await editor.send(KEY, edits({ body: 'Newer' }))).toEqual({
      message: REASON_DRAFT_EDITED,
      ok: false,
    })
  })

  it('Send, Discard draft and Approve instead with no open refuse and read nothing', async () => {
    const h = harness(stateWith(mark()), {})
    const editor = createDraftEditor(h.deps)
    await expect(editor.send(KEY, edits())).rejects.toThrow(REFUSED_NO_DRAFT)
    await expect(editor.discard(KEY)).rejects.toThrow(REFUSED_NO_DRAFT)
    await expect(editor.approveInstead(KEY, approver().approver)).rejects.toThrow(REFUSED_NO_DRAFT)
    expect(h.calls).toEqual([])
  })

  it('Discard draft and Approve instead refuse a comment that the open did not give', async () => {
    const added = { ...COMMENT_1, id: 'PRRC_3' }
    for (const action of ['discard', 'approve'] as const) {
      const h = harness(stateWith(mark()), {
        DraftReview: [draftRead({ comments: [COMMENT_1, COMMENT_2, added] })],
        ReviewContext: [context()],
      })
      const editor = await openedEditor(h)
      const a = approver()
      const result =
        action === 'discard'
          ? await editor.discard(KEY)
          : await editor.approveInstead(KEY, a.approver)
      // So the warning about the comments of the user can never be skipped.
      expect(result).toEqual({ message: REASON_DRAFT_EDITED, ok: false })
      expect(h.writes()).toEqual([])
      expect(a.runs()).toBe(0)
      expect(h.state().prs[KEY]?.recommendation).toEqual(mark())
    }
  })

  it('Approve instead deletes nothing when the user approved this commit already', async () => {
    const approved = [{ commit: HEAD, state: 'APPROVED', submittedAt: '2026-11-13T09:00:00Z' }]
    const h = harness(stateWith(mark()), {
      DraftReview: [draftRead()],
      ReviewContext: [context({ reviews: approved })],
    })
    const editor = await openedEditor(h)
    const a = approver()
    expect(await editor.approveInstead(KEY, a.approver)).toEqual({
      message: REASON_APPROVE_DONE,
      ok: false,
    })
    expect(h.writes()).toEqual([])
    expect(a.runs()).toBe(0)
    expect(h.state().prs[KEY]?.recommendation).toEqual(mark())
  })
})

describe('checkDraftEdits (ruling B10)', () => {
  it('accepts the edits and gives a copy', () => {
    const value = edits()
    const checked = checkDraftEdits(value)
    expect(checked).toEqual(value)
    expect(checked).not.toBe(value)
    expect(checkDraftEdits({ ...value, body: 'x'.repeat(MAX_REVIEW_TEXT) }).body).toHaveLength(
      MAX_REVIEW_TEXT,
    )
  })

  const many = Array.from({ length: MAX_DRAFT_COMMENTS + 1 }, (_, i) => ({
    body: 'x',
    id: `C_${i}`,
  }))
  const bad: [string, unknown][] = [
    ['not an object', 'x'],
    ['null', null],
    ['an array', []],
    ['an extra key', { ...edits(), path: '/etc' }],
    ['no verdict', { body: '', comments: [] }],
    ['the verdict approve', { ...edits(), verdict: 'approve' }],
    ['the verdict COMMENT', { ...edits(), verdict: 'COMMENT' }],
    ['a body that is not a string', { ...edits(), body: 3 }],
    ['a body that is too long', { ...edits(), body: 'x'.repeat(MAX_REVIEW_TEXT + 1) }],
    ['comments that are not a list', { ...edits(), comments: {} }],
    ['too many comments', { ...edits(), comments: many }],
    ['a comment that is not an object', { ...edits(), comments: ['x'] }],
    ['a bad comment ID', { ...edits(), comments: [{ body: 'x', id: '../x' }] }],
    [
      'a comment ID that repeats',
      {
        ...edits(),
        comments: [
          { body: 'x', id: 'C_1' },
          { body: null, id: 'C_1' },
        ],
      },
    ],
    ['a comment with an extra key', { ...edits(), comments: [{ body: 'x', id: 'C_1', url: 'u' }] }],
    ['a comment body that is a number', { ...edits(), comments: [{ body: 1, id: 'C_1' }] }],
    [
      'a comment body that is too long',
      { ...edits(), comments: [{ body: 'x'.repeat(MAX_REVIEW_TEXT + 1), id: 'C_1' }] },
    ],
  ]
  it.each(bad)('refuses %s', (_name, value) => {
    expect(() => checkDraftEdits(value)).toThrow(REFUSED_BAD_EDITS)
  })
})
