import type * as os from 'node:os'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ExecFn, ExecResult } from '../../../src/main/claude/cli'
import { GH_LIMIT_LOGGED_OUT } from '../../../src/main/performance/bindings'
import { createHealthLog } from '../../../src/main/performance/health-log'
import {
  BATTERY_MS,
  CLONES_MS,
  COMMAND_MS,
  createPerformanceMonitor,
  DISK_MS,
  FAST_TICK_MS,
  type GithubLimit,
  HISTORY_MS,
  type MonitorDeps,
  PROBE_MS,
  PROBE_URLS,
  type ProbeResult,
  SAMPLE_GAP_MS,
  TICK_MS,
  TREND_MS,
} from '../../../src/main/performance/monitor'
import {
  DU,
  NETSTAT,
  NETWORKSETUP,
  PMSET,
  PS,
  ROUTE,
  SYSCTL,
} from '../../../src/main/performance/system'
import { EMPTY_PERFORMANCE, type PerformanceSnapshot } from '../../../src/shared/performance'
import type { SessionRow } from '../../../src/shared/types'

const SEC = 1000
const MIN = 60_000
// The KB in one MB.
const KB_PER_MB = 1024
const RESET = Date.parse('2026-11-09T11:00:00Z')

// A session ID. n is one digit.
const uuid = (n: number): string => `0000000${n}-0000-4000-8000-000000000000`
const chat = (id: string): string => `chat:${id}`
const send = (id: string): string => `send:${id}`

// One process of the fake ps table. cpu is the cumulative CPU time in seconds.
interface Proc {
  pid: number
  ppid: number
  rssMb: number
  cpu: number
}

// One Electron process of the fake getAppMetrics.
interface Metric {
  pid: number
  type: string
  cpu: number
  ramMb: number
}

// The ps time format M:SS.cc.
function cpuTime(seconds: number): string {
  const m = Math.floor(seconds / 60)
  return `${m}:${(seconds - m * 60).toFixed(2).padStart(5, '0')}`
}

function psOut(procs: Proc[]): string {
  return procs
    .map(p => `${p.pid} ${p.ppid} ${Math.round(p.rssMb * KB_PER_MB)} ${cpuTime(p.cpu)} /bin/thing`)
    .join('\n')
}

function netstatOut(device: string, inBytes: number, outBytes: number): string {
  return [
    'Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll',
    'lo0        16384 <Link#1>                       5610467     0 26388186710  5610467     0 26388186710     0',
    `${device}        1500  <Link#14>   aa:bb:cc:dd:ee:01  8000000     0  ${inBytes}  4000000     0  ${outBytes}     -`,
  ].join('\n')
}

const SWAP = 'total = 2048.00M  used = 512.00M  free = 1536.00M  (encrypted)'
const BATTERY =
  "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t80%; discharging; 3:00 remaining present: true\n"
const routeOut = (device: string): string =>
  `   route to: default\ndestination: default\n  interface: ${device}\n`
const PORTS = [
  'Hardware Port: Wi-Fi',
  'Device: en0',
  'Ethernet Address: aa:bb:cc:dd:ee:01',
  '',
  'Hardware Port: Ethernet',
  'Device: en1',
  'Ethernet Address: aa:bb:cc:dd:ee:02',
].join('\n')
const FAILED: ExecResult = { code: 1, stderr: 'failed', stdout: '' }

function ok(stdout: string): ExecResult {
  return { code: 0, stderr: '', stdout }
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

function cpuInfo(busy: number, idle: number): os.CpuInfo {
  return { model: 'M', speed: 1, times: { idle, irq: 0, nice: 0, sys: 0, user: busy } }
}

// Bifrost uses 700 MB and 12% CPU without chat terminals.
const BIFROST: Metric[] = [
  { cpu: 3, pid: 100, ramMb: 200, type: 'Browser' },
  { cpu: 5, pid: 101, ramMb: 300, type: 'Tab' },
  { cpu: 2, pid: 102, ramMb: 100, type: 'GPU' },
  { cpu: 1, pid: 103, ramMb: 60, type: 'Utility' },
  { cpu: 1, pid: 104, ramMb: 40, type: 'Utility' },
]

const SHOW = { chatPanels: [] as string[], focused: true, showing: true }
const HIDE = { chatPanels: [] as string[], focused: true, showing: false }

interface World {
  procs: Proc[]
  metrics: Metric[]
  ptys: Array<{ viewId: string; pid: number }>
  rows: SessionRow[]
  cpus: os.CpuInfo[]
  online: boolean
  thermal: string | null
  inBytes: number
  outBytes: number
  rateLimit: GithubLimit | null
  delay: number | null
  // The default route interface.
  device: string
  psFails: boolean
  routeFails: boolean
  clonesExist: boolean
  metricsThrow: boolean
  emitThrows: boolean
}

function setup(opts: { network?: boolean; clonesPath?: string | null } = {}) {
  const world: World = {
    clonesExist: true,
    cpus: [cpuInfo(0, 0)],
    delay: null,
    device: 'en0',
    emitThrows: false,
    inBytes: 1_000_000,
    metrics: BIFROST.map(m => ({ ...m })),
    metricsThrow: false,
    online: true,
    outBytes: 500_000,
    procs: [{ cpu: 0, pid: 100, ppid: 1, rssMb: 1 }],
    psFails: false,
    ptys: [],
    rateLimit: null,
    routeFails: false,
    rows: [],
    thermal: 'nominal',
  }
  const exec = vi.fn<ExecFn>(async (file, args) => {
    if (file === PS) return world.psFails ? FAILED : ok(psOut(world.procs))
    if (file === SYSCTL) return ok(args.includes('vm.swapusage') ? SWAP : '1\n')
    if (file === PMSET) return ok(BATTERY)
    if (file === ROUTE) return world.routeFails ? FAILED : ok(routeOut(world.device))
    if (file === NETWORKSETUP) return ok(PORTS)
    if (file === NETSTAT) return ok(netstatOut(world.device, world.inBytes, world.outBytes))
    if (file === DU) return ok(`2048\t${args.at(-1)}\n`)
    return { code: 1, stderr: `unknown command ${file}`, stdout: '' }
  })
  const probe = vi.fn(
    async (url: string): Promise<ProbeResult> => (url === PROBE_URLS.anthropic ? 120 : 80),
  )
  const ghRateLimit = vi.fn(
    async (): Promise<GithubLimit | { unavailable: string }> => ({
      limit: 5000,
      remaining: 4999,
      resetAt: RESET,
    }),
  )
  const freeDiskBytes = vi.fn(async (): Promise<number | null> => 250e9)
  const exists = vi.fn(async (_path: string): Promise<boolean> => world.clonesExist)
  const emitted: PerformanceSnapshot[] = []
  const health = createHealthLog(() => Date.now())
  const deps: MonitorDeps = {
    appMetrics: () => {
      if (world.metricsThrow) throw new Error('no metrics')
      return world.metrics.map(m => ({
        cpu: { percentCPUUsage: m.cpu },
        memory: { workingSetSize: m.ramMb * KB_PER_MB },
        pid: m.pid,
        type: m.type,
      }))
    },
    clonesPath: opts.clonesPath ?? null,
    cpus: () => world.cpus,
    delayMs: () => world.delay,
    emit: s => {
      if (world.emitThrows) throw new Error('no window')
      emitted.push(s)
    },
    exec,
    exists,
    freeDiskBytes,
    ghRateLimit,
    health,
    network: opts.network ?? true,
    now: () => Date.now(),
    online: () => world.online,
    probe,
    ptys: () => world.ptys,
    rateLimit: () => world.rateLimit,
    rows: () => world.rows,
    thermal: () => world.thermal,
  }
  const monitor = createPerformanceMonitor(deps)
  const calls = (file: string): number => exec.mock.calls.filter(([f]) => f === file).length
  const netCalls = (): number => calls(ROUTE) + calls(NETWORKSETUP) + calls(NETSTAT)
  return {
    calls,
    emitted,
    exec,
    exists,
    freeDiskBytes,
    ghRateLimit,
    health,
    monitor,
    netCalls,
    probe,
    world,
  }
}

type Setup = ReturnType<typeof setup>

function group(snap: PerformanceSnapshot, name: string) {
  return snap.bifrost?.groups.find(g => g.name === name)
}

function hasReason(t: Setup, part: string): boolean {
  return t.monitor.current().reasons.some(r => r.text.includes(part))
}

const orphan = (t: Setup): boolean => hasReason(t, 'no chat window')

// The next call of the command waits until the test calls the returned function.
function holdNext(t: Setup, file: string): () => void {
  const real = t.exec.getMockImplementation() as ExecFn
  let release: () => void = () => {}
  const held = new Promise<void>(resolve => {
    release = resolve
  })
  let used = false
  t.exec.mockImplementation(async (f, args, opts) => {
    if (f === file && !used) {
      used = true
      await held
    }
    return real(f, args, opts)
  })
  return release
}

beforeEach(() => {
  vi.useFakeTimers()
  vi.setSystemTime(new Date('2026-11-09T10:00:00Z'))
})
afterEach(() => {
  vi.useRealTimers()
})

describe('createPerformanceMonitor', () => {
  it('one tick runs one ps call and no network read while the panel is closed', async () => {
    const t = setup()
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(t.calls(PS)).toBe(1)
    expect(t.netCalls()).toBe(0)
    expect(t.probe).not.toHaveBeenCalled()
    expect(t.ghRateLimit).not.toHaveBeenCalled()
    // No Reviews clones folder is set, so du never runs.
    expect(t.calls(DU)).toBe(0)
    // The snapshot goes out also while the panel is closed, for the side bar dot.
    expect(t.emitted).toHaveLength(1)
    await vi.advanceTimersByTimeAsync(TICK_MS)
    expect(t.calls(PS)).toBe(2)
    expect(t.netCalls()).toBe(0)
    expect(t.emitted).toHaveLength(2)
    expect(t.emitted.at(-1)).toEqual(t.monitor.current())
    expect(t.monitor.current().network).toEqual({
      anthropicMs: null,
      downBps: null,
      githubMs: null,
      kind: null,
      online: true,
      upBps: null,
    })
    t.monitor.stop()
  })

  it('the tick is 2 s while showing and 15 s after the panel closes', async () => {
    const t = setup()
    // Each tick emits one snapshot.
    const ticks = (): number => t.emitted.length
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(ticks()).toBe(1)
    // The panel shows. The next tick comes 2 s after the end of the last tick.
    t.monitor.view(SHOW)
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS - 1)
    expect(ticks()).toBe(1)
    await vi.advanceTimersByTimeAsync(1)
    expect(ticks()).toBe(2)
    await vi.advanceTimersByTimeAsync(10 * FAST_TICK_MS)
    expect(ticks()).toBe(12)
    // The panel closes. The next tick comes 15 s after the end of the last tick.
    t.monitor.view(HIDE)
    await vi.advanceTimersByTimeAsync(TICK_MS - 1)
    expect(ticks()).toBe(12)
    await vi.advanceTimersByTimeAsync(1)
    expect(ticks()).toBe(13)
    // The panel shows 10 s after a tick. The 2 s are past, so a tick comes at once.
    await vi.advanceTimersByTimeAsync(10 * SEC)
    t.monitor.view(SHOW)
    await vi.advanceTimersByTimeAsync(0)
    expect(ticks()).toBe(14)
    // A report that changes only the chat panels does not move the timer.
    t.monitor.view({ ...SHOW, chatPanels: [chat(uuid(1))] })
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS - 1)
    expect(ticks()).toBe(14)
    await vi.advanceTimersByTimeAsync(1)
    expect(ticks()).toBe(15)
    t.monitor.stop()
  })

  it('while the panel shows, ps and netstat run at most every 6 s with real time deltas', async () => {
    const t = setup()
    t.world.procs = [{ cpu: 10, pid: 200, ppid: 100, rssMb: 40 }]
    t.world.ptys = [{ pid: 200, viewId: chat(uuid(1)) }]
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(t.calls(PS)).toBe(1)
    t.monitor.view(SHOW)
    // 0.6 s of CPU time before the next ps read.
    t.world.procs = [{ cpu: 10.6, pid: 200, ppid: 100, rssMb: 40 }]
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS)
    // No ps at 2 s. The tick keeps the terminal values of the last ps read.
    expect(t.calls(PS)).toBe(1)
    expect(group(t.monitor.current(), 'Chat terminals')).toMatchObject({ cpu: 0, ramMb: 40 })
    expect(t.calls(NETSTAT)).toBe(1)
    t.world.inBytes += 6000
    t.world.outBytes += 3000
    await vi.advanceTimersByTimeAsync(2 * FAST_TICK_MS)
    // The ps read at 6 s: 0.6 s of CPU time in 6 s is 10% of one core.
    expect(t.calls(PS)).toBe(2)
    expect(group(t.monitor.current(), 'Chat terminals')?.cpu).toBeCloseTo(10)
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS)
    // The netstat read at 8 s: 6000 bytes in 6 s.
    expect(t.calls(NETSTAT)).toBe(2)
    expect(t.monitor.current().network).toMatchObject({ downBps: 1000, upBps: 500 })
    // 30 s of showing: 15 ticks, but only 5 ps reads and 5 netstat reads.
    await vi.advanceTimersByTimeAsync(22 * SEC)
    expect(t.emitted).toHaveLength(16)
    expect(t.calls(PS)).toBe(1 + 5)
    expect(t.calls(NETSTAT)).toBe(5)
    expect(COMMAND_MS).toBe(6000)
    t.monitor.stop()
  })

  it('a clock that goes back does not stop the ticks or the reads', async () => {
    const t = setup()
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(t.calls(PMSET)).toBe(1)
    vi.setSystemTime(Date.now() - 60 * MIN)
    // The end of the last tick is now 60 minutes in the future. The wait is still 2 s.
    t.monitor.view(SHOW)
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS)
    expect(t.calls(PS)).toBe(2)
    // The last battery read is in the future, so the read is due again.
    expect(t.calls(PMSET)).toBe(2)
    t.monitor.stop()
  })

  it('groups Electron processes and chat terminals, and sums each session tree once', async () => {
    const t = setup()
    t.world.procs = [
      // Session B started Bifrost, as a dev run from a Claude session can do. Bifrost and its
      // child processes do not count for session B.
      { cpu: 0, pid: 100, ppid: 400, rssMb: 999 },
      { cpu: 0, pid: 101, ppid: 100, rssMb: 999 },
      { cpu: 0, pid: 200, ppid: 100, rssMb: 40 },
      { cpu: 0, pid: 201, ppid: 100, rssMb: 20 },
      // Session A, its MCP server and a tool of the MCP server.
      { cpu: 0, pid: 300, ppid: 1, rssMb: 100 },
      { cpu: 0, pid: 301, ppid: 300, rssMb: 50 },
      { cpu: 0, pid: 302, ppid: 301, rssMb: 10 },
      // Session C started inside session A. Its process counts only for C.
      { cpu: 0, pid: 310, ppid: 300, rssMb: 30 },
      { cpu: 0, pid: 400, ppid: 1, rssMb: 80 },
      // A process that is not in the registry.
      { cpu: 0, pid: 500, ppid: 1, rssMb: 900 },
    ]
    t.world.ptys = [
      { pid: 200, viewId: chat(uuid(1)) },
      { pid: 201, viewId: send(uuid(2)) },
    ]
    t.world.rows = [
      sessionRow(uuid(1), 'alpha', 300),
      sessionRow(uuid(2), 'bravo', 400),
      sessionRow(uuid(3), 'charlie', 310),
      sessionRow(uuid(4), 'parked'),
      sessionRow(uuid(5), 'gone', 600),
    ]
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    const snap = t.monitor.current()
    expect(snap.bifrost?.groups).toEqual([
      { count: 1, cpu: 3, name: 'Main process', ramMb: 200 },
      { count: 1, cpu: 5, name: 'Window', ramMb: 300 },
      { count: 1, cpu: 2, name: 'GPU', ramMb: 100 },
      { count: 2, cpu: 0, name: 'Chat terminals', ramMb: 60 },
      { count: 2, cpu: 2, name: 'Other helpers', ramMb: 100 },
    ])
    // The totals have the chat terminals.
    expect(snap.bifrost).toMatchObject({ cpu: 12, ramMb: 760 })
    expect(snap.sessions).toEqual({
      cpu: 0,
      more: { count: 0, cpu: 0, ramMb: 0 },
      ramMb: 270,
      top: [
        { cpu: 0, name: 'alpha', ramMb: 160, sessionId: uuid(1) },
        { cpu: 0, name: 'bravo', ramMb: 80, sessionId: uuid(2) },
        { cpu: 0, name: 'charlie', ramMb: 30, sessionId: uuid(3) },
      ],
    })
    t.monitor.stop()
  })

  it('cpu of a ps process is the change of its cpu time', async () => {
    const t = setup()
    t.world.procs = [
      { cpu: 10, pid: 200, ppid: 100, rssMb: 40 },
      { cpu: 5, pid: 300, ppid: 1, rssMb: 100 },
      { cpu: 1, pid: 301, ppid: 300, rssMb: 50 },
    ]
    t.world.ptys = [{ pid: 200, viewId: chat(uuid(1)) }]
    t.world.rows = [sessionRow(uuid(1), 'alpha', 300)]
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    // The first sample of a process gives 0, because macOS ps gives no current value (P3).
    expect(group(t.monitor.current(), 'Chat terminals')?.cpu).toBe(0)
    expect(t.monitor.current().sessions?.top[0]?.cpu).toBe(0)
    t.world.procs = [
      // 3 s of CPU time in 15 s is 20% of one core.
      { cpu: 13, pid: 200, ppid: 100, rssMb: 40 },
      { cpu: 6.5, pid: 300, ppid: 1, rssMb: 100 },
      { cpu: 1.75, pid: 301, ppid: 300, rssMb: 50 },
      // A new child process gives 0 in its first sample.
      { cpu: 100, pid: 302, ppid: 301, rssMb: 10 },
    ]
    await vi.advanceTimersByTimeAsync(TICK_MS)
    const snap = t.monitor.current()
    expect(group(snap, 'Chat terminals')?.cpu).toBeCloseTo(20)
    expect(snap.bifrost?.cpu).toBeCloseTo(12 + 20)
    expect(snap.sessions?.top[0]?.cpu).toBeCloseTo(15)
    expect(snap.sessions?.top[0]?.ramMb).toBe(160)
    expect(snap.sessions?.cpu).toBeCloseTo(15)
    t.monitor.stop()
  })

  it('cpu is a share of all cores of the Mac', async () => {
    const t = setup()
    t.world.cpus = Array.from({ length: 10 }, () => cpuInfo(0, 0))
    t.world.procs = [{ cpu: 5, pid: 300, ppid: 1, rssMb: 100 }]
    t.world.rows = [sessionRow(uuid(1), 'alpha', 300)]
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    // 18.75 s of CPU time in 15 s is 125% of one core and 12.5% of 10 cores.
    t.world.procs = [{ cpu: 23.75, pid: 300, ppid: 1, rssMb: 100 }]
    await vi.advanceTimersByTimeAsync(TICK_MS)
    const snap = t.monitor.current()
    expect(snap.sessions?.top[0]?.cpu).toBeCloseTo(12.5)
    expect(snap.sessions?.cpu).toBeCloseTo(12.5)
    // The Electron metrics of 12% of one core give 1.2% of 10 cores.
    expect(snap.bifrost?.cpu).toBeCloseTo(1.2)
    t.monitor.stop()
  })

  it('the three heaviest sessions and the rest', async () => {
    const t = setup()
    const sizes = [10, 50, 30, 40, 20]
    t.world.procs = sizes.map((rssMb, i) => ({ cpu: 0, pid: 300 + i, ppid: 1, rssMb }))
    t.world.rows = sizes.map((_, i) => sessionRow(uuid(i + 1), `s${i}`, 300 + i))
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    // Session i uses (i + 1)% of one core in the next 15 s.
    t.world.procs = sizes.map((rssMb, i) => ({ cpu: 0.15 * (i + 1), pid: 300 + i, ppid: 1, rssMb }))
    await vi.advanceTimersByTimeAsync(TICK_MS)
    const sessions = t.monitor.current().sessions
    expect(sessions?.top.map(s => [s.name, s.ramMb])).toEqual([
      ['s1', 50],
      ['s3', 40],
      ['s2', 30],
    ])
    expect(sessions?.top.map(s => Math.round(s.cpu))).toEqual([2, 4, 3])
    expect(sessions?.more.count).toBe(2)
    expect(sessions?.more.ramMb).toBe(30)
    expect(sessions?.more.cpu).toBeCloseTo(1 + 5)
    expect(sessions?.ramMb).toBe(150)
    expect(sessions?.cpu).toBeCloseTo(15)
    t.monitor.stop()
  })

  it('an orphan chat terminal after 60 s', async () => {
    const t = setup()
    t.world.procs = [{ cpu: 0, pid: 200, ppid: 100, rssMb: 40 }]
    t.world.ptys = [{ pid: 200, viewId: chat(uuid(1)) }]
    t.monitor.start()
    // Before the first report of the chat panels, no chat terminal is an orphan.
    await vi.advanceTimersByTimeAsync(5 * MIN)
    expect(orphan(t)).toBe(false)
    // The renderer reports no open chat panel.
    t.monitor.view(HIDE)
    // 60 s is not more than 60 s.
    await vi.advanceTimersByTimeAsync(60 * SEC)
    expect(orphan(t)).toBe(false)
    await vi.advanceTimersByTimeAsync(TICK_MS)
    expect(orphan(t)).toBe(true)
    expect(t.monitor.current().reasons).toContainEqual({
      level: 'warning',
      text: '1 chat terminal is running with no chat window.',
    })
    expect(t.monitor.current().state).toBe('warning')
    // The chat panel is open again.
    t.monitor.view({ ...HIDE, chatPanels: [chat(uuid(1))] })
    await vi.advanceTimersByTimeAsync(TICK_MS)
    expect(orphan(t)).toBe(false)
    t.monitor.stop()
  })

  it('a send terminal open for more than 60 s is an orphan', async () => {
    const t = setup()
    t.world.ptys = [{ pid: 201, viewId: send(uuid(2)) }]
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(60 * SEC)
    expect(orphan(t)).toBe(false)
    await vi.advanceTimersByTimeAsync(TICK_MS)
    expect(orphan(t)).toBe(true)
    // The send ends. A new send of the same session starts a new count.
    t.world.ptys = []
    await vi.advanceTimersByTimeAsync(TICK_MS)
    expect(orphan(t)).toBe(false)
    t.world.ptys = [{ pid: 202, viewId: send(uuid(2)) }]
    await vi.advanceTimersByTimeAsync(TICK_MS)
    expect(orphan(t)).toBe(false)
    t.monitor.stop()
  })

  it('no probe and no gh call when network is false', async () => {
    const t = setup({ network: false })
    t.monitor.start()
    t.monitor.view(SHOW)
    await vi.advanceTimersByTimeAsync(5 * MIN)
    expect(t.probe).not.toHaveBeenCalled()
    expect(t.ghRateLimit).not.toHaveBeenCalled()
    expect(t.monitor.current().network).toMatchObject({ anthropicMs: null, githubMs: null })
    expect(t.monitor.current().limits.github).toBeNull()
    // The reads of the Mac still run. They are not network requests.
    expect(t.calls(NETSTAT)).toBeGreaterThan(0)
    t.monitor.stop()
  })

  it('probes Anthropic and GitHub at most every 60 s, only while the panel shows', async () => {
    const t = setup()
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(5 * MIN)
    expect(t.probe).not.toHaveBeenCalled()
    t.monitor.view(SHOW)
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS)
    expect(t.probe.mock.calls.map(([url]) => url)).toEqual([
      'https://api.anthropic.com',
      'https://api.github.com',
    ])
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS)
    expect(t.monitor.current().network).toMatchObject({ anthropicMs: 120, githubMs: 80 })
    await vi.advanceTimersByTimeAsync(PROBE_MS - 2 * FAST_TICK_MS)
    expect(t.probe).toHaveBeenCalledTimes(2)
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS)
    expect(t.probe).toHaveBeenCalledTimes(4)
    t.monitor.view(HIDE)
    await vi.advanceTimersByTimeAsync(5 * MIN)
    expect(t.probe).toHaveBeenCalledTimes(4)
    t.monitor.stop()
  })

  it('uses the Reviews rate limit, else gh rate_limit at most every 60 s while showing', async () => {
    const t = setup()
    // The Reviews value has the cost too. The snapshot does not.
    const fromReviews = { cost: 1, limit: 5000, remaining: 4930, resetAt: RESET }
    t.world.rateLimit = fromReviews
    t.monitor.start()
    t.monitor.view(SHOW)
    await vi.advanceTimersByTimeAsync(2 * MIN)
    expect(t.ghRateLimit).not.toHaveBeenCalled()
    expect(t.monitor.current().limits.github).toEqual({
      limit: 5000,
      remaining: 4930,
      resetAt: RESET,
    })
    // Reviews is off.
    t.world.rateLimit = null
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS)
    expect(t.ghRateLimit).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS)
    expect(t.monitor.current().limits.github).toEqual({
      limit: 5000,
      remaining: 4999,
      resetAt: RESET,
    })
    t.ghRateLimit.mockResolvedValueOnce({ unavailable: GH_LIMIT_LOGGED_OUT })
    await vi.advanceTimersByTimeAsync(PROBE_MS - 2 * FAST_TICK_MS)
    expect(t.ghRateLimit).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS)
    expect(t.ghRateLimit).toHaveBeenCalledTimes(2)
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS)
    expect(t.monitor.current().limits.github).toEqual({ unavailable: "GitHub CLI isn't signed in" })
    // The panel closes: no more gh calls.
    t.monitor.view(HIDE)
    await vi.advanceTimersByTimeAsync(5 * MIN)
    expect(t.ghRateLimit).toHaveBeenCalledTimes(2)
    t.monitor.stop()
  })

  it('reads the interface when the panel shows, and the rates at most every 6 s', async () => {
    const t = setup()
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    t.monitor.view(SHOW)
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS)
    expect([t.calls(ROUTE), t.calls(NETWORKSETUP), t.calls(NETSTAT)]).toEqual([1, 1, 1])
    // One read of the bytes gives no rate yet.
    expect(t.monitor.current().network).toMatchObject({
      downBps: null,
      kind: 'wifi',
      online: true,
      upBps: null,
    })
    t.world.inBytes += 6000
    t.world.outBytes += 3000
    await vi.advanceTimersByTimeAsync(COMMAND_MS)
    expect(t.calls(NETSTAT)).toBe(2)
    expect(t.monitor.current().network).toMatchObject({ downBps: 1000, upBps: 500 })
    // The monitor reads the interface again only after 60 s.
    await vi.advanceTimersByTimeAsync(52 * SEC)
    expect(t.calls(ROUTE)).toBe(1)
    expect(t.calls(NETSTAT)).toBe(10)
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS)
    expect(t.calls(ROUTE)).toBe(2)
    expect(t.calls(NETSTAT)).toBe(11)
    // The panel closes: no network command runs, and the rates go.
    t.monitor.view(HIDE)
    await vi.advanceTimersByTimeAsync(5 * MIN)
    expect(t.calls(NETSTAT)).toBe(11)
    expect(t.calls(ROUTE)).toBe(2)
    expect(t.monitor.current().network).toMatchObject({ downBps: null, upBps: null })
    // The panel shows again: the monitor reads the interface and the bytes at the next tick.
    t.monitor.view(SHOW)
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS)
    expect(t.calls(ROUTE)).toBe(3)
    expect(t.calls(NETSTAT)).toBe(12)
    // Online comes from net.isOnline in each state.
    t.world.online = false
    t.monitor.view(HIDE)
    await vi.advanceTimersByTimeAsync(TICK_MS)
    expect(t.monitor.current().network?.online).toBe(false)
    t.monitor.stop()
  })

  it('a new interface clears the rates', async () => {
    const t = setup()
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    t.monitor.view(SHOW)
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS)
    t.world.inBytes += 6000
    await vi.advanceTimersByTimeAsync(COMMAND_MS)
    expect(t.monitor.current().network?.downBps).toBe(1000)
    // The default route moves to the Ethernet port. The monitor reads it at 62 s.
    t.world.device = 'en1'
    await vi.advanceTimersByTimeAsync(54 * SEC)
    expect(t.calls(ROUTE)).toBe(2)
    expect(t.monitor.current().network).toMatchObject({
      downBps: null,
      kind: 'ethernet',
      upBps: null,
    })
    // The next read of the new interface gives a rate again.
    t.world.inBytes += 12_000
    await vi.advanceTimersByTimeAsync(COMMAND_MS)
    expect(t.monitor.current().network?.downBps).toBe(2000)
    t.monitor.stop()
  })

  it('a failed interface read runs again at the next tick', async () => {
    const t = setup()
    t.world.routeFails = true
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    t.monitor.view(SHOW)
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS)
    expect(t.calls(ROUTE)).toBe(1)
    expect(t.calls(NETSTAT)).toBe(0)
    expect(t.monitor.current().network?.kind).toBeNull()
    t.world.routeFails = false
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS)
    expect(t.calls(ROUTE)).toBe(2)
    expect(t.monitor.current().network?.kind).toBe('wifi')
    t.monitor.stop()
  })

  it('reads the battery and the free disk every 60 s, and the clones every 10 minutes', async () => {
    const clones = '/fake/home/.bifrost/reviews/repos'
    const t = setup({ clonesPath: clones })
    const counts = () => [t.calls(PMSET), t.freeDiskBytes.mock.calls.length, t.calls(DU)]
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(counts()).toEqual([1, 1, 1])
    expect(t.exec).toHaveBeenCalledWith(DU, ['-sk', clones], expect.anything())
    expect(BATTERY_MS).toBe(DISK_MS)
    await vi.advanceTimersByTimeAsync(BATTERY_MS - 1)
    expect(counts()).toEqual([1, 1, 1])
    await vi.advanceTimersByTimeAsync(1)
    expect(counts()).toEqual([2, 2, 1])
    await vi.advanceTimersByTimeAsync(CLONES_MS - BATTERY_MS)
    expect(counts()).toEqual([11, 11, 2])
    const snap = t.monitor.current()
    expect(snap.mac?.battery).toEqual({ charging: false, onBattery: true, percent: 80 })
    expect(snap.limits).toMatchObject({ clonesMb: 2, freeDiskGb: 250 })
    t.monitor.stop()
  })

  it('reads the clones size only when the folder exists', async () => {
    const clones = '/fake/home/.bifrost/reviews/repos'
    const t = setup({ clonesPath: clones })
    t.world.clonesExist = false
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(TICK_MS)
    expect(t.exists).toHaveBeenCalledWith(clones)
    expect(t.calls(DU)).toBe(0)
    expect(t.monitor.current().limits.clonesMb).toBeNull()
    // The folder exists at the next check, 10 minutes after the first one.
    t.world.clonesExist = true
    await vi.advanceTimersByTimeAsync(CLONES_MS)
    expect(t.calls(DU)).toBe(1)
    await vi.advanceTimersByTimeAsync(TICK_MS)
    expect(t.monitor.current().limits.clonesMb).toBe(2)
    t.monitor.stop()
  })

  it('reads the Mac, with the pressure and the swap at most every 15 s', async () => {
    const t = setup()
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(t.calls(SYSCTL)).toBe(2)
    // The CPU load needs two samples of the CPU times.
    expect(t.monitor.current().mac?.cpuLoad).toBeNull()
    t.monitor.view(SHOW)
    t.world.cpus = [cpuInfo(25, 75)]
    t.world.thermal = 'serious'
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS)
    // The tick at 2 s keeps the pressure and the swap of the last read.
    expect(t.calls(SYSCTL)).toBe(2)
    expect(t.monitor.current().mac).toEqual({
      battery: { charging: false, onBattery: true, percent: 80 },
      cpuLoad: 25,
      pressure: 'normal',
      swap: { totalMb: 2048, usedMb: 512 },
      thermal: 'serious',
    })
    // 30 s of showing: the reads at 0 s and 16 s.
    await vi.advanceTimersByTimeAsync(28 * SEC)
    expect(t.calls(SYSCTL)).toBe(4)
    t.monitor.stop()
  })

  it('a tick with a failed ps adds no sample and keeps the terminal and session values', async () => {
    const t = setup()
    t.world.procs = [
      { cpu: 0, pid: 200, ppid: 100, rssMb: 40 },
      { cpu: 0, pid: 300, ppid: 1, rssMb: 100 },
    ]
    t.world.ptys = [{ pid: 200, viewId: chat(uuid(1)) }]
    t.world.rows = [sessionRow(uuid(1), 'alpha', 300)]
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    await vi.advanceTimersByTimeAsync(TICK_MS)
    const before = t.monitor.current()
    expect(before.okText).toBe('Bifrost is using 740 MB RAM and 12% CPU.')
    t.world.psFails = true
    const main = t.world.metrics[0]
    if (main) main.ramMb += 100
    await vi.advanceTimersByTimeAsync(TICK_MS)
    const snap = t.monitor.current()
    expect(snap.bifrost?.trend).toHaveLength(1)
    expect(snap.okText).toBe(before.okText)
    expect(group(snap, 'Chat terminals')).toEqual({
      count: 1,
      cpu: 0,
      name: 'Chat terminals',
      ramMb: 40,
    })
    expect(snap.sessions).toEqual(before.sessions)
    expect(snap.sessions?.top[0]?.ramMb).toBe(100)
    // ps works again.
    t.world.psFails = false
    await vi.advanceTimersByTimeAsync(TICK_MS)
    expect(t.monitor.current().bifrost?.trend).toHaveLength(2)
    expect(t.monitor.current().okText).toBe('Bifrost is using 840 MB RAM and 12% CPU.')
    t.monitor.stop()
  })

  it('the first metrics tick adds no sample, so the headline waits', async () => {
    const t = setup()
    // The first read of the Electron metrics fails. The next one is the first real read.
    t.world.metricsThrow = true
    const error = vi.spyOn(console, 'error').mockImplementation(() => {})
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    t.world.metricsThrow = false
    await vi.advanceTimersByTimeAsync(TICK_MS)
    // Electron gives 0% CPU at its first read. That tick adds no sample and no trend point.
    let snap = t.monitor.current()
    expect(snap.bifrost?.trend).toEqual([])
    expect(snap.okText).toBeNull()
    expect(snap.state).toBe('ok')
    await vi.advanceTimersByTimeAsync(TICK_MS)
    snap = t.monitor.current()
    expect(snap.bifrost?.trend).toHaveLength(1)
    expect(snap.okText).toBe('Bifrost is using 700 MB RAM and 12% CPU.')
    t.monitor.stop()
    error.mockRestore()
  })

  it('the OK text needs a sample from the last 60 s', async () => {
    const t = setup()
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    await vi.advanceTimersByTimeAsync(TICK_MS)
    expect(t.monitor.current().okText).toBe('Bifrost is using 700 MB RAM and 12% CPU.')
    // ps fails. The sample of 60 s ago is still new enough.
    t.world.psFails = true
    await vi.advanceTimersByTimeAsync(4 * TICK_MS)
    expect(t.monitor.current().okText).toBe('Bifrost is using 700 MB RAM and 12% CPU.')
    // A sample of 75 s ago is too old. The headline then shows "Checking Bifrost…".
    await vi.advanceTimersByTimeAsync(TICK_MS)
    expect(t.monitor.current().okText).toBeNull()
    expect(t.monitor.current().state).toBe('ok')
    t.world.psFails = false
    await vi.advanceTimersByTimeAsync(TICK_MS)
    expect(t.monitor.current().okText).toBe('Bifrost is using 700 MB RAM and 12% CPU.')
    t.monitor.stop()
  })

  it('ignores a Reviews rate limit whose reset time is past', async () => {
    const t = setup()
    t.world.rateLimit = { limit: 5000, remaining: 3, resetAt: Date.now() - MIN }
    t.monitor.start()
    t.monitor.view(SHOW)
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS)
    expect(t.ghRateLimit).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS)
    expect(t.monitor.current().limits.github).toEqual({
      limit: 5000,
      remaining: 4999,
      resetAt: RESET,
    })
    t.monitor.stop()
  })

  it('runs the health model on each tick and gives the OK text', async () => {
    const t = setup()
    // No helper process: the Other helpers row does not show.
    t.world.metrics = BIFROST.slice(0, 3).map(m => ({ ...m }))
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    await vi.advanceTimersByTimeAsync(TICK_MS)
    let snap = t.monitor.current()
    expect(snap.state).toBe('ok')
    expect(snap.reasons).toEqual([])
    expect(snap.okText).toBe('Bifrost is using 600 MB RAM and 10% CPU.')
    expect(snap.bifrost?.groups.map(g => g.name)).toEqual([
      'Main process',
      'Window',
      'GPU',
      'Chat terminals',
    ])
    // The RAM limits leave out the chat terminals, but one large chat terminal is a warning (user
    // decision, 2026-11-10).
    t.world.procs = [{ cpu: 0, pid: 200, ppid: 100, rssMb: 520 }]
    t.world.ptys = [{ pid: 200, viewId: chat(uuid(1)) }]
    for (let i = 0; i < 3; i++) t.health.poll('sessions', 'failed')
    t.world.delay = 1500
    await vi.advanceTimersByTimeAsync(TICK_MS)
    snap = t.monitor.current()
    expect(snap.state).toBe('problem')
    expect(snap.reasons).toEqual([
      { level: 'problem', text: "Bifrost's main process was slow to respond (up to 1500 ms)." },
      { level: 'warning', text: 'A chat terminal is using 520 MB RAM, above the 500 MB limit.' },
      { level: 'warning', text: "Bifrost couldn't check for sessions 3 times in a row." },
    ])
    expect(snap.bifrost?.delayMs).toBe(1500)
    expect(snap.okText).toBe('Bifrost is using 1.1 GB RAM and 10% CPU.')
    t.monitor.stop()
  })

  it('sets clearable from the past events and refreshes the snapshot at once', async () => {
    const t = setup()
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    await vi.advanceTimersByTimeAsync(TICK_MS)
    expect(t.monitor.current().clearable).toBe(false)
    t.health.crash('gpu', 'killed')
    // The snapshot does not change before the next tick or a refresh.
    expect(t.monitor.current().clearable).toBe(false)
    const emits = t.emitted.length
    t.monitor.refresh()
    expect(t.monitor.current().clearable).toBe(true)
    expect(t.monitor.current().reasons.map(r => r.text)).toEqual([
      expect.stringContaining('The graphics process crashed'),
    ])
    expect(t.emitted).toHaveLength(emits + 1)
    t.health.clear()
    t.monitor.refresh()
    expect(t.monitor.current().clearable).toBe(false)
    expect(t.monitor.current().reasons).toEqual([])
    expect(t.emitted).toHaveLength(emits + 2)
    t.monitor.stop()
  })

  it('refresh before the first tick does nothing', () => {
    const t = setup()
    t.monitor.refresh()
    expect(t.emitted).toEqual([])
  })

  it('after an 8 h clock jump, the samples right after wake give no memory or CPU reason', async () => {
    const t = setup()
    const reasonFor = (part: string): boolean => hasReason(t, part)
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    // 30 minutes awake with a flat RAM.
    await vi.advanceTimersByTimeAsync(30 * MIN)
    expect(t.monitor.current().reasons).toEqual([])
    // The Mac sleeps for 8 hours. The clock jumps, and no timer runs during the sleep.
    vi.setSystemTime(Date.now() + 8 * 60 * MIN)
    const main = t.world.metrics[0]
    if (main) main.cpu = 60
    await vi.advanceTimersByTimeAsync(TICK_MS)
    if (main) main.ramMb += 4
    await vi.advanceTimersByTimeAsync(TICK_MS)
    // Without the gap rule: "growing by about 960 MB an hour" and a CPU warning.
    expect(reasonFor('growing')).toBe(false)
    expect(reasonFor('CPU on average')).toBe(false)
    expect(t.monitor.current().bifrost?.trend).toHaveLength(2)
    expect(SAMPLE_GAP_MS).toBe(60_000)
    t.monitor.stop()
  })

  it('after a 5 minute clock jump, the CPU check waits for 2 new minutes of samples', async () => {
    const t = setup()
    const cpuReason = (): boolean => hasReason(t, 'CPU on average')
    const main = t.world.metrics[0]
    if (main) main.cpu = 60
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    await vi.advanceTimersByTimeAsync(5 * MIN)
    expect(cpuReason()).toBe(true)
    vi.setSystemTime(Date.now() + 5 * MIN)
    await vi.advanceTimersByTimeAsync(TICK_MS)
    expect(cpuReason()).toBe(false)
    // The new samples cover 2 minutes 15 s after the jump.
    await vi.advanceTimersByTimeAsync(2 * MIN - TICK_MS)
    expect(cpuReason()).toBe(false)
    await vi.advanceTimersByTimeAsync(TICK_MS)
    expect(cpuReason()).toBe(true)
    t.monitor.stop()
  })

  it('normal 15 s and 2 s ticks never clear the history', async () => {
    const t = setup()
    const start = Date.now()
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    // 5 minutes closed: the samples at 15 s to 300 s.
    await vi.advanceTimersByTimeAsync(5 * MIN)
    // 1 minute open: 30 samples. Then 1 minute closed: 4 samples.
    t.monitor.view(SHOW)
    await vi.advanceTimersByTimeAsync(MIN)
    t.monitor.view(HIDE)
    await vi.advanceTimersByTimeAsync(MIN)
    const trend = t.monitor.current().bifrost?.trend ?? []
    expect(trend).toHaveLength(20 + 30 + 4)
    expect(trend[0]?.at).toBe(start + TICK_MS)
    t.monitor.stop()
  })

  it('gives the memory trend after a full hour, also when the ticks drift', async () => {
    const t = setup()
    // Each ps read takes 10 ms. So the ticks drift, and no sample is exactly 60 minutes old.
    const real = t.exec.getMockImplementation() as ExecFn
    t.exec.mockImplementation(async (file, args, opts) => {
      if (file === PS) await new Promise(resolve => setTimeout(resolve, 10))
      return real(file, args, opts)
    })
    const growing = () => hasReason(t, "Bifrost's memory is growing by about")
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    // The main process grows by 10 MB in each tick of about 15 s: about 2,400 MB an hour.
    const grow = async (minutes: number): Promise<void> => {
      const end = Date.now() + minutes * MIN
      while (Date.now() < end) {
        const main = t.world.metrics[0]
        if (main) main.ramMb += 10
        await vi.advanceTimersByTimeAsync(TICK_MS)
      }
    }
    // After 30 minutes, the trend gives no reason yet.
    await grow(30)
    expect(growing()).toBe(false)
    await grow(29)
    expect(growing()).toBe(false)
    // After the first full hour, and later, the trend gives the reason.
    await grow(2)
    expect(growing()).toBe(true)
    await grow(60)
    expect(growing()).toBe(true)
    const texts = t.monitor.current().reasons.map(r => r.text)
    expect(texts.some(text => /growing by about 23\d\d MB an hour\./.test(text))).toBe(true)
    expect(HISTORY_MS).toBe(60 * MIN)
    t.monitor.stop()
  })

  it('the trend has the totals of the last 10 minutes', async () => {
    const t = setup()
    t.world.procs = [{ cpu: 0, pid: 200, ppid: 100, rssMb: 100 }]
    t.world.ptys = [{ pid: 200, viewId: chat(uuid(1)) }]
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(11 * MIN)
    const trend = t.monitor.current().bifrost?.trend ?? []
    const now = Date.now()
    expect(trend).toHaveLength(TREND_MS / TICK_MS + 1)
    expect(trend[0]?.at).toBe(now - TREND_MS)
    expect(trend.at(-1)).toEqual({ at: now, cpu: 12, ramMb: 800 })
    t.monitor.stop()
  })

  it('the frame rate is low when the last two burst reports of this showing are low', async () => {
    const t = setup()
    const low = (): boolean => hasReason(t, 'fps')
    // One burst report each 10 s, as the renderer sends them. The tick after it reads it.
    const burst = async (value: number): Promise<void> => {
      await vi.advanceTimersByTimeAsync(10 * SEC - FAST_TICK_MS)
      t.monitor.fps(value)
      await vi.advanceTimersByTimeAsync(FAST_TICK_MS)
    }
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    // A report while the panel is closed does not count.
    t.monitor.fps(5)
    t.monitor.view(SHOW)
    await vi.advanceTimersByTimeAsync(0)
    expect(t.monitor.current().bifrost?.fps).toBeNull()
    // One low burst is not enough.
    await burst(20)
    expect(low()).toBe(false)
    expect(t.monitor.current().bifrost?.fps).toBe(20)
    // The fps row keeps the last burst value between the bursts.
    await vi.advanceTimersByTimeAsync(6 * SEC)
    expect(t.monitor.current().bifrost?.fps).toBe(20)
    // Two low bursts in a row cover 10 s.
    await burst(25)
    expect(low()).toBe(true)
    expect(t.monitor.current().reasons).toContainEqual({
      level: 'warning',
      text: 'The Performance panel ran below 30 fps for 10 seconds.',
    })
    // One burst at 30 fps or more ends it. The next low burst alone does not start it again.
    await burst(30)
    expect(low()).toBe(false)
    await burst(10)
    expect(low()).toBe(false)
    await burst(10)
    expect(low()).toBe(true)
    // A change of focus starts a new count. A report without focus does not count.
    t.monitor.view({ ...SHOW, focused: false })
    await burst(10)
    await burst(10)
    expect(low()).toBe(false)
    expect(t.monitor.current().bifrost?.fps).toBeNull()
    t.monitor.view(SHOW)
    await burst(10)
    expect(low()).toBe(false)
    await burst(10)
    expect(low()).toBe(true)
    // A change of showing also starts a new count.
    t.monitor.view(HIDE)
    t.monitor.view(SHOW)
    await burst(10)
    expect(low()).toBe(false)
    t.monitor.stop()
  })

  it('stop clears every timer', async () => {
    const t = setup({ clonesPath: '/fake/repos' })
    t.monitor.start()
    t.monitor.view(SHOW)
    await vi.advanceTimersByTimeAsync(10 * SEC)
    t.monitor.stop()
    expect(vi.getTimerCount()).toBe(0)
    expect(t.monitor.current()).toEqual(EMPTY_PERFORMANCE)
    const calls = t.exec.mock.calls.length
    const emits = t.emitted.length
    await vi.advanceTimersByTimeAsync(5 * MIN)
    expect(t.exec.mock.calls.length).toBe(calls)
    expect(t.emitted).toHaveLength(emits)
    // A report after the stop sets no timer.
    t.monitor.view(HIDE)
    t.monitor.view(SHOW)
    expect(vi.getTimerCount()).toBe(0)
  })

  it('a tick that ends after stop emits nothing and sets no timer', async () => {
    const t = setup()
    let release: (r: ExecResult) => void = () => {}
    const hang = new Promise<ExecResult>(resolve => {
      release = resolve
    })
    const real = t.exec.getMockImplementation() as ExecFn
    // Only the ps call waits.
    t.exec.mockImplementation((file, args, opts) => (file === PS ? hang : real(file, args, opts)))
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    t.monitor.stop()
    release(ok(psOut([{ cpu: 0, pid: 100, ppid: 1, rssMb: 1 }])))
    await vi.advanceTimersByTimeAsync(0)
    expect(t.emitted).toEqual([])
    expect(vi.getTimerCount()).toBe(0)
    expect(t.monitor.current()).toEqual(EMPTY_PERFORMANCE)
  })

  it('a dep that throws or a rejected side read keeps the loop running', async () => {
    const error = vi.spyOn(console, 'error').mockImplementation(() => {})
    const t = setup()
    t.world.metricsThrow = true
    t.freeDiskBytes.mockRejectedValueOnce(new Error('statfs failed'))
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(t.emitted).toHaveLength(0)
    t.world.metricsThrow = false
    await vi.advanceTimersByTimeAsync(TICK_MS)
    expect(t.emitted).toHaveLength(1)
    t.world.emitThrows = true
    await vi.advanceTimersByTimeAsync(TICK_MS)
    expect(t.emitted).toHaveLength(1)
    t.world.emitThrows = false
    await vi.advanceTimersByTimeAsync(TICK_MS)
    expect(t.emitted).toHaveLength(2)
    expect(t.monitor.current().limits.freeDiskGb).toBeNull()
    // The rejected read runs again 60 s after the first one.
    await vi.advanceTimersByTimeAsync(TICK_MS)
    expect(t.freeDiskBytes).toHaveBeenCalledTimes(2)
    await vi.advanceTimersByTimeAsync(TICK_MS)
    expect(t.monitor.current().limits.freeDiskGb).toBe(250)
    expect(error).toHaveBeenCalled()
    t.monitor.stop()
    error.mockRestore()
  })

  it('start after stop works', async () => {
    const t = setup()
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    t.monitor.stop()
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(t.emitted).toHaveLength(2)
    expect(t.calls(PS)).toBe(2)
    expect(t.monitor.current().state).toBe('ok')
    expect(vi.getTimerCount()).toBe(1)
    await vi.advanceTimersByTimeAsync(TICK_MS)
    expect(t.emitted).toHaveLength(3)
    t.monitor.stop()
  })

  it('pageGone goes back to 15 s ticks with no probe, no gh call and no network command', async () => {
    const t = setup()
    t.world.ptys = [{ pid: 200, viewId: chat(uuid(1)) }]
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    t.monitor.view({ ...SHOW, chatPanels: [chat(uuid(1))] })
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS)
    t.monitor.fps(60)
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS)
    expect(t.probe).toHaveBeenCalledTimes(2)
    expect(t.ghRateLimit).toHaveBeenCalledTimes(1)
    expect(t.netCalls()).toBeGreaterThan(0)
    expect(t.monitor.current().bifrost?.fps).toBe(60)
    // The window closes. The renderer sends no report for that.
    const ticks = t.emitted.length
    const net = t.netCalls()
    t.monitor.pageGone()
    await vi.advanceTimersByTimeAsync(TICK_MS - 1)
    expect(t.emitted).toHaveLength(ticks)
    await vi.advanceTimersByTimeAsync(1)
    expect(t.emitted).toHaveLength(ticks + 1)
    expect(t.monitor.current().bifrost?.fps).toBeNull()
    expect(t.monitor.current().network).toMatchObject({ downBps: null, upBps: null })
    await vi.advanceTimersByTimeAsync(10 * MIN)
    expect(t.emitted).toHaveLength(ticks + 1 + (10 * MIN) / TICK_MS)
    expect(t.netCalls()).toBe(net)
    expect(t.probe).toHaveBeenCalledTimes(2)
    expect(t.ghRateLimit).toHaveBeenCalledTimes(1)
    // The chat panels are not known until the next report. So the chat PTY is no orphan.
    expect(orphan(t)).toBe(false)
    // The next report of a new page works as before.
    t.monitor.view(SHOW)
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS)
    expect(t.probe).toHaveBeenCalledTimes(4)
    t.monitor.stop()
  })

  it('a view report during a busy tick moves the next tick to the new interval', async () => {
    const t = setup()
    const releasePs = holdNext(t, PS)
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    // The panel shows during the first tick. The tick ends at 1 s.
    t.monitor.view(SHOW)
    await vi.advanceTimersByTimeAsync(SEC)
    releasePs()
    await vi.advanceTimersByTimeAsync(0)
    expect(t.emitted).toHaveLength(1)
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS - 1)
    expect(t.emitted).toHaveLength(1)
    await vi.advanceTimersByTimeAsync(1)
    expect(t.emitted).toHaveLength(2)
    // The panel closes during the tick at 9 s, which waits for netstat. The tick ends at 10 s.
    const releaseNet = holdNext(t, NETSTAT)
    await vi.advanceTimersByTimeAsync(COMMAND_MS)
    expect(t.emitted).toHaveLength(4)
    t.monitor.view(HIDE)
    await vi.advanceTimersByTimeAsync(SEC)
    releaseNet()
    await vi.advanceTimersByTimeAsync(0)
    expect(t.emitted).toHaveLength(5)
    expect(t.monitor.current().network).toMatchObject({ downBps: null, upBps: null })
    await vi.advanceTimersByTimeAsync(TICK_MS - 1)
    expect(t.emitted).toHaveLength(5)
    await vi.advanceTimersByTimeAsync(1)
    expect(t.emitted).toHaveLength(6)
    t.monitor.stop()
  })
})
