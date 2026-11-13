import { expect, test } from 'vitest'
import type { SpawnLines } from '../../../src/main/claude/spawn-lines'
import {
  PROBE_ARGS,
  PROBE_TIMEOUT_MS,
  parseInitEvent,
  probeInventory,
} from '../../../src/main/daily-update/mcp-inventory'

const init = (servers: unknown, tools: unknown) =>
  JSON.stringify({ mcp_servers: servers, subtype: 'init', tools, type: 'system' })

test('parseInitEvent ignores a hook event and a bad line', () => {
  expect(parseInitEvent('{"type":"system","subtype":"hook_started"}')).toBeNull()
  expect(parseInitEvent('not json')).toBeNull()
  expect(parseInitEvent('[1]')).toBeNull()
  expect(parseInitEvent('null')).toBeNull()
  expect(parseInitEvent(init('x', []))).toBeNull()
  expect(parseInitEvent(init([], 'x'))).toBeNull()
})

test('parseInitEvent groups the tools by server', () => {
  const result = parseInitEvent(
    init(
      [
        { name: 'board', source: 'user', status: 'connected' },
        { name: 'claude.ai Docs', source: 'claudeai', status: 'connected' },
        { status: 'connected' },
      ],
      ['mcp__board__a_list', 'mcp__claude_ai_Docs__read', 'Read'],
    ),
  )
  expect(result).toEqual({
    servers: [
      { name: 'board', prefix: 'mcp__board__', status: 'connected', tools: ['mcp__board__a_list'] },
      {
        name: 'claude.ai Docs',
        prefix: 'mcp__claude_ai_Docs__',
        status: 'connected',
        tools: ['mcp__claude_ai_Docs__read'],
      },
    ],
  })
})

test('parseInitEvent gives a tool to the server with the longest matching prefix', () => {
  const result = parseInitEvent(
    init(
      [
        { name: 'a', status: 'connected' },
        { name: 'a__b', status: 'connected' },
      ],
      ['mcp__a__x', 'mcp__a__b__y'],
    ),
  )
  expect(result?.servers.map(s => [s.name, s.tools])).toEqual([
    ['a', ['mcp__a__x']],
    ['a__b', ['mcp__a__b__y']],
  ])
})

test('probeInventory resolves on the init event and rejects with probe-failed', async () => {
  const seen: string[][] = []
  const ok: SpawnLines = async (args, opts) => {
    seen.push(args)
    expect(opts.timeoutMs).toBe(PROBE_TIMEOUT_MS)
    expect(opts.onLine('{"type":"system","subtype":"hook_started"}')).toBe(false)
    expect(opts.onLine(init([{ name: 'board', status: 'connected' }], ['mcp__board__a']))).toBe(
      true,
    )
    return { code: null, stopped: true, timedOut: false }
  }
  const inventory = await probeInventory(ok, '/w')
  expect(inventory.servers[0]?.tools).toEqual(['mcp__board__a'])
  expect(seen[0]).toEqual(PROBE_ARGS)

  const ended: SpawnLines = async () => ({ code: 0, stopped: false, timedOut: false })
  await expect(probeInventory(ended, '/w')).rejects.toThrow('probe-failed')
})

test('the probe uses Haiku and the dontAsk mode, and the prompt is last', () => {
  const at = (flag: string) => PROBE_ARGS[PROBE_ARGS.indexOf(flag) + 1]
  expect(at('--model')).toBe('haiku')
  expect(at('--permission-mode')).toBe('dontAsk')
  expect(at('--tools')).toBe('')
  expect(PROBE_ARGS.at(-1)).toBe('Reply with OK only.')
  expect(PROBE_ARGS.filter(arg => arg === '--model')).toHaveLength(1)
})

test('probeInventory passes the signal to the run', async () => {
  const controller = new AbortController()
  let seen: AbortSignal | undefined
  const run: SpawnLines = async (_args, opts) => {
    seen = opts.signal
    opts.onLine(init([], []))
    return { code: null, stopped: true, timedOut: false }
  }
  await probeInventory(run, '/w', controller.signal)
  expect(seen).toBe(controller.signal)
})
