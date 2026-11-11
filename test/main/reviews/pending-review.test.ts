import { describe, expect, it } from 'vitest'
import type { ExecResult } from '../../../src/main/claude/cli'
import type { Gh } from '../../../src/main/reviews/gh'
import {
  type PostArgs,
  postPendingReview,
  reviewPayload,
} from '../../../src/main/reviews/pending-review'
import { MAX_REVIEW_BODY, type ResultComment } from '../../../src/main/reviews/result-file'
import {
  REASON_BAD_PR,
  REASON_DRAFT_TOO_LONG,
  REASON_NOT_PENDING,
  REASON_OTHER_COMMIT,
  REASON_POST_TIMEOUT,
  REASON_POST_UNREADABLE,
  REASON_SUMMARY_TOO_LONG,
  reasonPartlyAdded,
  reasonPostFailed,
  reasonPostUnknown,
  reasonSummaryFailed,
} from '../../../src/main/reviews/round-text'
import { REASON_GH_LOGGED_OUT, REASON_GH_MISSING } from '../../../src/shared/reviews'

const HEAD = 'a'.repeat(40)
const OLD = 'b'.repeat(40)

interface Call {
  args: string[]
  input?: string
}

// A fake gh that records each call and gives the next answer. It never calls GitHub.
function fakeGh(answers: ExecResult[]): { gh: Gh; calls: Call[] } {
  const calls: Call[] = []
  const gh: Gh = {
    async run(args, opts) {
      calls.push(opts?.input === undefined ? { args } : { args, input: opts.input })
      const answer = answers.shift()
      if (answer === undefined) throw new Error(`no answer for call ${calls.length}`)
      return answer
    },
  }
  return { calls, gh }
}

const ok = (data: unknown): ExecResult => ({ code: 0, stderr: '', stdout: JSON.stringify(data) })
const refused = (stderr: string): ExecResult => ({ code: 1, stderr, stdout: '' })
const timedOut = (): ExecResult => ({ code: 1, stderr: '', stdout: '', timedOut: true })
const overflow = (): ExecResult => ({ code: 1, overflow: true, stderr: 'maxBuffer', stdout: '' })
const unreadable = (): ExecResult => ({ code: 0, stderr: '', stdout: 'not json' })
// gh prints the GraphQL answer on stdout and the first error on stderr, and exits with code 1.
const graphqlRefused = (message: string): ExecResult => ({
  code: 1,
  stderr: `gh: ${message}`,
  stdout: JSON.stringify({ data: null, errors: [{ message }] }),
})
const created = (state = 'PENDING'): ExecResult => ok({ id: 5, node_id: 'PRR_new', state })
const threadAdded = (): ExecResult =>
  ok({ data: { addPullRequestReviewThread: { thread: { id: 'T' } } } })
const bodySet = (state = 'PENDING'): ExecResult =>
  ok({ data: { updatePullRequestReview: { pullRequestReview: { id: 'PRR_mine', state } } } })

const comment = (extra: Partial<ResultComment> = {}): ResultComment => ({
  body: 'Check this value.',
  line: 12,
  path: 'src/a.ts',
  side: 'RIGHT',
  ...extra,
})

const args = (extra: Partial<PostArgs> = {}): PostArgs => ({
  comments: [comment()],
  headSha: HEAD,
  number: 7,
  owner: 'acme',
  pending: null,
  repo: 'tool',
  summary: 'Looks close.',
  ...extra,
})

const mine = (body = '', commit: string | null = HEAD): PostArgs['pending'] => ({
  body,
  commit,
  id: 'PRR_mine',
})

// The value of the -f or -F field with this name, and the flag that sent it.
function field(call: Call, name: string): { flag: string; value: string } | undefined {
  for (let i = 0; i < call.args.length - 1; i++) {
    const flag = call.args[i]
    const next = call.args[i + 1]
    if ((flag === '-f' || flag === '-F') && next.startsWith(`${name}=`)) {
      return { flag, value: next.slice(name.length + 1) }
    }
  }
  return undefined
}

// The texts of a failed post. A text never says more than Bifrost knows.
describe('the texts of a failed post', () => {
  it('says that Bifrost cannot tell when the result of a write is unknown', () => {
    expect(REASON_POST_TIMEOUT).toBe(
      "GitHub didn't answer in time, so Bifrost can't tell if your draft review was saved. " +
        'Check the pull request on GitHub.',
    )
    expect(REASON_POST_UNREADABLE).toBe(
      "Bifrost couldn't read the answer from GitHub, so it can't tell if your draft review was " +
        'saved. Check the pull request on GitHub.',
    )
    for (const text of [REASON_POST_TIMEOUT, REASON_POST_UNREADABLE]) {
      expect(text).not.toMatch(/try again|Nothing was posted/i)
    }
  })

  it('gives the gh message when the result of a failed write is unknown', () => {
    expect(reasonPostUnknown('gh: Server Error (HTTP 502)')).toBe(
      "Bifrost can't tell if your draft review was saved: gh: Server Error (HTTP 502) " +
        'Check the pull request on GitHub.',
    )
  })

  it('says what is in the draft when only the summary failed', () => {
    expect(reasonSummaryFailed('gh: No.')).toBe(
      "Bifrost added the comments to your draft review, but GitHub didn't add the summary: " +
        'gh: No. Check your draft review on GitHub.',
    )
  })

  it('does not say that GitHub refused a text that Bifrost did not send', () => {
    expect(REASON_DRAFT_TOO_LONG).toBe(
      "Your draft review text and Claude's summary together are longer than GitHub allows " +
        '(65,536 characters). Nothing was posted.',
    )
    expect(REASON_SUMMARY_TOO_LONG).toBe(
      "Claude's summary is longer than GitHub allows (65,536 characters). Nothing was posted.",
    )
    expect(REASON_BAD_PR).toBe(
      "Bifrost couldn't use the owner, repository or number of this pull request. " +
        'Nothing was posted.',
    )
    for (const text of [REASON_DRAFT_TOO_LONG, REASON_SUMMARY_TOO_LONG, REASON_BAD_PR]) {
      expect(text).not.toContain("GitHub didn't accept")
    }
  })
})

describe('reviewPayload', () => {
  it('has no body for a summary with no text, and no comments key with no comments', () => {
    expect(reviewPayload(args({ comments: [], summary: ' \n ' }))).toEqual({ commit_id: HEAD })
  })
})

describe('postPendingReview with no pending review of the user', () => {
  it('creates a pending review with commit_id and no event', async () => {
    const { gh, calls } = fakeGh([created()])
    const out = await postPendingReview(gh, args())
    expect(out).toEqual({ added: 1, ok: true, reviewId: 'PRR_new' })
    expect(calls).toHaveLength(1)
    expect(calls[0].args).toEqual([
      'api',
      '--method',
      'POST',
      'repos/acme/tool/pulls/7/reviews',
      '--input',
      '-',
    ])
    const payload = JSON.parse(calls[0].input ?? '')
    expect(payload).toEqual({
      body: 'Looks close.',
      comments: [{ body: 'Check this value.', line: 12, path: 'src/a.ts', side: 'RIGHT' }],
      commit_id: HEAD,
    })
    expect(payload).not.toHaveProperty('event')
    expect(reviewPayload(args())).not.toHaveProperty('event')
  })

  it('refuses an answer that is not PENDING', async () => {
    const { gh } = fakeGh([created('COMMENTED')])
    expect(await postPendingReview(gh, args())).toEqual({
      added: 1,
      message: REASON_NOT_PENDING,
      ok: false,
    })
  })

  it('marks a create with an unknown result', async () => {
    const answers: [ExecResult, string][] = [
      [timedOut(), REASON_POST_TIMEOUT],
      [overflow(), REASON_POST_UNREADABLE],
      [unreadable(), REASON_POST_UNREADABLE],
      [ok([]), REASON_POST_UNREADABLE],
      [ok({ id: 5 }), REASON_POST_UNREADABLE],
      [ok({ id: 5, state: 'PENDING' }), REASON_POST_UNREADABLE],
    ]
    for (const [answer, message] of answers) {
      const { gh } = fakeGh([answer])
      const out = await postPendingReview(gh, args())
      expect(out).toEqual({ added: 0, message, ok: false, unknownResult: true })
    }
  })

  it('gives the gh message when GitHub refuses the review', async () => {
    const { gh } = fakeGh([refused('gh: Validation Failed (HTTP 422)\nmore')])
    expect(await postPendingReview(gh, args())).toEqual({
      added: 0,
      message: reasonPostFailed('gh: Validation Failed (HTTP 422)'),
      ok: false,
    })
  })

  it('a range comment sends start_line and start_side', async () => {
    const { gh, calls } = fakeGh([created()])
    const range = [
      comment({ startLine: 10 }),
      comment({ side: 'LEFT', startLine: 3, startSide: 'LEFT' }),
    ]
    await postPendingReview(gh, args({ comments: range }))
    const sent = JSON.parse(calls[0].input ?? '').comments
    expect(sent).toEqual([
      {
        body: 'Check this value.',
        line: 12,
        path: 'src/a.ts',
        side: 'RIGHT',
        start_line: 10,
        start_side: 'RIGHT',
      },
      {
        body: 'Check this value.',
        line: 12,
        path: 'src/a.ts',
        side: 'LEFT',
        start_line: 3,
        start_side: 'LEFT',
      },
    ])
  })

  it('refuses a summary longer than MAX_REVIEW_BODY before any call', async () => {
    const { gh, calls } = fakeGh([created()])
    const out = await postPendingReview(gh, args({ summary: 'x'.repeat(MAX_REVIEW_BODY + 1) }))
    expect(out).toEqual({ added: 0, message: REASON_SUMMARY_TOO_LONG, ok: false })
    expect(calls).toEqual([])
  })

  it('refuses a pull request name that is not valid before any call', async () => {
    const { gh, calls } = fakeGh([created()])
    for (const bad of [{ owner: '..' }, { repo: '../x' }, { number: 0 }, { number: 1.5 }]) {
      const out = await postPendingReview(gh, args(bad))
      expect(out).toEqual({ added: 0, message: REASON_BAD_PR, ok: false })
    }
    expect(calls).toEqual([])
  })
})

describe('postPendingReview with a pending review of the user', () => {
  it('adds each comment to the pending review of the user and sets an empty body', async () => {
    const { gh, calls } = fakeGh([threadAdded(), threadAdded(), bodySet()])
    const two = [comment(), comment({ body: 'And this one.', line: 20, path: 'src/b.ts' })]
    const out = await postPendingReview(gh, args({ comments: two, pending: mine() }))
    expect(out).toEqual({ added: 2, ok: true, reviewId: 'PRR_mine' })
    expect(calls).toHaveLength(3)
    for (const call of calls) {
      expect(call.args.slice(0, 2)).toEqual(['api', 'graphql'])
      expect(call.input).toBeUndefined()
    }
    const [first, second, last] = calls
    expect(field(first, 'query')?.value).toContain('addPullRequestReviewThread(')
    expect(field(first, 'review')).toEqual({ flag: '-f', value: 'PRR_mine' })
    expect(field(first, 'path')).toEqual({ flag: '-f', value: 'src/a.ts' })
    expect(field(first, 'line')).toEqual({ flag: '-F', value: '12' })
    expect(field(first, 'side')).toEqual({ flag: '-f', value: 'RIGHT' })
    expect(field(first, 'body')).toEqual({ flag: '-f', value: 'Check this value.' })
    expect(field(first, 'startLine')).toBeUndefined()
    expect(field(second, 'body')?.value).toBe('And this one.')
    expect(field(second, 'path')?.value).toBe('src/b.ts')
    expect(field(last, 'query')?.value).toContain('updatePullRequestReview(')
    expect(field(last, 'review')).toEqual({ flag: '-f', value: 'PRR_mine' })
    expect(field(last, 'body')).toEqual({ flag: '-f', value: 'Looks close.' })
    // No value goes inside the query text.
    for (const call of calls) {
      const query = field(call, 'query')?.value ?? ''
      for (const value of ['PRR_mine', 'src/a.ts', 'Check this value.', 'Looks close.']) {
        expect(query).not.toContain(value)
      }
      expect(query).not.toContain('event')
    }
  })

  it('adds the summary below a body with text', async () => {
    const { gh, calls } = fakeGh([bodySet()])
    const out = await postPendingReview(gh, args({ comments: [], pending: mine('My notes.') }))
    expect(out).toEqual({ added: 0, ok: true, reviewId: 'PRR_mine' })
    expect(calls).toHaveLength(1)
    expect(field(calls[0], 'body')?.value).toBe('My notes.\n\nLooks close.')
  })

  it('keeps the body of the user when the summary has no text', async () => {
    const { gh, calls } = fakeGh([threadAdded()])
    const out = await postPendingReview(gh, args({ pending: mine('My notes.'), summary: '' }))
    expect(out).toEqual({ added: 1, ok: true, reviewId: 'PRR_mine' })
    expect(calls).toHaveLength(1)
    expect(field(calls[0], 'query')?.value).toContain('addPullRequestReviewThread(')
  })

  it('refuses a pending review on another commit before any call', async () => {
    for (const commit of [OLD, null]) {
      const { gh, calls } = fakeGh([threadAdded(), bodySet()])
      const out = await postPendingReview(gh, args({ pending: mine('', commit) }))
      expect(out).toEqual({ added: 0, message: REASON_OTHER_COMMIT, ok: false })
      expect(calls).toEqual([])
    }
  })

  it('stops at the first refused comment and reports the count', async () => {
    const three = [comment(), comment({ line: 13 }), comment({ line: 14 })]
    const { gh, calls } = fakeGh([
      threadAdded(),
      graphqlRefused('Line is not in the diff'),
      threadAdded(),
    ])
    const out = await postPendingReview(gh, args({ comments: three, pending: mine() }))
    expect(out).toEqual({
      added: 1,
      message: reasonPartlyAdded(1, 3, 'Line is not in the diff'),
      ok: false,
    })
    expect(calls).toHaveLength(2)
  })

  it('gives reasonPostFailed when the first comment is refused', async () => {
    const { gh, calls } = fakeGh([graphqlRefused('Line is not in the diff')])
    const out = await postPendingReview(gh, args({ pending: mine() }))
    expect(out).toEqual({
      added: 0,
      message: reasonPostFailed('Line is not in the diff'),
      ok: false,
    })
    expect(calls).toHaveLength(1)
  })

  it('a GraphQL answer with errors is a failure', async () => {
    const errors = ok({
      data: { addPullRequestReviewThread: null },
      errors: [{ message: 'No.\nThe second line.' }],
    })
    const { gh } = fakeGh([errors])
    const out = await postPendingReview(gh, args({ pending: mine() }))
    expect(out).toEqual({ added: 0, message: reasonPostFailed('No.'), ok: false })
  })

  it('says that the comments are in the draft when the body is refused after them', async () => {
    const { gh } = fakeGh([threadAdded(), graphqlRefused('Something went wrong')])
    const out = await postPendingReview(gh, args({ pending: mine() }))
    expect(out).toEqual({
      added: 1,
      message: reasonSummaryFailed('Something went wrong'),
      ok: false,
    })
  })

  it('gives reasonPostFailed when the body is refused and there are no comments', async () => {
    const { gh } = fakeGh([refused('gh: Something went wrong (HTTP 403)')])
    const out = await postPendingReview(gh, args({ comments: [], pending: mine() }))
    expect(out).toEqual({
      added: 0,
      message: reasonPostFailed('gh: Something went wrong (HTTP 403)'),
      ok: false,
    })
  })

  it('counts a failure as known only for exit 4, ENOENT, HTTP 4xx or GraphQL errors', async () => {
    const known: [ExecResult, string][] = [
      [{ code: 4, stderr: 'To get started, run: gh auth login', stdout: '' }, REASON_GH_LOGGED_OUT],
      [{ code: 1, stderr: 'spawn gh ENOENT', stdout: '' }, REASON_GH_MISSING],
      [refused('gh: Not Found (HTTP 404)'), 'gh: Not Found (HTTP 404)'],
      [graphqlRefused('Could not resolve to a node.'), 'Could not resolve to a node.'],
    ]
    for (const [answer, message] of known) {
      const { gh } = fakeGh([answer])
      const out = await postPendingReview(gh, args({ pending: mine() }))
      expect(out).toEqual({ added: 0, message: reasonPostFailed(message), ok: false })
    }
  })

  it('marks each other failure of a write with an unknown result', async () => {
    // A network error after the request went out, and a kill signal that is not the timeout.
    const reset = 'Post "https://api.github.com/graphql": read: connection reset by peer'
    const killed = 'Command failed: gh api graphql'
    const other: [ExecResult, string][] = [
      [refused(reset), reset],
      [refused(killed), killed],
      [
        { code: 2, stderr: 'gh: Server Error (HTTP 502)', stdout: '' },
        'gh: Server Error (HTTP 502)',
      ],
    ]
    for (const [answer, message] of other) {
      const two = [comment(), comment({ line: 13 })]
      const { gh, calls } = fakeGh([threadAdded(), answer, threadAdded(), bodySet()])
      const out = await postPendingReview(gh, args({ comments: two, pending: mine() }))
      expect(out).toEqual({
        added: 1,
        message: reasonPostUnknown(message),
        ok: false,
        unknownResult: true,
      })
      expect(calls).toHaveLength(2)
    }
    const { gh } = fakeGh([refused(reset)])
    expect(await postPendingReview(gh, args())).toEqual({
      added: 0,
      message: reasonPostUnknown(reset),
      ok: false,
      unknownResult: true,
    })
  })

  it('marks a comment with an unknown result and stops', async () => {
    const answers: [ExecResult, string][] = [
      [timedOut(), REASON_POST_TIMEOUT],
      [overflow(), REASON_POST_UNREADABLE],
      [unreadable(), REASON_POST_UNREADABLE],
      [ok({ data: { addPullRequestReviewThread: { thread: null } } }), REASON_POST_UNREADABLE],
    ]
    for (const [answer, message] of answers) {
      const two = [comment(), comment({ line: 13 })]
      const { gh, calls } = fakeGh([threadAdded(), answer, threadAdded(), bodySet()])
      const out = await postPendingReview(gh, args({ comments: two, pending: mine() }))
      expect(out).toEqual({ added: 1, message, ok: false, unknownResult: true })
      expect(calls).toHaveLength(2)
    }
  })

  it('marks a body with an unknown result', async () => {
    const answers: [ExecResult, string][] = [
      [timedOut(), REASON_POST_TIMEOUT],
      [overflow(), REASON_POST_UNREADABLE],
      [unreadable(), REASON_POST_UNREADABLE],
      [ok({ data: { updatePullRequestReview: {} } }), REASON_POST_UNREADABLE],
    ]
    for (const [answer, message] of answers) {
      const { gh } = fakeGh([threadAdded(), answer])
      const out = await postPendingReview(gh, args({ pending: mine() }))
      expect(out).toEqual({ added: 1, message, ok: false, unknownResult: true })
    }
  })

  it('refuses a body answer that is not PENDING', async () => {
    const { gh } = fakeGh([threadAdded(), bodySet('COMMENTED')])
    const out = await postPendingReview(gh, args({ pending: mine() }))
    expect(out).toEqual({ added: 1, message: REASON_NOT_PENDING, ok: false })
  })

  it('a range comment sends startLine and startSide', async () => {
    const { gh, calls } = fakeGh([threadAdded(), bodySet()])
    await postPendingReview(gh, args({ comments: [comment({ startLine: 10 })], pending: mine() }))
    expect(field(calls[0], 'startLine')).toEqual({ flag: '-F', value: '10' })
    expect(field(calls[0], 'startSide')).toEqual({ flag: '-f', value: 'RIGHT' })
  })

  it('refuses a joined body longer than MAX_REVIEW_BODY before any call', async () => {
    // The joined body is the body, a blank line (2 characters) and the summary (4 characters).
    const summary = 'Sum.'
    const fits = 'a'.repeat(MAX_REVIEW_BODY - 2 - summary.length)
    const over = await postPendingReview(
      fakeGh([]).gh,
      args({ pending: mine(`${fits}a`), summary }),
    )
    expect(over).toEqual({ added: 0, message: REASON_DRAFT_TOO_LONG, ok: false })
    const alone = await postPendingReview(
      fakeGh([]).gh,
      args({ pending: mine(' '), summary: 'x'.repeat(MAX_REVIEW_BODY + 1) }),
    )
    expect(alone).toEqual({ added: 0, message: REASON_SUMMARY_TOO_LONG, ok: false })

    const { gh, calls } = fakeGh([threadAdded(), bodySet()])
    expect((await postPendingReview(gh, args({ pending: mine(fits), summary }))).ok).toBe(true)
    expect(field(calls[1], 'body')?.value).toHaveLength(MAX_REVIEW_BODY)
  })
})

describe('postPendingReview with nothing to post', () => {
  it('makes no call', async () => {
    for (const pending of [null, mine()]) {
      const { gh, calls } = fakeGh([])
      const out = await postPendingReview(gh, args({ comments: [], pending, summary: ' ' }))
      expect(out).toEqual({ added: 0, message: 'nothing to post', ok: false })
      expect(calls).toEqual([])
    }
  })
})
