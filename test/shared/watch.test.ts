import { expect, test } from 'vitest'
import {
  DEFAULT_WATCH_COLOUR,
  isWatchColour,
  OLD_WATCH_COLOURS,
  WATCH_COLOURS,
} from '../../src/shared/watch'

test('WATCH_COLOURS has the eight colours in order', () => {
  expect(WATCH_COLOURS).toEqual([
    'dark-red',
    'red',
    'amber',
    'yellow',
    'green',
    'light-blue',
    'dark-blue',
    'white',
  ])
})

test('isWatchColour accepts only a watch colour', () => {
  for (const colour of WATCH_COLOURS) expect(isWatchColour(colour)).toBe(true)
  for (const bad of ['purple', 'orange', 'Red', '', null, undefined, 1, {}, ['red']]) {
    expect(isWatchColour(bad)).toBe(false)
  }
})

test('the default colour is light blue', () => {
  expect(DEFAULT_WATCH_COLOUR).toBe('light-blue')
})

test('OLD_WATCH_COLOURS maps each old name to a new colour', () => {
  expect(OLD_WATCH_COLOURS).toEqual({
    blue: 'dark-blue',
    cyan: 'light-blue',
    green: 'green',
    lime: 'green',
    orange: 'amber',
    pink: 'red',
    purple: 'dark-blue',
    white: 'white',
  })
  for (const colour of Object.values(OLD_WATCH_COLOURS)) expect(isWatchColour(colour)).toBe(true)
})
