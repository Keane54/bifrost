import { expect, test } from 'vitest'
import { isPriority, PRIORITIES } from '../../src/shared/priority'

test('isPriority accepts 1 to 5 and refuses 0, 6, 2.5, "3" and null', () => {
  for (const value of PRIORITIES) expect(isPriority(value)).toBe(true)
  for (const value of [0, 6, 2.5, '3', null, undefined, Number.NaN]) {
    expect(isPriority(value)).toBe(false)
  }
})
