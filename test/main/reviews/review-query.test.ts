import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import type { ExecResult } from '../../../src/main/claude/cli'
import type { Gh } from '../../../src/main/reviews/gh'
import {
  fetchReviewContext,
  lastSubmittedReview,
  MAX_PAGES,
  type ViewerReview,
} from '../../../src/main/reviews/review-query'
import {
  draftNotice,
  REASON_PR_READ_FAILED,
  reviewedNotice,
  trustNotice,
} from '../../../src/main/reviews/round-text'
import { RECOMMENDATION_TEXT } from '../../../src/shared/reviews'

const load = (name: string): unknown =>
  JSON.parse(readFileSync(new URL(`../../fixtures/reviews/${name}.json`, import.meta.url), 'utf8'))

interface PrFx {
  [k: string]: unknown
  pending: { nodes: { [k: string]: unknown }[] }
  reviews: { nodes: { [k: string]: unknown }[] }
  state?: string
}
interface Fx {
  data: { repository: { pullRequest: PrFx } }
  errors?: unknown
}
interface Threads {
  data: {
    repository: {
      pullRequest: { reviewThreads: { pageInfo: { endCursor: string; hasNextPage: boolean } } }
    }
  }
}
const loadFx = (name: string): Fx => structuredClone(load(name)) as Fx
const loadPages = (): Fx[] => (load('context-rereview') as { pages: Fx[] }).pages

const ok = (body: unknown): ExecResult => ({ code: 0, stderr: '', stdout: JSON.stringify(body) })

const PR = { number: 7, owner: 'acme', repo: 'api' }

// The variables of one call: -f name=value and -F name=value.
function vars(args: string[]): Record<string, string> {
  const out: Record<string, string> = {}
  for (let i = 0; i < args.length; i++) {
    if ((args[i] === '-f' || args[i] === '-F') && !args[i + 1]?.startsWith('query=')) {
      const [k, ...v] = (args[i + 1] ?? '').split('=')
      out[k ?? ''] = v.join('=')
    }
  }
  return out
}

const queryOf = (args: string[]): string => args.find(a => a.startsWith('query=')) ?? ''

// The directives of a query that do not follow a name or the arguments of a field. GraphQL puts
// a directive before the selection set of its field. GitHub refuses each other place.
const badDirectives = (query: string): string[] =>
  [...query.matchAll(/(\S)\s*@\w+/g)].filter(m => !/[\w)]/.test(m[1] ?? '')).map(m => m[0])

function fakeGh(
  answer: (
    op: 'ReviewContext' | 'ReviewThreads',
    v: Record<string, string>,
    n: number,
  ) => ExecResult,
): { gh: Gh; calls: string[][] } {
  const calls: string[][] = []
  const counts = { ReviewContext: 0, ReviewThreads: 0 }
  const gh: Gh = {
    async run(args) {
      calls.push(args)
      const op = queryOf(args).includes('query ReviewThreads') ? 'ReviewThreads' : 'ReviewContext'
      counts[op] += 1
      return answer(op, vars(args), counts[op])
    },
  }
  return { calls, gh }
}

describe('fetchReviewContext', () => {
  it('reads the PR, the pending review of the viewer and the reviews of the viewer', async () => {
    const first = load('context-first')
    const { gh } = fakeGh(() => ok(first))
    const r = await fetchReviewContext(gh, PR, 'me')
    expect(r.ok).toBe(true)
    if (!r.ok) return
    expect(r.context).toMatchObject({
      author: 'dana',
      baseRef: 'main',
      baseSha: 'a'.repeat(40),
      headRef: 'feat/retry',
      headSha: 'b'.repeat(40),
      number: 7,
      owner: 'acme',
      pending: null,
      repo: 'api',
      reviews: [],
      state: 'OPEN',
      threads: [],
      title: 'Add the retry policy',
      truncated: false,
    })

    const re = { pages: loadPages() }
    const { gh: gh2, calls } = fakeGh((_op, v) =>
      ok(v.after === 'CUR1' ? re.pages[1] : re.pages[0]),
    )
    const r2 = await fetchReviewContext(gh2, PR, 'me')
    expect(r2.ok).toBe(true)
    if (!r2.ok) return
    expect(r2.context.pending).toEqual({
      body: 'My draft',
      commit: 'c'.repeat(40),
      id: 'PRR_mine',
    })
    expect(r2.context.reviews.map(x => x.state)).toEqual([
      'APPROVED',
      'COMMENTED',
      'CHANGES_REQUESTED',
    ])
    expect(r2.context.reviews[1]?.replyOnly).toBe(true)
    expect(r2.context.reviews[2]?.replyOnly).toBe(false)
    expect(r2.context.reviews[2]?.submittedAt).toBe(Date.parse('2026-11-05T10:00:00Z'))
    expect(r2.context.reviews[2]?.commit).toBe('b'.repeat(40))
    expect(lastSubmittedReview(r2.context.reviews)?.state).toBe('CHANGES_REQUESTED')
    // Reviews exist, so the threads were read too.
    expect(calls.some(c => queryOf(c).includes('query ReviewThreads'))).toBe(true)
  })

  it('pages the reviews and stops at MAX_PAGES with truncated', async () => {
    const endless = loadPages()[0]
    const { gh, calls } = fakeGh(op =>
      op === 'ReviewThreads' ? ok(load('threads-1')) : ok(endless),
    )
    const r = await fetchReviewContext(gh, PR, 'me')
    expect(r.ok).toBe(true)
    if (!r.ok) return
    const contextCalls = calls.filter(c => queryOf(c).includes('query ReviewContext'))
    expect(contextCalls).toHaveLength(MAX_PAGES)
    expect(r.context.truncated).toBe(true)
    expect(r.context.reviews).toHaveLength(MAX_PAGES * 2)
  })

  it('keeps only the threads that the viewer started', async () => {
    const re = { pages: loadPages() }
    const { gh } = fakeGh((op, v) => {
      if (op === 'ReviewThreads') return ok(load('threads-1'))
      return ok(v.after === 'CUR1' ? re.pages[1] : re.pages[0])
    })
    const r = await fetchReviewContext(gh, PR, 'me')
    expect(r.ok).toBe(true)
    if (!r.ok) return
    expect(r.context.threads).toEqual([
      {
        comments: [
          { author: 'Me', body: 'Add a test here.' },
          { author: 'dana', body: 'Done.' },
        ],
        isOutdated: false,
        isResolved: false,
        line: 42,
        path: 'src/client.ts',
        url: 'https://github.com/acme/api/pull/7#discussion_r1',
      },
    ])
    expect(r.context.truncated).toBe(false)
  })

  it('sets truncated when the thread list is cut', async () => {
    const re = { pages: loadPages() }
    const threads = structuredClone(load('threads-1')) as Threads
    threads.data.repository.pullRequest.reviewThreads.pageInfo = {
      endCursor: 'T',
      hasNextPage: true,
    }
    const { gh, calls } = fakeGh((op, v) => {
      if (op === 'ReviewThreads') return ok(threads)
      return ok(v.after === 'CUR1' ? re.pages[1] : re.pages[0])
    })
    const r = await fetchReviewContext(gh, PR, 'me')
    expect(r.ok && r.context.truncated).toBe(true)
    expect(calls.filter(c => queryOf(c).includes('query ReviewThreads'))).toHaveLength(MAX_PAGES)
  })

  it('passes the owner, repo and number as variables', async () => {
    const { gh, calls } = fakeGh(() => ok(load('context-first')))
    await fetchReviewContext(gh, PR, 'me')
    const args = calls[0] ?? []
    expect(args).toContain('owner=acme')
    expect(args.join(' ')).toContain('-f owner=acme')
    expect(args.join(' ')).toContain('-F number=7')
    expect(args.join(' ')).toContain('-f login=me')
    expect(queryOf(args)).not.toContain('acme')
    expect(queryOf(args)).not.toContain('api')
  })

  it('puts each directive before the selection set of its field', async () => {
    const pages = loadPages()
    const { gh, calls } = fakeGh((op, v) => {
      if (op === 'ReviewThreads') return ok(load('threads-1'))
      return ok(v.after === 'CUR1' ? pages[1] : pages[0])
    })
    await fetchReviewContext(gh, PR, 'me')
    const queries = [...new Set(calls.map(queryOf))]
    expect(queries.some(q => q.includes('query ReviewContext'))).toBe(true)
    expect(queries.some(q => q.includes('query ReviewThreads'))).toBe(true)
    for (const query of queries) expect(badDirectives(query)).toEqual([])
  })

  it('gives pending null when the draft has no id', async () => {
    const fx = loadFx('context-first')
    fx.data.repository.pullRequest.pending.nodes = [
      { body: 'x', commit: null, id: '', viewerDidAuthor: true },
    ]
    const { gh } = fakeGh(() => ok(fx))
    const r = await fetchReviewContext(gh, PR, 'me')
    expect(r.ok && r.context.pending).toBeNull()
  })

  it('fails with the first error message, also when data is present', async () => {
    const fx = loadFx('context-first')
    fx.errors = [{ message: 'Partial failure' }]
    const { gh } = fakeGh(() => ok(fx))
    expect(await fetchReviewContext(gh, PR, 'me')).toEqual({
      detail: 'Partial failure',
      message: REASON_PR_READ_FAILED,
      ok: false,
    })
  })

  it('skips a review with an unknown state', async () => {
    const fx = loadFx('context-first')
    fx.data.repository.pullRequest.reviews.nodes = [
      { body: 'x', comments: { nodes: [] }, state: 'WEIRD', submittedAt: '2026-11-01T10:00:00Z' },
      {
        body: 'y',
        comments: { nodes: [] },
        state: 'APPROVED',
        submittedAt: '2026-11-02T10:00:00Z',
      },
    ]
    const { gh } = fakeGh(op => (op === 'ReviewThreads' ? ok(load('threads-1')) : ok(fx)))
    const r = await fetchReviewContext(gh, PR, 'me')
    expect(r.ok && r.context.reviews.map(x => x.state)).toEqual(['APPROVED'])
  })

  it('fails when the PR state is missing or unknown', async () => {
    for (const state of [undefined, 'WEIRD']) {
      const fx = loadFx('context-first')
      fx.data.repository.pullRequest.state = state
      const { gh } = fakeGh(() => ok(fx))
      const r = await fetchReviewContext(gh, PR, 'me')
      expect(r.ok).toBe(false)
    }
  })

  it('reads only the review page from page 2 on', async () => {
    const pages = loadPages()
    const { gh, calls } = fakeGh((_op, v) => ok(v.after === 'CUR1' ? pages[1] : pages[0]))
    await fetchReviewContext(gh, PR, 'me')
    const ctx = calls.filter(c => queryOf(c).includes('query ReviewContext'))
    expect(ctx[0]?.join(' ')).toContain('-F head=true')
    expect(ctx[1]?.join(' ')).toContain('-F head=false')
  })

  it('reads no threads when only a pending review of the viewer exists', async () => {
    const fx = loadFx('context-first')
    const pr = fx.data.repository.pullRequest
    pr.pending.nodes = [{ body: 'd', commit: null, id: 'PRR_1', viewerDidAuthor: true }]
    pr.reviews.nodes = [{ body: 'd', comments: { nodes: [] }, state: 'PENDING', submittedAt: null }]
    const { gh, calls } = fakeGh(() => ok(fx))
    const r = await fetchReviewContext(gh, PR, 'me')
    expect(r.ok && r.context.pending?.id).toBe('PRR_1')
    expect(r.ok && r.context.threads).toEqual([])
    expect(calls.some(c => queryOf(c).includes('query ReviewThreads'))).toBe(false)
  })

  it('uses ghFailure for a failed call', async () => {
    const { gh } = fakeGh(() => ({ code: 1, stderr: 'boom\nmore', stdout: '' }))
    expect(await fetchReviewContext(gh, PR, 'me')).toEqual({
      detail: 'boom',
      message: REASON_PR_READ_FAILED,
      ok: false,
    })
  })

  it('fails when the answer has no pull request', async () => {
    const { gh } = fakeGh(() => ok({ data: { repository: null }, errors: [{ message: 'Gone' }] }))
    const r = await fetchReviewContext(gh, PR, 'me')
    expect(r).toEqual({ detail: 'Gone', message: REASON_PR_READ_FAILED, ok: false })
  })

  it('fails on text that is not JSON', async () => {
    const { gh } = fakeGh(() => ({ code: 0, stderr: '', stdout: 'nope' }))
    const r = await fetchReviewContext(gh, PR, 'me')
    expect(r.ok).toBe(false)
  })
})

describe('lastSubmittedReview', () => {
  const rv = (extra: Partial<ViewerReview>): ViewerReview => ({
    body: 'x',
    commit: null,
    replyOnly: false,
    state: 'COMMENTED',
    submittedAt: 1,
    url: 'u',
    ...extra,
  })

  it('skips PENDING and reply-only reviews', () => {
    const list = [
      rv({ state: 'APPROVED', submittedAt: 10 }),
      rv({ replyOnly: true, state: 'COMMENTED', submittedAt: 30 }),
      rv({ state: 'PENDING', submittedAt: 40 }),
      rv({ state: 'CHANGES_REQUESTED', submittedAt: 20 }),
    ]
    expect(lastSubmittedReview(list)?.submittedAt).toBe(20)
    expect(lastSubmittedReview([rv({ state: 'PENDING' })])).toBeNull()
    expect(lastSubmittedReview([])).toBeNull()
  })
})

describe('the notices', () => {
  it('use RECOMMENDATION_TEXT', () => {
    const pr = { number: 7, repo: 'api' }
    const text = RECOMMENDATION_TEXT['request-changes']
    expect(draftNotice(pr, 'request-changes')).toEqual({
      body: `Your draft review is ready. Claude suggests: ${text}.`,
      title: 'api #7',
    })
    expect(reviewedNotice(pr).body).toBe(
      'Claude found nothing to flag and suggests you approve. Nothing was posted.',
    )
    expect(trustNotice('acme/api')).toEqual({
      body: 'Trust acme/api in Bifrost so Claude can work on its pull requests.',
      title: 'Trust needed',
    })
  })
})
