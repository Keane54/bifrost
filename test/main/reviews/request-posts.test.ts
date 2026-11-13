import { describe, expect, it } from 'vitest'
import type { ExecResult } from '../../../src/main/claude/cli'
import type { Gh } from '../../../src/main/reviews/gh'
import type { WorkItem } from '../../../src/main/reviews/model'
import type { Author, PrComment } from '../../../src/main/reviews/pr-data'
import {
  buildOutbox,
  POST_GAP_MS,
  type PostDeps,
  type PostsOutcome,
  runPosts,
  SENT_WINDOW_MS,
} from '../../../src/main/reviews/request-posts'
import type { PushOutcome } from '../../../src/main/reviews/request-push'
import type { RequestContext, RequestThread } from '../../../src/main/reviews/request-query'
import type { RequestResult } from '../../../src/main/reviews/request-result'
import { defuseMentions } from '../../../src/main/reviews/request-writes'
import {
  REASON_BAD_PR,
  REASON_FIX_PR_CLOSED,
  REASON_FORK,
  REASON_NOT_YOURS,
  REASON_OWN_PENDING,
  REASON_POSTS_READ_FAILED,
  REASON_PR_READ_FAILED,
  REASON_PUSH_CONFLICT,
  REASON_PUSH_MOVED,
  REASON_PUSH_TARGET,
  REASON_REPLY_PENDING,
  REASON_SIGNED_EXECUTABLE,
  REASON_TOO_MANY_COMMENTS,
  REASON_WRITE_FAILED,
  REASON_WRITE_TIMEOUT,
  reasonCommitFailed,
  reasonPostsStopped,
  reasonPushFailed,
  reasonUserStoppedPosts,
} from '../../../src/main/reviews/round-text'
import type { Outbox, Post } from '../../../src/main/reviews/state'
import { REASON_GH_TIMEOUT } from '../../../src/shared/reviews'

const KEY = 'acme/api#9'
const VIEWER = 'dana'
const HEAD = 'a'.repeat(40)
const BASE = 'b'.repeat(40)
const FIX = 'c'.repeat(40)
const MERGE = 'd'.repeat(40)
const BY = 'e'.repeat(40)
const NEW_HEAD = 'f'.repeat(40)
const START = Date.parse('2026-11-12T10:00:00Z')
const ASKED = START - 60_000
const NOW = START + 99
// The zero-width space that defuses a mention.
const Z = '\u200b'
// No open item of a reviewer.
const NONE: ReadonlySet<string> = new Set()

const author = (login: string, over: Partial<Author> = {}): Author => ({
  association: 'MEMBER',
  bot: false,
  login,
  ...over,
})

function comment(
  id: string,
  login: string,
  body: string,
  createdAt: number,
  over: Partial<Author> = {},
): PrComment {
  return { author: author(login, over), body, createdAt, databaseId: 1, id }
}

function thread(id: string, over: Partial<RequestThread> = {}): RequestThread {
  return {
    comments: [comment(`${id}_c1`, 'ravi', 'Rename this.', ASKED)],
    diffHunk: '',
    id,
    isOutdated: false,
    isResolved: false,
    line: 3,
    path: 'src/a.ts',
    reviewId: 'PRR_1',
    viewerCanReply: true,
    ...over,
  }
}

function context(over: Partial<RequestContext> = {}): RequestContext {
  return {
    author: VIEWER,
    baseRef: 'main',
    baseSha: BASE,
    body: '',
    comments: [comment('IC_1', 'ravi', 'Please add a test, @mia.', ASKED)],
    decisions: [],
    defaultBranch: 'main',
    headRef: 'feature',
    headSha: HEAD,
    id: 'PR_1',
    isCrossRepository: false,
    number: 9,
    owner: 'acme',
    repo: 'api',
    requested: [],
    reviews: [
      {
        author: author('ravi'),
        body: 'Split this PR.',
        commit: HEAD,
        databaseId: 2,
        id: 'PRR_9',
        state: 'CHANGES_REQUESTED',
        submittedAt: ASKED,
      },
    ],
    state: 'OPEN',
    threads: [thread('PRRT_1'), thread('PRRT_2')],
    title: 'Add the rate limit',
    truncated: false,
    updatedAt: ASKED,
    url: 'https://github.com/acme/api/pull/9',
    viewerPending: false,
    ...over,
  }
}

const COMMIT: Post = {
  id: 'commit',
  kind: 'commit',
  message: 'fix: rename the value',
  paths: ['src/a.ts'],
  state: 'todo',
}
const PUSH: Post = { id: 'push', kind: 'push', state: 'todo' }
const REREQUEST: Post = { id: 'rerequest', kind: 'rerequest', state: 'todo' }

const reply = (itemId: string, text: string | null, over: Partial<Post> = {}): Post =>
  ({ id: `reply:${itemId}`, itemId, kind: 'reply', state: 'todo', text, ...over }) as Post
const resolve = (itemId: string, over: Partial<Post> = {}): Post =>
  ({ id: `resolve:${itemId}`, itemId, kind: 'resolve', state: 'todo', ...over }) as Post
const prComment = (
  itemId: string,
  quote: string,
  text: string | null,
  over: Partial<Post> = {},
): Post =>
  ({
    id: `comment:${itemId}`,
    itemId,
    kind: 'comment',
    quote,
    state: 'todo',
    text,
    ...over,
  }) as Post

function outbox(posts: Post[]): Outbox {
  return {
    headSha: HEAD,
    mergeBase: BASE,
    posts: posts.map(post => structuredClone(post)),
    seen: { IC_1: ASKED, PRR_9: ASKED, PRRT_1: ASKED, PRRT_2: ASKED },
    startedAt: START,
  }
}

type Op = 'ReplyToThread' | 'ResolveThread' | 'CommentOnPr' | 'RequestReviewer'

interface Write {
  op: Op
  vars: Record<string, string>
}

function writeOf(args: string[]): Write {
  const vars: Record<string, string> = {}
  let query = ''
  for (let i = 2; i < args.length; i += 2) {
    const [name = '', ...rest] = (args[i + 1] ?? '').split('=')
    if (name === 'query') query = rest.join('=')
    else vars[name] = rest.join('=')
  }
  const op = /^mutation (\w+)/.exec(query)?.[1]
  if (
    op !== 'ReplyToThread' &&
    op !== 'ResolveThread' &&
    op !== 'CommentOnPr' &&
    op !== 'RequestReviewer'
  ) {
    throw new Error(`not a write of a request round: ${op}`)
  }
  return { op, vars }
}

const answer = (data: unknown): ExecResult => ({
  code: 0,
  stderr: '',
  stdout: JSON.stringify({ data }),
})

// The answer of GitHub to each write, by the name of the operation.
function okAnswer(write: Write, n: number): ExecResult {
  const createdAt = new Date(START + n * 1_000).toISOString()
  switch (write.op) {
    case 'ReplyToThread':
      return answer({
        addPullRequestReviewThreadReply: {
          comment: { createdAt, id: `PRRC_new${n}`, state: 'SUBMITTED' },
        },
      })
    case 'ResolveThread':
      return answer({
        resolveReviewThread: { thread: { id: write.vars.thread, isResolved: true } },
      })
    case 'CommentOnPr':
      return answer({ addComment: { commentEdge: { node: { createdAt, id: `IC_new${n}` } } } })
    case 'RequestReviewer':
      return answer({ requestReviews: { pullRequest: { id: write.vars.pr } } })
  }
}

interface Harness {
  deps: PostDeps
  // The steps of the run: context, commit, push, sleep and each write.
  log: string[]
  writes: Write[]
  saves: Outbox[]
  // The raw error texts that go to the Event log.
  details: string[]
}

function harness(
  o: {
    contexts?: RequestContext[]
    answer?: (write: Write, n: number) => ExecResult | undefined
    commit?: () => { ok: true; sha: string } | { ok: false; message: string }
    push?: (fix: string, signed: boolean) => PushOutcome
    saveFails?: (n: number) => boolean
    // True when the user stopped the round. n is the count of writes so far.
    stopped?: (n: number) => boolean
  } = {},
): Harness {
  const log: string[] = []
  const writes: Write[] = []
  const saves: Outbox[] = []
  const details: string[] = []
  const contexts = o.contexts ?? [context()]
  let reads = 0
  const gh: Gh = {
    async run(args) {
      const write = writeOf(args)
      writes.push(write)
      log.push(`write ${write.op}`)
      return o.answer?.(write, writes.length) ?? okAnswer(write, writes.length)
    },
  }
  const deps: PostDeps = {
    async commit() {
      log.push('commit')
      return o.commit?.() ?? { ok: true, sha: FIX }
    },
    async context() {
      const next = contexts[Math.min(reads, contexts.length - 1)] ?? context()
      reads++
      log.push('context')
      return { context: structuredClone(next), ok: true }
    },
    eventDetail: detail => details.push(detail),
    gh,
    now: () => NOW,
    async push(fix, _context, signed) {
      log.push(`push ${fix.slice(0, 7)}${signed ? ' signed' : ''}`)
      return o.push?.(fix, signed) ?? { already: false, merged: false, ok: true, sha: fix }
    },
    async save(box) {
      saves.push(structuredClone(box))
      if (o.saveFails?.(saves.length)) throw new Error('disk full')
    },
    async sleep(ms) {
      log.push(`sleep ${ms}`)
    },
    stopped: () => o.stopped?.(writes.length) ?? false,
    viewer: VIEWER,
  }
  return { deps, details, log, saves, writes }
}

const stateOf = (r: PostsOutcome): Record<string, string> =>
  Object.fromEntries(r.outbox.posts.map(post => [post.id, post.state]))
const postOf = (r: PostsOutcome, id: string): Post | undefined =>
  r.outbox.posts.find(post => post.id === id)

describe('buildOutbox', () => {
  const items: WorkItem[] = [
    { id: 'PRRT_1', kind: 'thread' },
    { id: 'IC_1', kind: 'comment' },
    { id: 'PRRT_2', kind: 'thread' },
    { id: 'PRR_9', kind: 'review-body' },
    { id: 'PRRT_3', kind: 'thread' },
    { id: 'PRRT_4', kind: 'thread' },
  ]
  const result: RequestResult = {
    checks: 'passed',
    commit: { message: 'fix: rename the value', paths: ['src/a.ts'] },
    headSha: HEAD,
    items: [
      { id: 'PRRT_4', outcome: 'needs-you', question: 'Which name?' },
      { by: BY, id: 'PRR_9', outcome: 'fixed' },
      { id: 'PRRT_1', outcome: 'fixed' },
      { id: 'IC_1', outcome: 'no-fix', reply: 'It has one.' },
      { id: 'PRRT_2', outcome: 'no-fix', reply: 'Kept on purpose.' },
      { id: 'PRRT_3', outcome: 'no-action' },
    ],
    pr: KEY,
    version: 1,
  }
  const seen = { IC_1: 1, PRR_9: 2, PRRT_1: 3, PRRT_2: 4, PRRT_3: 5, PRRT_4: 6 }

  it(
    'buildOutbox orders the commit, the push, each reply and its resolve, each PR comment and ' +
      'the re-request',
    () => {
      const box = buildOutbox({
        context: context(),
        head: HEAD,
        items,
        mergeBase: BASE,
        now: START,
        result,
        seen,
      })
      expect(box).toMatchObject({ headSha: HEAD, mergeBase: BASE, seen, startedAt: START })
      expect(box.posts.map(post => post.id)).toEqual([
        'commit',
        'push',
        'reply:PRRT_1',
        'resolve:PRRT_1',
        'comment:IC_1',
        'reply:PRRT_2',
        'resolve:PRRT_2',
        'comment:PRR_9',
        'rerequest',
      ])
      expect(box.posts).toEqual([
        COMMIT,
        PUSH,
        reply('PRRT_1', null),
        resolve('PRRT_1'),
        prComment('IC_1', `> Please add a test, @${Z}mia.`, 'It has one.'),
        reply('PRRT_2', 'Kept on purpose.'),
        resolve('PRRT_2'),
        prComment('PRR_9', '> Split this PR.', null, { by: BY }),
        REREQUEST,
      ])
    },
  )

  it('skips a repeated item ID', () => {
    const box = buildOutbox({
      context: context(),
      head: HEAD,
      items: [
        { id: 'PRRT_1', kind: 'thread' },
        { id: 'PRRT_1', kind: 'thread' },
      ],
      mergeBase: BASE,
      now: START,
      result: { ...result, commit: null, items: [{ by: BY, id: 'PRRT_1', outcome: 'fixed' }] },
      seen: { PRRT_1: 3 },
    })
    expect(box.posts.map(post => post.id)).toEqual(['reply:PRRT_1', 'resolve:PRRT_1', 'rerequest'])
  })

  it('saves the signed method on the push post when the round signs through GitHub', () => {
    const build = (signed?: boolean) =>
      buildOutbox({
        context: context(),
        head: HEAD,
        items: [{ id: 'PRRT_1', kind: 'thread' }],
        mergeBase: BASE,
        now: START,
        result: { ...result, items: [{ id: 'PRRT_1', outcome: 'fixed' }] },
        seen: { PRRT_1: 3 },
        ...(signed === undefined ? {} : { signed }),
      })
    expect(build(true).posts[1]).toEqual({ ...PUSH, signed: true })
    expect(build(false).posts[1]).toEqual(PUSH)
    expect(build().posts[1]).toEqual(PUSH)
    expect(build(false).posts[1]).not.toHaveProperty('signed')
    // With no commit, there is no push post to sign.
    const none = buildOutbox({
      context: context(),
      head: HEAD,
      items: [{ id: 'PRRT_1', kind: 'thread' }],
      mergeBase: BASE,
      now: START,
      result: { ...result, commit: null, items: [{ by: BY, id: 'PRRT_1', outcome: 'fixed' }] },
      seen: { PRRT_1: 3 },
      signed: true,
    })
    expect(none.posts.map(post => post.kind)).toEqual(['reply', 'resolve', 'rerequest'])
  })

  it('makes no commit and no push without a commit in the result', () => {
    const box = buildOutbox({
      context: context(),
      head: HEAD,
      items: [{ id: 'PRRT_1', kind: 'thread' }],
      mergeBase: BASE,
      now: START,
      result: { ...result, commit: null, items: [{ by: BY, id: 'PRRT_1', outcome: 'fixed' }] },
      seen: { PRRT_1: 3 },
    })
    expect(box.posts).toEqual([reply('PRRT_1', null, { by: BY }), resolve('PRRT_1'), REREQUEST])
  })
})

describe('runPosts', () => {
  it('a run after a crash finds a sent reply and does not send it again', async () => {
    const text = 'Kept on purpose, as @ravi said.'
    const body = defuseMentions(text)
    // The viewer login can come in another case.
    const sent = comment('PRRC_old', 'Dana', body, START + 5_000)
    const h = harness({
      contexts: [
        context({ threads: [thread('PRRT_1', { comments: [...thread('x').comments, sent] })] }),
      ],
    })
    const r = await runPosts(
      h.deps,
      KEY,
      outbox([reply('PRRT_1', text, { state: 'sending' }), resolve('PRRT_1')]),
      {},
      NONE,
    )
    expect(h.writes.map(w => w.op)).toEqual(['ResolveThread'])
    expect(r).toMatchObject({ ok: true, posted: [{ at: NOW, body, id: 'PRRC_old', prKey: KEY }] })
    expect(postOf(r, 'reply:PRRT_1')).toMatchObject({ commentId: 'PRRC_old', state: 'done' })

    // A comment of the user with the same text from long before the round does not count.
    const old = comment('PRRC_older', VIEWER, body, START - SENT_WINDOW_MS - 1)
    const h2 = harness({
      contexts: [
        context({ threads: [thread('PRRT_1', { comments: [...thread('x').comments, old] })] }),
      ],
    })
    await runPosts(h2.deps, KEY, outbox([reply('PRRT_1', text, { state: 'sending' })]), {}, NONE)
    expect(h2.writes).toEqual([{ op: 'ReplyToThread', vars: { body, thread: 'PRRT_1' } }])

    // GitHub can give the body back with no zero-width space.
    const plain = comment('PRRC_plain', VIEWER, text, START + 5_000)
    const h3 = harness({
      contexts: [
        context({ threads: [thread('PRRT_1', { comments: [...thread('x').comments, plain] })] }),
      ],
    })
    await runPosts(h3.deps, KEY, outbox([reply('PRRT_1', text, { state: 'sending' })]), {}, NONE)
    expect(h3.writes).toEqual([])
  })

  it('a sending resolve on a resolved thread writes nothing', async () => {
    const h = harness({
      contexts: [context({ threads: [thread('PRRT_1', { isResolved: true })] })],
    })
    const r = await runPosts(
      h.deps,
      KEY,
      outbox([
        reply('PRRT_1', 'Kept.', { commentId: 'PRRC_1', state: 'done' }),
        resolve('PRRT_1', { state: 'sending' }),
      ]),
      {},
      NONE,
    )
    expect(h.writes).toEqual([])
    expect(r.ok).toBe(true)
    expect(stateOf(r)).toEqual({ 'reply:PRRT_1': 'done', 'resolve:PRRT_1': 'done' })
  })

  it('a write with an unknown result is never sent again before a check of GitHub', async () => {
    const posts = [reply('PRRT_1', 'Kept.'), resolve('PRRT_1')]
    const h = harness({
      answer: w =>
        w.op === 'ReplyToThread' ? { code: 1, stderr: '', stdout: '', timedOut: true } : undefined,
    })
    const first = await runPosts(h.deps, KEY, outbox(posts), {}, NONE)
    expect(first).toEqual({
      conflict: false,
      dropOutbox: false,
      message: reasonPostsStopped(0, 2, REASON_WRITE_TIMEOUT),
      ok: false,
      outbox: expect.anything(),
      wrote: true,
    })
    expect(h.writes.map(w => w.op)).toEqual(['ReplyToThread'])
    expect(stateOf(first)['reply:PRRT_1']).toBe('sending')

    // The reply reached GitHub. Try again finds it and sends only the resolve.
    const landed = comment('PRRC_late', VIEWER, 'Kept.', START + 1_000)
    const h2 = harness({
      contexts: [
        context({ threads: [thread('PRRT_1', { comments: [...thread('x').comments, landed] })] }),
      ],
    })
    const again = await runPosts(h2.deps, KEY, first.outbox, {}, NONE)
    expect(h2.writes.map(w => w.op)).toEqual(['ResolveThread'])
    expect(again.ok).toBe(true)
  })

  it('checks a sending PR comment, push, commit and re-request before any new write', async () => {
    const quote = `> Please add a test, @${Z}mia.`
    const posted = comment('IC_mine', VIEWER, `${quote}\n\nIt has one.`, START + 2_000)
    const ctx = context({
      comments: [...context().comments, posted],
      decisions: [{ bot: false, login: 'ravi', state: 'CHANGES_REQUESTED', userId: 'U_ravi' }],
      requested: ['ravi'],
      threads: [thread('PRRT_1', { isResolved: true })],
    })
    const h = harness({
      commit: () => ({ ok: true, sha: FIX }),
      contexts: [ctx],
      push: fix => ({ already: true, merged: false, ok: true, sha: fix }),
    })
    const r = await runPosts(
      h.deps,
      KEY,
      outbox([
        { ...COMMIT, state: 'sending' },
        { ...PUSH, state: 'sending' },
        prComment('IC_1', quote, 'It has one.', { state: 'sending' }),
        { ...REREQUEST, logins: ['ravi'], state: 'sending' },
      ] as Post[]),
      {},
      NONE,
    )
    expect(h.writes).toEqual([])
    expect(h.log.filter(step => step !== 'context')).toEqual(['commit', 'push ccccccc'])
    expect(r).toMatchObject({ ok: true, rerequested: { ravi: HEAD } })
    expect(postOf(r, 'commit')).toMatchObject({ sha: FIX, state: 'done' })
    expect(postOf(r, 'push')).toMatchObject({ sha: FIX, state: 'done' })
    expect(postOf(r, 'comment:IC_1')).toMatchObject({ commentId: 'IC_mine', state: 'done' })
  })

  it(
    'refuses a closed PR, a PR of another author, a fork and a pending review of the user ' +
      'before any write',
    async () => {
      const cases: [Partial<RequestContext>, string][] = [
        [{ state: 'CLOSED' }, REASON_FIX_PR_CLOSED],
        [{ state: 'MERGED' }, REASON_FIX_PR_CLOSED],
        [{ author: 'mia' }, REASON_NOT_YOURS],
        [{ isCrossRepository: true }, REASON_FORK],
        [{ viewerPending: true }, REASON_OWN_PENDING],
      ]
      for (const [over, message] of cases) {
        const h = harness({ contexts: [context(over)] })
        const start = outbox([COMMIT, PUSH, reply('PRRT_1', null), resolve('PRRT_1'), REREQUEST])
        const r = await runPosts(h.deps, KEY, start, {}, NONE)
        expect(r).toEqual({
          conflict: false,
          dropOutbox: false,
          message,
          ok: false,
          outbox: start,
          wrote: false,
        })
        expect(h.log).toEqual(['context'])
        expect(h.saves).toEqual([])
      }
    },
  )

  it('takes the author in another case as the user, and no viewer login as nobody', async () => {
    const h = harness({ contexts: [context({ author: 'DANA' })] })
    const r = await runPosts(h.deps, KEY, outbox([reply('PRRT_1', 'Kept.')]), {}, NONE)
    expect(r.ok).toBe(true)
    expect(h.writes.map(w => w.op)).toEqual(['ReplyToThread'])
    // With no viewer login, no PR is the user's.
    const none = harness({ contexts: [context({ author: '' })] })
    none.deps.viewer = ''
    const refused = await runPosts(none.deps, KEY, outbox([reply('PRRT_1', 'Kept.')]), {}, NONE)
    expect(refused).toMatchObject({ message: REASON_NOT_YOURS, ok: false })
    expect(none.writes).toEqual([])
  })

  it('a reply that goes into a pending review stops the run and resolves nothing', async () => {
    const h = harness({
      answer: w =>
        w.op === 'ReplyToThread'
          ? answer({
              addPullRequestReviewThreadReply: {
                comment: {
                  createdAt: new Date(START).toISOString(),
                  id: 'PRRC_p',
                  state: 'PENDING',
                },
              },
            })
          : undefined,
    })
    const r = await runPosts(
      h.deps,
      KEY,
      outbox([reply('PRRT_1', 'Kept.'), resolve('PRRT_1'), reply('PRRT_2', 'Also.'), REREQUEST]),
      {},
      NONE,
    )
    expect(r).toMatchObject({ conflict: false, message: REASON_REPLY_PENDING, ok: false })
    expect(h.writes.map(w => w.op)).toEqual(['ReplyToThread'])
    // The next run checks GitHub for the reply after the user submits or deletes the draft.
    expect(stateOf(r)).toEqual({
      'reply:PRRT_1': 'sending',
      'reply:PRRT_2': 'todo',
      rerequest: 'todo',
      'resolve:PRRT_1': 'todo',
    })
  })

  it('a trusted comment that came during the round drops the resolve of its thread', async () => {
    const later = START + 1_000
    const t1 = thread('PRRT_1')
    const t2 = thread('PRRT_2')
    t1.comments.push(comment('PRRC_mia', 'mia', 'Wait, also the other one.', later))
    // A bot, an author who is not trusted and the user do not stop the resolve.
    t2.comments.push(
      comment('PRRC_bot', 'ci-bot', 'Coverage went down.', later, { bot: true }),
      comment('PRRC_x', 'stranger', 'Me too.', later, { association: 'CONTRIBUTOR' }),
      comment('PRRC_me', 'Dana', 'Looking.', later),
    )
    const h = harness({ contexts: [context({ threads: [t1, t2] })] })
    const r = await runPosts(
      h.deps,
      KEY,
      outbox([
        reply('PRRT_1', 'Kept.'),
        resolve('PRRT_1'),
        reply('PRRT_2', 'Also.'),
        resolve('PRRT_2'),
      ]),
      {},
      NONE,
    )
    expect(r.ok).toBe(true)
    expect(h.writes).toEqual([
      { op: 'ReplyToThread', vars: { body: 'Kept.', thread: 'PRRT_1' } },
      { op: 'ReplyToThread', vars: { body: 'Also.', thread: 'PRRT_2' } },
      { op: 'ResolveThread', vars: { thread: 'PRRT_2' } },
    ])
    expect(stateOf(r)['resolve:PRRT_1']).toBe('dropped')
  })

  it.each([
    ['conflict', REASON_PUSH_CONFLICT],
    ['moved', REASON_PUSH_MOVED],
  ] as const)(
    'a push %s drops the fixed posts, sends the other posts and reports the conflict',
    async (reason, message) => {
      const h = harness({ push: () => ({ message, ok: false, reason }) })
      const r = await runPosts(
        h.deps,
        KEY,
        outbox([
          COMMIT,
          PUSH,
          reply('PRRT_1', null),
          resolve('PRRT_1'),
          prComment('IC_1', '> q', null),
          reply('PRRT_2', 'Kept.'),
          resolve('PRRT_2'),
          prComment('PRR_9', '> Split this PR.', null, { by: BY }),
          REREQUEST,
        ]),
        {},
        NONE,
      )
      expect(r).toMatchObject({ conflict: true, message, ok: false })
      expect(stateOf(r)).toEqual({
        'comment:IC_1': 'dropped',
        'comment:PRR_9': 'done',
        commit: 'dropped',
        push: 'dropped',
        'reply:PRRT_1': 'dropped',
        'reply:PRRT_2': 'done',
        rerequest: 'done',
        'resolve:PRRT_1': 'dropped',
        'resolve:PRRT_2': 'done',
      })
      expect(h.writes).toEqual([
        { op: 'ReplyToThread', vars: { body: 'Kept.', thread: 'PRRT_2' } },
        { op: 'ResolveThread', vars: { thread: 'PRRT_2' } },
        {
          op: 'CommentOnPr',
          vars: { body: '> Split this PR.\n\nFixed by eeeeeee', subject: 'PR_1' },
        },
      ])
    },
  )

  it('a conflict that a failed write cut off is a conflict at the end of Try again', async () => {
    const h = harness({
      answer: w =>
        w.op === 'ResolveThread' ? { code: 1, stderr: '', stdout: '', timedOut: true } : undefined,
      push: () => ({ message: REASON_PUSH_CONFLICT, ok: false, reason: 'conflict' }),
    })
    const posts = [COMMIT, PUSH, reply('PRRT_1', null), reply('PRRT_2', 'Kept.'), resolve('PRRT_2')]
    const first = await runPosts(h.deps, KEY, outbox(posts), {}, NONE)
    // The outbox must stay for Try again, so this is not the conflict outcome.
    expect(first).toMatchObject({
      conflict: false,
      message: reasonPostsStopped(1, 2, REASON_WRITE_TIMEOUT),
      ok: false,
    })
    const again = await runPosts(harness().deps, KEY, first.outbox, {}, NONE)
    expect(again).toMatchObject({ conflict: true, message: REASON_PUSH_CONFLICT, ok: false })
    expect(stateOf(again)['resolve:PRRT_2']).toBe('done')
  })

  it.each([
    ['a failed commit', { commit: () => ({ message: reasonCommitFailed('x.'), ok: false }) }],
    [
      'a refused push',
      { push: (): PushOutcome => ({ message: REASON_PUSH_TARGET, ok: false, reason: 'refused' }) },
    ],
  ] as [string, Parameters<typeof harness>[0]][])(
    '%s stops the run with its own text and posts nothing',
    async (_name, over) => {
      const h = harness(over)
      const r = await runPosts(
        h.deps,
        KEY,
        outbox([COMMIT, PUSH, reply('PRRT_1', null), reply('PRRT_2', 'Kept.'), REREQUEST]),
        {},
        NONE,
      )
      const expected = over?.commit ? reasonCommitFailed('x.') : REASON_PUSH_TARGET
      expect(r).toMatchObject({ conflict: false, message: expected, ok: false, wrote: false })
      expect(h.writes).toEqual([])
    },
  )

  it('a deleted thread counts as done with no write', async () => {
    const h = harness({ contexts: [context({ comments: [], reviews: [], threads: [] })] })
    const r = await runPosts(
      h.deps,
      KEY,
      outbox([
        reply('PRRT_1', 'Kept.'),
        resolve('PRRT_1'),
        prComment('IC_1', '> q', 'Thanks.'),
        prComment('PRR_9', '> q', 'Done.', { state: 'sending' }),
      ]),
      {},
      NONE,
    )
    expect(h.writes).toEqual([])
    expect(r).toMatchObject({ ok: true, posted: [] })
    expect(new Set(Object.values(stateOf(r)))).toEqual(new Set(['done']))
  })

  it(
    're-requests a reviewer only when all their threads are resolved, never Copilot, and one ' +
      'time for each head',
    async () => {
      const copilot = 'copilot-pull-request-reviewer'
      const by = (id: string, login: string, isResolved: boolean, bot = false): RequestThread =>
        thread(id, {
          comments: [comment(`${id}_c1`, login, 'Change this.', ASKED, { bot })],
          isResolved,
        })
      const ctx = context({
        decisions: [
          // All threads resolved: asked.
          { bot: false, login: 'ravi', state: 'CHANGES_REQUESTED', userId: 'U_ravi' },
          // An open thread: not asked.
          { bot: false, login: 'mia', state: 'CHANGES_REQUESTED', userId: 'U_mia' },
          // Copilot: never.
          { bot: true, login: copilot, state: 'CHANGES_REQUESTED', userId: 'BOT_1' },
          // No change request: not asked.
          { bot: false, login: 'lee', state: 'APPROVED', userId: 'U_lee' },
          // Asked already, in another case: not asked.
          { bot: false, login: 'sam', state: 'CHANGES_REQUESTED', userId: 'U_sam' },
          // No user ID: not asked.
          { bot: false, login: 'kim', state: 'CHANGES_REQUESTED', userId: null },
          // Asked for this head already: not asked.
          { bot: false, login: 'jo', state: 'CHANGES_REQUESTED', userId: 'U_jo' },
          // The viewer: never.
          { bot: false, login: 'Dana', state: 'CHANGES_REQUESTED', userId: 'U_dana' },
        ],
        headSha: NEW_HEAD,
        requested: ['SAM'],
        threads: [
          by('PRRT_1', 'ravi', true),
          by('PRRT_2', 'Ravi', true),
          by('PRRT_5', 'mia', true),
          by('PRRT_6', 'mia', false),
          by('PRRT_7', copilot, true, true),
        ],
      })
      const h = harness({ contexts: [ctx] })
      const r = await runPosts(h.deps, KEY, outbox([REREQUEST]), { jo: NEW_HEAD, ravi: HEAD }, NONE)
      expect(h.writes).toEqual([{ op: 'RequestReviewer', vars: { pr: 'PR_1', user: 'U_ravi' } }])
      // The rerequest post reads the context again.
      expect(h.log.filter(step => step === 'context')).toHaveLength(2)
      expect(r).toMatchObject({ ok: true, rerequested: { jo: NEW_HEAD, ravi: NEW_HEAD } })
      if (!r.ok) throw new Error(r.message)

      // One time for each head.
      const again = harness({ contexts: [ctx] })
      await runPosts(again.deps, KEY, outbox([REREQUEST]), r.rerequested, NONE)
      expect(again.writes).toEqual([])
    },
  )

  it('waits POST_GAP_MS between two writes', async () => {
    const h = harness()
    await runPosts(
      h.deps,
      KEY,
      outbox([
        COMMIT,
        PUSH,
        reply('PRRT_1', null),
        resolve('PRRT_1'),
        prComment('IC_1', '> q', 'Ok.'),
      ]),
      {},
      NONE,
    )
    expect(h.log).toEqual([
      'context',
      'commit',
      'push ccccccc',
      `sleep ${POST_GAP_MS}`,
      'write ReplyToThread',
      `sleep ${POST_GAP_MS}`,
      'write ResolveThread',
      `sleep ${POST_GAP_MS}`,
      'write CommentOnPr',
    ])
    expect(POST_GAP_MS).toBe(1_000)
  })

  it('a fixed reply names the fix commit, or the by commit', async () => {
    const quote = `> Please add a test, @${Z}mia.`
    const h = harness({ push: () => ({ already: false, merged: true, ok: true, sha: MERGE }) })
    const r = await runPosts(
      h.deps,
      KEY,
      outbox([
        COMMIT,
        PUSH,
        reply('PRRT_1', null),
        reply('PRRT_2', null, { by: BY }),
        prComment('IC_1', quote, null),
      ]),
      {},
      NONE,
    )
    // The fix commit, not the merge commit of the push.
    expect(h.writes.map(w => w.vars.body)).toEqual([
      'Fixed by ccccccc',
      'Fixed by eeeeeee',
      `${quote}\n\nFixed by ccccccc`,
    ])
    expect(postOf(r, 'push')).toMatchObject({ sha: MERGE, state: 'done' })
    expect(postOf(r, 'commit')).toMatchObject({ sha: FIX, state: 'done' })
    expect(r).toMatchObject({
      ok: true,
      posted: [
        { body: 'Fixed by ccccccc', id: 'PRRC_new1', prKey: KEY },
        { body: 'Fixed by eeeeeee', id: 'PRRC_new2', prKey: KEY },
        { body: `${quote}\n\nFixed by ccccccc`, id: 'IC_new3', prKey: KEY },
      ],
    })
  })

  it('a signed push gets its saved method, and the reply names the GitHub commit', async () => {
    const quote = `> Please add a test, @${Z}mia.`
    const h = harness({ push: () => ({ already: false, merged: false, ok: true, sha: MERGE }) })
    const r = await runPosts(
      h.deps,
      KEY,
      outbox([
        COMMIT,
        { ...PUSH, signed: true },
        reply('PRRT_1', null),
        reply('PRRT_2', null, { by: BY }),
        prComment('IC_1', quote, null),
      ]),
      {},
      NONE,
    )
    expect(h.log).toContain('push ccccccc signed')
    // The commit of GitHub, not the local fix commit. A by commit stays as it is.
    expect(h.writes.map(w => w.vars.body)).toEqual([
      'Fixed by ddddddd',
      'Fixed by eeeeeee',
      `${quote}\n\nFixed by ddddddd`,
    ])
    expect(postOf(r, 'push')).toMatchObject({ sha: MERGE, signed: true, state: 'done' })
    expect(r).toMatchObject({
      ok: true,
      posted: [
        { body: 'Fixed by ddddddd', id: 'PRRC_new1', prKey: KEY },
        { body: 'Fixed by eeeeeee', id: 'PRRC_new2', prKey: KEY },
        { body: `${quote}\n\nFixed by ddddddd`, id: 'IC_new3', prKey: KEY },
      ],
    })
    // A push with no saved method uses git.
    const g = harness()
    await runPosts(g.deps, KEY, outbox([COMMIT, PUSH, reply('PRRT_1', null)]), {}, NONE)
    expect(g.log).toContain('push ccccccc')
    expect(g.log).not.toContain('push ccccccc signed')
  })

  it('a signed push that was refused before any write drops the outbox (ruling P4)', async () => {
    const h = harness({
      push: () => ({ message: REASON_SIGNED_EXECUTABLE, ok: false, reason: 'not-landed' }),
    })
    const r = await runPosts(
      h.deps,
      KEY,
      outbox([COMMIT, { ...PUSH, signed: true }, reply('PRRT_1', null), resolve('PRRT_1')]),
      {},
      NONE,
    )
    expect(r).toMatchObject({
      dropOutbox: true,
      message: REASON_SIGNED_EXECUTABLE,
      ok: false,
      wrote: false,
    })
    expect(h.writes).toEqual([])
  })

  it('each text goes through defuseMentions one time', async () => {
    const quote = `> Ask @${Z}mia.`
    const h = harness()
    await runPosts(
      h.deps,
      KEY,
      outbox([reply('PRRT_1', 'Thanks @ravi!'), prComment('IC_1', quote, 'cc @lee')]),
      {},
      NONE,
    )
    expect(h.writes.map(w => w.vars.body)).toEqual([`Thanks @${Z}ravi!`, `${quote}\n\ncc @${Z}lee`])
  })

  it('a failed save stops the run before the next write', async () => {
    // Save 1 is the sending reply, save 2 the done reply, save 3 the sending resolve.
    const h = harness({ saveFails: n => n === 3 })
    await expect(
      runPosts(h.deps, KEY, outbox([reply('PRRT_1', 'Kept.'), resolve('PRRT_1')]), {}, NONE),
    ).rejects.toThrow('disk full')
    expect(h.writes.map(w => w.op)).toEqual(['ReplyToThread'])
    expect(h.saves.map(box => box.posts.map(post => post.state))).toEqual([
      ['sending', 'todo'],
      ['done', 'todo'],
      ['done', 'sending'],
    ])
  })

  it('never re-requests a reviewer with an open item, also with only a review body', async () => {
    const asked = (login: string) => ({
      bot: false,
      login,
      state: 'CHANGES_REQUESTED' as const,
      userId: `U_${login}`,
    })
    // ravi has only resolved threads. lee and kim have only a review body.
    const ctx = context({
      decisions: [asked('ravi'), asked('lee'), asked('kim')],
      threads: [thread('PRRT_1', { isResolved: true })],
    })
    const h = harness({ contexts: [ctx] })
    // Task 7 gives the logins with an open item: here a held item of ravi and a question of lee.
    const r = await runPosts(h.deps, KEY, outbox([REREQUEST]), {}, new Set(['RAVI', 'lee']))
    expect(h.writes).toEqual([{ op: 'RequestReviewer', vars: { pr: 'PR_1', user: 'U_kim' } }])
    expect(r).toMatchObject({ ok: true, rerequested: { kim: HEAD } })
  })

  it('never re-requests a reviewer whose item the push conflict dropped', async () => {
    // mia asked for a test in a PR comment. The fix did not go, so her request is open.
    const ctx = context({
      comments: [comment('IC_7', 'mia', 'Add a test.', ASKED)],
      decisions: [{ bot: false, login: 'mia', state: 'CHANGES_REQUESTED', userId: 'U_mia' }],
      threads: [],
    })
    const h = harness({
      contexts: [ctx],
      push: () => ({ message: REASON_PUSH_CONFLICT, ok: false, reason: 'conflict' }),
    })
    const posts = [COMMIT, PUSH, prComment('IC_7', '> Add a test.', null), REREQUEST]
    const r = await runPosts(h.deps, KEY, outbox(posts), {}, NONE)
    expect(r).toMatchObject({ conflict: true, ok: false })
    expect(h.writes).toEqual([])
  })

  it('a context with cut lists stops before any write and keeps the outbox', async () => {
    expect(REASON_TOO_MANY_COMMENTS).toBe(
      'This pull request has too many comments for Bifrost to check, so nothing was posted. ' +
        'Reply to them on GitHub.',
    )
    // The cut context shows no thread and no comment. No post may count as gone.
    const start = outbox([
      reply('PRRT_1', 'Kept.', { state: 'sending' }),
      resolve('PRRT_1'),
      prComment('IC_1', '> q', 'Thanks.'),
      REREQUEST,
    ])
    const h = harness({ contexts: [context({ comments: [], threads: [], truncated: true })] })
    const r = await runPosts(h.deps, KEY, start, {}, NONE)
    expect(r).toEqual({
      conflict: false,
      dropOutbox: false,
      message: REASON_TOO_MANY_COMMENTS,
      ok: false,
      outbox: start,
      wrote: true,
    })
    expect(h.log).toEqual(['context'])
    expect(h.saves).toEqual([])

    // A re-request with a cut context asks nobody.
    const ravi = { bot: false, login: 'ravi', state: 'CHANGES_REQUESTED' as const, userId: 'U_r' }
    const ctx = context({ decisions: [ravi], threads: [] })
    const later = harness({ contexts: [ctx, { ...ctx, truncated: true }] })
    const done = await runPosts(later.deps, KEY, outbox([REREQUEST]), {}, NONE)
    expect(later.writes).toEqual([])
    expect(done).toMatchObject({ ok: true, rerequested: {} })
    expect(stateOf(done)).toEqual({ rerequest: 'dropped' })
  })

  it('stops with no write when the fresh context is another pull request', async () => {
    const others: Partial<RequestContext>[] = [{ owner: 'other' }, { repo: 'web' }, { number: 10 }]
    for (const over of others) {
      const h = harness({ contexts: [context(over)] })
      const r = await runPosts(h.deps, KEY, outbox([reply('PRRT_1', 'Kept.')]), {}, NONE)
      expect(r).toMatchObject({ message: REASON_BAD_PR, ok: false, wrote: false })
      expect(h.writes).toEqual([])
    }
    // The key in another case is the same pull request.
    const same = harness({ contexts: [context({ owner: 'ACME' })] })
    const ok = await runPosts(same.deps, KEY, outbox([reply('PRRT_1', 'Kept.')]), {}, NONE)
    expect(ok.ok).toBe(true)
    // The read of the re-request must give the same pull request too.
    const ravi = { bot: false, login: 'ravi', state: 'CHANGES_REQUESTED' as const, userId: 'U_r' }
    const two = harness({
      contexts: [context(), context({ decisions: [ravi], number: 10, threads: [] })],
    })
    const r = await runPosts(two.deps, KEY, outbox([REREQUEST]), {}, NONE)
    expect(r).toMatchObject({ message: REASON_BAD_PR, ok: false })
    expect(two.writes).toEqual([])
  })

  it('wrote tells if a write of the outbox reached GitHub or can have reached it', async () => {
    const run = (o: Parameters<typeof harness>[0], posts: Post[]): Promise<PostsOutcome> =>
      runPosts(harness(o).deps, KEY, outbox(posts), {}, NONE)
    const fix = [COMMIT, PUSH, reply('PRRT_1', null)]
    const refused = (message: string) => (): PushOutcome => ({
      message,
      ok: false,
      reason: 'refused',
    })
    // Nothing went to GitHub.
    expect(await run({ commit: () => ({ message: 'x', ok: false }) }, fix)).toMatchObject({
      ok: false,
      wrote: false,
    })
    expect(await run({ push: refused(REASON_PUSH_TARGET) }, fix)).toMatchObject({
      ok: false,
      wrote: false,
    })
    const conflict = (): PushOutcome => ({ message: 'c', ok: false, reason: 'conflict' })
    expect(await run({ push: conflict }, fix)).toMatchObject({ conflict: true, wrote: false })
    // The push or a write with no answer can have reached GitHub.
    expect(await run({ push: refused(reasonPushFailed('x')) }, fix)).toMatchObject({
      ok: false,
      wrote: true,
    })
    const timedOut = (): ExecResult => ({ code: 1, stderr: '', stdout: '', timedOut: true })
    expect(await run({ answer: timedOut }, [reply('PRRT_1', 'Kept.')])).toMatchObject({
      ok: false,
      wrote: true,
    })
    // An earlier run sent a post.
    const closed = { contexts: [context({ state: 'CLOSED' })] }
    const sent = [reply('PRRT_1', 'Kept.', { state: 'done' }), resolve('PRRT_1')]
    expect(await run(closed, sent)).toMatchObject({ ok: false, wrote: true })
    expect(await run({ push: conflict }, [...fix, reply('PRRT_2', 'Kept.')])).toMatchObject({
      conflict: true,
      wrote: true,
    })
  })

  it('a failed read of the pull request stops the run with a clear reason', async () => {
    const h = harness()
    h.deps.context = async () => ({ message: REASON_GH_TIMEOUT, ok: false })
    const r = await runPosts(h.deps, KEY, outbox([reply('PRRT_1', 'Kept.')]), {}, NONE)
    expect(r).toMatchObject({
      message: reasonPostsStopped(0, 1, REASON_WRITE_TIMEOUT),
      ok: false,
      wrote: false,
    })
  })

  it('a failed read with an error text sends the text to the Event log only', async () => {
    const h = harness()
    const detail = 'GraphQL: Something went wrong while executing your query.'
    h.deps.context = async () => ({ detail, message: REASON_PR_READ_FAILED, ok: false })
    const r = await runPosts(h.deps, KEY, outbox([reply('PRRT_1', 'Kept.')]), {}, NONE)
    // The text of the row is true also when an earlier run posted updates.
    expect(r).toMatchObject({
      message: reasonPostsStopped(0, 1, REASON_POSTS_READ_FAILED),
      ok: false,
    })
    expect(REASON_POSTS_READ_FAILED).not.toMatch(/nothing was posted/)
    expect(h.details).toEqual([detail])
  })

  it('a failed read in the middle of the outbox sends its text to the Event log', async () => {
    const h = harness()
    const first = h.deps.context
    let reads = 0
    h.deps.context = async () =>
      reads++ === 0 ? first() : { detail: 'HTTP 502', message: REASON_PR_READ_FAILED, ok: false }
    const posts = [reply('PRRT_1', 'Kept.'), REREQUEST]
    const r = await runPosts(h.deps, KEY, outbox(posts), {}, NONE)
    expect(r).toMatchObject({
      message: reasonPostsStopped(1, 2, REASON_POSTS_READ_FAILED),
      ok: false,
      wrote: true,
    })
    expect(h.details).toEqual(['HTTP 502'])
  })

  it('a write with an error text shows a fixed text and logs the error text', async () => {
    const line = 'gh: Resource not accessible by integration (HTTP 403)'
    const h = harness({
      answer: w => (w.op === 'ReplyToThread' ? { code: 1, stderr: line, stdout: '' } : undefined),
    })
    const r = await runPosts(h.deps, KEY, outbox([reply('PRRT_1', 'Kept.')]), {}, NONE)
    expect(r).toMatchObject({ message: reasonPostsStopped(0, 1, REASON_WRITE_FAILED), ok: false })
    expect(h.details).toEqual([line])
  })

  it('a signed push with an error text sends the text to the Event log', async () => {
    const message = reasonPushFailed(REASON_WRITE_FAILED)
    const h = harness({
      push: () => ({
        detail: 'Repository rule violations found',
        message,
        ok: false,
        reason: 'not-landed',
      }),
    })
    const r = await runPosts(h.deps, KEY, outbox([COMMIT, PUSH, reply('PRRT_1', null)]), {}, NONE)
    expect(r).toMatchObject({ message, ok: false })
    expect(h.details).toEqual(['Repository rule violations found'])
  })

  it('dropOutbox is true only for a step that fails again in each run', async () => {
    const run = (o: Parameters<typeof harness>[0], posts: Post[]): Promise<PostsOutcome> =>
      runPosts(harness(o).deps, KEY, outbox(posts), {}, NONE)
    const fix = [COMMIT, PUSH, reply('PRRT_1', null), REREQUEST]
    const refused =
      (message: string, reason: 'refused' | 'not-landed' = 'refused') =>
      () =>
        ({ message, ok: false, reason }) as PushOutcome
    const failed = reasonPushFailed('remote: GH013: Repository rule violations found')
    // These steps fail again in each run, and nothing went to GitHub.
    for (const o of [
      { commit: () => ({ message: reasonCommitFailed('x.'), ok: false as const }) },
      { push: refused(REASON_PUSH_TARGET) },
      { push: refused(failed, 'not-landed') },
      { contexts: [context({ truncated: true })] },
    ]) {
      expect(await run(o, fix)).toMatchObject({ dropOutbox: true, ok: false, wrote: false })
    }
    // A push of an earlier run that a quit cut off did not land either.
    const cutOff = [COMMIT, { ...PUSH, state: 'sending' as const }, reply('PRRT_1', null)]
    const done = { ...COMMIT, sha: FIX, state: 'done' as const }
    expect(
      await run({ push: refused(failed, 'not-landed') }, [done, ...cutOff.slice(1)]),
    ).toMatchObject({ dropOutbox: true, message: failed, wrote: false })
    // A push that can have reached GitHub keeps the outbox.
    expect(await run({ push: refused(failed) }, fix)).toMatchObject({
      dropOutbox: false,
      wrote: true,
    })
    // A cut-off commit with a failed read: the read stopped the run, not the commit.
    const later = harness()
    later.deps.context = async () => ({ message: REASON_GH_TIMEOUT, ok: false })
    const sending = [{ ...COMMIT, state: 'sending' as const }, PUSH, reply('PRRT_1', null)]
    const r = await runPosts(later.deps, KEY, outbox(sending), {}, NONE)
    expect(r).toMatchObject({ dropOutbox: false, ok: false, wrote: false })
    expect(later.log).toEqual([])
    // A cut context after a write keeps the outbox.
    const sent = [reply('PRRT_1', 'Kept.', { state: 'done' }), resolve('PRRT_1')]
    expect(await run({ contexts: [context({ truncated: true })] }, sent)).toMatchObject({
      dropOutbox: false,
      message: REASON_TOO_MANY_COMMENTS,
      wrote: true,
    })
  })

  it('a stop of the user ends the run before the next write', async () => {
    const h = harness({ stopped: n => n >= 1 })
    const posts = [reply('PRRT_1', 'Kept.'), resolve('PRRT_1'), reply('PRRT_2', 'Kept.')]
    const r = await runPosts(h.deps, KEY, outbox(posts), {}, NONE)
    expect(h.writes.map(w => w.op)).toEqual(['ReplyToThread'])
    expect(r).toMatchObject({
      dropOutbox: false,
      message: reasonUserStoppedPosts(1, 3),
      ok: false,
      wrote: true,
    })
    expect(stateOf(r)).toEqual({
      'reply:PRRT_1': 'done',
      'reply:PRRT_2': 'todo',
      'resolve:PRRT_1': 'todo',
    })
    expect(reasonUserStoppedPosts(1, 3)).toBe(
      'You stopped Bifrost after 1 of 3 updates. Choose Try again to send the rest.',
    )
    // A stop before the first write stops before the push too.
    const early = harness({ stopped: () => true })
    const fix = await runPosts(
      early.deps,
      KEY,
      outbox([COMMIT, PUSH, reply('PRRT_1', null)]),
      {},
      NONE,
    )
    expect(early.log).toEqual(['context', 'commit'])
    expect(fix).toMatchObject({ dropOutbox: false, message: reasonUserStoppedPosts(0, 2) })
  })
})
