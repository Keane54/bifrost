import { expect, test } from 'vitest'
import { draftToSave } from '../../../src/renderer/src/settings/draft'

test('draftToSave trims the text before the save (final review, parked from Task 3)', () => {
  expect(draftToSave('  Menlo ', 'SF Mono')).toBe('Menlo')
  expect(draftToSave('Menlo', 'SF Mono')).toBe('Menlo')
})

test('draftToSave gives null for a text that only adds spaces to the saved value', () => {
  expect(draftToSave(' SF Mono  ', 'SF Mono')).toBeNull()
  expect(draftToSave('13', '13')).toBeNull()
})

test('draftToSave keeps an empty text, so the save gives its reason', () => {
  expect(draftToSave('   ', 'SF Mono')).toBe('')
})
