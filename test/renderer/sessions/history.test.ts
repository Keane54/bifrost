import { describe, expect, it } from 'vitest'
import {
  EMPTY_HISTORY,
  parseHistory,
  recentDirectories,
  rememberSession,
  rememberSlash,
} from '../../../src/renderer/src/sessions/history'
import { row } from '../overview/fixtures'

const spec = {
  cwd: '/a',
  model: 'opus' as const,
  name: 'n',
  permissionMode: 'plan',
  prompt: '',
  worktree: false,
}

describe('history', () => {
  it('parseHistory gives the empty history for bad data', () => {
    for (const bad of [null, [], { model: 'gpt' }]) {
      expect(parseHistory(bad)).toEqual(EMPTY_HISTORY)
    }
  })

  it('parseHistory keeps the valid values and drops the bad ones', () => {
    const parsed = parseHistory({
      model: 'sonnet',
      permissionMode: 'plan',
      recentDirs: ['/a', 'rel/b', '/a', 7, '/c'],
      recentSlash: [
        '/compact',
        '/two\nlines',
        'no slash',
        '/compact',
        `/${'x'.repeat(200)}`,
        '/ok',
      ],
    })
    expect(parsed).toEqual({
      model: 'sonnet',
      permissionMode: 'plan',
      recentDirs: ['/a', '/c'],
      recentSlash: ['/compact', '/ok'],
    })
    expect(parseHistory({ permissionMode: 'bypassPermissions' }).permissionMode).toBe('')
    const many = Array.from({ length: 30 }, (_, i) => `/d${i}`)
    expect(parseHistory({ recentDirs: many, recentSlash: many }).recentDirs).toHaveLength(10)
    expect(parseHistory({ recentDirs: many, recentSlash: many }).recentSlash).toHaveLength(8)
  })

  it('rememberSession puts the directory first, keeps 10, and keeps the model and the mode', () => {
    let h = EMPTY_HISTORY
    for (let i = 0; i < 12; i++) h = rememberSession(h, { ...spec, cwd: `/d${i}` })
    h = rememberSession(h, { ...spec, cwd: '/d5' })
    expect(h.recentDirs).toHaveLength(10)
    expect(h.recentDirs[0]).toBe('/d5')
    expect(h.recentDirs.filter(d => d === '/d5')).toHaveLength(1)
    expect(h.model).toBe('opus')
    expect(h.permissionMode).toBe('plan')
  })

  it('rememberSlash keeps the 8 newest commands with no copy', () => {
    let h = EMPTY_HISTORY
    for (let i = 0; i < 10; i++) h = rememberSlash(h, `/c${i}`)
    h = rememberSlash(h, '  /c5  ')
    expect(h.recentSlash).toHaveLength(8)
    expect(h.recentSlash[0]).toBe('/c5')
    expect(h.recentSlash.filter(c => c === '/c5')).toHaveLength(1)
  })

  it('rememberSlash ignores text that is not a slash command', () => {
    for (const text of ['hello', '', '/a\nb', `/${'x'.repeat(200)}`]) {
      expect(rememberSlash(EMPTY_HISTORY, text)).toBe(EMPTY_HISTORY)
    }
  })

  it('recentDirectories adds the project directories of the rows without the worktree tail', () => {
    const rows = [
      row({ cwd: '/r/.claude/worktrees/fix-a', sessionId: '1' }),
      row({ cwd: '/r', sessionId: '2' }),
      row({ cwd: '', sessionId: '3' }),
      row({ cwd: '/z', sessionId: '4' }),
    ]
    expect(recentDirectories({ ...EMPTY_HISTORY, recentDirs: ['/h'] }, rows)).toEqual([
      '/h',
      '/r',
      '/z',
    ])
  })
})
