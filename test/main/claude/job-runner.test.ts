// The runner of the module jobs of the modules (plan Task 7). It starts claude in its own process
// group, gives the text on stdin, and kills the whole group at the timeout, at an abort and at
// the output limit.
import type { spawn as nodeSpawn } from 'node:child_process'
import { EventEmitter } from 'node:events'
import { tmpdir } from 'node:os'
import { PassThrough } from 'node:stream'
import { afterEach, expect, test, vi } from 'vitest'
import {
  createRunClaudeJob,
  JOB_KILL_GRACE_MS,
  type JobRunOptions,
} from '../../../src/main/claude/job-runner'

class FakeChild extends EventEmitter {
  pid: number | undefined = 4242
  stdout = new PassThrough()
  stderr = new PassThrough()
  stdin = new PassThrough()
}

function fakeSpawn() {
  const child = new FakeChild()
  const calls: { file: string; args: string[]; opts: unknown }[] = []
  const kills: [number, string][] = []
  const spawn = ((file: string, args: string[], opts: unknown) => {
    calls.push({ args, file, opts })
    return child
  }) as unknown as typeof nodeSpawn
  const kill = (pid: number, signal: NodeJS.Signals): void => {
    kills.push([pid, signal])
  }
  return { calls, child, kill, kills, spawn }
}

function options(over: Partial<JobRunOptions> = {}): JobRunOptions {
  return {
    cwd: '/w',
    input: 'Sum it',
    maxBuffer: 1000,
    signal: new AbortController().signal,
    timeoutMs: 5000,
    ...over,
  }
}

// Let the streams give their data.
const tick = (): Promise<void> => new Promise(resolve => setImmediate(resolve))

afterEach(() => {
  vi.useRealTimers()
})

test('starts claude in its own process group, with the clean env and stdin', async () => {
  const f = fakeSpawn()
  const stdin: string[] = []
  f.child.stdin.on('data', chunk => stdin.push(String(chunk)))
  const env = { CLAUDECODE: '1', PATH: '/login' }
  const deps = { kill: f.kill, spawn: f.spawn }
  const run = createRunClaudeJob('/bin/claude', env, deps)(['-p'], options())
  f.child.stdout.write('{"is_error":false}')
  f.child.stderr.write('a note')
  await tick()
  f.child.emit('close', 0, null)
  await expect(run).resolves.toEqual({ code: 0, stderr: 'a note', stdout: '{"is_error":false}' })
  expect(f.calls).toEqual([
    {
      args: ['-p'],
      file: '/bin/claude',
      opts: {
        cwd: '/w',
        detached: true,
        env: { PATH: '/login' },
        stdio: ['pipe', 'pipe', 'pipe'],
      },
    },
  ])
  expect(stdin.join('')).toBe('Sum it')
  expect(f.kills).toEqual([])
})

test('kills the whole process group at the timeout', async () => {
  vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] })
  const f = fakeSpawn()
  const run = createRunClaudeJob('/c', {}, f)(['-p'], options({ timeoutMs: 100 }))
  vi.advanceTimersByTime(99)
  expect(f.kills).toEqual([])
  vi.advanceTimersByTime(1)
  expect(f.kills).toEqual([[-4242, 'SIGKILL']])
  f.child.emit('close', null, 'SIGKILL')
  await expect(run).resolves.toEqual({ code: 1, stderr: '', stdout: '', timedOut: true })
})

test('kills the whole process group at an abort, and starts nothing after an abort', async () => {
  const f = fakeSpawn()
  const abort = new AbortController()
  const run = createRunClaudeJob('/c', {}, f)(['-p'], options({ signal: abort.signal }))
  abort.abort()
  expect(f.kills).toEqual([[-4242, 'SIGKILL']])
  f.child.emit('close', null, 'SIGKILL')
  await expect(run).resolves.toMatchObject({ aborted: true, code: 1 })
  const later = fakeSpawn()
  const again = createRunClaudeJob('/c', {}, later)(['-p'], options({ signal: abort.signal }))
  await expect(again).resolves.toMatchObject({ aborted: true, code: 1 })
  expect(later.calls).toEqual([])
})

test('kills the whole process group when the output is over the limit', async () => {
  const f = fakeSpawn()
  const run = createRunClaudeJob('/c', {}, f)(['-p'], options({ maxBuffer: 5 }))
  f.child.stdout.write('0123456789')
  await tick()
  expect(f.kills).toEqual([[-4242, 'SIGKILL']])
  f.child.emit('close', null, 'SIGKILL')
  await expect(run).resolves.toMatchObject({ code: 1, overflow: true })
})

test('ends the run after a kill, also when the pipes stay open', async () => {
  vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] })
  const f = fakeSpawn()
  const run = createRunClaudeJob('/c', {}, f)(['-p'], options({ timeoutMs: 10 }))
  vi.advanceTimersByTime(10)
  vi.advanceTimersByTime(JOB_KILL_GRACE_MS)
  await expect(run).resolves.toMatchObject({ code: 1, timedOut: true })
})

test('gives a failed result when claude cannot start, and a gone group is no error', async () => {
  const f = fakeSpawn()
  const run = createRunClaudeJob('/c', {}, f)(['-p'], options())
  f.child.emit('error', new Error('spawn /c ENOENT'))
  await expect(run).resolves.toEqual({ code: 1, stderr: 'spawn /c ENOENT', stdout: '' })
  const throws = {
    kill: () => {
      throw new Error('ESRCH')
    },
    spawn: (() => {
      throw new Error('EAGAIN')
    }) as unknown as typeof nodeSpawn,
  }
  await expect(createRunClaudeJob('/c', {}, throws)(['-p'], options())).resolves.toEqual({
    code: 1,
    stderr: 'Error: EAGAIN',
    stdout: '',
  })
  const gone = fakeSpawn()
  const abort = new AbortController()
  const deps = { kill: throws.kill, spawn: gone.spawn }
  const stopped = createRunClaudeJob('/c', {}, deps)(['-p'], options({ signal: abort.signal }))
  expect(() => abort.abort()).not.toThrow()
  gone.child.emit('close', null, 'SIGKILL')
  await expect(stopped).resolves.toMatchObject({ aborted: true })
})

test('a real program gets the text on stdin', async () => {
  const opts = options({ cwd: tmpdir(), input: 'a job text' })
  const result = await createRunClaudeJob('/bin/cat', {})([], opts)
  expect(result).toEqual({ code: 0, stderr: '', stdout: 'a job text' })
})

// The shell starts a sleep in the background, prints its pid and waits. The timeout must stop
// the sleep too, not only the shell.
test('a timeout stops each process of the group of a real program', async () => {
  const script = 'sleep 30 & echo $!; wait'
  const result = await createRunClaudeJob('/bin/sh', { PATH: '/bin:/usr/bin' })(
    ['-c', script],
    options({ cwd: tmpdir(), input: '', timeoutMs: 500 }),
  )
  expect(result.timedOut).toBe(true)
  const pid = Number(result.stdout.trim())
  expect(pid).toBeGreaterThan(0)
  let alive = true
  for (let i = 0; i < 100 && alive; i += 1) {
    try {
      process.kill(pid, 0)
      await new Promise(resolve => setTimeout(resolve, 20))
    } catch {
      alive = false
    }
  }
  expect(alive).toBe(false)
})
