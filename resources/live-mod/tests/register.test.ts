import type { On, SessionMeasureInput, SessionUsage } from 'claude-code'
import { expect, type MockClock, mock, test } from 'claude-code/testing'

// Tests of the Live details mod. The hooks of each test stand for the engine.
// The http.fetch hook records each line. No line goes to a real socket.

const URL = 'http://bifrost/v1/event'
const SOCKET_PATH = '/h/.bifrost/live.sock'
const S = '6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b'
const S1 = '11111111-2222-4333-8444-555555555555'
const S2 = '66666666-7777-4888-9999-aaaaaaaaaaaa'
const MODEL = 'claude-haiku-5-5'
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
  // The engine part of session.end calls this function.
  onSessionEnd?: () => void
}

interface World {
  clock: MockClock
  lines: Line[]
  kinds: () => string[]
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
  return { clock, kinds: () => lines.map(line => line.kind), lines }
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
