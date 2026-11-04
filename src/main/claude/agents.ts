import type { RunClaude } from './cli'

export interface AgentEntry {
  pid: number
  cwd: string
  kind: string
  startedAt: number
  sessionId: string
  name: string
  status: string
  id?: string
}
export type AgentList = { entries: AgentEntry[]; error?: string }

function toEntry(raw: unknown): AgentEntry | null {
  if (typeof raw !== 'object' || raw === null) return null
  const r = raw as Record<string, unknown>
  if (typeof r.pid !== 'number' || typeof r.sessionId !== 'string' || r.sessionId === '')
    return null
  const entry: AgentEntry = {
    cwd: typeof r.cwd === 'string' ? r.cwd : '',
    kind: typeof r.kind === 'string' ? r.kind : '',
    name: typeof r.name === 'string' ? r.name : '',
    pid: r.pid,
    sessionId: r.sessionId,
    startedAt: typeof r.startedAt === 'number' ? r.startedAt : 0,
    status: typeof r.status === 'string' ? r.status : '',
  }
  if (typeof r.id === 'string') entry.id = r.id
  return entry
}

// Read the output of "claude agents --json".
// The parser starts at the first line that begins with "[".
// It skips an entry that has no pid or no sessionId.
export function parseAgents(stdout: string): AgentList {
  if (stdout.trim() === '') return { entries: [], error: 'empty output' }
  const lines = stdout.split('\n')
  const start = lines.findIndex(line => line.startsWith('['))
  if (start === -1) return { entries: [], error: 'parse error: no JSON array in output' }
  let data: unknown
  try {
    data = JSON.parse(lines.slice(start).join('\n'))
  } catch (e) {
    return { entries: [], error: `parse error: ${(e as Error).message}` }
  }
  if (!Array.isArray(data)) return { entries: [], error: 'parse error: output is not an array' }
  const entries = data.map(toEntry).filter((e): e is AgentEntry => e !== null)
  return { entries }
}

export async function listAgents(run: RunClaude, opts?: { all?: boolean }): Promise<AgentList> {
  const args = ['agents', '--json']
  if (opts?.all) args.push('--all')
  const result = await run(args)
  if (result.code !== 0) {
    return { entries: [], error: result.stderr.trim() || `claude exited with code ${result.code}` }
  }
  return parseAgents(result.stdout)
}
