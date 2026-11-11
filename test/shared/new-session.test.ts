import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, test } from 'vitest'
import { MAX_TEXT, REASON_TOO_LONG } from '../../src/shared/input'
import {
  CLAUDE_COMMANDS,
  checkNewSessionSpec,
  isClaudeCommand,
  MAX_NAME,
  MODEL_CHOICES,
  MODEL_VALUES,
  modelOptions,
  PERMISSION_MODES,
  REASON_DIR_CHECK,
  REASON_DIR_MISSING,
  REASON_NO_GIT,
  REASON_PROMPT_IS_COMMAND,
  REASON_WORKTREE_OFF,
  WORKTREE_OK,
  worktreeName,
} from '../../src/shared/new-session'

// The command names and aliases in the "Commands:" part of a claude help text.
// A name line starts with two spaces. A longer indent is the next line of a description.
function helpCommands(text: string): string[] {
  const lines = text.split('\n')
  const start = lines.findIndex(line => line.trim() === 'Commands:')
  const names: string[] = []
  for (const line of lines.slice(start + 1)) {
    if (line.trim() === '' || !line.startsWith(' ')) break
    const m = /^ {2}([a-z][a-z0-9-]*(?:\|[a-z][a-z0-9-]*)*)(?:\s|$)/.exec(line)
    if (m) names.push(...m[1].split('|'))
  }
  return names
}

const FIXTURE = readFileSync(join(__dirname, '../fixtures/claude-commands.txt'), 'utf8')

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

  test('CLAUDE_COMMANDS has each command and alias of the claude help text', () => {
    const names = helpCommands(FIXTURE)
    // The parse found the list. A broken parse gives few names.
    expect(names.length).toBeGreaterThan(15)
    expect(names).toEqual(expect.arrayContaining(['stop', 'kill', 'update', 'upgrade', 'rm']))
    expect(names.filter(name => !CLAUDE_COMMANDS.includes(name))).toEqual([])
    // The list also keeps the names of older versions.
    // The help text does not show "help" and the hidden commands. The list keeps them.
    expect(CLAUDE_COMMANDS).toEqual(expect.arrayContaining(['config', 'migrate-installer', 'help']))
  })

  test('helpCommands reads the commander help form', () => {
    const help = [
      'Usage: claude [options] [command] [prompt]',
      'Commands:',
      '  mcp                     Configure and manage MCP servers',
      '  install [options] [target]  Install Claude Code native build. Use [target]',
      '                          to specify version',
      '  stop|kill <id>          Stop a background session',
      '',
      'Examples:',
      '  claude agents',
    ].join('\n')
    expect(helpCommands(help)).toEqual(['mcp', 'install', 'stop', 'kill'])
  })

  test('isClaudeCommand matches only a whole command name after the trim', () => {
    for (const text of ['update', ' help ', 'stop', 'kill', 'rc', 'rm', 'migrate-installer']) {
      expect(isClaudeCommand(text), text).toBe(true)
    }
    for (const text of ['update the docs', 'Update', 'stopped', '', 'rm -rf']) {
      expect(isClaudeCommand(text), text).toBe(false)
    }
    expect(checkNewSessionSpec(spec({ prompt: 'update the docs' })).ok).toBe(true)
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
      [{ cwd: 'p' }, 'Choose a project folder.'],
      [{ cwd: '' }, 'Choose a project folder.'],
      [{ cwd: 7 }, 'Choose a project folder.'],
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
      [{ prompt: 'update' }, REASON_PROMPT_IS_COMMAND],
      [{ prompt: ' help\n' }, REASON_PROMPT_IS_COMMAND],
      [{ prompt: 'install' }, REASON_PROMPT_IS_COMMAND],
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

describe('in-app texts', () => {
  test('the shared texts are plain English with the word folder', () => {
    expect(REASON_WORKTREE_OFF).toBe(
      "Worktrees don't work with background sessions in this version of Claude Code.",
    )
    expect(REASON_DIR_CHECK).toBe('Checking the folder...')
    expect(REASON_DIR_MISSING).toBe("This folder doesn't exist.")
    expect(REASON_NO_GIT).toBe("This folder isn't in a git repository, so it can't use a worktree.")
    const empty = checkNewSessionSpec({ cwd: '' })
    expect(empty).toEqual({ ok: false, reason: 'Choose a project folder.' })
  })
})

describe('model options', () => {
  test('MODEL_VALUES comes from MODEL_CHOICES', () => {
    expect(MODEL_VALUES).toEqual(['', 'opus', 'sonnet', 'haiku'])
  })

  test('modelOptions names the empty value Claude Code default', () => {
    expect(modelOptions()).toEqual([
      { label: 'Claude Code default', value: '' },
      { label: 'Opus', value: 'opus' },
      { label: 'Sonnet', value: 'sonnet' },
      { label: 'Haiku', value: 'haiku' },
    ])
  })
})
