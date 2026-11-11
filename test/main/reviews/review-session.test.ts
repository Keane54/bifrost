import { describe, expect, test } from 'vitest'
import { NO_STATUSLINE_SETTINGS } from '../../../src/main/actions/session-actions'
import type { ExecResult, RunClaude } from '../../../src/main/claude/cli'
import {
  createReviewSessions,
  REVIEW_TOOLS,
  reviewPrompt,
  reviewSessionArgs,
  reviewSessionName,
  TEST_PREFIX,
} from '../../../src/main/reviews/review-session'
import { MAX_NAME } from '../../../src/shared/new-session'
import type { SessionRow } from '../../../src/shared/types'

const pr = { number: 7, owner: 'acme', repo: 'api' }
const SHORT = 'abcd1234'
const TRUST =
  'Workspace not trusted. Run `claude` in /p once and accept the trust prompt, then retry.'
const STARTED: ExecResult = { code: 0, stderr: '', stdout: `backgrounded · ${SHORT} · x\n` }
const OK: ExecResult = { code: 0, stderr: '', stdout: '' }
const VARIADIC = new Set(['--tools', '--add-dir', '--plugin-dir'])

const args = (model: '' | 'haiku' = 'haiku') =>
  reviewSessionArgs({
    ioDir: '/io',
    model,
    name: 'api-7-review',
    pluginDir: '/skills',
    prompt: reviewPrompt('/io/input.json'),
  })

describe('review session args', () => {
  test('the args have the fixed flags, and the prompt is last after --name and its value', () => {
    expect(REVIEW_TOOLS).toEqual(['Read', 'Glob', 'Grep', 'Write', 'Skill'])
    expect(args()).toEqual([
      '--bg',
      '--restricted',
      '--strict-mcp-config',
      '--tools',
      'Read',
      'Glob',
      'Grep',
      'Write',
      'Skill',
      '--permission-mode',
      'auto',
      '--add-dir',
      '/io',
      '--plugin-dir',
      '/skills',
      '--settings',
      NO_STATUSLINE_SETTINGS,
      '--model',
      'haiku',
      '--name',
      'api-7-review',
      '/bifrost-review bifrost-input=/io/input.json',
    ])
  })

  test('no variadic flag comes right before the prompt', () => {
    for (const model of ['', 'haiku'] as const) {
      const a = args(model)
      expect(VARIADIC.has(a[a.length - 2])).toBe(false)
      expect(a[a.length - 2]).toBe('api-7-review')
      expect(a[a.length - 3]).toBe('--name')
    }
  })

  test('an empty model gives no --model', () => {
    expect(args('')).not.toContain('--model')
  })
})

describe('review session name', () => {
  test('the name: plain, with the owner on a clash, with the test prefix, cut to MAX_NAME', () => {
    expect(reviewSessionName(pr, new Set(), false)).toBe('api-7-review')
    expect(reviewSessionName(pr, new Set(['api-7-review']), false)).toBe('acme-api-7-review')
    expect(reviewSessionName(pr, new Set(), true)).toBe(`${TEST_PREFIX}api-7-review`)
    const long = { ...pr, repo: 'r'.repeat(200) }
    for (const test of [false, true]) {
      const name = reviewSessionName(long, new Set(), test)
      expect(name.length).toBe(MAX_NAME)
      expect(name.endsWith('-7-review')).toBe(true)
    }
    const clash = reviewSessionName(
      long,
      new Set([reviewSessionName(long, new Set(), false)]),
      false,
    )
    expect(clash.length).toBeLessThanOrEqual(MAX_NAME)
    expect(clash.startsWith('acme-')).toBe(true)
    expect(clash.endsWith('-7-review')).toBe(true)
  })
})

const row = (o: Partial<SessionRow> = {}): SessionRow =>
  ({
    box: 'none',
    boxSince: null,
    claudeName: 'x',
    cwd: '/wt',
    flashing: false,
    kind: 'owned',
    lastActivity: 0,
    name: 'x',
    pid: 9,
    sessionId: 'sid-1',
    shortId: SHORT,
    startedAt: 0,
    state: 'working',
    status: 'busy',
    ...o,
  }) as SessionRow

function setup(results: ExecResult[]) {
  const calls: { args: string[]; cwd?: string }[] = []
  const log: string[] = []
  const events: string[] = []
  const run: RunClaude = async (a, opts) => {
    calls.push({ args: a, cwd: opts?.cwd })
    return results.shift() ?? OK
  }
  const sessions = createReviewSessions({
    forget: id => events.push(`forget ${id}`),
    log: m => log.push(m),
    markPrSession: id => events.push(`pr ${id}`),
    markStarted: id => events.push(`started ${id}`),
    run: async () => run,
    waitForRow: async match => {
      events.push('wait')
      const r = row()
      if (!match(r)) throw new Error('no match')
      return r
    },
  })
  return { calls, events, log, sessions }
}

describe('createReviewSessions', () => {
  test('a trust error gives trust true', async () => {
    const { sessions } = setup([{ code: 1, stderr: TRUST, stdout: '' }])
    const out = await sessions.start({ args: ['--bg'], cwd: '/p' })
    expect(out).toMatchObject({ ok: false, trust: true })
  })

  test('another failure gives the message and trust false', async () => {
    const { sessions } = setup([{ code: 1, stderr: 'boom', stdout: '' }])
    const out = await sessions.start({ args: ['--bg'], cwd: '/p' })
    expect(out).toMatchObject({ ok: false, trust: false })
  })

  test('start waits for the owned row and marks it as a PR session', async () => {
    const { calls, events, sessions } = setup([STARTED])
    const out = await sessions.start({ args: ['--bg', 'x'], cwd: '/wt' })
    expect(out).toEqual({ ok: true, sessionId: 'sid-1', shortId: SHORT })
    expect(calls[0]).toMatchObject({ args: ['--bg', 'x'], cwd: '/wt' })
    expect(events).toEqual(['wait', 'started sid-1', 'pr sid-1'])
  })

  test('stop runs claude stop', async () => {
    const { calls, sessions } = setup([OK])
    await sessions.stop(SHORT)
    expect(calls[0].args).toEqual(['stop', SHORT])
  })

  test('remove forgets the row also when claude rm refuses', async () => {
    const { calls, events, log, sessions } = setup([
      { code: 1, stderr: 'no', stdout: '' },
      { code: 1, stderr: 'refused', stdout: '' },
    ])
    await sessions.remove({ sessionId: 'sid-1', shortId: SHORT })
    expect(calls.map(c => c.args)).toEqual([
      ['stop', SHORT],
      ['rm', SHORT],
    ])
    expect(log.length).toBe(1)
    expect(events).toEqual(['forget sid-1'])
  })

  test('a bad short ID is refused', async () => {
    const { calls, sessions } = setup([])
    await expect(sessions.stop('--all')).rejects.toThrow()
    await expect(sessions.remove({ sessionId: 's', shortId: 'x y' })).rejects.toThrow()
    expect(calls).toEqual([])
  })
})
