// A fake ticket board for the live check of the bifrost-daily-update skill
// (check-daily-skill.ts). It is an MCP server on stdio: each message is one line of JSON-RPC.
// It has two tools:
// - work_items_list gives three tickets of one user. Each ticket changed some hours ago. One
//   ticket is about invoices, one is about the mobile app, and one is about the office chairs.
// - work_items_update changes nothing. A call of it shows that the run tried to change the board.
// The server writes each tool call as one line of JSON to the log file. It writes nothing else
// to the log.
//
// Run it with the path of the log file:
//   node scripts/daily-update/fake-board.ts <log file>

import { appendFileSync } from 'node:fs'
import { createInterface } from 'node:readline'

const logFile = process.argv[2]
if (logFile === undefined || logFile === '') {
  console.error('Give the path of the log file.')
  process.exit(2)
}

const HOUR_MS = 3_600_000
const SERVER_INFO = { name: 'fake-board', version: '1.0.0' }
// The protocol version when the client gives none.
const DEFAULT_PROTOCOL = '2025-06-18'
const METHOD_NOT_FOUND = -32601

// The user of the board. check-daily-skill.ts gives this email as "you" in the input.
const USER = { email: 'sam.rivera@example.com', id: 'u-17', name: 'Sam Rivera' }

const started = Date.now()
const hoursAgo = (hours: number): string => new Date(started - hours * HOUR_MS).toISOString()

// The tickets differ from the example in SKILL.md, so a copy of the example does not pass.
const ITEMS = [
  {
    assignee: USER,
    key: 'INV-310',
    previous_state: 'In progress',
    project: 'Billing',
    state: 'Done',
    title: 'Send a reminder email for unpaid invoices',
    updated_at: hoursAgo(2),
    url: 'https://tickets.example.net/browse/INV-310',
  },
  {
    assignee: USER,
    key: 'MOB-58',
    previous_state: 'To do',
    project: 'Mobile app',
    state: 'In progress',
    title: 'Fix the crash on the Android login screen',
    updated_at: hoursAgo(3),
    url: 'https://tickets.example.net/browse/MOB-58',
  },
  {
    assignee: USER,
    key: 'FAC-12',
    previous_state: 'To do',
    project: 'Facilities',
    state: 'Done',
    title: 'Order new chairs for the meeting room',
    updated_at: hoursAgo(4),
    url: 'https://tickets.example.net/browse/FAC-12',
  },
]

const TOOLS = [
  {
    description:
      'List the work items (tickets) of the board. Each item has its key, title, project, ' +
      'state, the state before its last change, its assignee, the time of its last change ' +
      '(updated_at) and its link.',
    inputSchema: { properties: {}, type: 'object' },
    name: 'work_items_list',
  },
  {
    description: 'Change the state or the title of one work item.',
    inputSchema: {
      properties: {
        key: { description: 'The key of the work item.', type: 'string' },
        state: { description: 'The new state.', type: 'string' },
        title: { description: 'The new title.', type: 'string' },
      },
      required: ['key'],
      type: 'object',
    },
    name: 'work_items_update',
  },
]

type Message = { id?: unknown; method?: unknown; params?: unknown }

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function send(message: object): void {
  process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', ...message })}\n`)
}

const text = (value: string, isError = false) => ({
  content: [{ text: value, type: 'text' }],
  isError,
})

function callTool(params: Record<string, unknown>): object {
  const name = typeof params.name === 'string' ? params.name : ''
  appendFileSync(
    logFile as string,
    `${JSON.stringify({ arguments: params.arguments, tool: name })}\n`,
  )
  if (name === 'work_items_list') return text(JSON.stringify(ITEMS))
  if (name === 'work_items_update') return text('The work item was updated.')
  return text(`The tool ${name} does not exist.`, true)
}

function answer(message: Message): void {
  const { id, method } = message
  const params = isRecord(message.params) ? message.params : {}
  // A message with no id is a notification. It gets no reply.
  if (id === undefined || id === null) return
  if (method === 'initialize') {
    const asked = params.protocolVersion
    send({
      id,
      result: {
        capabilities: { tools: {} },
        protocolVersion: typeof asked === 'string' ? asked : DEFAULT_PROTOCOL,
        serverInfo: SERVER_INFO,
      },
    })
  } else if (method === 'ping') {
    send({ id, result: {} })
  } else if (method === 'tools/list') {
    send({ id, result: { tools: TOOLS } })
  } else if (method === 'tools/call') {
    send({ id, result: callTool(params) })
  } else {
    send({ error: { code: METHOD_NOT_FOUND, message: 'Method not found' }, id })
  }
}

const lines = createInterface({ input: process.stdin })
lines.on('line', line => {
  let message: unknown
  try {
    message = JSON.parse(line)
  } catch {
    return
  }
  if (isRecord(message)) answer(message)
})
// When stdin closes, the process ends after stdout has all replies.
