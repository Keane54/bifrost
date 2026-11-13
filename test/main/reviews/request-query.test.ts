import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import type { ExecResult } from '../../../src/main/claude/cli'
import type { Gh } from '../../../src/main/reviews/gh'
import { splitWork } from '../../../src/main/reviews/model'
import type { PrData } from '../../../src/main/reviews/pr-data'
import {
  asPrData,
  fetchRequestContext,
  MAX_READ_CALLS,
} from '../../../src/main/reviews/request-query'
import { MAX_PAGES } from '../../../src/main/reviews/review-query'
import { REASON_PR_READ_FAILED } from '../../../src/main/reviews/round-text'
import { emptyPrState } from '../../../src/main/reviews/state'

type Json = Record<string, unknown>
type Op = 'RequestContext' | 'RequestThreads' | 'ThreadComments' | 'RequestComments'

const load = (name: string): Json =>
  JSON.parse(readFileSync(new URL(`../../fixtures/reviews/${name}.json`, import.meta.url), 'utf8'))

const ok = (body: unknown): ExecResult => ({ code: 0, stderr: '', stdout: JSON.stringify(body) })

const PR = { number: 9, owner: 'acme', repo: 'api' }
const VIEWER = 'dana'
const A = 'a'.repeat(40)
const B = 'b'.repeat(40)

const queryOf = (args: string[]): string => args.find(a => a.startsWith('query=')) ?? ''

function opOf(args: string[]): Op {
  const name = /query (\w+)/.exec(queryOf(args))?.[1]
  if (
    name === 'RequestContext' ||
    name === 'RequestThreads' ||
    name === 'ThreadComments' ||
    name === 'RequestComments'
  ) {
    return name
  }
  throw new Error(`unknown operation ${name}`)
}

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

// The answers of the fixtures for acme/api#9.
function fixture(op: Op, v: Record<string, string>): Json {
  switch (op) {
    case 'RequestContext':
      return load('request-context-1')
    case 'RequestThreads':
      return load(v.after === 'THREADS_1' ? 'request-threads-2' : 'request-threads-1')
    case 'ThreadComments':
      if (v.id !== 'PRRT_long1' || v.after !== 'LONG_1') throw new Error('unexpected thread')
      return load('thread-comments-1')
    case 'RequestComments':
      return load('request-comments-1')
  }
}

function fakeGh(
  answer: (op: Op, v: Record<string, string>, n: number) => ExecResult = (op, v) =>
    ok(fixture(op, v)),
): { gh: Gh; calls: string[][]; counts: Record<Op, number> } {
  const calls: string[][] = []
  const counts: Record<Op, number> = {
    RequestComments: 0,
    RequestContext: 0,
    RequestThreads: 0,
    ThreadComments: 0,
  }
  const gh: Gh = {
    async run(args) {
      calls.push(args)
      const op = opOf(args)
      counts[op] += 1
      return answer(op, vars(args), counts[op])
    },
  }
  return { calls, counts, gh }
}

// The pull request object of an answer of the fixtures.
const prOf = (body: Json): Json => ((body.data as Json).repository as Json).pullRequest as Json

async function context() {
  const r = await fetchRequestContext(fakeGh().gh, PR)
  if (!r.ok) throw new Error(r.message)
  return r.context
}

function polled(over: Partial<PrData> = {}): PrData {
  return {
    additions: 1,
    author: VIEWER,
    baseRef: 'main',
    comments: [],
    createdAt: 1,
    decisions: [],
    deletions: 1,
    failedChecks: 0,
    headRef: 'feature',
    headSha: B,
    isCrossRepository: false,
    isDraft: false,
    key: 'acme/api#9',
    number: 9,
    owner: 'acme',
    repo: 'api',
    requestedAt: 1,
    requestedTeams: [],
    requestedUsers: [],
    reviewDecision: 'CHANGES_REQUESTED',
    reviews: [],
    threads: [],
    title: 'Add the rate limit',
    truncatedChecks: true,
    truncatedComments: true,
    truncatedReviews: true,
    truncatedThreads: true,
    updatedAt: 5,
    url: 'https://github.com/acme/api/pull/9',
    viewerPendingReviewId: null,
    ...over,
  }
}

describe('fetchRequestContext', () => {
  it('reads the PR fields, default branch, decisions with user IDs and open requests', async () => {
    const c = await context()
    expect(c).toMatchObject({
      author: 'dana',
      baseRef: 'main',
      baseSha: A,
      body: 'This adds a rate limit to the client.',
      defaultBranch: 'main',
      headRef: 'feature',
      headSha: B,
      id: 'PR_kwDOacme9',
      isCrossRepository: false,
      number: 9,
      owner: 'acme',
      repo: 'api',
      state: 'OPEN',
      title: 'Add the rate limit',
      truncated: false,
      updatedAt: Date.parse('2026-11-12T10:00:00Z'),
      url: 'https://github.com/acme/api/pull/9',
      viewerPending: false,
    })
    expect(c.decisions).toEqual([
      { bot: false, login: 'alice', state: 'CHANGES_REQUESTED', userId: 'U_kgDOalice' },
    ])
    expect(c.requested).toEqual(['carol'])
    expect(c.reviews.map(r => r.id)).toEqual(['PRR_copilot1', 'PRR_alice1'])
    expect(c.reviews[0]?.author).toEqual({
      association: 'NONE',
      bot: true,
      login: 'copilot-pull-request-reviewer',
    })
    expect(c.reviews[1]).toMatchObject({
      author: { association: 'MEMBER', bot: false, login: 'alice' },
      body: 'Please add a limit check.',
      commit: B,
      state: 'CHANGES_REQUESTED',
      submittedAt: Date.parse('2026-11-11T09:00:00Z'),
    })
  })

  it('pages the threads, the comments of a long thread and the PR comments', async () => {
    const { calls, counts, gh } = fakeGh()
    const r = await fetchRequestContext(gh, PR)
    if (!r.ok) throw new Error(r.message)
    const c = r.context
    expect(counts).toEqual({
      RequestComments: 1,
      RequestContext: 1,
      RequestThreads: 2,
      ThreadComments: 1,
    })
    expect(c.truncated).toBe(false)
    expect(c.threads.map(t => t.id)).toEqual([
      'PRRT_alice1',
      'PRRT_copilot1',
      'PRRT_old1',
      'PRRT_long1',
    ])
    const [alice, copilot, old, long] = c.threads
    expect(alice).toMatchObject({
      diffHunk: expect.stringContaining('@@ -10,3 +10,4 @@'),
      isOutdated: false,
      isResolved: false,
      line: 12,
      path: 'src/limit.ts',
      reviewId: 'PRR_alice1',
      viewerCanReply: true,
    })
    expect(alice?.comments.map(m => [m.id, m.author.login, m.author.association])).toEqual([
      ['PRRC_1', 'alice', 'MEMBER'],
      ['PRRC_2', 'dana', 'OWNER'],
    ])
    expect(alice?.comments[0]?.createdAt).toBe(Date.parse('2026-11-11T09:00:00Z'))
    expect(copilot?.reviewId).toBe('PRR_copilot1')
    expect(copilot?.comments[0]?.author.bot).toBe(true)
    expect(old).toMatchObject({ isOutdated: true, line: null, path: 'src/old.ts' })
    expect(long?.comments).toHaveLength(52)
    expect(long?.comments.at(-1)?.id).toBe('PRRC_long52')
    expect(long?.diffHunk).toBe('@@ -1,2 +1,3 @@\n+export const LONG = 1')
    expect(c.comments.map(m => [m.id, m.author.association])).toEqual([
      ['IC_member1', 'MEMBER'],
      ['IC_none1', 'NONE'],
    ])
    // The next page of the threads and the comments of the long thread use their cursors.
    const threadCalls = calls.filter(a => opOf(a) === 'RequestThreads').map(vars)
    expect(threadCalls.map(v => v.after)).toEqual([undefined, 'THREADS_1'])
    const more = calls.filter(a => opOf(a) === 'ThreadComments').map(vars)
    expect(more).toEqual([{ after: 'LONG_1', id: 'PRRT_long1' }])
  })

  it('stops at MAX_PAGES and sets truncated', async () => {
    // Each list says that it has one more page.
    const endless = (op: Op, v: Record<string, string>, n: number): ExecResult => {
      const page = { endCursor: `C${n}`, hasNextPage: true }
      const body = fixture(op, op === 'ThreadComments' ? { after: 'LONG_1', id: 'PRRT_long1' } : v)
      if (op === 'ThreadComments') {
        ;((body.data as Json).node as Json).comments = { nodes: [], pageInfo: page }
      } else if (op === 'RequestContext') {
        ;(prOf(body).reviews as Json).pageInfo = page
      } else if (op === 'RequestThreads') {
        prOf(body).reviewThreads = {
          nodes: [{ comments: { nodes: [] }, id: `PRRT_${n}`, isResolved: false }],
          pageInfo: page,
        }
      } else {
        ;(prOf(body).comments as Json).pageInfo = page
      }
      return ok(body)
    }
    const all = fakeGh(endless)
    const r = await fetchRequestContext(all.gh, PR)
    expect(r.ok && r.context.truncated).toBe(true)
    expect(all.counts).toEqual({
      RequestComments: MAX_PAGES,
      RequestContext: MAX_PAGES,
      RequestThreads: MAX_PAGES,
      ThreadComments: 0,
    })
    if (r.ok) expect(r.context.threads).toHaveLength(MAX_PAGES)

    // One cut list is enough. The comments of one thread count their first page too.
    const longOnly = fakeGh((op, v, n) =>
      op === 'ThreadComments' ? endless(op, v, n) : ok(fixture(op, v)),
    )
    const cut = await fetchRequestContext(longOnly.gh, PR)
    expect(cut.ok && cut.context.truncated).toBe(true)
    expect(longOnly.counts.ThreadComments).toBe(MAX_PAGES - 1)

    for (const list of ['latestOpinionatedReviews', 'reviewRequests'] as const) {
      const one = fakeGh((op, v) => {
        const body = fixture(op, v)
        if (op === 'RequestContext') (prOf(body)[list] as Json).pageInfo = { hasNextPage: true }
        return ok(body)
      })
      const read = await fetchRequestContext(one.gh, PR)
      expect(read.ok && read.context.truncated, list).toBe(true)
    }

    // A page that has more items but no cursor cuts the list too.
    const noCursor = fakeGh((op, v) => {
      const body = fixture(op, v)
      if (op === 'RequestComments') (prOf(body).comments as Json).pageInfo = { hasNextPage: true }
      return ok(body)
    })
    const stopped = await fetchRequestContext(noCursor.gh, PR)
    expect(stopped.ok && stopped.context.truncated).toBe(true)
    expect(noCursor.counts.RequestComments).toBe(1)
  })

  it('stops at MAX_READ_CALLS calls in all and sets truncated', async () => {
    // Each page of threads has 50 threads with more comments, and each thread has more pages.
    const { calls, counts, gh } = fakeGh((op, v, n) => {
      const body = fixture(op, op === 'ThreadComments' ? { after: 'LONG_1', id: 'PRRT_long1' } : v)
      const more = { endCursor: `C${n}`, hasNextPage: true }
      if (op === 'RequestThreads') {
        prOf(body).reviewThreads = {
          nodes: Array.from({ length: 50 }, (_, i) => ({
            comments: { nodes: [], pageInfo: more },
            id: `PRRT_${n}_${i}`,
            isResolved: false,
          })),
          pageInfo: more,
        }
      }
      if (op === 'ThreadComments') {
        ;((body.data as Json).node as Json).comments = { nodes: [], pageInfo: more }
      }
      return ok(body)
    })
    const r = await fetchRequestContext(gh, PR)
    if (!r.ok) throw new Error(r.message)
    expect(r.context.truncated).toBe(true)
    expect(calls).toHaveLength(MAX_READ_CALLS)
    // The main lists come first, so the budget never cuts the PR comments.
    expect(counts.RequestThreads).toBe(MAX_PAGES)
    expect(counts.RequestComments).toBe(1)
    expect(r.context.comments).toHaveLength(2)
    expect(r.context.threads).toHaveLength(50 * MAX_PAGES)
  })

  it('an answer with errors fails', async () => {
    for (const failing of [
      'RequestContext',
      'RequestThreads',
      'ThreadComments',
      'RequestComments',
    ] as const) {
      const { gh } = fakeGh((op, v) => {
        const body = fixture(op, v)
        return ok(op === failing ? { ...body, errors: [{ message: 'Something failed' }] } : body)
      })
      // The row gets the friendly text. The raw text is the detail for the Event log.
      expect(await fetchRequestContext(gh, PR), failing).toEqual({
        detail: 'Something failed',
        message: REASON_PR_READ_FAILED,
        ok: false,
      })
    }
    // A failed call and a PR state that Bifrost does not know fail too.
    const down = fakeGh(() => ({ code: 1, stderr: 'HTTP 502\nmore', stdout: '' }))
    expect(await fetchRequestContext(down.gh, PR)).toEqual({
      detail: 'HTTP 502',
      message: REASON_PR_READ_FAILED,
      ok: false,
    })
    const odd = fakeGh((op, v) => {
      const body = fixture(op, v)
      if (op === 'RequestContext') prOf(body).state = 'DRAFT'
      return ok(body)
    })
    expect((await fetchRequestContext(odd.gh, PR)).ok).toBe(false)
  })

  it('passes each value as a variable', async () => {
    const { calls, gh } = fakeGh()
    await fetchRequestContext(gh, PR)
    const first = calls[0] ?? []
    expect(first.join(' ')).toContain('-f owner=acme')
    expect(first.join(' ')).toContain('-f repo=api')
    expect(first.join(' ')).toContain('-F number=9')
    expect(first.join(' ')).toContain('-F head=true')
    const node = calls.find(a => opOf(a) === 'ThreadComments') ?? []
    expect(node.join(' ')).toContain('-f id=PRRT_long1')
    expect(node.join(' ')).toContain('-f after=LONG_1')
    expect(vars(node)).not.toHaveProperty('owner')
    for (const args of calls) {
      const query = queryOf(args)
      expect(query).not.toContain('acme')
      expect(query).not.toContain('PRRT_long1')
      expect(query).not.toContain('THREADS_1')
      expect(query).not.toContain('LONG_1')
    }
  })

  it('puts each directive before the selection set of its field', async () => {
    const { calls, gh } = fakeGh()
    await fetchRequestContext(gh, PR)
    for (const args of calls) {
      const bad = [...queryOf(args).matchAll(/(\S)\s*@\w+/g)].filter(m => !/[\w)]/.test(m[1] ?? ''))
      expect(bad).toEqual([])
    }
  })

  it('viewerPending is true only for a pending review of the viewer', async () => {
    const withPending = (nodes: unknown[]) =>
      fakeGh((op, v) => {
        const body = fixture(op, v)
        if (op === 'RequestContext') prOf(body).pending = { nodes }
        return ok(body)
      }).gh
    const read = async (nodes: unknown[]) => {
      const r = await fetchRequestContext(withPending(nodes), PR)
      return r.ok && r.context.viewerPending
    }
    expect(await read([{ viewerDidAuthor: false }])).toBe(false)
    expect(await read([])).toBe(false)
    expect(await read([{ viewerDidAuthor: false }, { viewerDidAuthor: true }])).toBe(true)
  })

  it('asPrData gives splitWork the full lists', async () => {
    const c = await context()
    const before = polled()
    expect(splitWork(before, VIEWER, emptyPrState(), new Set(), null).work).toEqual([])
    const full = asPrData(c, before)
    expect(full.threads).toHaveLength(4)
    expect(full.reviews).toHaveLength(2)
    expect(full.comments).toHaveLength(2)
    expect(full).toMatchObject({
      decisions: [],
      key: 'acme/api#9',
      truncatedChecks: true,
      truncatedComments: false,
      truncatedReviews: false,
      truncatedThreads: false,
    })
    const split = splitWork(full, VIEWER, emptyPrState(), new Set(), null)
    expect(split.work.map(i => i.id)).toEqual([
      'PRRT_alice1',
      'PRRT_copilot1',
      'PRRT_old1',
      'PRRT_long1',
      'PRR_alice1',
      'IC_member1',
    ])
    expect(asPrData({ ...c, truncated: true }, before).truncatedThreads).toBe(true)
  })
})
