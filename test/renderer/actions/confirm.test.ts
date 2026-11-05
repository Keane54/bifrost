import { describe, expect, it } from 'vitest'
import { confirmFor, isWorktreeRow } from '../../../src/renderer/src/actions/confirm'
import type { WorktreeCheck } from '../../../src/shared/types'
import { row } from '../overview/fixtures'

describe('confirm texts', () => {
  it('Stop asks only for a working session', () => {
    expect(confirmFor('stop', row({ sessionId: 'a', state: 'idle' }), 'plain')).toBeNull()
    expect(confirmFor('stop', row({ name: 'fix-a', sessionId: 'a' }), 'plain')).toEqual({
      body: 'fix-a is working right now. Stop it anyway? The current turn will end.',
      confirm: 'Stop session',
      title: 'Stop session',
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

  const WT = '/r/.claude/worktrees/fix-a'
  const check = (over: Partial<WorktreeCheck>): WorktreeCheck => ({
    branch: 'worktree-fix-a',
    changedFiles: 0,
    unmergedCommits: 0,
    worktree: WT,
    ...over,
  })
  const del = (c: WorktreeCheck | null | undefined) =>
    confirmFor('delete', row({ cwd: WT, name: 'fix-a', sessionId: 'a' }), 'plain', c)

  it('Delete without unmerged work gives the plain text', () => {
    const text = del(check({}))
    expect(text?.body).toBe('Delete fix-a? This removes the session and its conversation.')
    expect(text?.confirmAgain).toBeUndefined()
    expect(text?.openFolder).toBeUndefined()
    expect(del(check({ changedFiles: 4, worktree: null }))?.confirmAgain).toBeUndefined()
  })

  it('Delete with unmerged work gives the counts and asks again', () => {
    expect(del(check({ changedFiles: 3, unmergedCommits: 2 }))).toEqual({
      body: 'This session has 2 commits that are not merged and 3 changed files on worktree-fix-a. Are you sure you want to delete this?',
      confirm: 'Delete session',
      confirmAgain: 'Delete anyway',
      openFolder: WT,
      title: 'Delete session',
    })
  })

  it('Delete uses the singular and leaves out a zero part', () => {
    expect(del(check({ unmergedCommits: 1 }))?.body).toBe(
      'This session has 1 commit that is not merged on worktree-fix-a. Are you sure you want to delete this?',
    )
    expect(del(check({ changedFiles: 1 }))?.body).toBe(
      'This session has 1 changed file on worktree-fix-a. Are you sure you want to delete this?',
    )
    expect(del(check({ branch: null, unmergedCommits: 1 }))?.body).toBe(
      'This session has 1 commit that is not merged in its worktree. Are you sure you want to delete this?',
    )
  })

  it('Delete after a failed check says so and asks again', () => {
    const text = del(null)
    expect(text?.body).toBe(
      'Bifrost could not check this session for unmerged work. Are you sure you want to delete this?',
    )
    expect(text?.confirmAgain).toBe('Delete anyway')
    expect(text?.openFolder).toBe(WT)
    const plainRow = row({ cwd: '/p', sessionId: 'a' })
    expect(confirmFor('delete', plainRow, 'plain', null)?.openFolder).toBeUndefined()
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
    expect(confirmFor('stop', r, 'space')?.confirm).toBe('Power down')
    expect(confirmFor('stop', r, 'space')?.title).toBe('Power down')
    expect(confirmFor('delete', r, 'space')?.confirm).toBe('Self-destruct')
    expect(confirmFor('delete', r, 'space')?.title).toBe('Self-destruct')
  })
})
