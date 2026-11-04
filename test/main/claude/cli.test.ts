import { homedir } from 'node:os'
import { join } from 'node:path'
import { expect, test, vi } from 'vitest'
import { createRunClaude, resolveClaudePath } from '../../../src/main/claude/cli'

test('createRunClaude runs claude with the cwd and the clean child env', async () => {
  vi.stubEnv('CLAUDECODE', '1')
  vi.stubEnv('CLAUDE_CODE_SESSION_KIND', 'bash')
  vi.stubEnv('TERM_PROGRAM', 'WarpTerminal')
  vi.stubEnv('HOME', '/Users/test')
  try {
    const exec = vi.fn().mockResolvedValue({ code: 0, stdout: '', stderr: '' })
    await createRunClaude(exec, '/bin/claude')(['agents', '--json'], { cwd: '/tmp' })
    expect(exec).toHaveBeenCalledWith(
      '/bin/claude',
      ['agents', '--json'],
      expect.objectContaining({ cwd: '/tmp' })
    )
    const env = exec.mock.calls[0][2].env
    expect(env).not.toHaveProperty('CLAUDECODE')
    expect(env).not.toHaveProperty('CLAUDE_CODE_SESSION_KIND')
    expect(env).not.toHaveProperty('TERM_PROGRAM')
    expect(env.HOME).toBe('/Users/test')
  } finally {
    vi.unstubAllEnvs()
  }
})

test('resolveClaudePath asks an interactive login shell for the path', async () => {
  const exec = vi.fn().mockResolvedValue({ code: 0, stdout: '/Users/test/.local/bin/claude\n', stderr: '' })
  expect(await resolveClaudePath(exec, '/bin/zsh')).toBe('/Users/test/.local/bin/claude')
  expect(exec).toHaveBeenCalledWith('/bin/zsh', ['-lic', 'command -v claude'], expect.anything())
})
test('resolveClaudePath returns null when the shell and the fallback paths do not find claude', async () => {
  const exec = vi.fn().mockResolvedValue({ code: 1, stdout: '', stderr: '' })
  expect(await resolveClaudePath(exec, '/bin/zsh', () => false)).toBeNull()
})
test('resolveClaudePath uses the first executable fallback path when the shell fails', async () => {
  const exec = vi.fn().mockResolvedValue({ code: 1, stdout: '', stderr: '' })
  const local = join(homedir(), '.local/bin/claude')
  expect(await resolveClaudePath(exec, '/bin/zsh', (p) => p === local)).toBe(local)
})
test('resolveClaudePath does not check the fallback paths when the shell finds claude', async () => {
  const exec = vi.fn().mockResolvedValue({ code: 0, stdout: '/Users/test/.local/bin/claude\n', stderr: '' })
  const isExecutable = vi.fn().mockReturnValue(true)
  await resolveClaudePath(exec, '/bin/zsh', isExecutable)
  expect(isExecutable).not.toHaveBeenCalled()
})
