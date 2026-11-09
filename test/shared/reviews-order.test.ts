import { describe, expect, it } from 'vitest'
import type { MyPrRow, ToReviewRow } from '../../src/shared/reviews'
import { MINE_ORDER, sortMine, sortToReview, TO_REVIEW_ORDER } from '../../src/shared/reviews-order'

function tr(key: string, over: Partial<ToReviewRow>): ToReviewRow {
  return {
    additions: 0,
    author: 'a',
    deletions: 0,
    flash: false,
    key,
    number: 1,
    owner: 'o',
    pauseEndsAt: null,
    repo: 'r',
    requestedAt: 0,
    sessionId: null,
    state: 'new',
    title: 't',
    ...over,
  }
}

function mp(key: string, over: Partial<MyPrRow>): MyPrRow {
  return {
    claude: 'waiting',
    error: null,
    failedChecks: 0,
    fixing: 0,
    key,
    laterCopilot: 0,
    number: 1,
    olderOpen: 0,
    owner: 'o',
    repo: 'r',
    reviewers: [],
    sessionId: null,
    status: 'pending',
    title: 't',
    updatedAt: 0,
    ...over,
  }
}

describe('sortToReview', () => {
  it('gives the group order, then the oldest request first', () => {
    expect(TO_REVIEW_ORDER[0]).toBe('new')
    const rows = [
      tr('team', { state: 'team' }),
      tr('wait', { state: 'waiting' }),
      tr('new-late', { requestedAt: 20, state: 'new' }),
      tr('new-early', { requestedAt: 10, state: 'new' }),
      tr('draft', { state: 'draft-ready' }),
    ]
    expect(sortToReview(rows).map(r => r.key)).toEqual([
      'new-early',
      'new-late',
      'draft',
      'wait',
      'team',
    ])
  })

  it('puts the pause that ends first first', () => {
    const rows = [
      tr('b', { pauseEndsAt: 200, requestedAt: 1, state: 'paused' }),
      tr('a', { pauseEndsAt: 100, requestedAt: 9, state: 'paused' }),
    ]
    expect(sortToReview(rows).map(r => r.key)).toEqual(['a', 'b'])
  })
})

describe('sortMine', () => {
  it('puts needs-you first, then the status order, then the newest update', () => {
    expect(MINE_ORDER[0]).toBe('changes-requested')
    const rows = [
      mp('approved', { status: 'approved' }),
      mp('pending-old', { status: 'pending', updatedAt: 1 }),
      mp('pending-new', { status: 'pending', updatedAt: 9 }),
      mp('comments', { status: 'comments' }),
      mp('needs', { claude: 'needs-you', status: 'approved' }),
      mp('changes', { status: 'changes-requested' }),
    ]
    expect(sortMine(rows).map(r => r.key)).toEqual([
      'needs',
      'changes',
      'comments',
      'pending-new',
      'pending-old',
      'approved',
    ])
  })
})

describe('order tables and tiebreaks', () => {
  it('sorts all eight To review states and all four status groups', () => {
    const states = [...TO_REVIEW_ORDER].reverse()
    const rows = states.map(state => tr(state, { state }))
    expect(sortToReview(rows).map(r => r.state)).toEqual([...TO_REVIEW_ORDER])
    const statuses = [...MINE_ORDER].reverse()
    expect(sortMine(statuses.map(status => mp(status, { status }))).map(r => r.status)).toEqual([
      ...MINE_ORDER,
    ])
  })

  it('ends with the key, so equal rows keep their place', () => {
    expect(sortToReview([tr('b', {}), tr('a', {})]).map(r => r.key)).toEqual(['a', 'b'])
    expect(sortMine([mp('b', {}), mp('a', {})]).map(r => r.key)).toEqual(['a', 'b'])
  })
})
