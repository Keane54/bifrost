import { describe, expect, it } from 'vitest'
import { dropTarget, watchedRows } from '../../../src/renderer/src/watch/watch-order'
import { row } from '../overview/fixtures'

const order = ['a', 'b', 'c', 'd']

describe('dropTarget', () => {
  it('moves a row down: the upper half of a row puts the row before it', () => {
    expect(dropTarget(order, 'a', 2, true)).toBe('c')
  })

  it('moves a row down: the lower half puts the row after the row under the pointer', () => {
    expect(dropTarget(order, 'a', 1, false)).toBe('c')
  })

  it('moves a row up', () => {
    expect(dropTarget(order, 'd', 1, true)).toBe('b')
    expect(dropTarget(order, 'c', 0, true)).toBe('a')
    expect(dropTarget(order, 'd', 0, false)).toBe('b')
  })

  it('a drop on the row itself keeps the place', () => {
    // The place is before the row that follows it.
    expect(dropTarget(order, 'b', 1, true)).toBe('c')
    expect(dropTarget(order, 'b', 1, false)).toBe('c')
    expect(dropTarget(order, 'd', 3, true)).toBeNull()
  })

  it('a drop at the end gives null', () => {
    expect(dropTarget(order, 'a', 3, false)).toBeNull()
    expect(dropTarget(order, 'a', 9, false)).toBeNull()
  })

  it('a drop at the top puts the row first', () => {
    expect(dropTarget(order, 'c', -4, true)).toBe('a')
  })

  it('an empty list gives null', () => {
    expect(dropTarget([], 'a', 0, true)).toBeNull()
  })
})

describe('watchedRows', () => {
  it('gives only the watched rows in watch order', () => {
    const rows = [
      row({ sessionId: 'x' }),
      row({ sessionId: 'p', watch: { colour: 'pink', order: 1 } }),
      row({ sessionId: 'q', watch: { colour: 'blue', order: 0 } }),
    ]
    expect(watchedRows(rows).map(r => r.sessionId)).toEqual(['q', 'p'])
  })
})
