import type { On, SessionMeasureInput, SessionUsage } from 'claude-code'
import { expect, type MockClock, mock, test } from 'claude-code/testing'
import { register } from '../hooks/register'

// Tests of the Live details mod. The hooks of each test stand for the engine.
// The http.fetch hook records each line. No line goes to a real socket.

const URL = 'http://bifrost/v1/event'
const SOCKET_PATH = '/h/.bifrost/live.sock'
const S = '6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b'
const S1 = '11111111-2222-4333-8444-555555555555'
const S2 = '66666666-7777-4888-9999-aaaaaaaaaaaa'
const MODEL = 'claude-haiku-5-5'
const CLAUDE_VERSION = '2.1.318'
const TRANSCRIPT = '/h/.claude/projects/p/S.jsonl'
const RATE_LIMITS = [{ kind: 'seven_day', percentUsed: 15, resetsAt: '2026-11-07T02:00:00.000Z' }]
const USAGE: SessionUsage = {
  context: { percent: 6, tokens: 58151, window: 1000000 },
  cost: { usd: 0.0069 },
  rateLimits: RATE_LIMITS,
  startedAt: 0,
}

type Line = { [field: string]: unknown; kind: string }

interface Options {
  // How the http.fetch hook answers: at once, never, or with an ENOENT error.
  fetch?: 'answer' | 'hang' | 'fail'
  // The environment of the plugin. The default has HOME.
  env?: Record<string, string>
  // The answer of $.session.id().
  sessionId?: () => string
  // The answer of $.session.usage().
  usage?: SessionUsage
  // The version in the answer of $.session.version(). Without it, the engine part fails.
  version?: string
  // The engine part of session.version waits for this promise before it answers.
  versionWait?: Promise<void>
  // The engine part of session.end calls this function.
  onSessionEnd?: () => void
}

interface World {
  clock: MockClock
  lines: Line[]
  kinds: () => string[]
  // The number of calls of $.session.version().
  versionCalls: () => number
}

// Register the hooks that stand for the engine. The http.fetch hook records what the plugin sends.
function world(on: On, options: Options = {}): World {
  const lines: Line[] = []
  const clock = mock.clock(on)
  mock.env(on, options.env ?? { HOME: '/h' })
  on('http.fetch', (_, e) => {
    expect(e.url).toBe(URL)
    expect(e.init?.method).toBe('POST')
    expect(e.init?.socketPath).toBe(SOCKET_PATH)
    expect(e.init?.headers).toEqual({ 'content-type': 'application/json' })
    lines.push(JSON.parse(e.init?.body ?? '{}'))
    if (options.fetch === 'hang') return new Promise<never>(() => {})
    if (options.fetch === 'fail') {
      throw Object.assign(new Error('connect ENOENT /h/.bifrost/live.sock'), { code: 'ENOENT' })
    }
    return { value: { headers: {}, ok: true, status: 204, text: '' } }
  })
  on('session.id', () => ({ value: options.sessionId ? options.sessionId() : S }))
  on('session.model', () => ({ value: MODEL }))
  on('session.usage', () => ({ value: options.usage ?? USAGE }))
  let versionCalls = 0
  on('session.version', async () => {
    versionCalls++
    await options.versionWait
    if (options.version === undefined) throw new Error('no version')
    return { value: { version: options.version } }
  })
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.end', (_, e) => {
    options.onSessionEnd?.()
    return { sessionId: e.sessionId }
  })
  on('session.measure', (_, e) => ({ changed: e.changed }))
  on('turn.start', (_, e) => ({ turnId: e.turnId }))
  on('turn.complete', (_, e) => ({ text: e.answer }))
  on('classic.PermissionRequest', () => ({}))
  on('classic.StopFailure', () => ({}))
  on('classic.Stop', () => ({}))
  return {
    clock,
    kinds: () => lines.map(line => line.kind),
    lines,
    versionCalls: () => versionCalls,
  }
}

const START = { cwd: '/', isInteractive: true, surface: 'terminal' } as const

function turnEnd(answer: string, agentId?: string) {
  return {
    answer,
    durationMs: 10,
    isAborted: false,
    reason: 'answer',
    turnId: 't1',
    ...(agentId ? { agentId } : {}),
  } as const
}

test('turn.complete sends the answer and the reason', async ($, on) => {
  const w = world(on)
  expect(await $.turn.complete(turnEnd('ALPHA'))).toEqual({ text: 'ALPHA' })
  await w.clock.settle()
  expect(w.lines).toEqual([
    {
      answer: 'ALPHA',
      at: expect.any(Number),
      kind: 'turn.complete',
      reason: 'answer',
      seq: expect.any(Number),
      sid: S,
      v: 1,
    },
  ])
})

test('a subagent turn sends no turn line', async ($, on) => {
  const w = world(on)
  await $.turn.start({ agentId: 'a1', text: 'go', turnId: 't1' })
  await $.turn.complete(turnEnd('DONE', 'a1'))
  await w.clock.settle()
  await w.clock.advance(2500)
  expect(w.kinds().filter(kind => kind.startsWith('turn.'))).toEqual([])
  expect(w.lines).toEqual([])
})

test('the answer is cut to 4000 characters', async ($, on) => {
  const w = world(on)
  await $.turn.complete(turnEnd('x'.repeat(5000)))
  await w.clock.settle()
  expect(w.lines.length).toBe(1)
  expect(w.lines[0]?.answer).toBe('x'.repeat(4000))
})

test('tool.call sends ask before an AskUserQuestion call and tool.done after each call', async ($, on) => {
  const w = world(on)
  // The engine part of the tool stays open until the test releases it. In a session, the dialog
  // of AskUserQuestion also stays open until the user answers.
  let release = () => {}
  const answered = new Promise<void>(resolve => {
    release = resolve
  })
  let toolRuns = 0
  on('tool.call', async (_, e) => {
    toolRuns++
    if (e.tool === 'AskUserQuestion') await answered
    return { result: {} }
  })

  const ask = $.tool.call({
    questions: [
      {
        header: 'Colour',
        multiSelect: false,
        options: [
          { description: 'Red', label: 'red' },
          { description: 'Blue', label: 'blue' },
        ],
        question: 'Red or blue?',
      },
    ],
    tool: 'AskUserQuestion',
  })
  await w.clock.settle()
  expect(toolRuns).toBe(1)
  expect(w.kinds()).toEqual(['ask'])
  release()
  expect(await ask).toEqual({ result: {} })
  await w.clock.settle()
  expect(w.kinds()).toEqual(['ask', 'tool.done'])
  expect(w.lines[1]?.tool).toBe('AskUserQuestion')
  expect(Number(w.lines[0]?.seq)).toBeLessThan(Number(w.lines[1]?.seq))

  w.lines.length = 0
  await $.tool.call({ command: 'ls', tool: 'Bash' })
  await w.clock.settle()
  expect(w.kinds()).toEqual(['tool.done'])
  expect(w.lines[0]?.tool).toBe('Bash')

  w.lines.length = 0
  await $.tool.call({ agentId: 'a1', command: 'ls', tool: 'Bash' })
  await w.clock.settle()
  expect(w.kinds()).toEqual(['tool.done'])
})

test('a hook does not wait for a send that never ends', async ($, on) => {
  const w = world(on, { fetch: 'hang' })
  on('tool.call', () => ({ result: {} }))
  expect(await $.tool.call({ command: 'ls', tool: 'Bash' })).toEqual({ result: {} })
  expect(await $.turn.complete(turnEnd('ALPHA'))).toEqual({ text: 'ALPHA' })
  expect(await $.session.start(START)).toEqual({ cwd: '/' })
  expect(await $.turn.start({ text: 'go', turnId: 't2' })).toEqual({ turnId: 't2' })
  await w.clock.settle()
  expect(w.kinds()).toContain('tool.done')
  expect(w.kinds()).toContain('turn.complete')
})

test('a failed send changes nothing', async ($, on) => {
  const w = world(on, { fetch: 'fail' })
  on('tool.call', () => ({ result: {} }))
  expect(await $.tool.call({ command: 'ls', tool: 'Bash' })).toEqual({ result: {} })
  expect(await $.turn.complete(turnEnd('ALPHA'))).toEqual({ text: 'ALPHA' })
  expect(await $.session.start(START)).toEqual({ cwd: '/' })
  await w.clock.settle()
  await w.clock.advance(30_000)
  expect(await $.session.end({ reason: 'other', resume: { id: S }, sessionId: S })).toEqual({
    sessionId: S,
  })
  expect(w.kinds()).toContain('session.end')
})

test('at 32 sends in flight, a new line is not sent and each hook still returns', async ($, on) => {
  const w = world(on, { fetch: 'hang' })
  on('tool.call', () => ({ result: {} }))
  for (let i = 1; i <= 33; i++) {
    expect(await $.turn.start({ text: 'go', turnId: `t${i}` })).toEqual({ turnId: `t${i}` })
  }
  await w.clock.settle()
  expect(w.lines.length).toBe(32)
  expect(await $.tool.call({ command: 'ls', tool: 'Bash' })).toEqual({ result: {} })
  expect(await $.turn.complete(turnEnd('ALPHA'))).toEqual({ text: 'ALPHA' })
  const measure: SessionMeasureInput = {
    changed: ['cost'],
    context: USAGE.context,
    cost: { usd: 1 },
    rateLimits: [],
  }
  expect(await $.session.measure(measure)).toEqual({ changed: ['cost'] })
  // The send of session.end returns at once, so the hook does not wait for its 200 ms.
  expect(await $.session.end({ reason: 'other', resume: { id: S }, sessionId: S })).toEqual({
    sessionId: S,
  })
  await w.clock.settle()
  await w.clock.advance(2500)
  expect(w.lines.length).toBe(32)
  expect(new Set(w.kinds())).toEqual(new Set(['turn.start']))
})

test('session.end with the reason clear sends usage for the new session after 1 s', async ($, on) => {
  let current = S1
  const w = world(on, {
    onSessionEnd: () => {
      current = S2
    },
    sessionId: () => current,
  })
  expect(await $.session.end({ reason: 'clear', resume: { id: S1 }, sessionId: S1 })).toEqual({
    sessionId: S1,
  })
  await w.clock.settle()
  await w.clock.advance(999)
  expect(w.kinds()).toEqual(['session.end'])
  await w.clock.advance(1)
  expect(w.lines.map(line => [line.kind, line.sid])).toEqual([
    ['session.end', S1],
    ['usage', S2],
  ])
  expect(w.lines[1]).toMatchObject({ costUsd: 0.0069, model: MODEL })
})

test('session.end with another reason sends no usage', async ($, on) => {
  const w = world(on)
  await $.session.end({ reason: 'prompt_input_exit', resume: { id: S }, sessionId: S })
  await w.clock.settle()
  await w.clock.advance(5000)
  expect(w.kinds()).toEqual(['session.end'])
})

test('each line carries the session id at the time of the send', async ($, on) => {
  let current = S1
  const w = world(on, {
    onSessionEnd: () => {
      current = S2
    },
    sessionId: () => current,
  })

  await $.turn.start({ text: 'one', turnId: 't1' })
  await w.clock.settle()
  await $.session.end({ reason: 'clear', resume: { id: S1 }, sessionId: S1 })
  await w.clock.settle()
  await $.turn.start({ text: 'two', turnId: 't2' })
  await w.clock.settle()

  expect(w.lines.map(line => [line.kind, line.sid])).toEqual([
    ['turn.start', S1],
    ['session.end', S1],
    ['turn.start', S2],
  ])
  expect(w.lines[1]?.reason).toBe('clear')
})

test('turn.complete reads the usage again after 2500 ms', async ($, on) => {
  const w = world(on)
  await $.turn.complete(turnEnd('ALPHA'))
  await w.clock.settle()
  await w.clock.advance(2499)
  expect(w.kinds()).toEqual(['turn.complete'])
  await w.clock.advance(1)
  expect(w.kinds()).toEqual(['turn.complete', 'usage'])
  expect(w.lines[1]).toEqual({
    at: expect.any(Number),
    context: { percent: 6, tokens: 58151, window: 1000000 },
    costUsd: 0.0069,
    kind: 'usage',
    model: MODEL,
    rateLimits: RATE_LIMITS,
    seq: expect.any(Number),
    sid: S,
    v: 1,
  })
})

test('session.start sends session.start and usage, then usage each 30 s', async ($, on) => {
  const w = world(on)
  expect(await $.session.start(START)).toEqual({ cwd: '/' })
  await w.clock.settle()
  expect(w.kinds()).toEqual(['session.start', 'usage'])
  await w.clock.advance(29_999)
  expect(w.kinds()).toEqual(['session.start', 'usage'])
  await w.clock.advance(1)
  expect(w.kinds()).toEqual(['session.start', 'usage', 'usage'])
  await w.clock.advance(30_000)
  expect(w.kinds()).toEqual(['session.start', 'usage', 'usage', 'usage'])
})

test('session.end sends the ending session id and waits at most 200 ms', async ($, on) => {
  const w = world(on, { fetch: 'hang' })
  let isDone = false
  const ended = $.session
    .end({ reason: 'other', resume: { id: S2 }, sessionId: S2 })
    .then(result => {
      isDone = true
      return result
    })
  await w.clock.settle()
  await w.clock.advance(199)
  expect(isDone).toBe(false)
  await w.clock.advance(1)
  expect(isDone).toBe(true)
  expect(await ended).toEqual({ sessionId: S2 })
  expect(w.lines).toEqual([
    {
      at: expect.any(Number),
      kind: 'session.end',
      reason: 'other',
      seq: expect.any(Number),
      sid: S2,
      v: 1,
    },
  ])
})

test('classic events send permission and stop.failure', async ($, on) => {
  const w = world(on)
  await $.classic.PermissionRequest({ tool_input: { command: 'ls' }, tool_name: 'Bash' })
  await w.clock.settle()
  await $.classic.StopFailure({ error: 'server_error' })
  await w.clock.settle()
  expect(w.lines).toEqual([
    expect.objectContaining({ kind: 'permission', sid: S, tool: 'Bash', v: 1 }),
    expect.objectContaining({ error: 'server_error', kind: 'stop.failure', sid: S, v: 1 }),
  ])
})

test('session.measure sends the context, the cost and the rate limits', async ($, on) => {
  const other: SessionUsage = {
    context: { percent: 1, tokens: 10, window: 200000 },
    cost: { usd: 9 },
    rateLimits: [],
    startedAt: 0,
  }
  const w = world(on, { usage: other })
  const measure: SessionMeasureInput = {
    changed: ['context', 'cost', 'rateLimits'],
    context: { percent: 6, tokens: 58151, window: 1000000 },
    cost: { usd: 0.0069 },
    rateLimits: RATE_LIMITS,
  }
  expect(await $.session.measure(measure)).toEqual({ changed: measure.changed })
  await w.clock.settle()
  expect(w.lines).toEqual([
    {
      at: expect.any(Number),
      context: { percent: 6, tokens: 58151, window: 1000000 },
      costUsd: 0.0069,
      kind: 'usage',
      model: MODEL,
      rateLimits: RATE_LIMITS,
      seq: expect.any(Number),
      sid: S,
      v: 1,
    },
  ])
})

test('no HOME gives no send', async ($, on) => {
  const w = world(on, { env: {} })
  await $.turn.complete(turnEnd('ALPHA'))
  await w.clock.settle()
  await w.clock.advance(2500)
  expect(w.lines).toEqual([])
})

// The input of a classic.Stop hook of the session S. The engine stamps the folder.
const STOP = {
  effort: { level: 'xhigh' },
  permission_mode: 'acceptEdits',
  session_id: S,
  stop_hook_active: false,
  transcript_path: TRANSCRIPT,
}

test('classic.Stop keeps the effort, the permission mode and the transcript path for the next usage line', async ($, on) => {
  const w = world(on)
  await $.session.start(START)
  await w.clock.settle()
  const count = w.lines.length
  expect(await $.classic.Stop(STOP)).toEqual({})
  await w.clock.settle()
  // The classic.Stop hook makes no fetch.
  expect(w.lines.length).toBe(count)
  await w.clock.advance(30_000)
  expect(w.kinds().slice(count)).toEqual(['usage'])
  expect(w.lines.at(-1)).toMatchObject({
    effort: 'xhigh',
    permissionMode: 'acceptEdits',
    transcriptPath: TRANSCRIPT,
  })
})

test('the usage line carries the Claude Code version', async ($, on) => {
  const w = world(on, { version: CLAUDE_VERSION })
  await $.session.start(START)
  await w.clock.settle()
  expect(w.kinds()).toEqual(['session.start', 'usage'])
  expect(w.lines[1]?.version).toBe(CLAUDE_VERSION)
})

test('a usage line before any classic.Stop has no effort', async ($, on) => {
  const w = world(on, { version: CLAUDE_VERSION })
  await $.turn.complete(turnEnd('ALPHA'))
  await w.clock.settle()
  await w.clock.advance(2500)
  expect(w.kinds()).toEqual(['turn.complete', 'usage'])
  expect(w.lines[1]).not.toHaveProperty('effort')
  expect(w.lines[1]).not.toHaveProperty('permissionMode')
  expect(w.lines[1]).not.toHaveProperty('transcriptPath')
})

test('the usage line cuts the version, the effort and the permission mode', async ($, on) => {
  const w = world(on, { version: 'v'.repeat(300) })
  await $.classic.Stop({
    effort: { level: 'e'.repeat(300) },
    permission_mode: 'p'.repeat(300),
    session_id: S,
    stop_hook_active: false,
    transcript_path: TRANSCRIPT,
  })
  await $.session.start(START)
  await w.clock.settle()
  expect(w.kinds()).toEqual(['session.start', 'usage'])
  expect(w.lines[1]).toMatchObject({
    effort: 'e'.repeat(200),
    permissionMode: 'p'.repeat(200),
    transcriptPath: TRANSCRIPT,
    version: 'v'.repeat(200),
  })
})

test('the usage line leaves out a transcript path longer than 1,024 characters', async ($, on) => {
  const w = world(on)
  const stopWith = (transcript_path: string) => $.classic.Stop({ ...STOP, transcript_path })
  // A cut path names another file. So the mod does not cut a path.
  await stopWith(`/${'t'.repeat(1024)}`)
  await $.turn.complete(turnEnd('ALPHA'))
  await w.clock.settle()
  await w.clock.advance(2500)
  expect(w.kinds()).toEqual(['turn.complete', 'usage'])
  expect(w.lines[1]).toMatchObject({ effort: 'xhigh' })
  expect(w.lines[1]).not.toHaveProperty('transcriptPath')
  // A path of 1,024 characters goes in the line whole.
  const path = `/${'t'.repeat(1023)}`
  await stopWith(path)
  await $.turn.complete(turnEnd('BRAVO'))
  await w.clock.settle()
  await w.clock.advance(2500)
  expect(w.lines.at(-1)).toMatchObject({ kind: 'usage', transcriptPath: path })
})

test('a version read that never settles does not stop the usage lines', async ($, on) => {
  const w = world(on, { version: CLAUDE_VERSION, versionWait: new Promise<void>(() => {}) })
  await $.session.start(START)
  await w.clock.settle()
  expect(w.kinds()).toEqual(['session.start'])
  // The mod waits at most 500 ms for the version. Then it sends the line without it.
  await w.clock.advance(500)
  expect(w.kinds()).toEqual(['session.start', 'usage'])
  expect(w.lines[1]).not.toHaveProperty('version')
  // The heartbeat line waits for the same read again. It also comes.
  await w.clock.advance(30_000)
  expect(w.kinds()).toEqual(['session.start', 'usage', 'usage'])
  expect(w.lines[2]).not.toHaveProperty('version')
  expect(w.versionCalls()).toBe(1)
})

test('a version that comes late goes into the next usage line', async ($, on) => {
  let release = () => {}
  const versionWait = new Promise<void>(resolve => {
    release = resolve
  })
  const w = world(on, { version: CLAUDE_VERSION, versionWait })
  await $.session.start(START)
  await w.clock.settle()
  await w.clock.advance(500)
  expect(w.kinds()).toEqual(['session.start', 'usage'])
  expect(w.lines[1]).not.toHaveProperty('version')
  release()
  await w.clock.settle()
  await w.clock.advance(29_500)
  expect(w.kinds()).toEqual(['session.start', 'usage', 'usage'])
  expect(w.lines[2]?.version).toBe(CLAUDE_VERSION)
  expect(w.versionCalls()).toBe(1)
})

test('a usage line after /clear has no classic.Stop values of the old session', async ($, on) => {
  let current = S1
  const w = world(on, {
    onSessionEnd: () => {
      current = S2
    },
    sessionId: () => current,
  })
  await $.classic.Stop({ ...STOP, session_id: S1 })
  await $.session.end({ reason: 'clear', resume: { id: S1 }, sessionId: S1 })
  await w.clock.settle()
  await w.clock.advance(1000)
  expect(w.lines.map(line => [line.kind, line.sid])).toEqual([
    ['session.end', S1],
    ['usage', S2],
  ])
  expect(w.lines[1]).not.toHaveProperty('effort')
  expect(w.lines[1]).not.toHaveProperty('permissionMode')
  expect(w.lines[1]).not.toHaveProperty('transcriptPath')
  // The first classic.Stop of the new session gives its own values.
  const path = '/h/.claude/projects/p/S2.jsonl'
  await $.classic.Stop({ ...STOP, session_id: S2, transcript_path: path })
  await $.turn.complete(turnEnd('ALPHA'))
  await w.clock.settle()
  await w.clock.advance(2500)
  expect(w.lines.at(-1)).toMatchObject({
    effort: 'xhigh',
    kind: 'usage',
    sid: S2,
    transcriptPath: path,
  })
})

test('session.end removes the classic.Stop values of its session', async ($, on) => {
  const w = world(on)
  await $.classic.Stop(STOP)
  await $.session.end({ reason: 'other', resume: { id: S }, sessionId: S })
  // A later line of the same session ID has none of the old values.
  await $.turn.complete(turnEnd('ALPHA'))
  await w.clock.settle()
  await w.clock.advance(2500)
  expect(w.kinds()).toEqual(['session.end', 'turn.complete', 'usage'])
  expect(w.lines[2]).not.toHaveProperty('effort')
  expect(w.lines[2]).not.toHaveProperty('transcriptPath')
})

test('a late classic.Stop of the old session does not go into a line of the new session', async ($, on) => {
  let current = S1
  const w = world(on, {
    onSessionEnd: () => {
      current = S2
    },
    sessionId: () => current,
  })
  await $.session.end({ reason: 'clear', resume: { id: S1 }, sessionId: S1 })
  await $.classic.Stop({ ...STOP, session_id: S1 })
  await w.clock.settle()
  await w.clock.advance(1000)
  expect(w.lines.map(line => [line.kind, line.sid])).toEqual([
    ['session.end', S1],
    ['usage', S2],
  ])
  expect(w.lines[1]).not.toHaveProperty('effort')
  expect(w.lines[1]).not.toHaveProperty('transcriptPath')
})

// One hook of a direct call of register: ($, e, next).
type Hook = (...args: unknown[]) => unknown

// An older engine build can lack $.session.version. A test of the kit cannot remove an engine
// call, so this test calls register with its own on and its own $. That $ has no
// session.version, so a call of it throws at once.
test('an engine without session.version still gives the usage line with the model and the cost', async () => {
  const hooks = new Map<string, Hook>()
  const ownOn = (name: string, hook: Hook) => {
    hooks.set(name, hook)
    return { catch: () => undefined }
  }
  register(ownOn as unknown as On, {})
  const lines: Line[] = []
  const engine = {
    clock: { after: () => {}, every: () => {}, sleep: () => new Promise<void>(() => {}) },
    env: { get: async () => '/h' },
    http: {
      fetch: async (_url: string, init: { body: string }) => {
        lines.push(JSON.parse(init.body))
        return { headers: {}, ok: true, status: 204, text: '' }
      },
    },
    session: { id: async () => S, model: async () => MODEL, usage: async () => USAGE },
  }
  const measure: SessionMeasureInput = {
    changed: ['cost'],
    context: USAGE.context,
    cost: { usd: 0.0069 },
    rateLimits: RATE_LIMITS,
  }
  const next = async (e: SessionMeasureInput) => ({ changed: e.changed })
  expect(await hooks.get('session.measure')?.(engine, measure, next)).toEqual({ changed: ['cost'] })
  // The line goes out after some promise steps. Let them all run.
  for (let i = 0; i < 100; i++) await Promise.resolve()
  expect(lines).toEqual([
    expect.objectContaining({ costUsd: 0.0069, kind: 'usage', model: MODEL, sid: S }),
  ])
  expect(lines[0]).not.toHaveProperty('version')
})
