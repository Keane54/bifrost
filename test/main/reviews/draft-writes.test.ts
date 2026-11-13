// The writes of the Review panel and their guard (ruling B10). The fake gh never calls GitHub.
import { describe, expect, it } from 'vitest'
import type { ExecResult } from '../../../src/main/claude/cli'
import {
  type DraftScope,
  type DraftTarget,
  type DraftWrite,
  draftAllowed,
  writeDraft,
} from '../../../src/main/reviews/draft-writes'
import type { Gh } from '../../../src/main/reviews/gh'
import {
  REASON_DISCARD_FAILED,
  REASON_DISCARD_UNKNOWN,
  REASON_DRAFT_EDIT_FAILED,
  REASON_DRAFT_EDIT_UNKNOWN,
  REASON_DRAFT_NOT_PENDING,
  REASON_DRAFT_REFUSED,
  REASON_SEND_FAILED,
  REASON_SEND_NOT_AS_SENT,
  REASON_SEND_UNKNOWN,
  reasonDraftFailed,
} from '../../../src/main/reviews/round-text'
import { REASON_GH_LOGGED_OUT } from '../../../src/shared/reviews'

const HEAD = 'a'.repeat(40)
const OTHER = 'b'.repeat(40)
const KEY = 'acme/api#7'

const target: DraftTarget = { headSha: HEAD, key: KEY, reviewId: 'PRR_draft' }
const scope: DraftScope = {
  comments: new Set(['PRRC_1', 'PRRC_2']),
  commit: HEAD,
  key: KEY,
  reviewId: 'PRR_draft',
}

// A fake gh that records each call and gives the next answer. It never calls GitHub.
function fakeGh(answers: ExecResult[]): { gh: Gh; calls: string[][] } {
  const calls: string[][] = []
  const gh: Gh = {
    async run(args, opts) {
      if (opts?.input !== undefined) throw new Error('a draft write must not use stdin')
      calls.push(args)
      const answer = answers.shift()
      if (answer === undefined) throw new Error(`no answer for call ${calls.length}`)
      return answer
    },
  }
  return { calls, gh }
}

const ok = (data: unknown): ExecResult => ({
  code: 0,
  stderr: '',
  stdout: JSON.stringify({ data }),
})
const review = (field: string, state?: string): ExecResult =>
  ok({ [field]: { pullRequestReview: { id: 'PRR_draft', ...(state ? { state } : {}) } } })
const comment = (): ExecResult =>
  ok({ updatePullRequestReviewComment: { pullRequestReviewComment: { id: 'PRRC_1' } } })
const NOT_FOUND: ExecResult = {
  code: 1,
  stderr: 'gh: Could not resolve to a node with the global id of PRRC_1',
  stdout: JSON.stringify({
    data: { x: null },
    errors: [
      { message: "Could not resolve to a node with the global id of 'PRRC_1'", type: 'NOT_FOUND' },
    ],
  }),
}
const REFUSED_BY_GITHUB: ExecResult = {
  code: 1,
  stderr: 'gh: Something went wrong',
  stdout: JSON.stringify({ data: { x: null }, errors: [{ message: 'Something went wrong' }] }),
}
const TIMED_OUT: ExecResult = { code: 1, stderr: '', stdout: '', timedOut: true }

// The query text and the -f fields of one call.
function sent(args: string[]): { query: string; vars: Record<string, string>; flags: string[] } {
  const vars: Record<string, string> = {}
  const flags: string[] = []
  let query = ''
  for (let i = 2; i < args.length; i += 2) {
    flags.push(args[i] ?? '')
    const [name = '', ...rest] = (args[i + 1] ?? '').split('=')
    if (name === 'query') query = rest.join('=')
    else vars[name] = rest.join('=')
  }
  return { flags, query, vars }
}

describe('the draft writes', () => {
  it('updates the summary of the draft with -f fields', async () => {
    const { calls, gh } = fakeGh([review('updatePullRequestReview', 'PENDING')])
    const out = await writeDraft(gh, target, scope, { body: 'New text', kind: 'body' })
    expect(out).toEqual({ ok: true, value: null })
    const call = calls[0] ?? []
    expect(call.slice(0, 2)).toEqual(['api', 'graphql'])
    const { flags, query, vars } = sent(call)
    expect(flags.every(f => f === '-f')).toBe(true)
    expect(query).toMatch(/^mutation EditBody\(/)
    expect(query).toContain(
      'updatePullRequestReview(input: { pullRequestReviewId: $review, body: $body })',
    )
    expect(vars).toEqual({ body: 'New text', review: 'PRR_draft' })
  })

  it('refuses a summary update that GitHub did not keep as a draft', async () => {
    const { gh } = fakeGh([review('updatePullRequestReview', 'COMMENTED')])
    const out = await writeDraft(gh, target, scope, { body: 'x', kind: 'body' })
    expect(out).toEqual({ message: REASON_DRAFT_NOT_PENDING, ok: false, unknown: false })
  })

  it('updates one comment of the draft', async () => {
    const { calls, gh } = fakeGh([comment()])
    const out = await writeDraft(gh, target, scope, {
      body: 'Better text',
      commentId: 'PRRC_1',
      kind: 'comment',
    })
    expect(out.ok).toBe(true)
    const { query, vars } = sent(calls[0] ?? [])
    expect(query).toMatch(/^mutation EditComment\(/)
    expect(query).toContain(
      'updatePullRequestReviewComment(input: { pullRequestReviewCommentId: $comment, ' +
        'body: $body })',
    )
    expect(vars).toEqual({ body: 'Better text', comment: 'PRRC_1' })
  })

  it('removes one comment of the draft, and a not found counts as done', async () => {
    const { calls, gh } = fakeGh([review('deletePullRequestReviewComment'), NOT_FOUND])
    const write: DraftWrite = { commentId: 'PRRC_2', kind: 'remove' }
    expect((await writeDraft(gh, target, scope, write)).ok).toBe(true)
    expect((await writeDraft(gh, target, scope, write)).ok).toBe(true)
    const { query, vars } = sent(calls[0] ?? [])
    expect(query).toMatch(/^mutation RemoveComment\(/)
    expect(query).toContain('deletePullRequestReviewComment(input: { id: $comment })')
    expect(vars).toEqual({ comment: 'PRRC_2' })
  })

  it('deletes the draft review, and a not found counts as done', async () => {
    const { calls, gh } = fakeGh([review('deletePullRequestReview'), NOT_FOUND])
    expect((await writeDraft(gh, target, scope, { kind: 'discard' })).ok).toBe(true)
    expect((await writeDraft(gh, target, scope, { kind: 'discard' })).ok).toBe(true)
    const { query, vars } = sent(calls[0] ?? [])
    expect(query).toMatch(/^mutation DiscardDraft\(/)
    expect(query).toContain('deletePullRequestReview(input: { pullRequestReviewId: $review })')
    expect(vars).toEqual({ review: 'PRR_draft' })
  })

  it('submits as a comment with the event COMMENT in the text', async () => {
    const { calls, gh } = fakeGh([review('submitPullRequestReview', 'COMMENTED')])
    const out = await writeDraft(gh, target, scope, { kind: 'submit', verdict: 'comment' })
    expect(out.ok).toBe(true)
    const { query, vars } = sent(calls[0] ?? [])
    expect(query).toMatch(/^mutation SendComment\(/)
    expect(query).toContain(
      'submitPullRequestReview(input: { pullRequestReviewId: $review, event: COMMENT })',
    )
    expect(vars).toEqual({ review: 'PRR_draft' })
  })

  it('submits as request changes with the event REQUEST_CHANGES in the text', async () => {
    const { calls, gh } = fakeGh([review('submitPullRequestReview', 'CHANGES_REQUESTED')])
    const out = await writeDraft(gh, target, scope, { kind: 'submit', verdict: 'request-changes' })
    expect(out.ok).toBe(true)
    const { query, vars } = sent(calls[0] ?? [])
    expect(query).toMatch(/^mutation SendChanges\(/)
    expect(query).toContain(
      'submitPullRequestReview(input: { pullRequestReviewId: $review, event: REQUEST_CHANGES })',
    )
    expect(vars).toEqual({ review: 'PRR_draft' })
  })

  it('a submit saved in another state is not done, and its result is unknown', async () => {
    const { gh } = fakeGh([review('submitPullRequestReview', 'COMMENTED')])
    const out = await writeDraft(gh, target, scope, { kind: 'submit', verdict: 'request-changes' })
    expect(out).toEqual({ message: REASON_SEND_NOT_AS_SENT, ok: false, unknown: true })
  })

  it('a submit with no review in the answer has an unknown result', async () => {
    const { gh } = fakeGh([ok({ submitPullRequestReview: null })])
    const out = await writeDraft(gh, target, scope, { kind: 'submit', verdict: 'comment' })
    expect(out).toMatchObject({ message: REASON_SEND_UNKNOWN, ok: false, unknown: true })
  })

  it('gives a text for each kind of write, with the raw line in detail only', async () => {
    const cases: [DraftWrite, string, string][] = [
      [{ body: 'x', kind: 'body' }, REASON_DRAFT_EDIT_FAILED, REASON_DRAFT_EDIT_UNKNOWN],
      [
        { body: 'x', commentId: 'PRRC_1', kind: 'comment' },
        REASON_DRAFT_EDIT_FAILED,
        REASON_DRAFT_EDIT_UNKNOWN,
      ],
      [
        { commentId: 'PRRC_1', kind: 'remove' },
        REASON_DRAFT_EDIT_FAILED,
        REASON_DRAFT_EDIT_UNKNOWN,
      ],
      [{ kind: 'discard' }, REASON_DISCARD_FAILED, REASON_DISCARD_UNKNOWN],
      [{ kind: 'submit', verdict: 'comment' }, REASON_SEND_FAILED, REASON_SEND_UNKNOWN],
    ]
    for (const [write, failed, unknown] of cases) {
      const { gh } = fakeGh([REFUSED_BY_GITHUB, TIMED_OUT])
      expect(await writeDraft(gh, target, scope, write)).toEqual({
        detail: 'Something went wrong',
        message: failed,
        ok: false,
        unknown: false,
      })
      expect(await writeDraft(gh, target, scope, write)).toMatchObject({
        message: unknown,
        ok: false,
        unknown: true,
      })
    }
  })

  it('a logged-out gh gives its own text', async () => {
    const { gh } = fakeGh([{ code: 4, stderr: 'To get started, run gh auth login', stdout: '' }])
    expect(await writeDraft(gh, target, scope, { kind: 'discard' })).toEqual({
      message: reasonDraftFailed(REASON_GH_LOGGED_OUT),
      ok: false,
      unknown: false,
    })
  })
})

describe('the guard of the draft writes (ruling B10)', () => {
  const allWrites: DraftWrite[] = [
    { body: 'x', kind: 'body' },
    { body: 'x', commentId: 'PRRC_1', kind: 'comment' },
    { commentId: 'PRRC_1', kind: 'remove' },
    { kind: 'discard' },
    { kind: 'submit', verdict: 'comment' },
    { kind: 'submit', verdict: 'request-changes' },
  ]

  it('allows each write for the PR of the row, the commit and the draft of the mark', () => {
    for (const write of allWrites) expect(draftAllowed(target, scope, write)).toBe(true)
  })

  const badScopes: [string, DraftScope][] = [
    ['another PR', { ...scope, key: 'acme/api#8' }],
    ['another repository', { ...scope, key: 'acme/web#7' }],
    ['an empty key from the read', { ...scope, key: '' }],
    ['another commit', { ...scope, commit: OTHER }],
    ['no commit', { ...scope, commit: null }],
    ['another review', { ...scope, reviewId: 'PRR_other' }],
    ['an empty review', { ...scope, reviewId: '' }],
  ]
  it.each(badScopes)('refuses %s and sends nothing', async (_name, bad) => {
    for (const write of allWrites) {
      expect(draftAllowed(target, bad, write)).toBe(false)
      const { calls, gh } = fakeGh([])
      expect(await writeDraft(gh, target, bad, write)).toEqual({
        message: REASON_DRAFT_REFUSED,
        ok: false,
        unknown: false,
      })
      expect(calls).toEqual([])
    }
  })

  const badTargets: [string, DraftTarget][] = [
    ['a bad key of the row', { ...target, key: 'acme/api' }],
    ['a bad head of the mark', { ...target, headSha: 'abc' }],
    ['a mark with no draft', { ...target, reviewId: '' }],
  ]
  it.each(badTargets)('refuses %s', (_name, bad) => {
    for (const write of allWrites) {
      expect(draftAllowed(bad, { ...scope, key: bad.key, reviewId: bad.reviewId }, write)).toBe(
        false,
      )
    }
  })

  it('refuses a comment that the fresh read did not give', () => {
    for (const kind of ['comment', 'remove'] as const) {
      for (const commentId of ['PRRC_9', '', 'PRRC 1', '../x']) {
        const write: DraftWrite =
          kind === 'comment' ? { body: 'x', commentId, kind } : { commentId, kind }
        expect(draftAllowed(target, scope, write)).toBe(false)
      }
    }
  })

  it('submits only as a comment or as request changes', async () => {
    for (const verdict of ['approve', 'APPROVE', 'COMMENT', 'dismiss', 'DISMISS', '']) {
      const write: DraftWrite = { kind: 'submit', verdict }
      expect(draftAllowed(target, scope, write)).toBe(false)
      const { calls, gh } = fakeGh([])
      expect((await writeDraft(gh, target, scope, write)).ok).toBe(false)
      expect(calls).toEqual([])
    }
  })
})
