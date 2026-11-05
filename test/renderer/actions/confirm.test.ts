import { describe, expect, it } from 'vitest'
import { confirmFor, isWorktreeRow } from '../../../src/renderer/src/actions/confirm'
import { row } from '../overview/fixtures'

describe('confirm texts', () => {
  it('Stop asks only for a working session', () => {
    expect(confirmFor('stop', row({ sessionId: 'a', state: 'idle' }), 'plain')).toBeNull()
    expect(confirmFor('stop', row({ name: 'fix-a', sessionId: 'a' }), 'plain')).toEqual({
      body: 'fix-a is working right now. Stop it anyway? The current turn will end.',
      confirm: 'Stop session...',
      title: 'Stop session...',
    })
  })

  it('Delete always asks', () => {
    for (const state of ['idle', 'working', 'parked'] as const) {
      expect(confirmFor('delete', row({ sessionId: 'a', state }), 'plain')).not.toBeNull()
    }
  })

  it('Delete gives the plain text', () => {
    expect(confirmFor('delete', row({ name: 'fix-a', sessionId: 'a' }), 'plain')?.body).toBe(
      'Delete fix-a? This removes the session and its conversation.',
    )
  })

  it('isWorktreeRow finds a worktree cwd and a worktree- branch', () => {
    expect(isWorktreeRow(row({ cwd: '/r/.claude/worktrees/fix-a', sessionId: 'a' }))).toBe(true)
    expect(isWorktreeRow(row({ branch: 'worktree-x', cwd: '/r', sessionId: 'a' }))).toBe(true)
    expect(isWorktreeRow(row({ branch: 'main', cwd: '/r', sessionId: 'a' }))).toBe(false)
  })

  it('Take control names the terminal app', () => {
    const base = { kind: 'external', sessionId: 'a' } as const
    expect(confirmFor('take-control', row({ ...base, terminalApp: 'Warp' }), 'plain')?.body).toBe(
      'This closes the session in Warp and moves it into Bifrost.',
    )
    expect(confirmFor('take-control', row(base), 'plain')?.body).toBe(
      'This closes the session in its terminal and moves it into Bifrost.',
    )
  })

  it('the confirm labels use the label set', () => {
    const r = row({ sessionId: 'a' })
    expect(confirmFor('stop', r, 'space')?.confirm).toBe('Power down...')
    expect(confirmFor('delete', r, 'space')?.confirm).toBe('Self-destruct...')
  })
})
