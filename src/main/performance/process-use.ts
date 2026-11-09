// The RAM and CPU of the process groups of Bifrost and of the Claude sessions (Performance design
// sections 5.2 and 6). This code is pure. The monitor gives it the Electron metrics, the chat
// terminal values and one ps table.
import {
  type PerformanceSnapshot,
  PROC_GROUPS,
  type ProcGroup,
  type SessionUse,
} from '../../shared/performance'
import type { SessionRow } from '../../shared/types'
import { childIndex, type ProcRow, treeSumIn } from './system'

// One Electron process of app.getAppMetrics(). The memory is in KB.
export interface AppMetric {
  pid: number
  type: string
  cpu: { percentCPUUsage: number }
  memory: { workingSetSize: number }
}

// The RAM in MB and the CPU in percent of one core.
export interface Use {
  ramMb: number
  cpu: number
}

// The groups of the Bifrost section and the totals with the chat terminals. terminals is the
// part of the chat terminals.
export interface BifrostUse extends Use {
  groups: ProcGroup[]
  terminals: Use
}

export type Sessions = NonNullable<PerformanceSnapshot['sessions']>

const KB_PER_MB = 1024
// The number of sessions with their own row. The others go in the "N more" row.
const TOP = 3

// Each Electron type that is not here is a helper.
const GROUP_OF: Readonly<Record<string, string>> = {
  Browser: PROC_GROUPS.main,
  GPU: PROC_GROUPS.gpu,
  Tab: PROC_GROUPS.window,
}
const TERMINALS = PROC_GROUPS.terminals
const HELPERS = PROC_GROUPS.helpers
const GROUP_ORDER = [PROC_GROUPS.main, PROC_GROUPS.window, PROC_GROUPS.gpu, TERMINALS, HELPERS]

// Group the Electron processes and the chat terminals (one value for each PTY). The groups are
// in a fixed order. Other helpers shows only when a helper runs.
export function bifrostUse(metrics: readonly AppMetric[], terminals: readonly Use[]): BifrostUse {
  const groups = new Map<string, ProcGroup>(
    GROUP_ORDER.map(name => [name, { count: 0, cpu: 0, name, ramMb: 0 }]),
  )
  const add = (name: string, ramMb: number, cpu: number): void => {
    const g = groups.get(name) as ProcGroup
    g.count += 1
    g.ramMb += ramMb
    g.cpu += cpu
  }
  for (const m of metrics) {
    add(GROUP_OF[m.type] ?? HELPERS, m.memory.workingSetSize / KB_PER_MB, m.cpu.percentCPUUsage)
  }
  for (const t of terminals) add(TERMINALS, t.ramMb, t.cpu)
  const term = groups.get(TERMINALS) as ProcGroup
  const shown = [...groups.values()].filter(g => g.name !== HELPERS || g.count > 0)
  return {
    cpu: shown.reduce((a, g) => a + g.cpu, 0),
    groups: shown,
    ramMb: shown.reduce((a, g) => a + g.ramMb, 0),
    terminals: { cpu: term.cpu, ramMb: term.ramMb },
  }
}

// The Claude sessions: each registry row with a pid and its process tree (design section 6).
// own holds the pids of Bifrost. They and their descendants count for no session.
// One children index serves all rows. A session that started inside another session keeps its
// own processes, because the smaller tree goes first. So each process counts one time, and
// procCpu runs one time for each process.
export function sessionUse(
  rows: readonly SessionRow[],
  table: Map<number, ProcRow>,
  own: ReadonlySet<number>,
  procCpu: (row: ProcRow) => number,
): Sessions {
  const children = childIndex(table, own)
  const trees = rows.flatMap(row =>
    row.pid !== undefined && !own.has(row.pid) && table.has(row.pid)
      ? [{ pids: treeSumIn(table, children, row.pid).pids, row }]
      : [],
  )
  trees.sort((a, b) => a.pids.length - b.pids.length)
  const counted = new Set<number>()
  const list: SessionUse[] = []
  for (const { pids, row } of trees) {
    let rssKb = 0
    let cpu = 0
    let found = 0
    for (const pid of pids) {
      const proc = table.get(pid)
      if (proc === undefined || counted.has(pid)) continue
      counted.add(pid)
      found += 1
      rssKb += proc.rssKb
      cpu += procCpu(proc)
    }
    // A row with the same pid as an earlier row has no process left.
    if (found === 0) continue
    list.push({ cpu, name: row.name, ramMb: rssKb / KB_PER_MB, sessionId: row.sessionId })
  }
  list.sort((a, b) => b.ramMb - a.ramMb)
  const rest = list.slice(TOP)
  return {
    cpu: list.reduce((a, s) => a + s.cpu, 0),
    more: {
      count: rest.length,
      cpu: rest.reduce((a, s) => a + s.cpu, 0),
      ramMb: rest.reduce((a, s) => a + s.ramMb, 0),
    },
    ramMb: list.reduce((a, s) => a + s.ramMb, 0),
    top: list.slice(0, TOP),
  }
}
