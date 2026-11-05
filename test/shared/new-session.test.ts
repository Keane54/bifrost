import { describe, expect, test } from 'vitest'
import { MAX_TEXT, REASON_TOO_LONG } from '../../src/shared/input'
import {
  checkNewSessionSpec,
  MAX_NAME,
  MODEL_CHOICES,
  PERMISSION_MODES,
  WORKTREE_OK,
  worktreeName,
} from '../../src/shared/new-session'

const spec = (o: Record<string, unknown> = {}): Record<string, unknown> => ({
  cwd: '/p',
  model: 'haiku',
  name: 'bifrost-test-n',
  permissionMode: 'plan',
  prompt: 'Reply',
  worktree: false,
  ...o,
})

const reason = (input: unknown): string | null => {
  const result = checkNewSessionSpec(input)
  return result.ok ? null : result.reason
}

describe('new session values', () => {
  test('the lists hold the Task 1 rulings and no bypassPermissions', () => {
    expect(MODEL_CHOICES).toEqual([
      { label: 'Default', value: '' },
      { label: 'Opus', value: 'opus' },
      { label: 'Sonnet', value: 'sonnet' },
      { label: 'Haiku', value: 'haiku' },
    ])
    expect(PERMISSION_MODES).toEqual(['acceptEdits', 'auto', 'manual', 'dontAsk', 'plan'])
    expect(PERMISSION_MODES).not.toContain('bypassPermissions')
    expect(WORKTREE_OK).toBe(true)
    expect(MAX_NAME).toBe(64)
  })

  test('checkNewSessionSpec accepts a full spec and gives clean values', () => {
    expect(
      checkNewSessionSpec(
        spec({ cwd: ' /p/ ', name: '  n1\x1b ', prompt: ' Reply\r\nnow\x07 ', worktree: true }),
      ),
    ).toEqual({
      ok: true,
      spec: {
        cwd: '/p',
        model: 'haiku',
        name: 'n1',
        permissionMode: 'plan',
        prompt: 'Reply\nnow',
        worktree: true,
      },
    })
  })

  test('checkNewSessionSpec accepts the defaults and keeps the root directory', () => {
    expect(
      checkNewSessionSpec(spec({ cwd: '/', model: '', permissionMode: '', prompt: '   ' })),
    ).toEqual({
      ok: true,
      spec: {
        cwd: '/',
        model: '',
        name: 'bifrost-test-n',
        permissionMode: '',
        prompt: '',
        worktree: false,
      },
    })
    expect(checkNewSessionSpec(spec({ cwd: '/a/b//' }))).toMatchObject({ spec: { cwd: '/a/b' } })
    expect(checkNewSessionSpec(spec({ name: 'n'.repeat(64) })).ok).toBe(true)
    expect(checkNewSessionSpec(spec({ prompt: 'p'.repeat(MAX_TEXT) })).ok).toBe(true)
  })

  test('checkNewSessionSpec refuses each bad value with its reason', () => {
    const cases: [Record<string, unknown>, string][] = [
      [{ cwd: 'p' }, 'Select a project directory.'],
      [{ cwd: '' }, 'Select a project directory.'],
      [{ cwd: 7 }, 'Select a project directory.'],
      [{ name: '' }, 'Type a name.'],
      [{ name: ' \x1b ' }, 'Type a name.'],
      [{ name: 'n'.repeat(65) }, 'The name is too long. The maximum is 64 characters.'],
      [{ name: 'a\nb' }, 'The name has one line.'],
      [{ name: 'a\r\nb' }, 'The name has one line.'],
      [{ name: 'a\tb' }, 'The name has one line.'],
      [{ name: '-n' }, 'The name cannot start with "-".'],
      [{ name: 7 }, 'refused: bad new session data'],
      [{ model: 'gpt' }, 'refused: unknown model'],
      [{ model: undefined }, 'refused: unknown model'],
      [{ permissionMode: 'bogus' }, 'refused: unknown permission mode'],
      [{ permissionMode: 'bypassPermissions' }, 'refused: unknown permission mode'],
      [{ permissionMode: 3 }, 'refused: unknown permission mode'],
      [{ prompt: 'p'.repeat(MAX_TEXT + 1) }, REASON_TOO_LONG],
      [{ prompt: ' -x' }, 'The first prompt cannot start with "-".'],
      [{ prompt: null }, 'refused: bad new session data'],
      [{ worktree: 'yes' }, 'refused: bad new session data'],
    ]
    for (const [o, expected] of cases) expect(reason(spec(o)), JSON.stringify(o)).toBe(expected)
  })

  test('checkNewSessionSpec refuses data that is not an object', () => {
    for (const input of [null, undefined, 'x', 3, []]) {
      expect(reason(input)).toBe('refused: bad new session data')
    }
  })

  test('worktreeName makes a name that git accepts', () => {
    expect(worktreeName('My Session_1!')).toBe('my-session-1')
    expect(worktreeName('---')).toBe('session')
    expect(worktreeName('')).toBe('session')
    expect(worktreeName('bifrost-test-wt')).toBe('bifrost-test-wt')
    expect(worktreeName('..a//b..')).toBe('a-b')
    expect(worktreeName(`${'a'.repeat(39)} b`)).toBe('a'.repeat(39))
    expect(worktreeName('x'.repeat(50))).toBe('x'.repeat(40))
  })
})
