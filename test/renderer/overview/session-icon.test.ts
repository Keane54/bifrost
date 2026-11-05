import { describe, expect, it } from 'vitest'
import {
  iconKind,
  projectColourIndex,
  projectKey,
} from '../../../src/renderer/src/overview/session-icon'
import { row } from './fixtures'

describe('projectKey', () => {
  it('gives a plain path as it is', () => {
    expect(projectKey('/Users/o/Developer/app')).toBe('/Users/o/Developer/app')
  })

  it('removes a trailing slash', () => {
    expect(projectKey('/Users/o/Developer/app/')).toBe('/Users/o/Developer/app')
  })

  it('gives the repository of a worktree path', () => {
    expect(projectKey('/Users/o/Developer/app/.claude/worktrees/fix-bug')).toBe(
      '/Users/o/Developer/app',
    )
  })

  it('gives the repository of a path inside a worktree', () => {
    expect(projectKey('/Users/o/Developer/app/.claude/worktrees/fix-bug/src/lib')).toBe(
      '/Users/o/Developer/app',
    )
  })
})

describe('projectColourIndex', () => {
  it('gives the same index for the same key', () => {
    expect(projectColourIndex('/a/b')).toBe(projectColourIndex('/a/b'))
  })

  it('gives an index from 1 to 8', () => {
    for (const key of ['', '/', '/a', '/a/b', '/Users/o/x', 'z'.repeat(500)]) {
      const index = projectColourIndex(key)
      expect(index).toBeGreaterThanOrEqual(1)
      expect(index).toBeLessThanOrEqual(8)
    }
  })

  it('gives the expected index for known keys (FNV-1a 32-bit)', () => {
    expect(projectColourIndex('/Users/o/Developer/app')).toBe(2)
    expect(projectColourIndex('/Users/o/Developer/bifrost')).toBe(8)
    expect(projectColourIndex('')).toBe(6)
  })
})

describe('iconKind', () => {
  it('gives owned for an owned row', () => {
    expect(iconKind(row({ kind: 'owned', sessionId: 'a' }))).toBe('owned')
  })

  it('gives external for an external row', () => {
    expect(iconKind(row({ kind: 'external', sessionId: 'a' }))).toBe('external')
  })

  it('gives parked for a parked row', () => {
    expect(iconKind(row({ sessionId: 'a', state: 'parked' }))).toBe('parked')
  })
})
