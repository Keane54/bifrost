import { describe, expect, it } from 'vitest'
import {
  EMPTY_STATE,
  emptyPrState,
  handledEntry,
  MAX_ANSWER,
  MAX_AUTHOR,
  MAX_DRAFTS,
  MAX_HELD,
  MAX_POSTED,
  MAX_QUESTION,
  MAX_QUEUE,
  MAX_QUOTE,
  MAX_VOICE_PAIRS,
  MAX_WHERE,
  type Outbox,
  parseState,
  type ReviewsState,
} from '../../../src/main/reviews/state'
import { ITEM_ID } from '../../../src/shared/reviews'

const KEY = 'acme/app#12'

function valid(): ReviewsState {
  return {
    autoFixConsent: null,
    baseline: ['PR_node1'],
    drafts: [{ at: 3, body: 'b', line: 4, path: 'a.ts', prKey: KEY, reviewId: 'r1' }],
    fixFrom: null,
    pauses: { [KEY]: 99 },
    posted: [{ at: 1, body: 'x', id: 'c1', prKey: KEY }],
    prs: { [KEY]: { ...emptyPrState(), handleCopilot: true } },
    queue: [],
    repos: {},
    requests: { [KEY]: { baseline: true, firstSeen: 5 } },
    setUpAt: null,
    turnedOnAt: 10,
    version: 1,
    voicePairs: [{ at: 2, draft: 'd', final: 'f', prKey: KEY }],
  }
}

describe('parseState', () => {
  it('keeps a valid queue, round, mark, actedAt and setUpAt', () => {
    const state = valid()
    state.queue = [
      { at: 1, key: KEY, kind: 'review' },
      { at: 2, key: 'acme/app#13', kind: 'review' },
    ]
    state.repos = { 'acme/app': { trustNotifiedAt: 7 } }
    state.setUpAt = 50
    state.prs[KEY] = {
      ...emptyPrState(),
      actedAt: 9,
      recommendation: { at: 8, headSha: 'abc', reviewId: 'r1', value: 'comment', why: 'w' },
      review: { name: 'n', sessionId: 's', shortId: 'abcd1234' },
      round: {
        at: 1,
        headSha: 'abc',
        phase: 'running',
        sessionId: 's',
        shortId: 'abcd1234',
        startedAt: 2,
        stoppedByUser: false,
      },
    }
    expect(parseState(JSON.parse(JSON.stringify(state)))).toEqual(state)
  })

  it('keeps a boolean autoFixConsent, and reads null for a missing or a bad value', () => {
    for (const value of [true, false]) {
      expect(parseState({ ...valid(), autoFixConsent: value }).autoFixConsent).toBe(value)
    }
    for (const value of [undefined, 'no', 0, null]) {
      expect(parseState({ ...valid(), autoFixConsent: value }).autoFixConsent).toBeNull()
    }
    expect(EMPTY_STATE.autoFixConsent).toBeNull()
  })

  it('drops a queue entry with a bad key and a second entry for one key', () => {
    const state = parseState({
      ...valid(),
      queue: [
        { at: 3, key: KEY, kind: 'review' },
        { at: 1, key: 'bad key', kind: 'review' },
        { at: 2, key: KEY, kind: 'review' },
        { at: 4, key: 'acme/app#2', kind: 'other' },
        { at: 5, key: 'acme/..#2', kind: 'review' },
      ],
    })
    expect(state.queue).toEqual([{ at: 2, key: KEY, kind: 'review' }])
  })

  it('a file from R1 parses with an empty queue, no round and a null setUpAt', () => {
    const old: Record<string, unknown> = JSON.parse(JSON.stringify(valid()))
    delete old.queue
    delete old.repos
    delete old.setUpAt
    const prs = old.prs as Record<string, Record<string, unknown>>
    for (const field of ['round', 'recommendation', 'actedAt']) delete prs[KEY]?.[field]
    const state = parseState(old)
    expect(state.queue).toEqual([])
    expect(state.repos).toEqual({})
    expect(state.setUpAt).toBeNull()
    expect(state.prs[KEY]?.round).toBeNull()
    expect(state.prs[KEY]?.recommendation).toBeNull()
    expect(state.prs[KEY]?.actedAt).toBeNull()
  })

  it('keeps the base commit of a round, and drops a base that is not a commit ID', () => {
    const base = 'b'.repeat(40)
    const round = {
      at: 1,
      baseSha: base,
      headSha: 'a'.repeat(40),
      phase: 'running',
      sessionId: 's',
      shortId: 'abcd1234',
      startedAt: 2,
      stoppedByUser: false,
    }
    const data = JSON.parse(JSON.stringify(valid()))
    data.prs[KEY] = { ...emptyPrState(), round }
    expect(parseState(data).prs[KEY]?.round?.baseSha).toBe(base)
    data.prs[KEY].round.baseSha = 'main'
    expect(parseState(data).prs[KEY]?.round).not.toHaveProperty('baseSha')
    delete data.prs[KEY].round.baseSha
    expect(parseState(data).prs[KEY]?.round).not.toHaveProperty('baseSha')
  })

  it('drops a shortId that is not 8 hex digits', () => {
    const data = valid()
    data.prs[KEY] = {
      ...emptyPrState(),
      request: { name: 'n', sessionId: 's', shortId: 'XYZ' },
      review: { name: 'n', sessionId: 's', shortId: 'abcd1234' },
      round: {
        at: 1,
        headSha: null,
        phase: 'running',
        sessionId: null,
        shortId: 'ABCD1234',
        startedAt: 2,
        stoppedByUser: false,
      },
    }
    const state = parseState(JSON.parse(JSON.stringify(data)))
    expect(state.prs[KEY]?.request).toEqual({ name: 'n', sessionId: 's' })
    expect(state.prs[KEY]?.review?.shortId).toBe('abcd1234')
    expect(state.prs[KEY]?.round?.shortId).toBeNull()
  })

  it(
    'gives the empty value for a bad round phase, mark ' + 'value, repos key, actedAt and setUpAt',
    () => {
      const data = JSON.parse(JSON.stringify(valid()))
      data.prs[KEY] = {
        ...emptyPrState(),
        actedAt: 'x',
        recommendation: { at: 1, headSha: 'a', reviewId: null, value: 'merge', why: 'w' },
        round: {
          at: 1,
          headSha: null,
          phase: 'dancing',
          sessionId: null,
          shortId: null,
          startedAt: 2,
        },
      }
      data.repos = { 'acme/.': { trustNotifiedAt: 1 }, 'acme/app': { trustNotifiedAt: 'x' } }
      data.setUpAt = 'soon'
      const state = parseState(data)
      expect(state.prs[KEY]?.round).toBeNull()
      expect(state.prs[KEY]?.recommendation).toBeNull()
      expect(state.prs[KEY]?.actedAt).toBeNull()
      expect(state.setUpAt).toBeNull()
      expect(state.repos).toEqual({ 'acme/app': { trustNotifiedAt: null } })
    },
  )

  it('caps the queue at MAX_QUEUE and keeps the oldest entries', () => {
    const queue = Array.from({ length: MAX_QUEUE + 5 }, (_, i) => ({
      at: i,
      key: `acme/app#${i + 1}`,
      kind: 'review',
    }))
    const state = parseState({ ...valid(), queue: [...queue].reverse() })
    expect(state.queue).toHaveLength(MAX_QUEUE)
    expect(state.queue[0]?.at).toBe(0)
    expect(state.queue[MAX_QUEUE - 1]?.at).toBe(MAX_QUEUE - 1)
  })

  it('keeps a valid state', () => {
    const state = valid()
    expect(parseState(JSON.parse(JSON.stringify(state)))).toEqual(state)
  })

  it('drops a key that fails PR_KEY', () => {
    const data = valid() as unknown as Record<string, Record<string, unknown>>
    data.requests['bad key'] = { baseline: false, firstSeen: 1 }
    data.pauses['../x#1'] = 5
    data.prs.nope = emptyPrState()
    const state = parseState(data)
    expect(Object.keys(state.requests)).toEqual([KEY])
    expect(Object.keys(state.pauses)).toEqual([KEY])
    expect(Object.keys(state.prs)).toEqual([KEY])
  })

  it('keeps only non-empty strings in baseline', () => {
    const state = parseState({ ...valid(), baseline: ['a', '', 3, null, 'b'] })
    expect(state.baseline).toEqual(['a', 'b'])
  })

  it('gives the empty value for a bad field', () => {
    const state = parseState({ ...valid(), pauses: [], posted: 'x', turnedOnAt: 'soon' })
    expect(state.posted).toEqual([])
    expect(state.turnedOnAt).toBeNull()
    expect(state.pauses).toEqual({})
    expect(state.requests).toEqual(valid().requests)
  })

  it('caps posted, drafts and voice pairs and keeps the newest', () => {
    const posted = Array.from({ length: MAX_POSTED + 5 }, (_, i) => ({
      at: i,
      body: '',
      id: `c${i}`,
      prKey: KEY,
    }))
    const drafts = Array.from({ length: MAX_DRAFTS + 1 }, (_, i) => ({
      at: i,
      body: '',
      line: 1,
      path: 'a',
      prKey: KEY,
      reviewId: 'r',
    }))
    const voicePairs = Array.from({ length: MAX_VOICE_PAIRS + 1 }, (_, i) => ({
      at: i,
      draft: '',
      final: '',
      prKey: KEY,
    }))
    const state = parseState({ ...valid(), drafts, posted: posted.reverse(), voicePairs })
    expect(state.posted).toHaveLength(MAX_POSTED)
    expect(state.posted[0]?.at).toBe(5)
    expect(state.posted.at(-1)?.at).toBe(MAX_POSTED + 4)
    expect(state.drafts).toHaveLength(MAX_DRAFTS)
    expect(state.drafts[0]?.at).toBe(1)
    expect(state.voicePairs).toHaveLength(MAX_VOICE_PAIRS)
    expect(state.voicePairs[0]?.at).toBe(1)
  })

  it('drops list entries with bad fields', () => {
    const state = parseState({ ...valid(), posted: [{ id: 1 }, null, valid().posted[0]] })
    expect(state.posted).toEqual(valid().posted)
  })

  it('skips the keys __proto__, constructor and prototype in handled and rerequested', () => {
    const text = JSON.stringify({
      handled: { constructor: { at: 2 }, prototype: { at: 3 }, t1: { at: 4 } },
      rerequested: { constructor: 'y', prototype: 'z', r1: 'w' },
    })
    // JSON.parse makes an own key __proto__. An object literal does not.
    const entry = JSON.parse(
      text
        .replace('"handled":{', '"handled":{"__proto__":{"at":1,"lastReplyAt":5},')
        .replace('"rerequested":{', '"rerequested":{"__proto__":"x",'),
    )
    expect(Object.keys(entry.handled)).toContain('__proto__')
    const pr = parseState({ ...valid(), prs: { [KEY]: entry } }).prs[KEY]
    expect(Object.keys(pr?.handled ?? {})).toEqual(['t1'])
    expect(Object.getPrototypeOf(pr?.handled)).toBe(Object.prototype)
    expect(Object.keys(pr?.rerequested ?? {})).toEqual(['r1'])
    expect(Object.getPrototypeOf(pr?.rerequested)).toBe(Object.prototype)
  })

  it('gives EMPTY_STATE for another version or a non-object', () => {
    expect(parseState({ version: 2 })).toEqual(EMPTY_STATE)
    expect(parseState(null)).toEqual(EMPTY_STATE)
    expect(parseState([])).toEqual(EMPTY_STATE)
  })
})

const SHA = 'a'.repeat(40)
const MERGE_BASE = 'c'.repeat(40)

function outbox(): Outbox {
  return {
    headSha: SHA,
    mergeBase: MERGE_BASE,
    posts: [
      {
        id: 'commit',
        kind: 'commit',
        message: 'fix: check the limit',
        paths: ['src/a.ts'],
        sha: 'd'.repeat(40),
        state: 'done',
      },
      { id: 'push', kind: 'push', sha: 'd'.repeat(40), state: 'done' },
      {
        by: 'e'.repeat(40),
        commentId: 'PRRC_9',
        id: 'reply:PRRT_1',
        itemId: 'PRRT_1',
        kind: 'reply',
        state: 'done',
        text: null,
      },
      { id: 'resolve:PRRT_1', itemId: 'PRRT_1', kind: 'resolve', state: 'sending' },
      {
        id: 'comment:IC_1',
        itemId: 'IC_1',
        kind: 'comment',
        quote: '> Please fix',
        state: 'todo',
        text: 'Done.',
      },
      { id: 'rerequest', kind: 'rerequest', logins: ['alice'], state: 'dropped' },
    ],
    seen: { IC_1: 40, PRRT_1: 30 },
    startedAt: 20,
  }
}

describe('parseState R3', () => {
  it('keeps a request entry and round, an outbox, questions, held and checkedAt', () => {
    const state = valid()
    state.fixFrom = 15
    state.queue = [
      { at: 1, key: KEY, kind: 'request' },
      { at: 2, key: KEY, kind: 'review' },
    ]
    state.prs[KEY] = {
      ...emptyPrState(),
      checkedAt: 77,
      held: ['PRRT_2', 'IC_3'],
      outbox: outbox(),
      questions: {
        PRRT_4: {
          answer: null,
          at: 5,
          question: 'Which limit?',
          seenUntil: 4,
          where: 'src/a.ts line 3',
        },
        PRRT_5: {
          answer: 'Use 10.',
          at: 6,
          question: 'How many?',
          seenUntil: 5,
          where: 'Comment from alice',
        },
      },
      round: {
        at: 1,
        baseSha: MERGE_BASE,
        fixSha: 'f'.repeat(40),
        headSha: SHA,
        items: { IC_1: 40, PRRT_1: 30 },
        kind: 'request',
        phase: 'posting',
        sessionId: 's',
        shortId: 'abcd1234',
        startedAt: 2,
        stoppedByUser: false,
      },
    }
    expect(parseState(JSON.parse(JSON.stringify(state)))).toEqual(state)
  })

  it('an R2 file parses with no outbox, questions or held, and null checkedAt and fixFrom', () => {
    const old: Record<string, unknown> = JSON.parse(JSON.stringify(valid()))
    delete old.fixFrom
    const prs = old.prs as Record<string, Record<string, unknown>>
    for (const field of ['outbox', 'questions', 'held', 'checkedAt']) delete prs[KEY]?.[field]
    prs[KEY] = {
      ...prs[KEY],
      round: {
        at: 1,
        headSha: SHA,
        phase: 'running',
        sessionId: 's',
        shortId: null,
        startedAt: 2,
        stoppedByUser: false,
      },
    }
    const state = parseState(old)
    expect(state.fixFrom).toBeNull()
    const pr = state.prs[KEY]
    expect(pr?.outbox).toBeNull()
    expect(pr?.questions).toEqual({})
    expect(pr?.held).toEqual([])
    expect(pr?.checkedAt).toBeNull()
    // A round with no kind is a review round.
    expect(pr?.round).not.toHaveProperty('kind')
    expect(pr?.round).not.toHaveProperty('items')
    expect(pr?.round).not.toHaveProperty('fixSha')
  })

  it('drops an outbox with a bad post', () => {
    const bad: unknown[] = [
      { id: 'push', kind: 'push', state: 'waiting' },
      { id: 'push', kind: 'pull', state: 'todo' },
      { id: 'push', kind: 'push', sha: 'main', state: 'todo' },
      { id: 'push', kind: 'push', signed: 'yes', state: 'todo' },
      { id: 'push', kind: 'push', signed: 1, state: 'todo' },
      { id: 'reply:x', itemId: 'bad id', kind: 'reply', state: 'todo', text: null },
      { id: 'reply:x', itemId: 'PRRT_1', kind: 'reply', state: 'todo' },
      { id: 'reply:x', itemId: 'PRRT_1', kind: 'reply', state: 'todo', text: 7 },
      { by: 'abc', id: 'reply:x', itemId: 'PRRT_1', kind: 'reply', state: 'todo', text: null },
      { id: 'comment:x', itemId: 'IC_1', kind: 'comment', state: 'todo', text: null },
      { id: 'commit', kind: 'commit', message: 'm', paths: ['a', 3], state: 'todo' },
      { id: 'rerequest', kind: 'rerequest', logins: [''], state: 'todo' },
      { id: '', kind: 'push', state: 'todo' },
      null,
    ]
    for (const post of bad) {
      const data = JSON.parse(JSON.stringify(valid()))
      const box = JSON.parse(JSON.stringify(outbox()))
      box.posts.push(post)
      data.prs[KEY] = { ...emptyPrState(), outbox: box }
      expect(parseState(data).prs[KEY]?.outbox, JSON.stringify(post)).toBeNull()
    }
    // Two posts with one ID, a bad seen entry and a bad head also drop the outbox.
    const twice = JSON.parse(JSON.stringify(outbox()))
    twice.posts.push(twice.posts[1])
    const seen = { ...outbox(), seen: { PRRT_1: 'soon' } }
    const head = { ...outbox(), headSha: 'main' }
    for (const box of [twice, seen, head]) {
      const data = JSON.parse(JSON.stringify(valid()))
      data.prs[KEY] = { ...emptyPrState(), outbox: box }
      expect(parseState(data).prs[KEY]?.outbox).toBeNull()
    }
    const data = JSON.parse(JSON.stringify(valid()))
    data.prs[KEY] = { ...emptyPrState(), outbox: outbox() }
    expect(parseState(data).prs[KEY]?.outbox).toEqual(outbox())
  })

  it('keeps the signed flag of a push post, and an old push post parses as not signed', () => {
    const box = outbox()
    box.posts[1] = { id: 'push', kind: 'push', sha: 'd'.repeat(40), signed: true, state: 'done' }
    const data = JSON.parse(JSON.stringify(valid()))
    data.prs[KEY] = { ...emptyPrState(), outbox: box }
    expect(parseState(data).prs[KEY]?.outbox?.posts[1]).toEqual(box.posts[1])
    // signed: false is the same as no flag.
    const plain = JSON.parse(JSON.stringify(valid()))
    const unsigned = JSON.parse(JSON.stringify(box))
    unsigned.posts[1].signed = false
    plain.prs[KEY] = { ...emptyPrState(), outbox: unsigned }
    expect(parseState(plain).prs[KEY]?.outbox?.posts[1]).toEqual({
      id: 'push',
      kind: 'push',
      sha: 'd'.repeat(40),
      state: 'done',
    })
    const old = JSON.parse(JSON.stringify(valid()))
    old.prs[KEY] = { ...emptyPrState(), outbox: outbox() }
    expect(parseState(old).prs[KEY]?.outbox?.posts[1]).not.toHaveProperty('signed')
  })

  it('keeps a legacy item ID that ends with = in each R3 field', () => {
    // A legacy GitHub node ID is base64 and can end with one or two = signs.
    const one = 'MDIzOlB1bGxSZXF1ZXN0UmV2aWV3VGhyZWFkMQ='
    const two = 'MDEyOklzc3VlQ29tbWVudDE=='
    expect(ITEM_ID.test(one) && ITEM_ID.test(two)).toBe(true)
    expect(ITEM_ID.test('abc===') || ITEM_ID.test('=') || ITEM_ID.test('a=b')).toBe(false)
    const box = outbox()
    box.posts.push(
      { id: `reply:${one}`, itemId: one, kind: 'reply', state: 'todo', text: null },
      {
        commentId: two,
        id: `comment:${two}`,
        itemId: two,
        kind: 'comment',
        quote: '> q',
        state: 'done',
        text: 'a',
      },
    )
    box.seen = { ...box.seen, [one]: 50, [two]: 60 }
    const state = valid()
    state.prs[KEY] = {
      ...emptyPrState(),
      held: [one, two],
      outbox: box,
      questions: { [one]: { answer: null, at: 1, question: 'q', seenUntil: 1, where: 'w' } },
      round: {
        at: 1,
        headSha: SHA,
        items: { [one]: 3, [two]: 4 },
        kind: 'request',
        phase: 'running',
        sessionId: 's',
        shortId: null,
        startedAt: 2,
        stoppedByUser: false,
      },
    }
    expect(parseState(JSON.parse(JSON.stringify(state)))).toEqual(state)
  })

  it('drops a question with a where over MAX_WHERE', () => {
    const ok = { answer: null, at: 1, question: 'q', seenUntil: 1 }
    const data = JSON.parse(JSON.stringify(valid()))
    data.prs[KEY] = {
      ...emptyPrState(),
      questions: {
        PRRT_1: { ...ok, where: 'w'.repeat(MAX_WHERE + 1) },
        PRRT_2: { ...ok, where: 'w'.repeat(MAX_WHERE) },
      },
    }
    expect(Object.keys(parseState(data).prs[KEY]?.questions ?? {})).toEqual(['PRRT_2'])
  })

  it('keeps the quote of a question, and an old question loads with no quote', () => {
    const ok = { answer: null, at: 1, question: 'q', seenUntil: 1, where: 'w' }
    const quote = {
      author: 'mia',
      body: 'Why?',
      kind: 'thread',
      url: 'https://github.com/acme/app/pull/12#c1',
    }
    const data = JSON.parse(JSON.stringify(valid()))
    data.prs[KEY] = { ...emptyPrState(), questions: { PRRT_1: { ...ok, ...quote }, PRRT_2: ok } }
    const questions = parseState(data).prs[KEY]?.questions ?? {}
    expect(questions.PRRT_1).toEqual({ ...ok, ...quote })
    expect(questions.PRRT_2).toEqual(ok)
    expect(questions.PRRT_2).not.toHaveProperty('body')
  })

  it('drops a bad quote field and keeps the question', () => {
    const ok = { answer: null, at: 1, question: 'q', seenUntil: 1, where: 'w' }
    const data = JSON.parse(JSON.stringify(valid()))
    data.prs[KEY] = {
      ...emptyPrState(),
      questions: {
        PRRT_1: {
          ...ok,
          author: 'a'.repeat(MAX_AUTHOR + 1),
          body: 'b'.repeat(MAX_QUOTE + 1),
          url: 'https://github.com.evil.example/x',
        },
        PRRT_2: { ...ok, author: 7, body: { a: 1 }, kind: 'other', url: 'http://github.com/x' },
        PRRT_3: { ...ok, author: 'a'.repeat(MAX_AUTHOR), body: 'b'.repeat(MAX_QUOTE) },
      },
    }
    const questions = parseState(data).prs[KEY]?.questions ?? {}
    expect(questions.PRRT_1).toEqual(ok)
    expect(questions.PRRT_2).toEqual(ok)
    expect(questions.PRRT_3?.body).toHaveLength(MAX_QUOTE)
    expect(questions.PRRT_3?.author).toHaveLength(MAX_AUTHOR)
  })

  it('drops a question over MAX_QUESTION', () => {
    const ok = { answer: null, at: 1, question: 'q', seenUntil: 1, where: 'w' }
    const data = JSON.parse(JSON.stringify(valid()))
    data.prs[KEY] = {
      ...emptyPrState(),
      held: ['PRRT_1', 'bad id', 'PRRT_1', '__proto__', 7, 'PRRT_2'],
      questions: {
        'bad id': ok,
        constructor: ok,
        PRRT_1: { ...ok, question: 'x'.repeat(MAX_QUESTION + 1) },
        PRRT_2: { ...ok, answer: 'y'.repeat(MAX_ANSWER + 1) },
        PRRT_3: { ...ok, answer: 'y'.repeat(MAX_ANSWER), question: 'x'.repeat(MAX_QUESTION) },
        PRRT_4: { ...ok, seenUntil: 'later' },
      },
      round: {
        at: 1,
        headSha: SHA,
        items: { 'bad id': 1, PRRT_1: 2, PRRT_2: 'x' },
        kind: 'request',
        phase: 'running',
        sessionId: 's',
        shortId: null,
        startedAt: 2,
        stoppedByUser: false,
      },
    }
    const pr = parseState(data).prs[KEY]
    expect(Object.keys(pr?.questions ?? {})).toEqual(['PRRT_3'])
    expect(pr?.held).toEqual(['PRRT_1', 'PRRT_2'])
    expect(pr?.round?.items).toEqual({ PRRT_1: 2 })
  })

  it('caps held at MAX_HELD and keeps the newest, and drops a round with an unknown kind', () => {
    const held = Array.from({ length: MAX_HELD + 3 }, (_, i) => `PRRT_${i}`)
    const data = JSON.parse(JSON.stringify(valid()))
    data.prs[KEY] = {
      ...emptyPrState(),
      held,
      round: {
        at: 1,
        headSha: null,
        kind: 'other',
        phase: 'running',
        sessionId: null,
        shortId: null,
        startedAt: 2,
      },
    }
    const pr = parseState(data).prs[KEY]
    expect(pr?.held).toHaveLength(MAX_HELD)
    expect(pr?.held[0]).toBe('PRRT_3')
    expect(pr?.round).toBeNull()
  })

  it('handledEntry never gives a null lastReplyAt', () => {
    expect(handledEntry(10, null)).toEqual({ at: 10, lastReplyAt: 10 })
    expect(handledEntry(10, 25)).toEqual({ at: 10, lastReplyAt: 25 })
    // An R1 entry with a null lastReplyAt still parses.
    const data = JSON.parse(JSON.stringify(valid()))
    data.prs[KEY] = { ...emptyPrState(), handled: { PRRT_1: { at: 3, lastReplyAt: null } } }
    expect(parseState(data).prs[KEY]?.handled).toEqual({ PRRT_1: { at: 3, lastReplyAt: null } })
  })
})
