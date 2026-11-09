import { describe, expect, it } from 'vitest'
import { panelBody } from '../../../src/renderer/src/reviews/panel-body'
import { EMPTY_REVIEWS, type ReviewsSnapshot } from '../../../src/shared/reviews'

const snap = (patch: Partial<ReviewsSnapshot>): ReviewsSnapshot => ({ ...EMPTY_REVIEWS, ...patch })

describe('panelBody', () => {
  it('gives the body for each availability', () => {
    expect(panelBody(snap({ availability: 'off' }), 0)).toBe('off')
    expect(panelBody(snap({ availability: 'starting' }), 0)).toBe('starting')
    expect(panelBody(snap({ availability: 'no-gh', message: 'x' }), 0)).toBe('notice')
    expect(panelBody(snap({ availability: 'logged-out', message: 'x', polledAt: 1 }), 2)).toBe(
      'notice',
    )
  })

  it('a failed first poll shows only the error, not the empty text', () => {
    expect(panelBody(snap({ availability: 'error', message: 'boom', polledAt: null }), 0)).toBe(
      'error',
    )
  })

  it('a failed later poll keeps the rows of the last good poll', () => {
    expect(panelBody(snap({ availability: 'error', message: 'boom', polledAt: 1 }), 2)).toBe('rows')
    expect(panelBody(snap({ availability: 'error', message: 'boom', polledAt: 1 }), 0)).toBe(
      'empty',
    )
  })

  it('a good poll gives the rows or the empty text', () => {
    expect(panelBody(snap({ availability: 'ok', polledAt: 1 }), 0)).toBe('empty')
    expect(panelBody(snap({ availability: 'ok', polledAt: 1 }), 3)).toBe('rows')
  })
})
