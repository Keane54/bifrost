import { expect, test, vi } from 'vitest'
import {
  checkClaudeVersion,
  compareVersions,
  parseClaudeVersion,
} from '../../../src/main/claude/version'

test('checkClaudeVersion compares with the minimum', async () => {
  const run = vi.fn().mockResolvedValue({ code: 0, stderr: '', stdout: '2.1.200 (Claude Code)\n' })
  expect(await checkClaudeVersion(run)).toEqual({
    minimum: '2.1.281',
    ok: false,
    version: '2.1.200',
  })
  expect(compareVersions('2.1.318', '2.1.281')).toBeGreaterThan(0)
  expect(compareVersions('2.10.0', '2.9.9')).toBeGreaterThan(0)
  expect(compareVersions('2.1.281', '2.1.281')).toBe(0)
})

test('checkClaudeVersion accepts the minimum and a newer version', async () => {
  const run = vi.fn().mockResolvedValue({ code: 0, stderr: '', stdout: '2.1.281 (Claude Code)\n' })
  expect((await checkClaudeVersion(run)).ok).toBe(true)
})

test('checkClaudeVersion gives a null version when the run fails or the text is odd', async () => {
  const failing = vi.fn().mockResolvedValue({ code: 1, stderr: 'x', stdout: '' })
  expect(await checkClaudeVersion(failing)).toEqual({
    minimum: '2.1.281',
    ok: false,
    version: null,
  })
  expect(parseClaudeVersion('hello')).toBeNull()
})
