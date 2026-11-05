import { describe, expect, it } from 'vitest'
import {
  DEFAULT_TERM,
  decideSize,
  fitScale,
  openSize,
  type SizeInput,
} from '../../../src/renderer/src/chat/size-rule'

const A = { cols: 100, rows: 30 }
const B = { cols: 80, rows: 24 }
const C = { cols: 90, rows: 20 }

const input = (over: Partial<SizeInput> = {}): SizeInput => ({
  fit: A,
  focused: false,
  focusGained: false,
  lastSent: null,
  lastSentAt: null,
  now: 10_000,
  session: null,
  term: B,
  ...over,
})

describe('decideSize', () => {
  it('an unfocused window never sends a resize', () => {
    const cases = [
      input(),
      input({ session: C }),
      input({ focusGained: true }),
      input({ fit: C, lastSent: A }),
    ]
    for (const c of cases) expect(decideSize(c).send).toBeNull()
  })

  it('the focused window sends its fit when it gains focus', () => {
    const d = decideSize(input({ focused: true, focusGained: true, lastSent: A }))
    expect(d).toEqual({ send: A, term: A })
  })

  it('the focused window sends its fit when the fit changes', () => {
    const d = decideSize(input({ focused: true, lastSent: B }))
    expect(d).toEqual({ send: A, term: A })
  })

  it('the focused window does not send the same fit again', () => {
    const d = decideSize(input({ focused: true, lastSent: A, term: A }))
    expect(d.send).toBeNull()
  })

  it('a session size from another client sets the terminal size and sends nothing', () => {
    expect(decideSize(input({ session: C }))).toEqual({ send: null, term: C })
    const focused = input({ focused: true, lastSent: A, session: C, term: A })
    expect(decideSize(focused)).toEqual({ send: null, term: C })
  })

  it('a different session size within 500 ms of a send is an old read', () => {
    const base = input({ focused: true, lastSent: A, lastSentAt: 9_600, session: C, term: A })
    expect(decideSize({ ...base, now: 10_100 })).toEqual({ send: null, term: A })
    expect(decideSize({ ...base, now: 10_101 })).toEqual({ send: null, term: C })
    // The same size as the send is not an old read.
    expect(decideSize({ ...base, now: 10_000, session: A }).term).toEqual(A)
  })

  it('without a session size the terminal keeps its size', () => {
    expect(decideSize(input({ fit: null }))).toEqual({ send: null, term: B })
    expect(decideSize(input({ fit: null, focused: true }))).toEqual({ send: null, term: B })
  })
})

describe('fitScale', () => {
  it('shrinks to fit and never zooms above 1', () => {
    expect(fitScale({ h: 500, w: 1000 }, { h: 500, w: 500 })).toBe(0.5)
    expect(fitScale({ h: 300, w: 400 }, { h: 600, w: 800 })).toBe(1)
    expect(fitScale({ h: 300, w: 400 }, null)).toBe(1)
    expect(fitScale({ h: 0, w: 400 }, { h: 600, w: 800 })).toBe(1)
  })
})

describe('openSize', () => {
  it('uses the session size only for an unfocused window', () => {
    expect(openSize({ fit: A, focused: false, session: C })).toEqual(C)
    expect(openSize({ fit: A, focused: true, session: C })).toEqual(A)
    expect(openSize({ fit: null, focused: true, session: C })).toEqual(C)
    expect(openSize({ fit: A, focused: false, session: null })).toEqual(A)
    expect(openSize({ fit: null, focused: false, session: null })).toEqual(DEFAULT_TERM)
  })
})
