import { describe, expect, test, vi } from 'vitest'
import {
  KEYCHAIN_ARGS,
  KEYCHAIN_SERVICE,
  readAccessToken,
} from '../../../src/main/account-usage/token'
import type { ExecFn, ExecResult } from '../../../src/main/claude/cli'

const NOW = 1_800_000_000_000
// A fake secret. It is not a real token.
const FAKE = 'fake-access-token-for-tests'

const answer = (stdout: string, code = 0): ExecFn =>
  vi.fn(async () => ({ code, stderr: '', stdout }))
const json = (oauth: unknown): string => JSON.stringify({ claudeAiOauth: oauth })

describe('readAccessToken', () => {
  test('a good item gives the token', async () => {
    const exec = answer(json({ accessToken: FAKE, expiresAt: NOW + 60_000 }))
    expect(await readAccessToken(exec, NOW)).toBe(FAKE)
  })

  test('the command has fixed arguments and a 10 second limit', async () => {
    const exec = answer(json({ accessToken: FAKE, expiresAt: NOW + 1 }))
    await readAccessToken(exec, NOW)
    expect(exec).toHaveBeenCalledWith(
      '/usr/bin/security',
      ['find-generic-password', '-s', KEYCHAIN_SERVICE, '-w'],
      { timeoutMs: 10_000 },
    )
    expect(KEYCHAIN_ARGS).toEqual(['find-generic-password', '-s', 'Claude Code-credentials', '-w'])
  })

  test('an item without expiresAt still gives the token', async () => {
    expect(await readAccessToken(answer(json({ accessToken: FAKE })), NOW)).toBe(FAKE)
  })

  test('an expired token gives null', async () => {
    const exec = answer(json({ accessToken: FAKE, expiresAt: NOW - 1 }))
    expect(await readAccessToken(exec, NOW)).toBeNull()
    expect(
      await readAccessToken(answer(json({ accessToken: FAKE, expiresAt: NOW })), NOW),
    ).toBeNull()
  })

  test('each other shape gives null', async () => {
    const shapes = [
      '',
      'not json',
      '[]',
      'null',
      '{}',
      JSON.stringify({ claudeAiOauth: null }),
      json({}),
      json({ accessToken: '' }),
      json({ accessToken: 7 }),
      json({ accessToken: FAKE, expiresAt: 'soon' }),
      json({ accessToken: FAKE, expiresAt: Number.NaN }),
    ]
    for (const stdout of shapes) expect(await readAccessToken(answer(stdout), NOW)).toBeNull()
  })

  test('a failed command gives null', async () => {
    const failed: ExecResult = { code: 44, stderr: FAKE, stdout: json({ accessToken: FAKE }) }
    expect(await readAccessToken(async () => failed, NOW)).toBeNull()
    const timed: ExecResult = { code: 1, stderr: '', stdout: '', timedOut: true }
    expect(await readAccessToken(async () => timed, NOW)).toBeNull()
  })

  test('a throw from exec gives null and the result never holds the input', async () => {
    const exec: ExecFn = async () => {
      throw new Error(`boom ${FAKE}`)
    }
    const result = await readAccessToken(exec, NOW)
    expect(result).toBeNull()
  })

  test('the reader never writes to the console', async () => {
    const spies = (['log', 'error', 'warn', 'info', 'debug'] as const).map(m =>
      vi.spyOn(console, m).mockImplementation(() => {}),
    )
    await readAccessToken(answer(json({ accessToken: FAKE, expiresAt: NOW - 1 })), NOW)
    await readAccessToken(answer(`not json ${FAKE}`), NOW)
    await readAccessToken(async () => {
      throw new Error(FAKE)
    }, NOW)
    for (const spy of spies) {
      expect(spy).not.toHaveBeenCalled()
      spy.mockRestore()
    }
  })
})
