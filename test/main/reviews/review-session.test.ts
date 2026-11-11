import { describe, expect, test } from 'vitest'
import { claudeFailure } from '../../../src/main/actions/claude-output'
import { NO_CLAUDE, NO_STATUSLINE_SETTINGS } from '../../../src/main/actions/session-actions'
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
    for (const testHome of [false, true]) {
      const name = reviewSessionName(long, new Set(), testHome)
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

function setup(results: ExecResult[], opts: { noClaude?: boolean; timeout?: boolean } = {}) {
  const calls: { args: string[]; cwd?: string }[] = []
  const log: string[] = []
  const events: string[] = []
  const run: RunClaude = async (a, o) => {
    calls.push({ args: a, cwd: o?.cwd })
    return results.shift() ?? OK
  }
  const sessions = createReviewSessions({
    expectPrSession: n => events.push(`expect ${n}`),
    forget: id => events.push(`forget ${id}`),
    log: m => log.push(m),
    markStarted: id => events.push(`started ${id}`),
    releasePrSession: n => events.push(`release ${n}`),
    run: async () => (opts.noClaude ? null : run),
    waitForRow: async match => {
      events.push('wait')
      if (opts.timeout) throw new Error('timeout')
      const r = row()
      if (!match(r)) throw new Error('no match')
      return r
    },
  })
  return { calls, events, log, sessions }
}

const START = { args: ['--bg', 'x'], cwd: '/wt', name: 'api-7-review' }

describe('createReviewSessions', () => {
  test('a trust error gives trust true and releases the name', async () => {
    const { events, sessions } = setup([{ code: 1, stderr: TRUST, stdout: '' }])
    const out = await sessions.start(START)
    expect(out).toMatchObject({ name: 'api-7-review', ok: false, trust: true })
    expect(events).toEqual(['expect api-7-review', 'release api-7-review'])
  })

  test('another failure gives the claudeFailure text and trust false', async () => {
    const fail = { code: 1, stderr: 'boom', stdout: '' }
    const { sessions } = setup([fail])
    const out = await sessions.start(START)
    expect(out).toEqual({
      message: claudeFailure(fail, 'claude --bg'),
      name: 'api-7-review',
      ok: false,
      trust: false,
    })
  })

  test('claude not found gives a failure', async () => {
    const { calls, sessions } = setup([], { noClaude: true })
    const out = await sessions.start(START)
    expect(out).toEqual({ message: NO_CLAUDE, name: 'api-7-review', ok: false, trust: false })
    expect(calls).toEqual([])
  })

  test('the name is marked before the start, and a timeout keeps the mark and the name', async () => {
    const { calls, events, sessions } = setup([STARTED], { timeout: true })
    const out = await sessions.start(START)
    expect(out).toMatchObject({ name: 'api-7-review', ok: false, trust: false })
    expect(events).toEqual(['expect api-7-review', 'wait'])
    expect(calls).toHaveLength(1)
  })

  test('start waits for the owned row', async () => {
    const { calls, events, sessions } = setup([STARTED])
    const out = await sessions.start(START)
    expect(out).toEqual({ name: 'api-7-review', ok: true, sessionId: 'sid-1', shortId: SHORT })
    expect(calls[0]).toMatchObject({ args: ['--bg', 'x'], cwd: '/wt' })
    expect(events).toEqual(['expect api-7-review', 'wait', 'started sid-1'])
  })

  test('stop runs claude stop and rejects when it fails', async () => {
    const { calls, sessions } = setup([OK, { code: 1, stderr: 'no', stdout: '' }])
    await sessions.stop(SHORT)
    expect(calls[0].args).toEqual(['stop', SHORT])
    await expect(sessions.stop(SHORT)).rejects.toThrow(
      claudeFailure({ code: 1, stderr: 'no', stdout: '' }, 'claude stop'),
    )
  })

  test('remove forgets the row and releases the name after a working rm', async () => {
    const { calls, events, sessions } = setup([OK, OK])
    await sessions.remove({ name: 'api-7-review', sessionId: 'sid-1', shortId: SHORT })
    expect(calls.map(c => c.args)).toEqual([
      ['stop', SHORT],
      ['rm', SHORT],
    ])
    expect(events).toEqual(['release api-7-review', 'forget sid-1'])
  })

  test('remove keeps the mark and the row when claude rm refuses', async () => {
    const { events, log, sessions } = setup([
      { code: 1, stderr: 'no', stdout: '' },
      { code: 1, stderr: 'refused', stdout: '' },
    ])
    await sessions.remove({ name: 'api-7-review', sessionId: 'sid-1', shortId: SHORT })
    expect(log.length).toBe(1)
    expect(events).toEqual([])
  })

  test('a bad short ID is refused', async () => {
    const { calls, sessions } = setup([])
    await expect(sessions.stop('--all')).rejects.toThrow()
    await expect(sessions.remove({ name: 'n', sessionId: 's', shortId: 'x y' })).rejects.toThrow()
    expect(calls).toEqual([])
  })
})
