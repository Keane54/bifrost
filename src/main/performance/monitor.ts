// The Performance monitor (design sections 5.2, 6 and 7). It samples Bifrost, the Claude sessions
// and the Mac on a timer, runs the health model and sends a snapshot after each tick. It never
// imports electron. ipc.ts gives it each Electron, Node and command function.
import type * as os from 'node:os'
import {
  EMPTY_PERFORMANCE,
  type PerformanceSnapshot,
  type ProcGroup,
  type SessionUse,
} from '../../shared/performance'
import type { SessionRow } from '../../shared/types'
import { CHAT_VIEW } from '../../shared/view-id'
import type { ExecFn } from '../claude/cli'
import { type Gh, ghFailure } from '../reviews/gh'
import { healthReasons, healthState, LIMITS, okText, type Sample } from './health'
import type { HealthLog } from './health-log'
import {
  cpuLoad,
  cpuPercent,
  type LinkKind,
  type ProcRow,
  readBattery,
  readDuKb,
  readLink,
  readNetBytes,
  readPressure,
  readPsStats,
  readSwap,
  treeSum,
} from './system'

// The tick while the panel is closed, and while it shows (P9).
export const TICK_MS = 15_000
export const FAST_TICK_MS = 2_000
// The response times and the gh rate limit, at most this often, only while the panel shows.
export const PROBE_MS = 60_000
// The battery, the free disk and the size of the Reviews clones, in each state (ruling 10).
export const BATTERY_MS = 60_000
export const DISK_MS = 60_000
export const CLONES_MS = 600_000
// The monitor keeps the samples of the health model for this time.
export const HISTORY_MS = 3_600_000
// The trend line of the panel shows this time.
export const TREND_MS = 600_000
// While the panel shows, the monitor reads the interface kind again after this time.
export const LINK_MS = 60_000
// The window of the main process delay.
export const DELAY_WINDOW_MS = 60_000
// A response time request ends after this time with 'no-answer'.
export const PROBE_TIMEOUT_MS = 5000
// The two hosts of the response times (design section 7).
export const PROBE_URLS = {
  anthropic: 'https://api.anthropic.com',
  github: 'https://api.github.com',
} as const

// gh api rate_limit costs no points (P11).
export const RATE_LIMIT_ARGS = ['api', 'rate_limit']
const RATE_LIMIT_TIMEOUT_MS = 15_000
// The texts of the GitHub limit row when gh cannot give the limit.
export const GH_LIMIT_MISSING = "GitHub CLI isn't installed"
export const GH_LIMIT_LOGGED_OUT = "GitHub CLI isn't signed in"
export const GH_LIMIT_FAILED = "Couldn't read the GitHub limit"

// The renderer sent a chat panel ID that is not a chat view ID.
export const REFUSED_BAD_CHAT_PANEL = 'refused: bad chat panel'
const REFUSED_BAD_INPUT = 'refused: bad input'
// More chat panels than this in one report is not a real window.
const MAX_CHAT_PANELS = 500
const MAX_FPS = 1000

const KB_PER_MB = 1024
// Finder shows the disk sizes in units of 1,000,000,000 bytes.
const BYTES_PER_GB = 1e9
const NS_PER_MS = 1e6

// The process groups of the Bifrost section. Each Electron type that is not here is a helper.
const GROUP_OF: Readonly<Record<string, string>> = {
  Browser: 'Main process',
  GPU: 'GPU',
  Tab: 'Window',
}
const TERMINALS = 'Chat terminals'
const HELPERS = 'Other helpers'
const GROUP_ORDER = ['Main process', 'Window', 'GPU', TERMINALS, HELPERS]

// The time until the response headers in ms, or the failure.
export type ProbeResult = number | 'no-answer' | 'unreachable'

// The GraphQL points that remain, the limit, and the time of the reset in ms.
export interface GithubLimit {
  remaining: number
  limit: number
  resetAt: number
}

// The report of the renderer (P9).
export interface PanelView {
  showing: boolean
  focused: boolean
  chatPanels: string[]
}

// The Electron, Node and command functions of the monitor. ipc.ts binds them.
export interface MonitorDeps {
  exec: ExecFn
  // Electron app.getAppMetrics(). The memory is in KB.
  appMetrics(): Array<{
    pid: number
    type: string
    cpu: { percentCPUUsage: number }
    memory: { workingSetSize: number }
  }>
  // The PTYs of the PTY manager (P1).
  ptys(): Array<{ viewId: string; pid: number }>
  rows(): SessionRow[]
  cpus(): os.CpuInfo[]
  thermal(): string | null
  online(): boolean
  freeDiskBytes(): Promise<number | null>
  // One HEAD request. The time until the response headers in ms, or the failure.
  probe(url: string): Promise<ProbeResult>
  // The rate limit of the last Reviews poll, or null (P11).
  rateLimit(): GithubLimit | null
  ghRateLimit(): Promise<GithubLimit | { unavailable: string }>
  // The folder of the Reviews clones. null reads no size.
  clonesPath: string | null
  health: HealthLog
  // The 99th percentile of the main process delay in ms, or null.
  delayP99(): number | null
  now(): number
  emit(s: PerformanceSnapshot): void
  // False in a test home: no probes and no gh call.
  network: boolean
}

// The monitor that ipc.ts starts and that stopRegistry stops.
export interface PerformanceMonitor {
  // Tick at once, then on the timer. A second call does nothing.
  start(): void
  // Stop all timers and forget all samples.
  stop(): void
  current(): PerformanceSnapshot
  // The renderer reports the panel and the open chat panels on each change (P2, P9).
  view(v: PanelView): void
  // The renderer reports the frame rate once a second while the panel shows and has focus.
  fps(value: number): void
}

type Network = NonNullable<PerformanceSnapshot['network']>
type Mac = NonNullable<PerformanceSnapshot['mac']>
type Sessions = NonNullable<PerformanceSnapshot['sessions']>
type TrendPoint = NonNullable<PerformanceSnapshot['bifrost']>['trend'][number]

// A read that runs at its own interval, in the background of the ticks.
interface SideRead {
  at: number
  busy: boolean
}

const newSide = (): SideRead => ({ at: Number.NEGATIVE_INFINITY, busy: false })
const newSides = () => ({
  battery: newSide(),
  clones: newSide(),
  disk: newSide(),
  gh: newSide(),
  probes: newSide(),
})

// True when the interval since the last read is past. A clock that went back also makes the read
// due, so a clock change cannot stop a read for a long time.
const due = (since: number, everyMs: number): boolean => since < 0 || since >= everyMs

// Make the monitor. Each tick reads the Electron processes, the PTYs, one ps table, the rows, the
// CPU times, the memory pressure and the swap. It keeps a sample, runs the health model and emits
// the snapshot. The tick is 15 s, or 2 s while the panel shows (P9).
export function createPerformanceMonitor(deps: MonitorDeps): PerformanceMonitor {
  let running = false
  let busy = false
  // Each start and each stop makes a new generation. A read of an old generation changes nothing.
  let generation = 0
  let timer: ReturnType<typeof setTimeout> | null = null
  let lastEndAt = Number.NEGATIVE_INFINITY
  let snapshot: PerformanceSnapshot = EMPTY_PERFORMANCE

  // The last report of the renderer. It stays after a stop, because the renderer reports only a
  // change.
  let reported = false
  let showing = false
  let focused = false
  let chatPanels = new Set<string>()

  let samples: Sample[] = []
  let trend: TrendPoint[] = []
  // The cumulative CPU time of each ps process of the last good ps read (P3).
  let lastCpu = new Map<number, number>()
  let lastCpuAt = 0
  let lastCpus: os.CpuInfo[] | null = null
  // For each PTY that can be an orphan, the time when it started to be one. The key is the view ID
  // and the pid.
  let orphanSince = new Map<string, number>()
  // The frame rate reports of the current count (ruling 1).
  let fpsReports: Array<{ at: number; value: number }> = []
  let fpsFrom: number | null = null

  let link: { device: string; kind: LinkKind } | null = null
  let linkAt = Number.NEGATIVE_INFINITY
  let linkDue = false
  let lastBytes: { device: string; inBytes: number; outBytes: number; at: number } | null = null
  let rates: { down: number; up: number } | null = null

  let sides = newSides()
  let battery: Mac['battery'] = null
  let freeDiskGb: number | null = null
  let clonesMb: number | null = null
  let anthropicMs: Network['anthropicMs'] = null
  let githubMs: Network['githubMs'] = null
  let ghLimit: GithubLimit | { unavailable: string } | null = null

  function reset(): void {
    snapshot = EMPTY_PERFORMANCE
    samples = []
    trend = []
    lastCpu = new Map()
    lastCpuAt = 0
    lastCpus = null
    orphanSince = new Map()
    fpsReports = []
    fpsFrom = null
    link = null
    linkAt = Number.NEGATIVE_INFINITY
    linkDue = showing
    lastBytes = null
    rates = null
    sides = newSides()
    battery = null
    freeDiskGb = null
    clonesMb = null
    anthropicMs = null
    githubMs = null
    ghLimit = null
  }

  // The next tick comes the tick interval after the end of the last tick. The wait is never longer
  // than the interval, also when the clock went back.
  function schedule(): void {
    if (timer) clearTimeout(timer)
    const interval = showing ? FAST_TICK_MS : TICK_MS
    const wait = Math.min(interval, Math.max(0, lastEndAt + interval - deps.now()))
    timer = setTimeout(() => {
      timer = null
      void tick()
    }, wait)
  }

  // Start the read when its interval is past and it does not run. The read gives a function that
  // applies its result. Only a read of the current generation applies.
  function runSide(side: SideRead, everyMs: number, now: number, read: () => Promise<() => void>) {
    if (side.busy || !due(now - side.at, everyMs)) return
    side.busy = true
    side.at = now
    const gen = generation
    read()
      .then(apply => {
        if (gen === generation) apply()
      })
      .catch(error => console.error('Bifrost cannot read a performance value.', error))
      .finally(() => {
        side.busy = false
      })
  }

  function startSideReads(now: number, reviewsLimit: GithubLimit | null): void {
    runSide(sides.battery, BATTERY_MS, now, async () => {
      const b = await readBattery(deps.exec)
      return () => {
        battery = b === null ? null : { charging: b.charging, percent: b.percent }
      }
    })
    runSide(sides.disk, DISK_MS, now, async () => {
      const bytes = await deps.freeDiskBytes()
      return () => {
        freeDiskGb = bytes === null ? null : bytes / BYTES_PER_GB
      }
    })
    // du fails when the folder does not exist. Then the size is null.
    const clones = deps.clonesPath
    if (clones !== null) {
      runSide(sides.clones, CLONES_MS, now, async () => {
        const kb = await readDuKb(deps.exec, clones)
        return () => {
          clonesMb = kb === null ? null : kb / KB_PER_MB
        }
      })
    }
    // A test home makes no network request and no gh call.
    if (!deps.network || !showing) return
    runSide(sides.probes, PROBE_MS, now, async () => {
      const [a, g] = await Promise.all([
        deps.probe(PROBE_URLS.anthropic),
        deps.probe(PROBE_URLS.github),
      ])
      return () => {
        anthropicMs = a
        githubMs = g
      }
    })
    // With Reviews on, the rate limit comes from its poll and costs nothing more.
    if (reviewsLimit !== null) return
    runSide(sides.gh, PROBE_MS, now, async () => {
      const next = await deps.ghRateLimit()
      return () => {
        ghLimit = next
      }
    })
  }

  // The interface and its byte counters, only while the panel shows (ruling 3).
  async function readNetwork(due: boolean) {
    const next = due ? await readLink(deps.exec) : link
    const bytes = next === null ? null : await readNetBytes(deps.exec, next.device)
    return { bytes, link: next }
  }

  function applyNetwork(now: number, read: Awaited<ReturnType<typeof readNetwork>>): void {
    if (read.link?.device !== link?.device) lastBytes = null
    link = read.link
    if (link === null || read.bytes === null) {
      rates = null
      lastBytes = null
      return
    }
    if (lastBytes !== null && now > lastBytes.at) {
      const seconds = (now - lastBytes.at) / 1000
      rates = {
        down: Math.max(0, (read.bytes.inBytes - lastBytes.inBytes) / seconds),
        up: Math.max(0, (read.bytes.outBytes - lastBytes.outBytes) / seconds),
      }
    }
    lastBytes = { at: now, device: link.device, ...read.bytes }
  }

  // A send PTY is an orphan after 60 s. A chat PTY is an orphan 60 s after the renderer reports
  // no chat panel for it. Before the first report, no chat PTY is an orphan (P2, ruling 11).
  function trackOrphans(now: number, ptys: Array<{ viewId: string; pid: number }>): number {
    const next = new Map<string, number>()
    let count = 0
    for (const { viewId, pid } of ptys) {
      const candidate =
        viewId.startsWith('send:') ||
        (viewId.startsWith('chat:') && reported && !chatPanels.has(viewId))
      if (!candidate) continue
      const key = `${viewId} ${pid}`
      const since = orphanSince.get(key) ?? now
      next.set(key, since)
      if (now - since > LIMITS.orphanSeconds * 1000) count++
    }
    orphanSince = next
    return count
  }

  // True while the panel shows and has focus, the count started at least 10 s ago, and each report
  // of the last 10 s is below the limit (ruling 1).
  function fpsLow(now: number): boolean {
    if (!showing || !focused || fpsFrom === null) return false
    const windowMs = LIMITS.fpsLowSeconds * 1000
    if (now - fpsFrom < windowMs) return false
    const recent = fpsReports.filter(r => r.at >= now - windowMs)
    return recent.length > 0 && recent.every(r => r.value < LIMITS.fpsLow)
  }

  function lastFps(now: number): number | null {
    if (!showing || !focused) return null
    const last = fpsReports.at(-1)
    return last !== undefined && last.at >= now - LIMITS.fpsLowSeconds * 1000 ? last.value : null
  }

  async function tick(): Promise<void> {
    if (!running || busy) return
    busy = true
    const gen = generation
    try {
      const now = deps.now()
      const reviewsLimit = deps.rateLimit()
      startSideReads(now, reviewsLimit)
      const metrics = deps.appMetrics()
      const ptys = deps.ptys()
      const rows = deps.rows()
      const cpus = deps.cpus()
      const showingAtStart = showing
      const linkRead = showing && (linkDue || due(now - linkAt, LINK_MS))
      if (linkRead) {
        linkDue = false
        linkAt = now
      }
      const [table, pressure, swap, net] = await Promise.all([
        readPsStats(deps.exec),
        readPressure(deps.exec),
        readSwap(deps.exec),
        showingAtStart ? readNetwork(linkRead) : null,
      ])
      if (!running || gen !== generation) return
      // The panel can close during the reads. Then the rates go.
      if (net !== null && showing) applyNetwork(now, net)

      // CPU of a ps process: the change of its CPU time since the last read (P3). The first read
      // of a process gives 0.
      const elapsed = now - lastCpuAt
      const nextCpu = new Map<number, number>()
      const procCpu = (row: ProcRow): number => {
        nextCpu.set(row.pid, row.cpuSeconds)
        const before = lastCpu.get(row.pid)
        return before === undefined ? 0 : cpuPercent(before, row.cpuSeconds, elapsed)
      }

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
      for (const p of ptys) {
        const row = table?.get(p.pid)
        add(TERMINALS, row ? row.rssKb / KB_PER_MB : 0, row ? procCpu(row) : 0)
      }
      const terminals = groups.get(TERMINALS) as ProcGroup
      const shown = [...groups.values()].filter(g => g.name !== HELPERS || g.count > 0)
      const ramMb = shown.reduce((a, g) => a + g.ramMb, 0)
      const cpu = shown.reduce((a, g) => a + g.cpu, 0)

      // Bifrost's own processes do not count for a session (P4).
      const own = new Set([...metrics.map(m => m.pid), ...ptys.map(p => p.pid)])
      const sessions = table === null ? null : sessionUse(rows, table, own, procCpu)
      if (table !== null) {
        lastCpu = nextCpu
        lastCpuAt = now
      }

      if (metrics.length > 0) {
        samples.push({
          at: now,
          bifrostCpuNoTerm: cpu - terminals.cpu,
          bifrostRamMb: ramMb,
          bifrostRamNoTermMb: ramMb - terminals.ramMb,
        })
        trend.push({ at: now, cpu, ramMb })
      }
      while ((samples[0]?.at ?? now) < now - HISTORY_MS) samples.shift()
      while ((trend[0]?.at ?? now) < now - TREND_MS) trend.shift()

      const load = lastCpus === null ? null : cpuLoad(lastCpus, cpus)
      lastCpus = cpus
      const online = deps.online()
      const delay = deps.delayP99()
      const orphans = trackOrphans(now, ptys)
      const reasons = healthReasons({
        delayP99Ms: delay,
        fpsLow10s: fpsLow(now),
        log: deps.health.view(now),
        now,
        online,
        orphans,
        samples,
      })
      const github =
        reviewsLimit === null
          ? ghLimit
          : {
              limit: reviewsLimit.limit,
              remaining: reviewsLimit.remaining,
              resetAt: reviewsLimit.resetAt,
            }
      snapshot = {
        bifrost:
          metrics.length === 0
            ? null
            : { cpu, delayMs: delay, fps: lastFps(now), groups: shown, ramMb, trend: [...trend] },
        limits: { clonesMb, freeDiskGb, github },
        mac: { battery, cpuLoad: load, pressure, swap, thermal: deps.thermal() },
        network: {
          anthropicMs,
          downBps: rates?.down ?? null,
          githubMs,
          kind: link?.kind ?? null,
          online,
          upBps: rates?.up ?? null,
        },
        okText: okText(samples.at(-1)),
        reasons,
        sessions,
        state: healthState(reasons),
      }
      deps.emit(snapshot)
    } catch (error) {
      console.error('Bifrost cannot sample the performance data.', error)
    } finally {
      // The next tick always gets its timer, so a throw never stops the loop.
      if (gen === generation) {
        busy = false
        lastEndAt = deps.now()
        if (running) schedule()
      }
    }
  }

  return {
    current: () => snapshot,
    fps(value) {
      if (!showing || !focused) return
      const now = deps.now()
      if (fpsFrom === null) fpsFrom = now
      fpsReports.push({ at: now, value })
      fpsReports = fpsReports.filter(r => r.at >= now - LIMITS.fpsLowSeconds * 1000)
    },
    start() {
      if (running) return
      running = true
      generation += 1
      void tick()
    },
    stop() {
      running = false
      generation += 1
      busy = false
      if (timer) clearTimeout(timer)
      timer = null
      lastEndAt = Number.NEGATIVE_INFINITY
      reset()
    },
    view(v) {
      const opened = v.showing && !showing
      const closed = !v.showing && showing
      // A change of showing or focus starts a new count of the frame rate.
      if (v.showing !== showing || v.focused !== focused) {
        fpsReports = []
        fpsFrom = null
      }
      showing = v.showing
      focused = v.focused
      chatPanels = new Set(v.chatPanels)
      reported = true
      if (opened) linkDue = true
      if (closed) {
        rates = null
        lastBytes = null
      }
      if (!running) return
      trackOrphans(deps.now(), deps.ptys())
      // During a tick, the end of the tick sets the timer.
      if ((opened || closed) && !busy) schedule()
    },
  }
}

// The Claude sessions: each registry row with a pid and its process tree (design section 6,
// ruling 5). A session that started inside another session keeps its own processes, because the
// smaller tree goes first. So each process counts one time.
function sessionUse(
  rows: SessionRow[],
  table: Map<number, ProcRow>,
  own: Set<number>,
  procCpu: (row: ProcRow) => number,
): Sessions {
  const others = new Map(table)
  for (const pid of own) others.delete(pid)
  const trees = rows.flatMap(row =>
    row.pid !== undefined && others.has(row.pid)
      ? [{ pids: treeSum(others, row.pid).pids, row }]
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
      const proc = others.get(pid)
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
  const rest = list.slice(3)
  return {
    cpu: list.reduce((a, s) => a + s.cpu, 0),
    more: {
      count: rest.length,
      cpu: rest.reduce((a, s) => a + s.cpu, 0),
      ramMb: rest.reduce((a, s) => a + s.ramMb, 0),
    },
    ramMb: list.reduce((a, s) => a + s.ramMb, 0),
    top: list.slice(0, 3),
  }
}

// Read the GraphQL limit from the REST answer of gh api rate_limit. reset is in seconds.
export function parseGhRateLimit(stdout: string): GithubLimit | null {
  let root: unknown
  try {
    root = JSON.parse(stdout)
  } catch {
    return null
  }
  type Answer = { resources?: { graphql?: Record<string, unknown> } } | null
  const graphql = (root as Answer)?.resources?.graphql
  const value = (v: unknown): number | null =>
    typeof v === 'number' && Number.isFinite(v) && v >= 0 ? v : null
  const limit = value(graphql?.limit)
  const remaining = value(graphql?.remaining)
  const reset = value(graphql?.reset)
  if (limit === null || remaining === null || reset === null) return null
  return { limit, remaining, resetAt: reset * 1000 }
}

// The GitHub limit with Reviews off (ruling 6). A failure gives a friendly reason.
export async function readGhRateLimit(
  gh: Pick<Gh, 'run'>,
): Promise<GithubLimit | { unavailable: string }> {
  try {
    const result = await gh.run(RATE_LIMIT_ARGS, { timeoutMs: RATE_LIMIT_TIMEOUT_MS })
    const failed = ghFailure(result)
    if (failed?.availability === 'no-gh') return { unavailable: GH_LIMIT_MISSING }
    if (failed?.availability === 'logged-out') return { unavailable: GH_LIMIT_LOGGED_OUT }
    if (failed !== null) return { unavailable: GH_LIMIT_FAILED }
    return parseGhRateLimit(result.stdout) ?? { unavailable: GH_LIMIT_FAILED }
  } catch {
    return { unavailable: GH_LIMIT_FAILED }
  }
}

// One HEAD request with no login, no token and no cookie (ruling 9). Any HTTP status is an answer.
// The time is until the response headers. The timeout gives 'no-answer'. A DNS or connection
// error gives 'unreachable'.
export async function probeUrl(
  fetch: (url: string, init: RequestInit) => Promise<Response>,
  url: string,
  clock: () => number,
): Promise<ProbeResult> {
  const signal = AbortSignal.timeout(PROBE_TIMEOUT_MS)
  const start = clock()
  try {
    const res = await fetch(url, {
      cache: 'no-store',
      credentials: 'omit',
      method: 'HEAD',
      signal,
    })
    const ms = Math.max(0, Math.round(clock() - start))
    res.body?.cancel().catch(() => {})
    return ms
  } catch (error) {
    const timedOut = signal.aborted || (error instanceof Error && error.name === 'TimeoutError')
    return timedOut ? 'no-answer' : 'unreachable'
  }
}

// The part of the Node event loop delay histogram that the monitor uses. Its values are in ns.
export interface DelayHistogram {
  readonly count: number
  percentile(p: number): number
  reset(): void
  enable(): unknown
  disable(): unknown
}

// The main process delay of ruling 8.
export interface LoopDelay {
  // The 99th percentile of the last full window in ms. null before the end of the first window,
  // and for a window with no data.
  p99(): number | null
  stop(): void
}

// Enable the histogram. At the end of each 60 s window, keep its 99th percentile and reset it
// (ruling 8). stop clears the timer and disables the histogram.
export function createLoopDelay(h: DelayHistogram): LoopDelay {
  let last: number | null = null
  let timer: ReturnType<typeof setTimeout> | null = null
  h.enable()
  const roll = (): void => {
    last = h.count > 0 ? h.percentile(99) / NS_PER_MS : null
    h.reset()
    timer = setTimeout(roll, DELAY_WINDOW_MS)
  }
  timer = setTimeout(roll, DELAY_WINDOW_MS)
  return {
    p99: () => last,
    stop() {
      if (timer === null) return
      clearTimeout(timer)
      timer = null
      h.disable()
    },
  }
}

// Check the view report of the renderer. It has two booleans and the chat panel IDs only.
export function checkView(v: unknown): PanelView {
  if (typeof v !== 'object' || v === null) throw new Error(REFUSED_BAD_INPUT)
  const { chatPanels, focused, showing } = v as Record<string, unknown>
  if (typeof showing !== 'boolean' || typeof focused !== 'boolean') {
    throw new Error(REFUSED_BAD_INPUT)
  }
  if (!Array.isArray(chatPanels) || chatPanels.length > MAX_CHAT_PANELS) {
    throw new Error(REFUSED_BAD_INPUT)
  }
  for (const id of chatPanels) {
    if (typeof id !== 'string' || !CHAT_VIEW.test(id)) throw new Error(REFUSED_BAD_CHAT_PANEL)
  }
  return { chatPanels: [...chatPanels] as string[], focused, showing }
}

// Check the frame rate of the renderer: a finite number from 0 to 1000.
export function checkFps(v: unknown): number {
  if (typeof v !== 'number' || !Number.isFinite(v) || v < 0 || v > MAX_FPS) {
    throw new Error(REFUSED_BAD_INPUT)
  }
  return v
}
