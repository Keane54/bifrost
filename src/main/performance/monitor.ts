// The Performance monitor (design sections 5.2, 6 and 7). It samples Bifrost, the Claude sessions
// and the Mac on a timer, runs the health model and sends a snapshot after each tick. It never
// imports electron. ipc.ts gives it each Electron, Node and command function.
import type * as os from 'node:os'
import { EMPTY_PERFORMANCE, type PerformanceSnapshot } from '../../shared/performance'
import type { SessionRow } from '../../shared/types'
import type { ExecFn } from '../claude/cli'
import { healthReasons, healthState, LIMITS, okText, type Sample } from './health'
import type { HealthLog } from './health-log'
import {
  type AppMetric,
  type BifrostUse,
  bifrostUse,
  type Sessions,
  sessionUse,
  type Use,
} from './process-use'
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
} from './system'

// The tick while the panel is closed, and while it shows (P9).
export const TICK_MS = 15_000
export const FAST_TICK_MS = 2_000
// ps and netstat run at most this often. While the panel is closed, ps runs on each tick
// (ruling A).
export const COMMAND_MS = 6_000
// The memory pressure and the swap, at most this often in each state (design section 7).
export const MAC_MS = 15_000
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
// The two hosts of the response times (design section 7).
export const PROBE_URLS = {
  anthropic: 'https://api.anthropic.com',
  github: 'https://api.github.com',
} as const

const KB_PER_MB = 1024
// Finder shows the disk sizes in units of 1,000,000,000 bytes.
const BYTES_PER_GB = 1e9
const NEVER = Number.NEGATIVE_INFINITY
const NO_USE: Use = { cpu: 0, ramMb: 0 }

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
  // Electron app.getAppMetrics().
  appMetrics(): AppMetric[]
  // The PTYs of the PTY manager (P1).
  ptys(): Array<{ viewId: string; pid: number }>
  rows(): SessionRow[]
  cpus(): os.CpuInfo[]
  thermal(): string | null
  online(): boolean
  freeDiskBytes(): Promise<number | null>
  // True when the folder exists. du runs only for a folder that exists (ruling B).
  exists(path: string): Promise<boolean>
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

type Pty = { viewId: string; pid: number }
type Mac = NonNullable<PerformanceSnapshot['mac']>
type TrendPoint = NonNullable<PerformanceSnapshot['bifrost']>['trend'][number]
type Link = { device: string; kind: LinkKind }

// A read that runs at its own interval, in the background of the ticks.
interface SideRead {
  at: number
  busy: boolean
}

const newSide = (): SideRead => ({ at: NEVER, busy: false })

// True when the interval since the last read is past. A clock that went back also makes the read
// due, so a clock change cannot stop a read for a long time.
const due = (since: number, everyMs: number): boolean => since < 0 || since >= everyMs

// The sampled state of the monitor. stop() replaces it with a new one.
function freshState(linkDue: boolean) {
  return {
    anthropicMs: null as ProbeResult | null,
    battery: null as Mac['battery'],
    clonesMb: null as number | null,
    fpsFrom: null as number | null,
    // The frame rate reports of the current count (ruling 1).
    fpsReports: [] as Array<{ at: number; value: number }>,
    freeDiskGb: null as number | null,
    ghLimit: null as GithubLimit | { unavailable: string } | null,
    githubMs: null as ProbeResult | null,
    lastBytes: null as { device: string; inBytes: number; outBytes: number; at: number } | null,
    // The cumulative CPU time of each ps process of the last good ps read (P3).
    lastCpu: new Map<number, number>(),
    lastCpuAt: 0,
    lastCpus: null as os.CpuInfo[] | null,
    link: null as Link | null,
    linkAt: NEVER,
    linkDue,
    macAt: NEVER,
    netAt: NEVER,
    // For each PTY that can be an orphan, the time when it started to be one. The key is the view
    // ID and the pid.
    orphanSince: new Map<string, number>(),
    pressure: null as Mac['pressure'],
    psAt: NEVER,
    rates: null as { down: number; up: number } | null,
    samples: [] as Sample[],
    // The sessions and the chat terminal values (by pid) of the last good ps read (ruling C).
    sessions: null as Sessions | null,
    sides: {
      battery: newSide(),
      clones: newSide(),
      disk: newSide(),
      gh: newSide(),
      probes: newSide(),
    },
    swap: null as Mac['swap'],
    terminals: new Map<number, Use>(),
    trend: [] as TrendPoint[],
  }
}

// Make the monitor. Each tick reads the Electron processes, the PTYs, the rows and the CPU times,
// and the commands that are due. It keeps a sample, runs the health model and emits the snapshot.
// The tick is 15 s, or 2 s while the panel shows (P9).
export function createPerformanceMonitor(deps: MonitorDeps): PerformanceMonitor {
  let running = false
  let busy = false
  // Each start and each stop makes a new generation. A read of an old generation changes nothing.
  let generation = 0
  let timer: ReturnType<typeof setTimeout> | null = null
  let lastEndAt = NEVER
  let snapshot: PerformanceSnapshot = EMPTY_PERFORMANCE
  // The last report of the renderer. It stays after a stop, because the renderer reports only a
  // change.
  let reported = false
  let showing = false
  let focused = false
  let chatPanels = new Set<string>()
  let st = freshState(false)

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
    const { sides } = st
    runSide(sides.battery, BATTERY_MS, now, async () => {
      const b = await readBattery(deps.exec)
      return () => {
        st.battery = b === null ? null : { charging: b.charging, percent: b.percent }
      }
    })
    runSide(sides.disk, DISK_MS, now, async () => {
      const bytes = await deps.freeDiskBytes()
      return () => {
        st.freeDiskGb = bytes === null ? null : bytes / BYTES_PER_GB
      }
    })
    const clones = deps.clonesPath
    if (clones !== null) {
      runSide(sides.clones, CLONES_MS, now, async () => {
        const kb = (await deps.exists(clones)) ? await readDuKb(deps.exec, clones) : null
        return () => {
          st.clonesMb = kb === null ? null : kb / KB_PER_MB
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
        st.anthropicMs = a
        st.githubMs = g
      }
    })
    // With Reviews on, the rate limit comes from its poll and costs nothing more.
    if (reviewsLimit !== null) return
    runSide(sides.gh, PROBE_MS, now, async () => {
      const next = await deps.ghRateLimit()
      return () => {
        st.ghLimit = next
      }
    })
  }

  // Mark and give the commands that this tick runs. ps and netstat run at most every 6 s, the
  // pressure and the swap at most every 15 s. The network commands run only while the panel
  // shows (ruling 3).
  function planReads(now: number) {
    const plan = {
      bytes: showing && due(now - st.netAt, COMMAND_MS),
      kind: showing && (st.linkDue || due(now - st.linkAt, LINK_MS)),
      mac: due(now - st.macAt, MAC_MS),
      ps: due(now - st.psAt, COMMAND_MS),
    }
    if (plan.ps) st.psAt = now
    if (plan.mac) st.macAt = now
    if (plan.kind) {
      st.linkDue = false
      st.linkAt = now
    }
    if (plan.bytes) st.netAt = now
    return plan
  }

  // The interface and its byte counters.
  async function readNetwork(readKind: boolean, readBytes: boolean) {
    const link = readKind ? await readLink(deps.exec) : st.link
    const bytes = readBytes && link !== null ? await readNetBytes(deps.exec, link.device) : null
    return { bytes, link, readBytes, readKind }
  }

  function applyNetwork(now: number, read: Awaited<ReturnType<typeof readNetwork>>): void {
    if (read.readKind) {
      // A failed read runs again at the next tick (review 4).
      if (read.link === null) st.linkDue = true
      // A new interface starts the rates again (review 3).
      if (read.link?.device !== st.link?.device) {
        st.lastBytes = null
        st.rates = null
      }
      st.link = read.link
    }
    if (!read.readBytes) return
    if (st.link === null || read.bytes === null) {
      st.lastBytes = null
      st.rates = null
      return
    }
    const last = st.lastBytes
    if (last !== null && now > last.at) {
      const seconds = (now - last.at) / 1000
      st.rates = {
        down: Math.max(0, (read.bytes.inBytes - last.inBytes) / seconds),
        up: Math.max(0, (read.bytes.outBytes - last.outBytes) / seconds),
      }
    }
    st.lastBytes = { at: now, device: st.link.device, ...read.bytes }
  }

  // Keep the chat terminal values and the sessions of one good ps read. The CPU of a ps process
  // is the change of its CPU time since the last read, over the real time between the two reads
  // (P3). The first read of a process gives 0.
  function applyPs(
    now: number,
    table: Map<number, ProcRow>,
    ptys: Pty[],
    rows: SessionRow[],
    metrics: AppMetric[],
  ): void {
    const elapsed = now - st.lastCpuAt
    const nextCpu = new Map<number, number>()
    const procCpu = (row: ProcRow): number => {
      nextCpu.set(row.pid, row.cpuSeconds)
      const before = st.lastCpu.get(row.pid)
      return before === undefined ? 0 : cpuPercent(before, row.cpuSeconds, elapsed)
    }
    st.terminals = new Map(
      ptys.map((p): [number, Use] => {
        const row = table.get(p.pid)
        return [p.pid, row ? { cpu: procCpu(row), ramMb: row.rssKb / KB_PER_MB } : NO_USE]
      }),
    )
    // Bifrost's own processes count for no session (P4).
    const own = new Set([...metrics.map(m => m.pid), ...ptys.map(p => p.pid)])
    st.sessions = sessionUse(rows, table, own, procCpu)
    st.lastCpu = nextCpu
    st.lastCpuAt = now
  }

  function addSample(now: number, use: BifrostUse): void {
    st.samples.push({
      at: now,
      bifrostCpuNoTerm: use.cpu - use.terminals.cpu,
      bifrostRamMb: use.ramMb,
      bifrostRamNoTermMb: use.ramMb - use.terminals.ramMb,
    })
    st.trend.push({ at: now, cpu: use.cpu, ramMb: use.ramMb })
    while ((st.samples[0]?.at ?? now) < now - HISTORY_MS) st.samples.shift()
    while ((st.trend[0]?.at ?? now) < now - TREND_MS) st.trend.shift()
  }

  // A send PTY is an orphan after 60 s. A chat PTY is an orphan 60 s after the renderer reports
  // no chat panel for it. Before the first report, no chat PTY is an orphan (P2, ruling 11).
  function trackOrphans(now: number, ptys: Pty[]): number {
    const next = new Map<string, number>()
    let count = 0
    for (const { viewId, pid } of ptys) {
      const candidate =
        viewId.startsWith('send:') ||
        (viewId.startsWith('chat:') && reported && !chatPanels.has(viewId))
      if (!candidate) continue
      const key = `${viewId} ${pid}`
      const since = st.orphanSince.get(key) ?? now
      next.set(key, since)
      if (now - since > LIMITS.orphanSeconds * 1000) count++
    }
    st.orphanSince = next
    return count
  }

  // True while the panel shows and has focus, the count started at least 10 s ago, and each report
  // of the last 10 s is below the limit (ruling 1).
  function fpsLow(now: number): boolean {
    if (!showing || !focused || st.fpsFrom === null) return false
    const windowMs = LIMITS.fpsLowSeconds * 1000
    if (now - st.fpsFrom < windowMs) return false
    const recent = st.fpsReports.filter(r => r.at >= now - windowMs)
    return recent.length > 0 && recent.every(r => r.value < LIMITS.fpsLow)
  }

  function lastFps(now: number): number | null {
    if (!showing || !focused) return null
    const last = st.fpsReports.at(-1)
    return last !== undefined && last.at >= now - LIMITS.fpsLowSeconds * 1000 ? last.value : null
  }

  // The snapshot of a tick, with the result of the health model.
  function build(t: {
    now: number
    hasMetrics: boolean
    use: BifrostUse
    load: number | null
    orphans: number
    reviewsLimit: GithubLimit | null
  }): PerformanceSnapshot {
    const { now, use, reviewsLimit } = t
    const online = deps.online()
    const delay = deps.delayP99()
    const reasons = healthReasons({
      delayP99Ms: delay,
      fpsLow10s: fpsLow(now),
      log: deps.health.view(now),
      now,
      online,
      orphans: t.orphans,
      samples: st.samples,
    })
    const github =
      reviewsLimit === null
        ? st.ghLimit
        : {
            limit: reviewsLimit.limit,
            remaining: reviewsLimit.remaining,
            resetAt: reviewsLimit.resetAt,
          }
    return {
      bifrost: t.hasMetrics
        ? {
            cpu: use.cpu,
            delayMs: delay,
            fps: lastFps(now),
            groups: use.groups,
            ramMb: use.ramMb,
            trend: [...st.trend],
          }
        : null,
      limits: { clonesMb: st.clonesMb, freeDiskGb: st.freeDiskGb, github },
      mac: {
        battery: st.battery,
        cpuLoad: t.load,
        pressure: st.pressure,
        swap: st.swap,
        thermal: deps.thermal(),
      },
      network: {
        anthropicMs: st.anthropicMs,
        downBps: st.rates?.down ?? null,
        githubMs: st.githubMs,
        kind: st.link?.kind ?? null,
        online,
        upBps: st.rates?.up ?? null,
      },
      okText: okText(st.samples.at(-1)),
      reasons,
      sessions: st.sessions,
      state: healthState(reasons),
    }
  }

  async function tick(): Promise<void> {
    if (!running || busy) return
    busy = true
    const gen = generation
    try {
      const now = deps.now()
      // A Reviews value after its reset time is old. Then gh gives the limit (review 6).
      const fromReviews = deps.rateLimit()
      const reviewsLimit = fromReviews !== null && fromReviews.resetAt > now ? fromReviews : null
      startSideReads(now, reviewsLimit)
      const metrics = deps.appMetrics()
      const ptys = deps.ptys()
      const rows = deps.rows()
      const cpus = deps.cpus()
      const plan = planReads(now)
      const [table, mac, net] = await Promise.all([
        plan.ps ? readPsStats(deps.exec) : undefined,
        plan.mac ? Promise.all([readPressure(deps.exec), readSwap(deps.exec)]) : undefined,
        plan.kind || plan.bytes ? readNetwork(plan.kind, plan.bytes) : undefined,
      ])
      if (!running || gen !== generation) return
      if (mac !== undefined) [st.pressure, st.swap] = mac
      // The panel can close during the reads. Then the rates stay away.
      if (net !== undefined && showing) applyNetwork(now, net)
      if (table) applyPs(now, table, ptys, rows, metrics)
      const use = bifrostUse(
        metrics,
        ptys.map(p => st.terminals.get(p.pid) ?? NO_USE),
      )
      // A tick with a failed ps adds no sample (ruling C).
      if (metrics.length > 0 && table !== null) addSample(now, use)
      const load = st.lastCpus === null ? null : cpuLoad(st.lastCpus, cpus)
      st.lastCpus = cpus
      snapshot = build({
        hasMetrics: metrics.length > 0,
        load,
        now,
        orphans: trackOrphans(now, ptys),
        reviewsLimit,
        use,
      })
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
      if (st.fpsFrom === null) st.fpsFrom = now
      st.fpsReports.push({ at: now, value })
      st.fpsReports = st.fpsReports.filter(r => r.at >= now - LIMITS.fpsLowSeconds * 1000)
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
      lastEndAt = NEVER
      snapshot = EMPTY_PERFORMANCE
      st = freshState(showing)
    },
    view(v) {
      const opened = v.showing && !showing
      const closed = !v.showing && showing
      // A change of showing or focus starts a new count of the frame rate.
      if (v.showing !== showing || v.focused !== focused) {
        st.fpsReports = []
        st.fpsFrom = null
      }
      showing = v.showing
      focused = v.focused
      chatPanels = new Set(v.chatPanels)
      reported = true
      if (opened) st.linkDue = true
      // The rates stop. The next showing reads the bytes at its first tick.
      if (closed) {
        st.rates = null
        st.lastBytes = null
        st.netAt = NEVER
      }
      if (!running) return
      trackOrphans(deps.now(), deps.ptys())
      // During a tick, the end of the tick sets the timer.
      if ((opened || closed) && !busy) schedule()
    },
  }
}
