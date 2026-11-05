import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ExecFn } from '../../../src/main/claude/cli'
import {
  chatSessionOf,
  parsePsTty,
  parseSttySize,
  psTtyArgs,
  readSessionSize,
  SessionSizeWatcher,
  sttyArgs,
} from '../../../src/main/pty/session-size'

describe('parsePsTty', () => {
  it('gives the device path and refuses ?? and other text', () => {
    expect(parsePsTty('ttys012\n')).toBe('/dev/ttys012')
    expect(parsePsTty('??\n')).toBeNull()
    expect(parsePsTty('')).toBeNull()
    expect(parsePsTty('../etc\n')).toBeNull()
  })
})

describe('parseSttySize', () => {
  it('reads rows, then cols', () => {
    expect(parseSttySize('32 120\n')).toEqual({ cols: 120, rows: 32 })
    expect(parseSttySize('0 0')).toBeNull()
    expect(parseSttySize('x')).toBeNull()
    expect(parseSttySize('32')).toBeNull()
  })
})

describe('readSessionSize', () => {
  it('runs ps, then stty -f <device> size', async () => {
    const calls: Array<[string, string[]]> = []
    const exec: ExecFn = async (file, args) => {
      calls.push([file, args])
      return file === '/bin/ps'
        ? { code: 0, stderr: '', stdout: 'ttys012\n' }
        : { code: 0, stderr: '', stdout: '32 120\n' }
    }
    expect(await readSessionSize(exec, 672)).toEqual({ cols: 120, rows: 32 })
    expect(calls).toEqual([
      ['/bin/ps', ['-o', 'tty=', '-p', '672']],
      ['/bin/stty', ['-f', '/dev/ttys012', 'size']],
    ])
    expect(psTtyArgs(672)).toEqual(calls[0][1])
    expect(sttyArgs('/dev/ttys012')).toEqual(calls[1][1])
  })

  it('gives null when ps finds no TTY', async () => {
    const calls: string[] = []
    const exec: ExecFn = async file => {
      calls.push(file)
      return { code: 0, stderr: '', stdout: '??\n' }
    }
    expect(await readSessionSize(exec, 672)).toBeNull()
    expect(calls).toEqual(['/bin/ps'])
  })
})

describe('chatSessionOf', () => {
  it('reads the session ID of a chat view only', () => {
    expect(chatSessionOf('chat:abc')).toBe('abc')
    expect(chatSessionOf('chat:')).toBeNull()
    expect(chatSessionOf('term:abc')).toBeNull()
  })
})

describe('SessionSizeWatcher', () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => vi.useRealTimers())

  const S1 = { cols: 120, rows: 32 }
  const S2 = { cols: 80, rows: 24 }

  it('reads one time after a burst of pokes', async () => {
    const read = vi.fn().mockResolvedValue(S1)
    const emit = vi.fn()
    const w = new SessionSizeWatcher({ emit, pidOf: () => 5, read }, 150)
    w.poke('chat:a')
    await vi.advanceTimersByTimeAsync(100)
    w.poke('chat:a')
    await vi.advanceTimersByTimeAsync(100)
    w.poke('chat:a')
    expect(read).not.toHaveBeenCalled()
    await vi.advanceTimersByTimeAsync(150)
    expect(read).toHaveBeenCalledTimes(1)
    expect(read).toHaveBeenCalledWith(5)
    expect(emit).toHaveBeenCalledWith('chat:a', S1)
  })

  it('emits only a changed size', async () => {
    const read = vi
      .fn()
      .mockResolvedValueOnce(S1)
      .mockResolvedValueOnce(S1)
      .mockResolvedValueOnce(S2)
    const emit = vi.fn()
    const w = new SessionSizeWatcher({ emit, pidOf: () => 5, read }, 150)
    for (let i = 0; i < 3; i++) {
      w.poke('chat:a')
      await vi.advanceTimersByTimeAsync(200)
    }
    expect(read).toHaveBeenCalledTimes(3)
    expect(emit.mock.calls).toEqual([
      ['chat:a', S1],
      ['chat:a', S2],
    ])
  })

  it('ignores a view without a pid and forgets a view', async () => {
    const read = vi.fn().mockResolvedValue(S1)
    const emit = vi.fn()
    let pid: number | undefined
    const w = new SessionSizeWatcher({ emit, pidOf: () => pid, read }, 150)
    w.poke('chat:a')
    await vi.advanceTimersByTimeAsync(200)
    expect(read).not.toHaveBeenCalled()
    pid = 7
    w.poke('chat:a')
    await vi.advanceTimersByTimeAsync(200)
    expect(emit).toHaveBeenCalledTimes(1)
    // After forget, the same size emits again.
    w.forget('chat:a')
    w.poke('chat:a')
    await vi.advanceTimersByTimeAsync(200)
    expect(emit).toHaveBeenCalledTimes(2)
    // A poke before forget gives no read.
    w.poke('chat:a')
    w.forget('chat:a')
    await vi.advanceTimersByTimeAsync(200)
    expect(read).toHaveBeenCalledTimes(2)
  })

  it('forget clears the last size and the timer, so a new page gets the size again', async () => {
    const read = vi.fn().mockResolvedValue(S1)
    const emit = vi.fn()
    const w = new SessionSizeWatcher({ emit, pidOf: () => 5, read }, 150)
    w.poke('chat:a')
    await vi.advanceTimersByTimeAsync(200)
    w.poke('chat:a')
    w.forget('chat:a')
    await vi.advanceTimersByTimeAsync(200)
    expect(read).toHaveBeenCalledTimes(1)
    w.poke('chat:a')
    await vi.advanceTimersByTimeAsync(200)
    expect(emit).toHaveBeenCalledTimes(2)
  })

  it('runs one read at a time for a view', async () => {
    let release: (s: typeof S1) => void = () => {}
    const read = vi
      .fn()
      .mockImplementationOnce(() => new Promise(r => (release = r)))
      .mockResolvedValue(S2)
    const emit = vi.fn()
    const w = new SessionSizeWatcher({ emit, pidOf: () => 5, read }, 150)
    w.poke('chat:a')
    await vi.advanceTimersByTimeAsync(200)
    w.poke('chat:a')
    await vi.advanceTimersByTimeAsync(200)
    expect(read).toHaveBeenCalledTimes(1)
    release(S1)
    await vi.advanceTimersByTimeAsync(200)
    expect(read).toHaveBeenCalledTimes(2)
    expect(emit.mock.calls.map(c => c[1])).toEqual([S1, S2])
  })
})
