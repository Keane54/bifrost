import { describe, expect, it } from 'vitest'
import {
  EMPTY_STATE,
  emptyPrState,
  MAX_DRAFTS,
  MAX_POSTED,
  MAX_VOICE_PAIRS,
  parseState,
  type ReviewsState,
} from '../../../src/main/reviews/state'

const KEY = 'acme/app#12'

function valid(): ReviewsState {
  return {
    baseline: ['PR_node1'],
    drafts: [{ at: 3, body: 'b', line: 4, path: 'a.ts', prKey: KEY, reviewId: 'r1' }],
    pauses: { [KEY]: 99 },
    posted: [{ at: 1, body: 'x', id: 'c1', prKey: KEY }],
    prs: { [KEY]: { ...emptyPrState(), handleCopilot: true } },
    requests: { [KEY]: { baseline: true, firstSeen: 5 } },
    turnedOnAt: 10,
    version: 1,
    voicePairs: [{ at: 2, draft: 'd', final: 'f', prKey: KEY }],
  }
}

describe('parseState', () => {
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
