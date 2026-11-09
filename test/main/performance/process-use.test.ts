import { describe, expect, it, vi } from 'vitest'
import { type AppMetric, bifrostUse, sessionUse } from '../../../src/main/performance/process-use'
import type { ProcRow } from '../../../src/main/performance/system'
import { PROC_GROUPS } from '../../../src/shared/performance'
import type { SessionRow } from '../../../src/shared/types'

// The KB in one MB.
const KB_PER_MB = 1024

// A session ID. n is one digit.
const uuid = (n: number): string => `0000000${n}-0000-4000-8000-000000000000`

function metric(pid: number, type: string, ramMb: number, cpu: number): AppMetric {
  return { cpu: { percentCPUUsage: cpu }, memory: { workingSetSize: ramMb * KB_PER_MB }, pid, type }
}

// A ps table from [pid, ppid, rssMb, cpuSeconds] rows.
function table(rows: Array<[number, number, number, number]>): Map<number, ProcRow> {
  return new Map(
    rows.map(([pid, ppid, rssMb, cpuSeconds]) => [
      pid,
      { cpuSeconds, pid, ppid, rssKb: rssMb * KB_PER_MB },
    ]),
  )
}

function sessionRow(sessionId: string, name: string, pid?: number): SessionRow {
  return {
    box: 'none',
    boxSince: null,
    claudeName: name,
    cwd: '/tmp/project',
    flashing: false,
    kind: 'owned',
    lastActivity: 0,
    name,
    sessionId,
    startedAt: 0,
    state: 'working',
    status: 'busy',
    ...(pid === undefined ? {} : { pid }),
  } as SessionRow
}

const noCpu = (): number => 0

describe('bifrostUse', () => {
  it('groups the Electron types and the chat terminals in a fixed order', () => {
    const use = bifrostUse(
      [
        metric(100, 'Browser', 200, 3),
        metric(101, 'Tab', 300, 5),
        metric(102, 'GPU', 100, 2),
        metric(103, 'Utility', 60, 1),
        metric(104, 'Pepper Plugin', 40, 1),
        metric(105, 'Tab', 50, 1),
      ],
      [
        { cpu: 4, ramMb: 40 },
        { cpu: 0, ramMb: 20 },
      ],
    )
    expect(use.groups).toEqual([
      { count: 1, cpu: 3, name: 'Main process', ramMb: 200 },
      { count: 2, cpu: 6, name: 'Window', ramMb: 350 },
      { count: 1, cpu: 2, name: 'GPU', ramMb: 100 },
      { count: 2, cpu: 4, name: 'Chat terminals', ramMb: 60 },
      { count: 2, cpu: 2, name: 'Other helpers', ramMb: 100 },
    ])
    expect(use).toMatchObject({ cpu: 17, ramMb: 810, terminals: { cpu: 4, ramMb: 60 } })
  })

  // The panel finds the chat terminal group by the shared name (fix round 1, ruling A).
  it('names the groups with the shared names of PROC_GROUPS', () => {
    expect(PROC_GROUPS).toEqual({
      gpu: 'GPU',
      helpers: 'Other helpers',
      main: 'Main process',
      terminals: 'Chat terminals',
      window: 'Window',
    })
    const use = bifrostUse([metric(100, 'Browser', 200, 3), metric(101, 'Utility', 60, 1)], [])
    expect(use.groups.map(g => g.name)).toEqual([
      PROC_GROUPS.main,
      PROC_GROUPS.window,
      PROC_GROUPS.gpu,
      PROC_GROUPS.terminals,
      PROC_GROUPS.helpers,
    ])
  })

  it('shows Other helpers only when a helper runs, and Chat terminals always', () => {
    const use = bifrostUse([metric(100, 'Browser', 200, 3)], [])
    expect(use.groups.map(g => [g.name, g.count])).toEqual([
      ['Main process', 1],
      ['Window', 0],
      ['GPU', 0],
      ['Chat terminals', 0],
    ])
    expect(use).toMatchObject({ cpu: 3, ramMb: 200, terminals: { cpu: 0, ramMb: 0 } })
  })
})

describe('sessionUse', () => {
  it('sums the tree of each session one time and leaves out Bifrost', () => {
    const procs = table([
      // Session B started Bifrost (100). Bifrost, its helper and its PTY do not count.
      [100, 400, 999, 0],
      [101, 100, 999, 0],
      [200, 100, 40, 0],
      // Session A, its MCP server, a tool, and session C that started inside A.
      [300, 1, 100, 0],
      [301, 300, 50, 0],
      [302, 301, 10, 0],
      [310, 300, 30, 0],
      [400, 1, 80, 0],
      [500, 1, 900, 0],
    ])
    const rows = [
      sessionRow(uuid(1), 'alpha', 300),
      sessionRow(uuid(2), 'bravo', 400),
      sessionRow(uuid(3), 'charlie', 310),
    ]
    const use = sessionUse(rows, procs, new Set([100, 101, 200]), noCpu)
    expect(use.top.map(s => [s.name, s.ramMb])).toEqual([
      ['alpha', 160],
      ['bravo', 80],
      ['charlie', 30],
    ])
    expect(use.ramMb).toBe(270)
  })

  it('gives the three largest sessions and the rest', () => {
    const sizes = [10, 50, 30, 40, 20]
    const procs = table(sizes.map((rssMb, i) => [300 + i, 1, rssMb, i + 1]))
    const rows = sizes.map((_, i) => sessionRow(uuid(i + 1), `s${i}`, 300 + i))
    // The fake CPU of a process is its CPU time.
    const use = sessionUse(rows, procs, new Set(), row => row.cpuSeconds)
    expect(use.top.map(s => [s.name, s.ramMb, s.cpu, s.sessionId])).toEqual([
      ['s1', 50, 2, uuid(2)],
      ['s3', 40, 4, uuid(4)],
      ['s2', 30, 3, uuid(3)],
    ])
    expect(use.more).toEqual({ count: 2, cpu: 1 + 5, ramMb: 30 })
    expect(use).toMatchObject({ cpu: 15, ramMb: 150 })
  })

  it('reads the CPU of each process one time', () => {
    const procs = table([
      [300, 1, 100, 0],
      [301, 300, 50, 0],
      [310, 300, 30, 0],
    ])
    const procCpu = vi.fn((_row: ProcRow) => 1)
    const use = sessionUse(
      [sessionRow(uuid(1), 'alpha', 300), sessionRow(uuid(2), 'charlie', 310)],
      procs,
      new Set(),
      procCpu,
    )
    expect(procCpu.mock.calls.map(([row]) => row.pid).sort()).toEqual([300, 301, 310])
    expect(use.top.map(s => [s.name, s.cpu])).toEqual([
      ['alpha', 2],
      ['charlie', 1],
    ])
  })

  it('skips a row with no pid, a gone pid, a Bifrost pid and a second row with the same pid', () => {
    const procs = table([
      [100, 1, 999, 0],
      [300, 1, 100, 0],
    ])
    const rows = [
      sessionRow(uuid(1), 'alpha', 300),
      sessionRow(uuid(2), 'parked'),
      sessionRow(uuid(3), 'gone', 600),
      sessionRow(uuid(4), 'bifrost', 100),
      sessionRow(uuid(5), 'again', 300),
    ]
    const use = sessionUse(rows, procs, new Set([100]), noCpu)
    expect(use.top.map(s => s.name)).toEqual(['alpha'])
    expect(use).toEqual({
      cpu: 0,
      more: { count: 0, cpu: 0, ramMb: 0 },
      ramMb: 100,
      top: [{ cpu: 0, name: 'alpha', ramMb: 100, sessionId: uuid(1) }],
    })
  })
})
