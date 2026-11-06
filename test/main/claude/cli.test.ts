import { homedir } from 'node:os'
import { join } from 'node:path'
import { expect, test, vi } from 'vitest'
import { createRunClaude, execFile, resolveClaudePath } from '../../../src/main/claude/cli'

test('execFile stops a program that ignores SIGTERM at the timeout', async () => {
  // exec keeps the ignored SIGTERM. So only SIGKILL can stop this sleep.
  const start = Date.now()
  const result = await execFile('/bin/sh', ['-c', 'trap "" TERM; exec sleep 5'], {
    timeoutMs: 200,
  })
  expect(Date.now() - start).toBeLessThan(1500)
  expect(result.code).not.toBe(0)
  expect(result.timedOut).toBe(true)
})

// This test does not depend on time. A real program can get the SIGTERM before its shell sets the
// trap, and under load that happened (the program then ends by the signal, with no code). So the
// test gives execFile a fake Node execFile: it checks that execFile passes the kill signal and the
// timeout of opts to Node, and that a program that the timeout stopped with code 7 gives code 7
// and timedOut.
test('execFile sends the kill signal of opts at the timeout and sets timedOut', async () => {
  const seen: unknown[] = []
  vi.resetModules()
  vi.doMock('node:child_process', async importOriginal => ({
    ...(await importOriginal<typeof import('node:child_process')>()),
    execFile: (
      _file: string,
      _args: string[],
      opts: unknown,
      done: (error: Error | null, stdout: string, stderr: string) => void,
    ) => {
      seen.push(opts)
      // Node sets killed when it sent the kill signal at the timeout. The program exited with 7.
      done(Object.assign(new Error('Command failed'), { code: 7, killed: true }), '', '')
    },
  }))
  try {
    const cli = await import('../../../src/main/claude/cli')
    const result = await cli.execFile('/bin/sh', ['-c', 'true'], {
      killSignal: 'SIGTERM',
      timeoutMs: 200,
    })
    expect(seen).toEqual([expect.objectContaining({ killSignal: 'SIGTERM', timeout: 200 })])
    expect(result).toEqual({ code: 7, stderr: '', stdout: '', timedOut: true })
  } finally {
    vi.doUnmock('node:child_process')
    vi.resetModules()
  }
})

test('execFile does not set timedOut for a program that exits with an error', async () => {
  const result = await execFile('/bin/sh', ['-c', 'exit 3'])
  expect(result.code).toBe(3)
  expect(result.timedOut).toBeUndefined()
})

test('createRunClaude uses the base env without the removed variables', async () => {
  const exec = vi.fn().mockResolvedValue({ code: 0, stderr: '', stdout: '' })
  await createRunClaude(exec, '/c', { CLAUDECODE: '1', PATH: '/login' })(['--version'])
  expect(exec.mock.calls[0][2].env).toEqual({ PATH: '/login' })
})

test('createRunClaude passes the args and the cwd to exec', async () => {
  const exec = vi.fn().mockResolvedValue({ code: 0, stderr: '', stdout: '' })
  await createRunClaude(exec, '/bin/claude', {})(['agents', '--json'], { cwd: '/tmp' })
  expect(exec).toHaveBeenCalledWith(
    '/bin/claude',
    ['agents', '--json'],
    expect.objectContaining({ cwd: '/tmp' }),
  )
})

test('resolveClaudePath asks an interactive login shell for the path', async () => {
  const exec = vi
    .fn()
    .mockResolvedValue({ code: 0, stderr: '', stdout: '/Users/test/.local/bin/claude\n' })
  expect(await resolveClaudePath(exec, '/bin/zsh')).toBe('/Users/test/.local/bin/claude')
  expect(exec).toHaveBeenCalledWith('/bin/zsh', ['-lic', 'command -v claude'], expect.anything())
})
test('resolveClaudePath returns null when the shell and the fallback paths do not find claude', async () => {
  const exec = vi.fn().mockResolvedValue({ code: 1, stderr: '', stdout: '' })
  expect(await resolveClaudePath(exec, '/bin/zsh', () => false)).toBeNull()
})
test('resolveClaudePath uses the first executable fallback path when the shell fails', async () => {
  const exec = vi.fn().mockResolvedValue({ code: 1, stderr: '', stdout: '' })
  const local = join(homedir(), '.local/bin/claude')
  expect(await resolveClaudePath(exec, '/bin/zsh', p => p === local)).toBe(local)
})
test('resolveClaudePath does not check the fallback paths when the shell finds claude', async () => {
  const exec = vi
    .fn()
    .mockResolvedValue({ code: 0, stderr: '', stdout: '/Users/test/.local/bin/claude\n' })
  const isExecutable = vi.fn().mockReturnValue(true)
  await resolveClaudePath(exec, '/bin/zsh', isExecutable)
  expect(isExecutable).not.toHaveBeenCalled()
})
