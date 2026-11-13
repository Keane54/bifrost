import { describe, expect, test } from 'vitest'
import {
  checkVisible,
  HIDDEN_POLL_MS,
  pollInterval,
} from '../../../src/main/registry/poll-interval'

describe('pollInterval', () => {
  test('a visible window uses the normal interval', () => {
    expect(pollInterval(2000, true)).toBe(2000)
  })

  test('a window that is not visible uses 15 seconds', () => {
    expect(HIDDEN_POLL_MS).toBe(15_000)
    expect(pollInterval(2000, false)).toBe(15_000)
  })

  test('a normal interval above 15 seconds stays when the window is hidden', () => {
    expect(pollInterval(30_000, false)).toBe(30_000)
  })
})

describe('checkVisible', () => {
  test('accepts a boolean', () => {
    expect(checkVisible(true)).toBe(true)
    expect(checkVisible(false)).toBe(false)
  })

  test.each([undefined, null, 'true', 1, 0, {}, []])('refuses %j', value => {
    expect(() => checkVisible(value)).toThrow('refused: bad input')
  })
})
