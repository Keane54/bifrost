import { expect, test, vi } from 'vitest'
import { readBranch } from '../../../src/main/registry/git-branch'

test('readBranch returns the trimmed branch or null', async () => {
  const exec = vi.fn().mockResolvedValue({ code: 0, stderr: '', stdout: 'main\n' })
  expect(await readBranch(exec, '/p')).toBe('main')
  expect(exec).toHaveBeenCalledWith('git', ['-C', '/p', 'rev-parse', '--abbrev-ref', 'HEAD'], {
    timeoutMs: 2000,
  })
  const failing = vi.fn().mockResolvedValue({ code: 128, stderr: 'fatal', stdout: '' })
  expect(await readBranch(failing, '/p')).toBeNull()
})
