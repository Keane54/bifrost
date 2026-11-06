import { expect, test } from 'vitest'
import { aliasTip, checkAliasRequest, cleanAlias } from '../../src/shared/alias'
import { MAX_RENAME } from '../../src/shared/input'

test('cleanAlias trims the name', () => {
  expect(cleanAlias('  Fix login  ')).toEqual({ name: 'Fix login', ok: true })
})

test('cleanAlias gives an empty name for white space only', () => {
  expect(cleanAlias('   ')).toEqual({ name: '', ok: true })
})

test('cleanAlias refuses control characters, tab and line break', () => {
  for (const text of ['a\x1bb', 'a\tb', 'a\nb', 'a\rb', 'a\x00b', 'a\x7fb', 'a\x85b']) {
    expect(cleanAlias(text).ok).toBe(false)
  }
})

test('cleanAlias keeps the MAX_RENAME limit', () => {
  expect(cleanAlias('a'.repeat(MAX_RENAME)).ok).toBe(true)
  expect(cleanAlias('a'.repeat(MAX_RENAME + 1)).ok).toBe(false)
})

test('checkAliasRequest accepts a string ID with a name or null', () => {
  expect(checkAliasRequest('s1', ' Work ')).toEqual({ name: 'Work', ok: true })
  expect(checkAliasRequest('s1', null)).toEqual({ name: null, ok: true })
})

test('checkAliasRequest refuses a bad session ID, a bad type and control characters', () => {
  for (const id of [1, null, undefined, {}, '']) {
    expect(checkAliasRequest(id, 'x').ok).toBe(false)
  }
  for (const name of [1, undefined, {}, ['a']]) {
    expect(checkAliasRequest('s1', name).ok).toBe(false)
  }
  expect(checkAliasRequest('s1', 'a\x1b[31mb').ok).toBe(false)
})

test('aliasTip names the Claude Code name when a local name is set', () => {
  expect(aliasTip({ claudeName: 'alpha', name: 'Work' })).toBe('Claude Code name: alpha')
})

test('aliasTip gives the name itself when no local name is set', () => {
  expect(aliasTip({ claudeName: 'alpha', name: 'alpha' })).toBe('alpha')
})
