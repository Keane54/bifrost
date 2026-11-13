import { expect, test } from 'vitest'
import { isTerminalSize, REFUSED_BAD_SIZE } from '../../../src/main/pty/terminal-size'

test('accepts whole numbers from 1 to 1000 only', () => {
  for (const ok of [1, 80, 1000]) expect(isTerminalSize(ok)).toBe(true)
  for (const bad of [
    0,
    1001,
    2.5,
    Number.NaN,
    Number.POSITIVE_INFINITY,
    -3,
    '80',
    null,
    undefined,
  ]) {
    expect(isTerminalSize(bad)).toBe(false)
  }
})

test('the refusal code is stable', () => {
  expect(REFUSED_BAD_SIZE).toBe('refused: bad terminal size')
})
