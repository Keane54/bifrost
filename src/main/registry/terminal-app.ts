import type { ExecFn } from '../claude/cli'

// The terminal app that holds a session process.
export interface TerminalApp {
  name: string
  bundle: string
}

// The process table. The key is the PID.
export type ProcessTable = Map<number, { ppid: number; comm: string }>

export const PS = '/bin/ps'
export const PS_TABLE_ARGS = ['-axo', 'pid=,ppid=,comm=']

const TABLE_TIMEOUT_MS = 5000
const MAX_STEPS = 64

// Read the output of ps. A line that does not match is skipped.
// The comm can hold spaces, so it is the rest of the line.
export function parseProcessTable(stdout: string): ProcessTable {
  const table: ProcessTable = new Map()
  for (const line of stdout.split('\n')) {
    const m = /^\s*(\d+)\s+(\d+)\s+(.+)$/.exec(line)
    if (m) table.set(Number(m[1]), { comm: m[3].trimEnd(), ppid: Number(m[2]) })
  }
  return table
}

// Walk up the parent PIDs from pid. The first process in an app bundle gives the app.
// The walk stops at PID 1 or less, at a missing PID, at a loop, and after 64 steps.
export function terminalAppOf(table: ProcessTable, pid: number): TerminalApp | null {
  const seen = new Set<number>()
  let current = pid
  for (let step = 0; step < MAX_STEPS; step++) {
    if (current <= 1 || seen.has(current)) return null
    seen.add(current)
    const entry = table.get(current)
    if (!entry) return null
    const at = entry.comm.indexOf('.app/')
    if (at >= 0) {
      const bundle = entry.comm.slice(0, at + 4)
      return { bundle, name: bundle.slice(bundle.lastIndexOf('/') + 1, -4) }
    }
    current = entry.ppid
  }
  return null
}

// Read the process table with one ps run. A failed run gives null.
export async function readProcessTable(exec: ExecFn): Promise<ProcessTable | null> {
  const result = await exec(PS, PS_TABLE_ARGS, { timeoutMs: TABLE_TIMEOUT_MS })
  return result.code === 0 ? parseProcessTable(result.stdout) : null
}
