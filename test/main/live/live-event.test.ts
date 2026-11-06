import { describe, expect, test } from 'vitest'
import { parseLiveLine, TRANSCRIPT_PATH_MAX } from '../../../src/main/live/live-event'

const S = '73b5ca76-a4a8-4f97-9764-e41657296414'
const line = (o: Record<string, unknown>) =>
  JSON.stringify({ at: 1000, seq: 3, sid: S, v: 1, ...o })
const R = 1005
const state = (event: Record<string, unknown>) => ({
  event: { at: 1000, seq: 3, sessionId: S, ...event },
  type: 'state',
})

describe('parseLiveLine', () => {
  test.each([
    [{ kind: 'session.start' }, { name: 'SessionStart' }],
    [{ kind: 'session.end', reason: 'clear' }, { name: 'SessionEnd' }],
    [{ kind: 'turn.start' }, { name: 'UserPromptSubmit' }],
    [{ kind: 'ask' }, { name: 'PreToolUse', toolName: 'AskUserQuestion' }],
    [
      { kind: 'tool.done', tool: 'Read' },
      { name: 'PostToolUse', toolName: 'Read' },
    ],
    [
      { kind: 'permission', tool: 'Bash' },
      { name: 'PermissionRequest', toolName: 'Bash' },
    ],
    [
      { answer: 'ALPHA', kind: 'turn.complete', reason: 'answer' },
      { lastAssistantMessage: 'ALPHA', name: 'Stop' },
    ],
    [
      { answer: 'NO', kind: 'turn.complete', reason: 'refusal' },
      { lastAssistantMessage: 'NO', name: 'Stop' },
    ],
    [{ answer: '', kind: 'turn.complete', reason: 'answer' }, { name: 'Stop' }],
    [
      { answer: '1\n2', kind: 'turn.complete', reason: 'aborted' },
      { lastAssistantMessage: '1\n2', name: 'TurnAborted' },
    ],
    [{ answer: '', kind: 'turn.complete', reason: 'error' }, { name: 'StopFailure' }],
    [{ error: 'boom', kind: 'stop.failure' }, { name: 'StopFailure' }],
    [{ kind: 'stop.failure' }, { name: 'StopFailure' }],
  ])('parseLiveLine maps each state kind (%j)', (input, event) => {
    expect(parseLiveLine(line(input), R)).toEqual(state(event))
  })

  test('parseLiveLine reads a usage line', () => {
    const text = line({
      context: { percent: 6, tokens: 58151, window: 1000000 },
      costUsd: 0.00691591,
      kind: 'usage',
      model: 'claude-haiku-5-5',
      rateLimits: [{ kind: 'seven_day', percentUsed: 15, resetsAt: '2026-11-07T02:00:00.000Z' }],
    })
    expect(parseLiveLine(text, R)).toEqual({
      at: 1000,
      sessionId: S,
      type: 'usage',
      usage: {
        contextPercent: 6,
        contextTokens: 58151,
        contextWindow: 1000000,
        costUsd: 0.00691591,
        model: 'claude-haiku-5-5',
        rateLimits: {
          sevenDay: { resetsAt: Date.parse('2026-11-07T02:00:00.000Z'), usedPercent: 15 },
        },
      },
    })
  })

  test('parseLiveLine reads the five hour window', () => {
    const text = line({
      kind: 'usage',
      rateLimits: [{ kind: 'five_hour', percentUsed: 0, resetsAt: '2026-11-07T02:00:00.000Z' }],
    })
    expect(parseLiveLine(text, R)).toEqual({
      at: 1000,
      sessionId: S,
      type: 'usage',
      usage: {
        rateLimits: {
          fiveHour: { resetsAt: Date.parse('2026-11-07T02:00:00.000Z'), usedPercent: 0 },
        },
      },
    })
  })

  test('parseLiveLine leaves out a bad usage field and keeps the line', () => {
    const text = line({
      context: { percent: 101, tokens: 58151, window: 1000000 },
      costUsd: -1,
      kind: 'usage',
      model: 'claude-haiku-5-5',
      rateLimits: [
        { kind: 'spend_limit', percentUsed: 5, resetsAt: '2026-11-07T02:00:00.000Z' },
        { kind: 'five_hour', percentUsed: 5, resetsAt: 'soon' },
      ],
    })
    expect(parseLiveLine(text, R)).toEqual({
      at: 1000,
      sessionId: S,
      type: 'usage',
      usage: { contextTokens: 58151, contextWindow: 1000000, model: 'claude-haiku-5-5' },
    })
  })

  test('parseLiveLine reads the four new usage fields', () => {
    const text = line({
      effort: 'xhigh',
      kind: 'usage',
      permissionMode: 'plan',
      transcriptPath: '/h/.claude/projects/p/S.jsonl',
      version: '2.1.318',
    })
    expect(parseLiveLine(text, R)).toEqual({
      at: 1000,
      sessionId: S,
      type: 'usage',
      usage: {
        effort: 'xhigh',
        permissionMode: 'plan',
        transcriptPath: '/h/.claude/projects/p/S.jsonl',
        version: '2.1.318',
      },
    })
  })

  test('parseLiveLine cuts the version, the effort and the permission mode', () => {
    const text = line({
      effort: 'e'.repeat(300),
      kind: 'usage',
      permissionMode: 'p'.repeat(300),
      version: 'v'.repeat(300),
    })
    expect(parseLiveLine(text, R)).toMatchObject({
      usage: { effort: 'e'.repeat(200), permissionMode: 'p'.repeat(200), version: 'v'.repeat(200) },
    })
  })

  test.each([['rel/p.jsonl'], ['/a\nb'], ['/a\rb'], [`/${'p'.repeat(1024)}`], [42]])(
    'parseLiveLine leaves out a bad transcript path (%j)',
    transcriptPath => {
      const text = line({ costUsd: 0.5, kind: 'usage', transcriptPath })
      expect(parseLiveLine(text, R)).toEqual({
        at: 1000,
        sessionId: S,
        type: 'usage',
        usage: { costUsd: 0.5 },
      })
    },
  )

  test('parseLiveLine keeps a transcript path of 1,024 characters', () => {
    expect(TRANSCRIPT_PATH_MAX).toBe(1024)
    const path = `/${'p'.repeat(1023)}`
    expect(parseLiveLine(line({ kind: 'usage', transcriptPath: path }), R)).toMatchObject({
      usage: { transcriptPath: path },
    })
  })

  // C0 controls, DEL and the bidi controls. A bidi control can make a path look like another path.
  // The test gives code points, so the source file has no invisible character.
  test.each([[0x00], [0x07], [0x1b], [0x1f], [0x7f], [0x202a], [0x202e], [0x2066], [0x2069]])(
    'parseLiveLine leaves out a transcript path with the control character %d',
    code => {
      const transcriptPath = `/h/p${String.fromCodePoint(code)}x.jsonl`
      const text = line({ costUsd: 0.5, kind: 'usage', transcriptPath })
      expect(parseLiveLine(text, R)).toEqual({
        at: 1000,
        sessionId: S,
        type: 'usage',
        usage: { costUsd: 0.5 },
      })
    },
  )

  test('parseLiveLine keeps a transcript path with spaces and letters that are not ASCII', () => {
    const path = '/Users/dev-user/Mes projets été/日本/S.jsonl'
    expect(parseLiveLine(line({ kind: 'usage', transcriptPath: path }), R)).toMatchObject({
      usage: { transcriptPath: path },
    })
  })

  test('parseLiveLine leaves out an empty or bad version, effort and permission mode', () => {
    const text = line({ costUsd: 0.5, effort: '', kind: 'usage', permissionMode: 3, version: null })
    expect(parseLiveLine(text, R)).toEqual({
      at: 1000,
      sessionId: S,
      type: 'usage',
      usage: { costUsd: 0.5 },
    })
  })

  test.each([
    ['not json'],
    ['[]'],
    ['null'],
    [line({ kind: 'turn.start', v: 2 })],
    [line({ kind: 'hello' })],
    [line({ kind: 'turn.start', sid: 'abc' })],
    [line({ at: 'x', kind: 'turn.start' })],
    [line({ kind: 'tool.done' })],
    [line({ kind: 'permission' })],
    [line({ kind: 'session.end' })],
    [line({ kind: 'turn.complete', reason: 'other' })],
  ])('parseLiveLine refuses bad lines (%s)', text => {
    expect(parseLiveLine(text, R)).toBeNull()
  })

  test('parseLiveLine cuts long texts', () => {
    const a = parseLiveLine(
      line({ answer: 'x'.repeat(5000), kind: 'turn.complete', reason: 'answer' }),
      R,
    )
    expect(a).toMatchObject({ event: { lastAssistantMessage: 'x'.repeat(4000) } })
    const t = parseLiveLine(line({ kind: 'tool.done', tool: 'y'.repeat(300) }), R)
    expect(t).toMatchObject({ event: { toolName: 'y'.repeat(200) } })
  })

  test('parseLiveLine uses the receive time for a far time', () => {
    expect(parseLiveLine(line({ at: 21_000, kind: 'turn.start' }), R)).toMatchObject({
      event: { at: 1005 },
    })
  })

  test.each([[-1], [1.5]])('parseLiveLine drops a bad seq (%s)', seq => {
    const result = parseLiveLine(line({ kind: 'turn.start', seq }), R)
    expect(result).not.toBeNull()
    expect(result).toEqual({
      event: { at: 1000, name: 'UserPromptSubmit', sessionId: S },
      type: 'state',
    })
  })
})
