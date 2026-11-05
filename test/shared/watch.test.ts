import { expect, test } from 'vitest'
import { isWatchColour, WATCH_COLOURS } from '../../src/shared/watch'

test('WATCH_COLOURS has the eight colours in order', () => {
  expect(WATCH_COLOURS).toEqual([
    'orange',
    'green',
    'lime',
    'cyan',
    'blue',
    'purple',
    'pink',
    'white',
  ])
})

test('isWatchColour accepts only a watch colour', () => {
  for (const colour of WATCH_COLOURS) expect(isWatchColour(colour)).toBe(true)
  for (const bad of ['red', 'Orange', '', null, undefined, 1, {}, ['orange']]) {
    expect(isWatchColour(bad)).toBe(false)
  }
})
