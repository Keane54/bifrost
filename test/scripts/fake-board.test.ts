// A test of the fake board of the live check of bifrost-daily-update. The test starts the fake
// board with node and talks to it on stdio, as Claude Code does. It starts no claude.
import { spawn } from 'node:child_process'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createInterface } from 'node:readline'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'

const FAKE_BOARD = join(import.meta.dirname, '..', '..', 'scripts', 'daily-update', 'fake-board.ts')
const PROTOCOL = '2025-06-18'

let dir: string

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'bifrost-fake-board-'))
})

afterEach(async () => {
  await rm(dir, { force: true, recursive: true })
})

type Reply = { id: number; result?: Record<string, unknown>; error?: { code: number } }

// Send each message on one line, close stdin, and give the replies by their id.
async function talk(log: string, messages: object[]): Promise<Map<number, Reply>> {
  const child = spawn(process.execPath, [FAKE_BOARD, log], { stdio: ['pipe', 'pipe', 'pipe'] })
  const replies = new Map<number, Reply>()
  const lines = createInterface({ input: child.stdout })
  lines.on('line', line => {
    const reply = JSON.parse(line) as Reply
    replies.set(reply.id, reply)
  })
  for (const message of messages) child.stdin.write(`${JSON.stringify(message)}\n`)
  child.stdin.end()
  await new Promise(done => child.on('close', done))
  return replies
}

const request = (id: number, method: string, params: object = {}) => ({
  id,
  jsonrpc: '2.0',
  method,
  params,
})

const call = (id: number, name: string, args: object = {}) =>
  request(id, 'tools/call', { arguments: args, name })

// The text of a tool result, as JSON.
function toolJson(reply: Reply | undefined): unknown {
  const content = reply?.result?.content as { type: string; text: string }[] | undefined
  return JSON.parse(content?.[0]?.text ?? 'null')
}

describe('the fake board', () => {
  it('answers initialize with the protocol of the client and a tools capability', async () => {
    const replies = await talk(join(dir, 'calls.log'), [
      request(1, 'initialize', {
        capabilities: {},
        clientInfo: { name: 'test', version: '1' },
        protocolVersion: PROTOCOL,
      }),
      { jsonrpc: '2.0', method: 'notifications/initialized' },
      request(2, 'ping'),
    ])
    expect(replies.get(1)?.result).toMatchObject({
      capabilities: { tools: {} },
      protocolVersion: PROTOCOL,
      serverInfo: { name: 'fake-board' },
    })
    expect(replies.get(2)?.result).toEqual({})
    // A notification gets no reply.
    expect([...replies.keys()].sort()).toEqual([1, 2])
  })

  it('lists a read tool and a write tool', async () => {
    const replies = await talk(join(dir, 'calls.log'), [request(1, 'tools/list')])
    const tools = replies.get(1)?.result?.tools as { name: string; inputSchema: object }[]
    expect(tools.map(tool => tool.name)).toEqual(['work_items_list', 'work_items_update'])
    for (const tool of tools) expect(tool.inputSchema).toMatchObject({ type: 'object' })
  })

  it('gives three recent tickets of one user with https links', async () => {
    const before = Date.now()
    const replies = await talk(join(dir, 'calls.log'), [call(1, 'work_items_list')])
    const items = toolJson(replies.get(1)) as {
      key: string
      url: string
      updated_at: string
      assignee: { email: string }
    }[]
    expect(items).toHaveLength(3)
    expect(new Set(items.map(item => item.assignee.email)).size).toBe(1)
    for (const item of items) {
      expect(item.url.startsWith('https://')).toBe(true)
      const age = before - Date.parse(item.updated_at)
      expect(age).toBeGreaterThan(0)
      expect(age).toBeLessThan(12 * 3_600_000)
    }
  })

  it('logs each tool call, also the write tool, and nothing else', async () => {
    const log = join(dir, 'calls.log')
    const replies = await talk(log, [
      request(1, 'tools/list'),
      call(2, 'work_items_list'),
      call(3, 'work_items_update', { key: 'X-1', state: 'Done' }),
    ])
    expect(replies.get(3)?.result).toBeDefined()
    const lines = (await readFile(log, 'utf8')).trimEnd().split('\n')
    expect(lines.map(line => (JSON.parse(line) as { tool: string }).tool)).toEqual([
      'work_items_list',
      'work_items_update',
    ])
  })

  it('refuses an unknown method and marks an unknown tool as an error', async () => {
    const replies = await talk(join(dir, 'calls.log'), [
      request(1, 'resources/list'),
      call(2, 'work_items_delete'),
    ])
    expect(replies.get(1)?.error?.code).toBe(-32601)
    expect(replies.get(2)?.result?.isError).toBe(true)
  })
})
