import { describe, expect, it, vi } from 'vitest'
import { OPEN } from '../../../src/main/actions/actions'
import {
  checkWorktree,
  createWorktreeActions,
  worktreeRoot,
} from '../../../src/main/actions/worktree-check'
import type { ExecFn, ExecResult } from '../../../src/main/claude/cli'
import type { SessionRow } from '../../../src/shared/types'

const WT = '/r/.claude/worktrees/fix-a'
const ok = (stdout: string): ExecResult => ({ code: 0, stderr: '', stdout })

function fake(outputs: (ExecResult | Error)[]) {
  const queue = [...outputs]
  const exec = vi.fn<ExecFn>(async () => {
    const next = queue.shift() ?? ok('')
    if (next instanceof Error) throw next
    return next
  })
  return exec
}

const good = () => [ok(' M a\n?? b\n'), ok('worktree-fix-a\n'), ok('abc123\n'), ok('3\n')]

describe('worktreeRoot', () => {
  it('finds the worktree and the repo', () => {
    const want = { repo: '/r', worktree: WT }
    expect(worktreeRoot(WT)).toEqual(want)
    expect(worktreeRoot(`${WT}/src`)).toEqual(want)
    expect(worktreeRoot('/r')).toBeNull()
    expect(worktreeRoot('/r/.claude/worktrees/')).toBeNull()
  })
})

describe('checkWorktree', () => {
  it('gives no worktree for a cwd outside .claude/worktrees', async () => {
    const exec = fake([])
    expect(await checkWorktree('/r', exec)).toEqual({
      branch: null,
      changedFiles: 0,
      unmergedCommits: 0,
      worktree: null,
    })
    expect(exec).not.toHaveBeenCalled()
  })

  it('counts changed files and unmerged commits', async () => {
    const exec = fake(good())
    expect(await checkWorktree(`${WT}/src`, exec)).toEqual({
      branch: 'worktree-fix-a',
      changedFiles: 2,
      unmergedCommits: 3,
      worktree: WT,
    })
    const opts = { timeoutMs: 5000 }
    expect(exec.mock.calls).toEqual([
      ['git', ['-C', WT, 'status', '--porcelain'], opts],
      ['git', ['-C', WT, 'rev-parse', '--abbrev-ref', 'HEAD'], opts],
      ['git', ['-C', '/r', 'rev-parse', 'HEAD'], opts],
      ['git', ['-C', WT, 'rev-list', '--count', 'abc123..HEAD'], opts],
    ])
  })

  it('gives branch null for a detached HEAD', async () => {
    const out = good()
    out[1] = ok('HEAD\n')
    expect((await checkWorktree(WT, fake(out)))?.branch).toBeNull()
  })

  it('gives null when a git command fails', async () => {
    const withAt = (i: number, v: ExecResult | Error) => {
      const out = good()
      out[i] = v
      return out
    }
    const fail: ExecResult = { code: 128, stderr: 'fatal', stdout: '' }
    const timeout: ExecResult = { code: 0, stderr: '', stdout: '', timedOut: true }
    for (const out of [
      withAt(0, fail),
      withAt(1, new Error('spawn')),
      withAt(2, timeout),
      withAt(3, ok('x\n')),
    ]) {
      expect(await checkWorktree(WT, fake(out))).toBeNull()
    }
  })
})

const row = (over: Partial<SessionRow>): SessionRow =>
  ({ cwd: `${WT}/src`, kind: 'owned', sessionId: 's1', state: 'idle', ...over }) as SessionRow

describe('worktree actions', () => {
  it('deleteCheck refuses an unknown session and an external session', async () => {
    const exec = fake([])
    const a = createWorktreeActions({
      exec,
      rows: () => [
        row({}),
        row({ kind: 'external', sessionId: 'e1' }),
        row({ cwd: '', sessionId: 'c' }),
      ],
    })
    await expect(a.deleteCheck('zz')).rejects.toThrow('refused: unknown session')
    await expect(a.deleteCheck(7)).rejects.toThrow('refused: unknown session')
    await expect(a.deleteCheck('e1')).rejects.toThrow(
      'refused: Bifrost does not delete an external session',
    )
    expect(await a.deleteCheck('c')).toBeNull()
    expect(exec).not.toHaveBeenCalled()
  })

  it('openWorktree opens only the worktree of the row', async () => {
    const exec = fake([ok('')])
    const a = createWorktreeActions({
      exec,
      rows: () => [row({}), row({ cwd: '/r', sessionId: 's2' })],
    })
    await a.openWorktree('s1')
    expect(exec).toHaveBeenCalledWith(OPEN, [WT], { timeoutMs: 10000 })
    exec.mockClear()
    await expect(a.openWorktree('s2')).rejects.toThrow('refused: the session has no worktree')
    expect(exec).not.toHaveBeenCalled()
  })
})
