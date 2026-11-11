import { describe, expect, test } from 'vitest'
import type { SessionRow } from '../../src/shared/types'
import { folderUser } from '../../src/shared/worktree'

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

describe('folderUser', () => {
  test('a row that runs in the worktree of a parked row uses its folder', () => {
    const user = row('b', { cwd: `${WT}/src`, state: 'working' })
    expect(folderUser(old, [old, user])).toBe(user)
  })

  test('the stored worktree of a row that runs also counts', () => {
    const user = row('b', { cwd: '/r', state: 'needs-you', worktree: WT })
    expect(folderUser(old, [user, old])).toBe(user)
    // The cwd of the parked row can also give the worktree.
    const inside = row('a', { cwd: `${WT}/src`, state: 'parked' })
    expect(folderUser(inside, [inside, user])).toBe(user)
  })

  test('a parked row never blocks, so two parked rows do not block each other', () => {
    const other = row('b', { cwd: WT, state: 'parked' })
    expect(folderUser(old, [old, other])).toBeUndefined()
  })

  test('a row that is not parked gets no block', () => {
    const running = row('a', { cwd: WT })
    const user = row('b', { cwd: WT })
    expect(folderUser(running, [running, user])).toBeUndefined()
  })

  test('a plain folder gives no block', () => {
    const plain = row('a', { state: 'parked' })
    const user = row('b')
    expect(folderUser(plain, [plain, user])).toBeUndefined()
  })

  test('another worktree of the same repository gives no block', () => {
    const user = row('b', { cwd: '/r/.claude/worktrees/w2' })
    expect(folderUser(old, [old, user])).toBeUndefined()
  })

  test('the row itself never counts', () => {
    expect(folderUser(old, [old])).toBeUndefined()
    // Also a copy of the row that runs again.
    expect(folderUser(old, [{ ...old, cwd: WT, state: 'idle' }])).toBeUndefined()
  })
})
