import { expect, test, vi } from 'vitest'
import { resolveClaudePath } from '../../../src/main/claude/cli'

test('resolveClaudePath asks a login shell for the path', async () => {
  const exec = vi.fn().mockResolvedValue({ code: 0, stdout: '/Users/test/.local/bin/claude\n', stderr: '' })
  expect(await resolveClaudePath(exec, '/bin/zsh')).toBe('/Users/test/.local/bin/claude')
  expect(exec).toHaveBeenCalledWith('/bin/zsh', ['-lc', 'command -v claude'], expect.anything())
})
test('resolveClaudePath returns null when the shell does not find claude', async () => {
  const exec = vi.fn().mockResolvedValue({ code: 1, stdout: '', stderr: '' })
  expect(await resolveClaudePath(exec, '/bin/zsh')).toBeNull()
})
