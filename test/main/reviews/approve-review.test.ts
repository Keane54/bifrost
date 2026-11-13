import { describe, expect, it } from 'vitest'
import type { ExecResult } from '../../../src/main/claude/cli'
import {
  APPROVE,
  type ApproveTarget,
  approveAllowed,
  approveDraft,
  approveHead,
} from '../../../src/main/reviews/approve-review'
import type { Gh } from '../../../src/main/reviews/gh'
import {
  REASON_APPROVE_FAILED,
  REASON_APPROVE_NOT_APPROVED,
  REASON_APPROVE_REFUSED,
  REASON_APPROVE_UNKNOWN,
  reasonApproveFailed,
} from '../../../src/main/reviews/round-text'
import { REASON_GH_LOGGED_OUT } from '../../../src/shared/reviews'

const HEAD = 'a'.repeat(40)
const OTHER = 'b'.repeat(40)
const KEY = 'acme/api#7'

// A fake gh that records each call and gives the next answer. It never calls GitHub.
function fakeGh(answers: ExecResult[]): { gh: Gh; calls: string[][] } {
  const calls: string[][] = []
  const gh: Gh = {
    async run(args, opts) {
      if (opts?.input !== undefined) throw new Error('an approve write must not use stdin')
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
const added = (state = 'APPROVED'): ExecResult =>
  ok({ addPullRequestReview: { pullRequestReview: { id: 'PRR_new', state } } })
const submitted = (state = 'APPROVED'): ExecResult =>
  ok({ submitPullRequestReview: { pullRequestReview: { id: 'PRR_draft', state } } })

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

const noDraft: ApproveTarget = { headSha: HEAD, key: KEY, reviewId: null }
const draft: ApproveTarget = { headSha: HEAD, key: KEY, reviewId: 'PRR_draft' }
const headWrite = { commit: HEAD, key: KEY, prId: 'PR_7', verdict: APPROVE }
const draftWrite = { commit: HEAD, key: KEY, reviewId: 'PRR_draft', verdict: APPROVE }

describe('the approve writes', () => {
  it('approves the reviewed commit with the event APPROVE and no text', async () => {
    const { calls, gh } = fakeGh([added()])
    expect(await approveHead(gh, noDraft, headWrite)).toEqual({
      ok: true,
      value: { state: 'APPROVED' },
    })
    expect(calls).toHaveLength(1)
    const call = calls[0] ?? []
    expect(call.slice(0, 2)).toEqual(['api', 'graphql'])
    const { flags, query, vars } = sent(call)
    expect(flags.every(f => f === '-f')).toBe(true)
    expect(query).toMatch(/^mutation ApproveHead\(/)
    expect(query).toContain(
      'addPullRequestReview(input: { pullRequestId: $pr, commitOID: $commit, event: APPROVE })',
    )
    expect(query).not.toMatch(/body/)
    expect(vars).toEqual({ commit: HEAD, pr: 'PR_7' })
  })

  it('submits the draft review with submitPullRequestReview and the event APPROVE', async () => {
    const { calls, gh } = fakeGh([submitted()])
    expect(await approveDraft(gh, draft, draftWrite)).toEqual({
      ok: true,
      value: { state: 'APPROVED' },
    })
    const { query, vars } = sent(calls[0] ?? [])
    expect(query).toMatch(/^mutation ApproveDraft\(/)
    expect(query).toContain(
      'submitPullRequestReview(input: { pullRequestReviewId: $review, event: APPROVE })',
    )
    // The body of the draft stays as it is.
    expect(query).not.toMatch(/body/)
    expect(vars).toEqual({ review: 'PRR_draft' })
  })

  it('a review that GitHub did not save as an approval has an unknown result', async () => {
    const { gh } = fakeGh([added('COMMENTED'), submitted('PENDING')])
    const message = REASON_APPROVE_NOT_APPROVED
    expect(await approveHead(gh, noDraft, headWrite)).toEqual({ message, ok: false, unknown: true })
    expect(await approveDraft(gh, draft, draftWrite)).toEqual({ message, ok: false, unknown: true })
  })

  it('a timeout or an answer that Bifrost cannot read has an unknown result', async () => {
    const timeout: ExecResult = { code: 1, stderr: '', stdout: '', timedOut: true }
    const garbled: ExecResult = { code: 0, stderr: '', stdout: 'not json' }
    const noId = ok({ addPullRequestReview: { pullRequestReview: { state: 'APPROVED' } } })
    const { gh } = fakeGh([timeout, garbled, noId])
    for (let i = 0; i < 3; i++) {
      expect(await approveHead(gh, noDraft, headWrite)).toEqual({
        message: REASON_APPROVE_UNKNOWN,
        ok: false,
        unknown: true,
      })
    }
  })

  it('a refusal of GitHub is known, and its raw line goes in detail only', async () => {
    const refused: ExecResult = {
      code: 1,
      stderr: 'gh: Can not approve your own pull request (HTTP 422)',
      stdout: '',
    }
    const errors: ExecResult = {
      code: 1,
      stderr: '',
      stdout: JSON.stringify({ errors: [{ message: 'Review cannot be submitted.' }] }),
    }
    const loggedOut: ExecResult = {
      code: 4,
      stderr: 'To get started, run gh auth login',
      stdout: '',
    }
    const { gh } = fakeGh([refused, errors, loggedOut])
    expect(await approveHead(gh, noDraft, headWrite)).toEqual({
      detail: 'gh: Can not approve your own pull request (HTTP 422)',
      message: REASON_APPROVE_FAILED,
      ok: false,
      unknown: false,
    })
    expect(await approveDraft(gh, draft, draftWrite)).toEqual({
      detail: 'Review cannot be submitted.',
      message: REASON_APPROVE_FAILED,
      ok: false,
      unknown: false,
    })
    expect(await approveHead(gh, noDraft, headWrite)).toEqual({
      message: reasonApproveFailed(REASON_GH_LOGGED_OUT),
      ok: false,
      unknown: false,
    })
  })
})

describe('the approve write guard', () => {
  const refusal = { message: REASON_APPROVE_REFUSED, ok: false, unknown: false }

  it('allows the event APPROVE for the PR of the row and the head of the mark', () => {
    expect(approveAllowed(noDraft, headWrite)).toBe(true)
    expect(approveAllowed(draft, draftWrite)).toBe(true)
  })

  it('refuses another event', async () => {
    for (const verdict of ['REQUEST_CHANGES', 'COMMENT', 'DISMISS', 'approve', '']) {
      expect(approveAllowed(noDraft, { ...headWrite, verdict })).toBe(false)
      expect(approveAllowed(draft, { ...draftWrite, verdict })).toBe(false)
    }
    const { calls, gh } = fakeGh([])
    expect(await approveHead(gh, noDraft, { ...headWrite, verdict: 'REQUEST_CHANGES' })).toEqual(
      refusal,
    )
    expect(await approveDraft(gh, draft, { ...draftWrite, verdict: 'COMMENT' })).toEqual(refusal)
    expect(calls).toEqual([])
  })

  it('refuses another PR', async () => {
    for (const key of ['acme/api#8', 'acme/web#7', 'other/api#7', '']) {
      expect(approveAllowed(noDraft, { ...headWrite, key })).toBe(false)
      expect(approveAllowed(draft, { ...draftWrite, key })).toBe(false)
    }
    // A row key that is not a PR key gets nothing.
    expect(
      approveAllowed({ ...noDraft, key: 'acme/..#7' }, { ...headWrite, key: 'acme/..#7' }),
    ).toBe(false)
    const { calls, gh } = fakeGh([])
    expect(await approveHead(gh, noDraft, { ...headWrite, key: 'acme/api#8' })).toEqual(refusal)
    expect(calls).toEqual([])
  })

  it('refuses another head', async () => {
    expect(approveAllowed(noDraft, { ...headWrite, commit: OTHER })).toBe(false)
    expect(approveAllowed(draft, { ...draftWrite, commit: OTHER })).toBe(false)
    expect(approveAllowed(draft, { ...draftWrite, commit: null })).toBe(false)
    // The head of the mark must be a commit ID.
    const short = { ...noDraft, headSha: 'abc' }
    expect(approveAllowed(short, { ...headWrite, commit: 'abc' })).toBe(false)
    const { calls, gh } = fakeGh([])
    expect(await approveHead(gh, noDraft, { ...headWrite, commit: OTHER })).toEqual(refusal)
    expect(await approveDraft(gh, draft, { ...draftWrite, commit: OTHER })).toEqual(refusal)
    expect(calls).toEqual([])
  })

  it('submits only the draft of the mark, and approves with no draft only without one', () => {
    expect(approveAllowed(draft, { ...draftWrite, reviewId: 'PRR_other' })).toBe(false)
    expect(approveAllowed(draft, { ...draftWrite, reviewId: '' })).toBe(false)
    expect(approveAllowed(noDraft, draftWrite)).toBe(false)
    expect(approveAllowed(draft, headWrite)).toBe(false)
    expect(approveAllowed(noDraft, { ...headWrite, prId: '' })).toBe(false)
  })
})
