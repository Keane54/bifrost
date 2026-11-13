import { EventEmitter } from 'node:events'
import { PassThrough } from 'node:stream'
import { expect, test, vi } from 'vitest'
import { createSpawnLines } from '../../../src/main/claude/spawn-lines'

// A fake child. kill ends the child with a close event, like a real child.
function fakeChild() {
  const child = new EventEmitter() as EventEmitter & {
    stdout: PassThrough
    kill: ReturnType<typeof vi.fn>
  }
  child.stdout = new PassThrough()
  child.kill = vi.fn(() => {
    setImmediate(() => child.emit('close', null))
    return true
  })
  return child
}

function setup() {
  const child = fakeChild()
  const spawn = vi.fn(() => child)
  const run = createSpawnLines(spawn as never, '/bin/claude', { CLAUDECODE: '1', HOME: '/h' })
  return { child, run, spawn }
}

test('spawn-lines stops the child when onLine returns true', async () => {
  const { child, run } = setup()
  const lines: string[] = []
  const promise = run(['-p'], {
    cwd: '/w',
    onLine: line => {
      lines.push(line)
      return line === 'b'
    },
    timeoutMs: 5000,
  })
  child.stdout.write('a\nb\nc\n')
  const result = await promise
  expect(child.kill).toHaveBeenCalledWith('SIGTERM')
  expect(lines).toEqual(['a', 'b'])
  expect(result).toEqual({ code: null, stopped: true, timedOut: false })
})

test('spawn-lines gives each line once across chunk breaks', async () => {
  const { child, run } = setup()
  const lines: string[] = []
  const promise = run([], {
    cwd: '/w',
    onLine: line => {
      lines.push(line)
      return false
    },
    timeoutMs: 5000,
  })
  child.stdout.write('{"a":')
  child.stdout.write('1}\nsec')
  child.stdout.write('ond\nlast')
  child.stdout.end()
  await new Promise(r => setImmediate(r))
  child.emit('close', 0)
  const result = await promise
  expect(lines).toEqual(['{"a":1}', 'second', 'last'])
  expect(result).toEqual({ code: 0, stopped: false, timedOut: false })
  expect(child.kill).not.toHaveBeenCalled()
})

test('spawn-lines kills and reports timedOut after the time limit', async () => {
  const { child, run } = setup()
  const result = await run([], { cwd: '/w', onLine: () => false, timeoutMs: 20 })
  expect(child.kill).toHaveBeenCalledWith('SIGTERM')
  expect(result.timedOut).toBe(true)
  expect(result.stopped).toBe(false)
})

test('spawn-lines passes the clean child env and ignores stdin', async () => {
  const { child, run, spawn } = setup()
  const promise = run(['-p', 'x'], { cwd: '/w', onLine: () => false, timeoutMs: 5000 })
  child.emit('close', 0)
  await promise
  const call = spawn.mock.calls[0] as unknown as [string, string[], Record<string, unknown>]
  expect(call[0]).toBe('/bin/claude')
  expect(call[1]).toEqual(['-p', 'x'])
  expect(call[2].cwd).toBe('/w')
  expect(call[2].env).toEqual({ HOME: '/h' })
  expect((call[2].stdio as string[])[0]).toBe('ignore')
})

test('spawn-lines reports a spawn error as a null code', async () => {
  const { child, run } = setup()
  const promise = run([], { cwd: '/w', onLine: () => false, timeoutMs: 5000 })
  child.emit('error', new Error('ENOENT'))
  expect(await promise).toEqual({ code: null, stopped: false, timedOut: false })
})

test('spawn-lines sends SIGKILL and settles when the child ignores SIGTERM', async () => {
  vi.useFakeTimers()
  try {
    const { child, run } = setup()
    child.kill = vi.fn(() => true)
    let settled = false
    const promise = run([], { cwd: '/w', onLine: () => false, timeoutMs: 1000 }).then(r => {
      settled = true
      return r
    })
    await vi.advanceTimersByTimeAsync(1000)
    expect(child.kill).toHaveBeenCalledWith('SIGTERM')
    expect(settled).toBe(false)
    await vi.advanceTimersByTimeAsync(2000)
    expect(child.kill).toHaveBeenCalledWith('SIGKILL')
    expect(await promise).toEqual({ code: null, stopped: false, timedOut: true })
    expect(vi.getTimerCount()).toBe(0)
  } finally {
    vi.useRealTimers()
  }
})

test('spawn-lines resolves with a null code when spawn throws', async () => {
  const run = createSpawnLines(
    (() => {
      throw new Error('EACCES')
    }) as never,
    '/bin/claude',
    {},
  )
  expect(await run([], { cwd: '/w', onLine: () => false, timeoutMs: 5000 })).toEqual({
    code: null,
    stopped: false,
    timedOut: false,
  })
})

test('spawn-lines stops the child on abort with SIGTERM, then SIGKILL', async () => {
  vi.useFakeTimers()
  try {
    const { child, run } = setup()
    child.kill = vi.fn(() => true)
    const controller = new AbortController()
    const lines: string[] = []
    const promise = run([], {
      cwd: '/w',
      onLine: line => {
        lines.push(line)
        return false
      },
      signal: controller.signal,
      timeoutMs: 60_000,
    })
    child.stdout.write('a\n')
    await vi.advanceTimersByTimeAsync(0)
    controller.abort()
    expect(child.kill).toHaveBeenCalledWith('SIGTERM')
    child.stdout.write('b\n')
    await vi.advanceTimersByTimeAsync(2000)
    expect(child.kill).toHaveBeenCalledWith('SIGKILL')
    expect(await promise).toEqual({ aborted: true, code: null, stopped: false, timedOut: false })
    expect(lines).toEqual(['a'])
    expect(vi.getTimerCount()).toBe(0)
  } finally {
    vi.useRealTimers()
  }
})

test('spawn-lines ends at once on abort when the child ends on SIGTERM', async () => {
  const { child, run } = setup()
  const controller = new AbortController()
  const promise = run([], {
    cwd: '/w',
    onLine: () => false,
    signal: controller.signal,
    timeoutMs: 60_000,
  })
  controller.abort()
  expect(await promise).toEqual({ aborted: true, code: null, stopped: false, timedOut: false })
  expect(child.kill).toHaveBeenCalledTimes(1)
})

test('spawn-lines with an aborted signal starts no child', async () => {
  const { run, spawn } = setup()
  const controller = new AbortController()
  controller.abort()
  const result = await run([], {
    cwd: '/w',
    onLine: () => false,
    signal: controller.signal,
    timeoutMs: 5000,
  })
  expect(spawn).not.toHaveBeenCalled()
  expect(result).toEqual({ aborted: true, code: null, stopped: false, timedOut: false })
})
