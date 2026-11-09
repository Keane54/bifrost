import type * as os from 'node:os'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ExecFn, ExecResult } from '../../../src/main/claude/cli'
import { createHealthLog } from '../../../src/main/performance/health-log'
import {
  BATTERY_MS,
  CLONES_MS,
  checkFps,
  checkView,
  createLoopDelay,
  createPerformanceMonitor,
  DELAY_WINDOW_MS,
  DISK_MS,
  FAST_TICK_MS,
  GH_LIMIT_FAILED,
  GH_LIMIT_LOGGED_OUT,
  GH_LIMIT_MISSING,
  type GithubLimit,
  HISTORY_MS,
  type MonitorDeps,
  PROBE_MS,
  PROBE_URLS,
  type ProbeResult,
  probeUrl,
  RATE_LIMIT_ARGS,
  REFUSED_BAD_CHAT_PANEL,
  readGhRateLimit,
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
import type { Gh } from '../../../src/main/reviews/gh'
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

function netstatOut(inBytes: number, outBytes: number): string {
  return [
    'Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll',
    'lo0        16384 <Link#1>                       5610467     0 26388186710  5610467     0 26388186710     0',
    `en0        1500  <Link#14>   aa:bb:cc:dd:ee:01  8000000     0  ${inBytes}  4000000     0  ${outBytes}     -`,
  ].join('\n')
}

const SWAP = 'total = 2048.00M  used = 512.00M  free = 1536.00M  (encrypted)'
const BATTERY =
  "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t80%; discharging; 3:00 remaining present: true\n"
const ROUTE_OUT = '   route to: default\ndestination: default\n  interface: en0\n'
const PORTS = 'Hardware Port: Wi-Fi\nDevice: en0\nEthernet Address: aa:bb:cc:dd:ee:01\n'

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
}

function setup(opts: { network?: boolean; clonesPath?: string | null } = {}) {
  const world: World = {
    cpus: [cpuInfo(0, 0)],
    delay: null,
    inBytes: 1_000_000,
    metrics: BIFROST.map(m => ({ ...m })),
    online: true,
    outBytes: 500_000,
    procs: [{ cpu: 0, pid: 100, ppid: 1, rssMb: 1 }],
    ptys: [],
    rateLimit: null,
    rows: [],
    thermal: 'nominal',
  }
  const exec = vi.fn<ExecFn>(async (file, args) => {
    if (file === PS) return ok(psOut(world.procs))
    if (file === SYSCTL) return ok(args.includes('vm.swapusage') ? SWAP : '1\n')
    if (file === PMSET) return ok(BATTERY)
    if (file === ROUTE) return ok(ROUTE_OUT)
    if (file === NETWORKSETUP) return ok(PORTS)
    if (file === NETSTAT) return ok(netstatOut(world.inBytes, world.outBytes))
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
  const emitted: PerformanceSnapshot[] = []
  const health = createHealthLog(() => Date.now())
  const deps: MonitorDeps = {
    appMetrics: () =>
      world.metrics.map(m => ({
        cpu: { percentCPUUsage: m.cpu },
        memory: { workingSetSize: m.ramMb * KB_PER_MB },
        pid: m.pid,
        type: m.type,
      })),
    clonesPath: opts.clonesPath ?? null,
    cpus: () => world.cpus,
    delayP99: () => world.delay,
    emit: s => emitted.push(s),
    exec,
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
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(t.calls(PS)).toBe(1)
    // The panel shows. The next tick comes 2 s after the end of the last tick.
    t.monitor.view(SHOW)
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS - 1)
    expect(t.calls(PS)).toBe(1)
    await vi.advanceTimersByTimeAsync(1)
    expect(t.calls(PS)).toBe(2)
    await vi.advanceTimersByTimeAsync(10 * FAST_TICK_MS)
    expect(t.calls(PS)).toBe(12)
    // The panel closes. The next tick comes 15 s after the end of the last tick.
    t.monitor.view(HIDE)
    await vi.advanceTimersByTimeAsync(TICK_MS - 1)
    expect(t.calls(PS)).toBe(12)
    await vi.advanceTimersByTimeAsync(1)
    expect(t.calls(PS)).toBe(13)
    // The panel shows 10 s after a tick. The 2 s are past, so a tick comes at once.
    await vi.advanceTimersByTimeAsync(10 * SEC)
    t.monitor.view(SHOW)
    await vi.advanceTimersByTimeAsync(0)
    expect(t.calls(PS)).toBe(14)
    // A report that changes only the chat panels does not move the timer.
    t.monitor.view({ ...SHOW, chatPanels: [chat(uuid(1))] })
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS - 1)
    expect(t.calls(PS)).toBe(14)
    await vi.advanceTimersByTimeAsync(1)
    expect(t.calls(PS)).toBe(15)
    expect(t.emitted).toHaveLength(15)
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

  it('reads the interface when the panel shows, and the rates on each fast tick', async () => {
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
    t.world.inBytes += 4000
    t.world.outBytes += 2000
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS)
    expect(t.monitor.current().network).toMatchObject({ downBps: 2000, upBps: 1000 })
    // The monitor reads the interface again only after 60 s.
    await vi.advanceTimersByTimeAsync(56 * SEC)
    expect(t.calls(ROUTE)).toBe(1)
    expect(t.calls(NETSTAT)).toBe(30)
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS)
    expect(t.calls(ROUTE)).toBe(2)
    // The panel closes: no network command runs, and the rates go.
    t.monitor.view(HIDE)
    const netstats = t.calls(NETSTAT)
    await vi.advanceTimersByTimeAsync(5 * MIN)
    expect(t.calls(NETSTAT)).toBe(netstats)
    expect(t.calls(ROUTE)).toBe(2)
    expect(t.monitor.current().network).toMatchObject({ downBps: null, upBps: null })
    // The panel shows again: the monitor reads the interface at the next tick.
    t.monitor.view(SHOW)
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS)
    expect(t.calls(ROUTE)).toBe(3)
    // Online comes from net.isOnline in each state.
    t.world.online = false
    t.monitor.view(HIDE)
    await vi.advanceTimersByTimeAsync(TICK_MS)
    expect(t.monitor.current().network?.online).toBe(false)
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
    expect(snap.mac?.battery).toEqual({ charging: false, percent: 80 })
    expect(snap.limits).toMatchObject({ clonesMb: 2, freeDiskGb: 250 })
    t.monitor.stop()
  })

  it('reads the Mac on each tick', async () => {
    const t = setup()
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    // The CPU load needs two samples of the CPU times.
    expect(t.monitor.current().mac?.cpuLoad).toBeNull()
    t.world.cpus = [cpuInfo(25, 75)]
    t.world.thermal = 'serious'
    await vi.advanceTimersByTimeAsync(TICK_MS)
    expect(t.monitor.current().mac).toEqual({
      battery: { charging: false, percent: 80 },
      cpuLoad: 25,
      pressure: 'normal',
      swap: { totalMb: 2048, usedMb: 512 },
      thermal: 'serious',
    })
    expect(t.calls(SYSCTL)).toBe(4)
    t.monitor.stop()
  })

  it('runs the health model on each tick and gives the OK text', async () => {
    const t = setup()
    // No helper process: the Other helpers row does not show.
    t.world.metrics = BIFROST.slice(0, 3).map(m => ({ ...m }))
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
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
    // The RAM check uses the total with the chat terminals.
    t.world.procs = [{ cpu: 0, pid: 200, ppid: 100, rssMb: 500 }]
    t.world.ptys = [{ pid: 200, viewId: chat(uuid(1)) }]
    for (let i = 0; i < 3; i++) t.health.poll('sessions', 'failed')
    t.world.delay = 1500
    await vi.advanceTimersByTimeAsync(TICK_MS)
    snap = t.monitor.current()
    expect(snap.state).toBe('problem')
    expect(snap.reasons).toEqual([
      { level: 'problem', text: "Bifrost's main process was slow to respond (up to 1500 ms)." },
      { level: 'warning', text: 'Bifrost is using 1,100 MB RAM, above the 1 GB limit.' },
      { level: 'warning', text: "Bifrost couldn't check for sessions 3 times in a row." },
    ])
    expect(snap.bifrost?.delayMs).toBe(1500)
    expect(snap.okText).toBe('Bifrost is using 1.1 GB RAM and 10% CPU.')
    t.monitor.stop()
  })

  it('keeps the samples for the memory trend', async () => {
    const t = setup()
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    // The main process grows by 10 MB in each 15 s, which is 2,400 MB an hour.
    for (let i = 0; i < 30 * 4; i++) {
      const main = t.world.metrics[0]
      if (main) main.ramMb += 10
      await vi.advanceTimersByTimeAsync(TICK_MS)
    }
    expect(hasReason(t, "Bifrost's memory is growing by about 2400 MB an hour.")).toBe(true)
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

  it('the frame rate is low only after 10 s of low reports while the panel shows and has focus', async () => {
    const t = setup()
    const low = (): boolean => hasReason(t, 'fps')
    // One report each second.
    const report = async (seconds: number, value: number): Promise<void> => {
      for (let i = 0; i < seconds; i++) {
        await vi.advanceTimersByTimeAsync(SEC)
        t.monitor.fps(value)
      }
    }
    t.monitor.start()
    await vi.advanceTimersByTimeAsync(0)
    // A report while the panel is closed does not count.
    t.monitor.fps(5)
    t.monitor.view(SHOW)
    // The tick at 10 s: the first report is 9 s old.
    await report(10, 20)
    expect(low()).toBe(false)
    expect(t.monitor.current().bifrost?.fps).toBe(20)
    await report(1, 20)
    await vi.advanceTimersByTimeAsync(SEC)
    expect(low()).toBe(true)
    expect(t.monitor.current().reasons).toContainEqual({
      level: 'warning',
      text: 'The Performance panel ran below 30 fps for 10 seconds.',
    })
    // One report at 30 fps or more in the last 10 s ends it.
    t.monitor.fps(45)
    await vi.advanceTimersByTimeAsync(FAST_TICK_MS)
    expect(low()).toBe(false)
    // A change of focus starts a new count. A report without focus does not count.
    t.monitor.view({ ...SHOW, focused: false })
    await report(12, 10)
    expect(low()).toBe(false)
    expect(t.monitor.current().bifrost?.fps).toBeNull()
    t.monitor.view(SHOW)
    await report(10, 10)
    expect(low()).toBe(false)
    await report(2, 10)
    expect(low()).toBe(true)
    // A change of showing also starts a new count.
    t.monitor.view(HIDE)
    t.monitor.view(SHOW)
    await report(4, 10)
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
})

describe('readGhRateLimit', () => {
  it('reads the GraphQL limit of gh api rate_limit, with the reset in ms', async () => {
    const run = vi.fn<Gh['run']>(async () =>
      ok(
        JSON.stringify({
          rate: { limit: 5000, remaining: 4990, reset: 1794229000, used: 10 },
          resources: {
            core: { limit: 5000, remaining: 4990, reset: 1794229000, used: 10 },
            graphql: { limit: 5000, remaining: 4321, reset: 1794229200, used: 679 },
          },
        }),
      ),
    )
    expect(await readGhRateLimit({ run })).toEqual({
      limit: 5000,
      remaining: 4321,
      resetAt: 1794229200 * 1000,
    })
    expect(RATE_LIMIT_ARGS).toEqual(['api', 'rate_limit'])
    expect(run).toHaveBeenCalledWith(RATE_LIMIT_ARGS, { timeoutMs: expect.any(Number) })
  })

  it('gives a friendly reason when gh cannot answer', async () => {
    expect(GH_LIMIT_MISSING).toBe("GitHub CLI isn't installed")
    expect(GH_LIMIT_LOGGED_OUT).toBe("GitHub CLI isn't signed in")
    expect(GH_LIMIT_FAILED).toBe("Couldn't read the GitHub limit")
    const cases: Array<[ExecResult, string]> = [
      [{ code: -2, stderr: 'spawn gh ENOENT', stdout: '' }, GH_LIMIT_MISSING],
      [{ code: 4, stderr: 'please run:  gh auth login', stdout: '' }, GH_LIMIT_LOGGED_OUT],
      [{ code: 1, stderr: 'gh: HTTP 502', stdout: '' }, GH_LIMIT_FAILED],
      [{ code: 1, stderr: '', stdout: '', timedOut: true }, GH_LIMIT_FAILED],
      [ok('not json'), GH_LIMIT_FAILED],
      [ok('{"resources":{"graphql":{"limit":5000}}}'), GH_LIMIT_FAILED],
    ]
    for (const [result, reason] of cases) {
      expect(await readGhRateLimit({ run: async () => result })).toEqual({ unavailable: reason })
    }
    const thrown = async (): Promise<ExecResult> => {
      throw new Error('spawn failed')
    }
    expect(await readGhRateLimit({ run: thrown })).toEqual({ unavailable: GH_LIMIT_FAILED })
  })
})

describe('probeUrl', () => {
  it('times a HEAD request with no login and counts any status as an answer', async () => {
    let clock = 1000
    const fetch = vi.fn(async (_url: string, _init: RequestInit) => {
      clock += 87
      return new Response(null, { status: 404 })
    })
    expect(await probeUrl(fetch, PROBE_URLS.anthropic, () => clock)).toBe(87)
    const [url, init] = fetch.mock.calls[0] ?? []
    expect(url).toBe('https://api.anthropic.com')
    expect(init).toMatchObject({ cache: 'no-store', credentials: 'omit', method: 'HEAD' })
    expect(init?.signal).toBeInstanceOf(AbortSignal)
    expect(init?.headers).toBeUndefined()
  })

  it('gives no-answer after the timeout and unreachable for a connection error', async () => {
    const timeout = async (): Promise<Response> => {
      throw new DOMException('The operation timed out.', 'TimeoutError')
    }
    expect(await probeUrl(timeout, PROBE_URLS.github, () => 0)).toBe('no-answer')
    const refused = async (): Promise<Response> => {
      throw new TypeError('net::ERR_NAME_NOT_RESOLVED')
    }
    expect(await probeUrl(refused, PROBE_URLS.github, () => 0)).toBe('unreachable')
  })
})

describe('createLoopDelay', () => {
  it('gives the 99th percentile of the last full 60 s window in ms', async () => {
    const h = {
      count: 0,
      disable: vi.fn(),
      enable: vi.fn(),
      percentile: vi.fn((_p: number) => 250e6),
      reset: vi.fn(() => {
        h.count = 0
      }),
    }
    const delay = createLoopDelay(h)
    expect(h.enable).toHaveBeenCalledTimes(1)
    h.count = 5000
    // The first window has not ended.
    expect(delay.p99()).toBeNull()
    await vi.advanceTimersByTimeAsync(DELAY_WINDOW_MS)
    expect(delay.p99()).toBe(250)
    expect(h.percentile).toHaveBeenCalledWith(99)
    expect(h.reset).toHaveBeenCalledTimes(1)
    // A window with no data gives null.
    await vi.advanceTimersByTimeAsync(DELAY_WINDOW_MS)
    expect(delay.p99()).toBeNull()
    expect(h.reset).toHaveBeenCalledTimes(2)
    delay.stop()
    expect(h.disable).toHaveBeenCalledTimes(1)
    expect(vi.getTimerCount()).toBe(0)
  })
})

describe('checkView and checkFps', () => {
  it('checkView takes two booleans and chat panel IDs only', () => {
    const good = { chatPanels: [chat(uuid(1))], focused: false, showing: true }
    expect(checkView(good)).toEqual(good)
    const base = { focused: false, showing: true }
    expect(() => checkView({ ...base, chatPanels: ['/etc/passwd'] })).toThrow(
      REFUSED_BAD_CHAT_PANEL,
    )
    expect(() => checkView({ ...base, chatPanels: [send(uuid(1))] })).toThrow(
      REFUSED_BAD_CHAT_PANEL,
    )
    expect(() => checkView({ ...base, chatPanels: [7] })).toThrow(REFUSED_BAD_CHAT_PANEL)
    expect(REFUSED_BAD_CHAT_PANEL).toBe('refused: bad chat panel')
    const bad: unknown[] = [
      null,
      'showing',
      { ...base, chatPanels: 'chat:x' },
      { ...base },
      { chatPanels: [], focused: 1, showing: true },
      { chatPanels: [], focused: true, showing: 'yes' },
      { ...base, chatPanels: Array.from({ length: 501 }, () => chat(uuid(1))) },
    ]
    for (const v of bad) expect(() => checkView(v)).toThrow('refused: bad input')
  })

  it('checkFps takes a finite number from 0 to 1000', () => {
    expect(checkFps(0)).toBe(0)
    expect(checkFps(59.5)).toBe(59.5)
    expect(checkFps(1000)).toBe(1000)
    for (const v of [-1, 1001, Number.NaN, Number.POSITIVE_INFINITY, '60', null]) {
      expect(() => checkFps(v)).toThrow('refused: bad input')
    }
  })
})
