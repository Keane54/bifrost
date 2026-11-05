import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'
import {
  dirInfo,
  isAlive,
  isSafePid,
  PROBE_TIMEOUT_MS,
  processName,
  sendSignal,
} from '../../../src/main/actions/process-info'
import type { ExecFn, ExecResult } from '../../../src/main/claude/cli'

// A fake kill. It records each call. It sends no signal.
function fakeKill(code?: string) {
  const calls: [number, string | number][] = []
  const kill = (pid: number, signal: string | number): void => {
    calls.push([pid, signal])
    if (code !== undefined) throw Object.assign(new Error(code), { code })
  }
  return { calls, kill }
}

function fakeExec(result: ExecResult) {
  const calls: [string, string[], unknown][] = []
  const exec: ExecFn = async (file, args, opts) => {
    calls.push([file, args, opts])
    return result
  }
  return { calls, exec }
}

const BAD_PIDS = [0, -1, 1, 1.5, Number.NaN]

describe('process info', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  test('isSafePid accepts only an integer above 1', () => {
    expect(isSafePid(4242)).toBe(true)
    expect(isSafePid(2)).toBe(true)
    for (const pid of BAD_PIDS) expect(isSafePid(pid), String(pid)).toBe(false)
  })

  test('sendSignal refuses a bad PID and does not call kill', () => {
    const k = fakeKill()
    for (const pid of BAD_PIDS) {
      expect(() => sendSignal(k.kill, pid, 'SIGTERM')).toThrow('refused: bad process ID')
    }
    expect(k.calls).toEqual([])
    sendSignal(k.kill, 4242, 'SIGTERM')
    expect(k.calls).toEqual([[4242, 'SIGTERM']])
  })

  test('isAlive uses signal 0: ESRCH gives false, EPERM and other errors give true', () => {
    const live = fakeKill()
    expect(isAlive(live.kill, 4242)).toBe(true)
    expect(live.calls).toEqual([[4242, 0]])
    expect(isAlive(fakeKill('ESRCH').kill, 4242)).toBe(false)
    expect(isAlive(fakeKill('EPERM').kill, 4242)).toBe(true)
    expect(isAlive(fakeKill('EINVAL').kill, 4242)).toBe(true)
  })

  test('isAlive gives true for a bad PID and does not call kill', () => {
    // True is the safe value: Take control then starts no copy.
    const k = fakeKill('ESRCH')
    for (const pid of BAD_PIDS) expect(isAlive(k.kill, pid)).toBe(true)
    expect(k.calls).toEqual([])
  })

  test('processName reads the comm of the PID with ps', async () => {
    const ok = fakeExec({ code: 0, stderr: '', stdout: '/Users/x/.local/bin/claude\n' })
    await expect(processName(ok.exec, 4242)).resolves.toBe('/Users/x/.local/bin/claude')
    expect(ok.calls).toEqual([
      ['/bin/ps', ['-o', 'comm=', '-p', '4242'], { timeoutMs: PROBE_TIMEOUT_MS }],
    ])
    const gone = fakeExec({ code: 1, stderr: '', stdout: '' })
    await expect(processName(gone.exec, 4242)).resolves.toBeNull()
    const empty = fakeExec({ code: 0, stderr: '', stdout: ' \n' })
    await expect(processName(empty.exec, 4242)).resolves.toBeNull()
    const bad = fakeExec({ code: 0, stderr: '', stdout: 'claude' })
    await expect(processName(bad.exec, -1)).resolves.toBeNull()
    expect(bad.calls).toEqual([])
  })

  test('dirInfo gives the kind of the path and the git result for a directory', async () => {
    const git = fakeExec({ code: 0, stderr: '', stdout: '/p\n' })
    const dir = async () => ({ isDirectory: () => true })
    await expect(dirInfo(git.exec, dir, '/p')).resolves.toEqual({ git: true, kind: 'dir' })
    expect(git.calls).toEqual([
      ['git', ['-C', '/p', 'rev-parse', '--show-toplevel'], { timeoutMs: PROBE_TIMEOUT_MS }],
    ])
    const noGit = fakeExec({ code: 128, stderr: 'not a git repository', stdout: '' })
    await expect(dirInfo(noGit.exec, dir, '/p')).resolves.toEqual({ git: false, kind: 'dir' })
    const file = fakeExec({ code: 0, stderr: '', stdout: '' })
    await expect(
      dirInfo(file.exec, async () => ({ isDirectory: () => false }), '/f'),
    ).resolves.toEqual({
      git: false,
      kind: 'other',
    })
    const missing = async () => {
      throw Object.assign(new Error('ENOENT'), { code: 'ENOENT' })
    }
    await expect(dirInfo(file.exec, missing, '/m')).resolves.toEqual({
      git: false,
      kind: 'missing',
    })
    // git runs only for a directory.
    expect(file.calls).toEqual([])
  })

  test('dirInfo gives missing when the stat does not end in 2 seconds', async () => {
    const git = fakeExec({ code: 0, stderr: '', stdout: '' })
    const hung = () => new Promise<{ isDirectory(): boolean }>(() => {})
    let result: unknown
    void dirInfo(git.exec, hung, '/Volumes/offline').then(r => {
      result = r
    })
    await vi.advanceTimersByTimeAsync(PROBE_TIMEOUT_MS - 1)
    expect(result).toBeUndefined()
    await vi.advanceTimersByTimeAsync(1)
    expect(result).toEqual({ git: false, kind: 'missing' })
    expect(git.calls).toEqual([])
  })
})
