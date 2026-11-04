import { expect, test } from 'vitest'
import { childEnv } from '../../src/main/child-env'

// An env as Bifrost gets it when a Claude Code Bash tool in Warp runs "pnpm dev".
const SOURCE: NodeJS.ProcessEnv = {
  HOME: '/Users/test',
  PATH: '/usr/bin:/bin',
  USER: 'test',
  SHELL: '/bin/zsh',
  LANG: 'en_GB.UTF-8',
  TERM: 'dumb',
  CLAUDE_CONFIG_DIR: '/Users/test/.claude',
  ANTHROPIC_MODEL: 'haiku',
  CLAUDECODE: '1',
  CLAUDE_CODE_ENTRYPOINT: 'cli',
  CLAUDE_CODE_CHILD_SESSION: '1',
  CLAUDE_CODE_SESSION_KIND: 'bash',
  TERM_PROGRAM: 'WarpTerminal',
  TERM_PROGRAM_VERSION: 'v0.2026',
  TERM_SESSION_ID: 'abc',
  WARP_IS_LOCAL_SHELL_SESSION: '1',
  WARP_HONOR_PS1: '0',
  UNSET: undefined
}

const REMOVED = [
  'CLAUDECODE',
  'CLAUDE_CODE_ENTRYPOINT',
  'CLAUDE_CODE_CHILD_SESSION',
  'CLAUDE_CODE_SESSION_KIND',
  'TERM_PROGRAM',
  'TERM_PROGRAM_VERSION',
  'TERM_SESSION_ID',
  'WARP_IS_LOCAL_SHELL_SESSION',
  'WARP_HONOR_PS1'
]

test('childEnv removes the Claude Code, terminal program and Warp variables', () => {
  for (const pty of [true, false]) {
    const env = childEnv(SOURCE, { pty })
    for (const key of REMOVED) expect(env).not.toHaveProperty(key)
  }
})

test('childEnv keeps all other variables and drops undefined values', () => {
  const env = childEnv(SOURCE, { pty: false })
  expect(env).toEqual({
    HOME: '/Users/test',
    PATH: '/usr/bin:/bin',
    USER: 'test',
    SHELL: '/bin/zsh',
    LANG: 'en_GB.UTF-8',
    TERM: 'dumb',
    CLAUDE_CONFIG_DIR: '/Users/test/.claude',
    ANTHROPIC_MODEL: 'haiku'
  })
})

test('childEnv sets TERM and COLORTERM for a PTY', () => {
  const env = childEnv(SOURCE, { pty: true })
  expect(env.TERM).toBe('xterm-256color')
  expect(env.COLORTERM).toBe('truecolor')
  expect(env.HOME).toBe('/Users/test')
})

test('childEnv does not change the source env', () => {
  const copy = { ...SOURCE }
  childEnv(SOURCE, { pty: true })
  expect(SOURCE).toEqual(copy)
})
