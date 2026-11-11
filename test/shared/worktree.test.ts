import { describe, expect, test } from 'vitest'
import type { SessionRow } from '../../src/shared/types'
import { folderSharer } from '../../src/shared/worktree'

type Row = Pick<SessionRow, 'sessionId' | 'state' | 'cwd' | 'worktree'>

const WT = '/r/.claude/worktrees/w1'

const row = (sessionId: string, o: Partial<Row> = {}): Row => ({
  cwd: '/r',
  sessionId,
  state: 'idle',
  ...o,
})

// A stopped worktree session reports its start folder. The row keeps the worktree.
const old = row('a', { state: 'parked', worktree: WT })

describe('folderSharer', () => {
  test('a running row in the worktree of a parked row shares its folder', () => {
    const other = row('b', { cwd: `${WT}/src`, state: 'working' })
    expect(folderSharer(old, [old, other])).toBe(other)
  })

  test('a parked row also shares the folder', () => {
    const other = row('b', { cwd: WT, state: 'parked' })
    expect(folderSharer(old, [old, other])).toBe(other)
    // The stored worktree of the other row also counts.
    const stored = row('b', { state: 'parked', worktree: WT })
    expect(folderSharer(old, [stored, old])).toBe(stored)
  })

  test('the state of the row itself does not matter', () => {
    const running = row('a', { cwd: `${WT}/src` })
    const other = row('b', { cwd: WT, state: 'needs-you' })
    expect(folderSharer(running, [running, other])).toBe(other)
  })

  test('a plain folder gives undefined', () => {
    const plain = row('a', { state: 'parked' })
    const other = row('b')
    expect(folderSharer(plain, [plain, other])).toBeUndefined()
  })

  test('another worktree of the same repository gives undefined', () => {
    const other = row('b', { cwd: '/r/.claude/worktrees/w2' })
    expect(folderSharer(old, [old, other])).toBeUndefined()
  })

  test('the row itself never counts', () => {
    expect(folderSharer(old, [old])).toBeUndefined()
    // Also a copy of the row that runs again.
    expect(folderSharer(old, [{ ...old, cwd: WT, state: 'idle' }])).toBeUndefined()
  })
})
