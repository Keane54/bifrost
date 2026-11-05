import { describe, expect, it } from 'vitest'
import { cx } from '../../../src/renderer/src/lib/cx'

describe('cx', () => {
  it('joins the parts with one space', () => {
    expect(cx('a', 'b')).toBe('a b')
  })

  it('skips false, null, undefined and empty strings', () => {
    expect(cx('a', false, null, undefined, '', 'b')).toBe('a b')
  })

  it('gives an empty string for no parts', () => {
    expect(cx()).toBe('')
  })
})
