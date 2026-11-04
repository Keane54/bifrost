import { homedir } from 'node:os'
import { join } from 'node:path'
import { expect, test, vi } from 'vitest'
import { createRunClaude, resolveClaudePath } from '../../../src/main/claude/cli'

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
