import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { OPEN } from '../../../src/main/actions/actions'
import {
  CHECK_RETRY_MS,
  checkWorktree,
  checkWorktreeHead,
  createWorktreeActions,
  worktreeRoot,
} from '../../../src/main/actions/worktree-check'
import type { ExecFn, ExecResult } from '../../../src/main/claude/cli'
import type { SessionRow } from '../../../src/shared/types'
import { worktreeOf } from '../../../src/shared/worktree'

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
// git status takes no optional lock, so it writes no index.lock (Task 17 bug 5).
const STATUS = (worktree: string) => [
  '--no-optional-locks',
  '-C',
  worktree,
  'status',
  '--porcelain',
]
const fail: ExecResult = { code: 128, stderr: 'fatal', stdout: '' }

// A failed check waits CHECK_RETRY_MS with the fake timers. This runs all timers.
async function settled<T>(promise: Promise<T>): Promise<T> {
  await vi.runAllTimersAsync()
  return promise
}

beforeEach(() => {
  vi.useFakeTimers()
})

afterEach(() => {
  vi.useRealTimers()
})

describe('worktreeRoot', () => {
  it('finds the worktree and the repo', () => {
    const want = { repo: '/r', worktree: WT }
    expect(worktreeRoot(WT)).toEqual(want)
    expect(worktreeRoot(`${WT}/src`)).toEqual(want)
    expect(worktreeRoot('/r')).toBeNull()
    expect(worktreeRoot('/r/.claude/worktrees/')).toBeNull()
  })

  it('worktreeRoot uses the first mark', () => {
    expect(worktreeRoot('/r/.claude/worktrees/a/.claude/worktrees/b')).toEqual({
      repo: '/r',
      worktree: '/r/.claude/worktrees/a',
    })
  })

  it('worktreeRoot refuses a relative path, dot segments and an empty repo', () => {
    for (const cwd of [
      'r/.claude/worktrees/a',
      '/r/.claude/worktrees/..',
      '/r/.claude/worktrees/a/../../x',
      '/r/./.claude/worktrees/a',
      '/.claude/worktrees/a',
    ]) {
      expect(worktreeRoot(cwd)).toBeNull()
    }
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
      ['git', STATUS(WT), opts],
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

  it('gives null when a git command fails in both tries', async () => {
    // One try runs the commands up to the one that fails. The second try gets the same outputs.
    const twice = (i: number, v: ExecResult | Error) => {
      const out = good().slice(0, i + 1)
      out[i] = v
      return [...out, ...out]
    }
    const timeout: ExecResult = { code: 0, stderr: '', stdout: '', timedOut: true }
    for (const [i, out] of [
      [0, twice(0, fail)],
      [1, twice(1, new Error('spawn'))],
      [2, twice(2, timeout)],
      [3, twice(3, ok('x\n'))],
    ] as const) {
      const exec = fake([...out])
      expect(await settled(checkWorktree(WT, exec))).toBeNull()
      expect(exec).toHaveBeenCalledTimes(2 * (i + 1))
    }
  })

  it('a failed check tries one more time after 500 ms', async () => {
    expect(CHECK_RETRY_MS).toBe(500)
    const exec = fake([fail, ...good()])
    const check = checkWorktree(WT, exec)
    await vi.advanceTimersByTimeAsync(CHECK_RETRY_MS - 1)
    expect(exec).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(1)
    expect(await check).toEqual({
      branch: 'worktree-fix-a',
      changedFiles: 2,
      unmergedCommits: 3,
      worktree: WT,
    })
    expect(exec.mock.calls.map(call => call[1])).toEqual([
      STATUS(WT),
      STATUS(WT),
      ['-C', WT, 'rev-parse', '--abbrev-ref', 'HEAD'],
      ['-C', '/r', 'rev-parse', 'HEAD'],
      ['-C', WT, 'rev-list', '--count', 'abc123..HEAD'],
    ])
  })

  it('a good check does not run again, and a second failure gives null', async () => {
    const exec = fake(good())
    expect((await settled(checkWorktree(WT, exec)))?.worktree).toBe(WT)
    expect(exec).toHaveBeenCalledTimes(4)
    const failing = fake([fail, fail, ...good()])
    expect(await settled(checkWorktree(WT, failing))).toBeNull()
    expect(failing).toHaveBeenCalledTimes(2)
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

describe('the stored worktree of a stopped session', () => {
  it('worktreeOf uses the cwd first, then the stored worktree', () => {
    expect(worktreeOf({ cwd: `${WT}/src` })).toBe(WT)
    expect(worktreeOf({ cwd: `${WT}/src`, worktree: '/q/.claude/worktrees/b' })).toBe(WT)
    expect(worktreeOf({ cwd: '/p', worktree: WT })).toBe(WT)
    expect(worktreeOf({ cwd: '', worktree: `${WT}/src` })).toBe(WT)
    expect(worktreeOf({ cwd: '/p' })).toBeNull()
    // A stored path that worktreeRoot refuses gives no worktree.
    for (const worktree of ['r/.claude/worktrees/a', '/r/x', '/r/.claude/worktrees/..']) {
      expect(worktreeOf({ cwd: '/p', worktree })).toBeNull()
    }
  })

  it('deleteCheck checks the stored worktree when the cwd is the start folder', async () => {
    const exec = fake(good())
    const a = createWorktreeActions({
      exec,
      rows: () => [row({ cwd: '/p', state: 'parked', worktree: WT })],
    })
    expect(await a.deleteCheck('s1')).toEqual({
      branch: 'worktree-fix-a',
      changedFiles: 2,
      unmergedCommits: 3,
      worktree: WT,
    })
    expect(exec.mock.calls[0]?.[1]).toEqual(STATUS(WT))
  })

  it('deleteCheck checks the stored worktree of a row with no cwd', async () => {
    const exec = fake(good())
    const a = createWorktreeActions({ exec, rows: () => [row({ cwd: '', worktree: WT })] })
    expect((await a.deleteCheck('s1'))?.worktree).toBe(WT)
  })

  it('openWorktree opens the stored worktree when the cwd is the start folder', async () => {
    const exec = fake([ok('')])
    const a = createWorktreeActions({
      exec,
      rows: () => [row({ cwd: '/p', state: 'parked', worktree: WT })],
    })
    await a.openWorktree('s1')
    expect(exec).toHaveBeenCalledWith(OPEN, [WT], { timeoutMs: 10000 })
  })
})

describe('checkWorktreeHead', () => {
  const HEAD = 'f7698d38614ba22b41f996fab73124361d2fe389'

  it('gives the counts and the HEAD commit of the worktree', async () => {
    const exec = fake([...good(), ok(`${HEAD}\n`)])
    expect(await checkWorktreeHead(WT, exec)).toEqual({
      branch: 'worktree-fix-a',
      changedFiles: 2,
      head: HEAD,
      unmergedCommits: 3,
      worktree: WT,
    })
    expect(exec.mock.calls.at(-1)).toEqual([
      'git',
      ['-C', WT, 'rev-parse', 'HEAD'],
      { timeoutMs: 5000 },
    ])
  })

  it('gives null when the HEAD read fails or gives no commit', async () => {
    const timeout: ExecResult = { code: 0, stderr: '', stdout: '', timedOut: true }
    for (const last of [
      fail,
      timeout,
      new Error('spawn'),
      ok(''),
      ok('abc\n'),
      ok(HEAD.toUpperCase()),
    ]) {
      expect(await settled(checkWorktreeHead(WT, fake([...good(), last])))).toBeNull()
    }
  })

  it('gives null for a failed check and for a folder outside .claude/worktrees', async () => {
    const failed = fake([fail, fail])
    expect(await settled(checkWorktreeHead(WT, failed))).toBeNull()
    expect(failed).toHaveBeenCalledTimes(2)
    const exec = fake([])
    expect(await checkWorktreeHead('/r', exec)).toBeNull()
    expect(exec).not.toHaveBeenCalled()
  })
})
