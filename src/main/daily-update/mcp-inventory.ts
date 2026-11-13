import { type McpInventory, type McpServerInfo, toolPrefix } from '../../shared/daily-update'
import { isRecord } from '../../shared/plain-object'
import type { SpawnLines } from '../claude/spawn-lines'

// The page gets the inventory too, so the types are in the shared module.
export type { McpInventory, McpServerInfo }

// The probe run. It has no built-in tools and no hooks. It only needs the init event. A probe
// that does not stop at that event uses the small model and asks for no permission.
export const PROBE_ARGS = [
  '-p',
  '--output-format',
  'stream-json',
  '--verbose',
  '--tools',
  '',
  '--model',
  'haiku',
  '--permission-mode',
  'dontAsk',
  '--settings',
  '{"disableAllHooks":true}',
  'Reply with OK only.',
]
export const PROBE_TIMEOUT_MS = 30_000

// Read one stream-json line. Give the inventory only for the init event.
// Give null for any other line. A server entry without a text name is ignored.
// Each tool goes to the server with the longest prefix that matches it.
export function parseInitEvent(line: string): McpInventory | null {
  let event: unknown
  try {
    event = JSON.parse(line)
  } catch {
    return null
  }
  if (!isRecord(event) || event.type !== 'system' || event.subtype !== 'init') return null
  const { mcp_servers: rawServers, tools: rawTools } = event
  if (!Array.isArray(rawServers) || !Array.isArray(rawTools)) return null
  const servers: McpServerInfo[] = []
  for (const raw of rawServers) {
    if (!isRecord(raw) || typeof raw.name !== 'string') continue
    servers.push({
      name: raw.name,
      prefix: toolPrefix(raw.name),
      status: typeof raw.status === 'string' ? raw.status : '',
      tools: [],
    })
  }
  for (const tool of rawTools) {
    if (typeof tool !== 'string') continue
    let best: McpServerInfo | null = null
    for (const server of servers) {
      if (tool.startsWith(server.prefix) && (!best || server.prefix.length > best.prefix.length)) {
        best = server
      }
    }
    best?.tools.push(tool)
  }
  return { servers }
}

// Run the probe and read the first init event. Stop the child at that event.
// Reject with Error('probe-failed') when the run ends with no init event. An abort of the signal
// stops the child.
export async function probeInventory(
  spawnLines: SpawnLines,
  cwd: string,
  signal?: AbortSignal,
): Promise<McpInventory> {
  let found: McpInventory | null = null
  await spawnLines(PROBE_ARGS, {
    cwd,
    onLine: line => {
      if (found) return true
      found = parseInitEvent(line)
      return found !== null
    },
    signal,
    timeoutMs: PROBE_TIMEOUT_MS,
  })
  if (!found) throw new Error('probe-failed')
  return found
}
