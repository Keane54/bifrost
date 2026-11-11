import type * as os from 'node:os'
import type { ExecFn } from '../claude/cli'

// Readers and parsers for the system data of the Performance panel.
// Each reader runs one read-only macOS command. A failed run gives null.
// A reader never throws.

export const PS = '/bin/ps'
export const PS_STATS_ARGS = ['-axo', 'pid=,ppid=,rss=,time=,comm=']
export const SYSCTL = '/usr/sbin/sysctl'
export const PRESSURE_ARGS = ['-n', 'kern.memorystatus_vm_pressure_level']
export const SWAP_ARGS = ['-n', 'vm.swapusage']
export const PMSET = '/usr/bin/pmset'
export const BATTERY_ARGS = ['-g', 'batt']
export const ROUTE = '/sbin/route'
export const ROUTE_ARGS = ['-n', 'get', 'default']
export const NETWORKSETUP = '/usr/sbin/networksetup'
export const PORTS_ARGS = ['-listallhardwareports']
export const NETSTAT = '/usr/sbin/netstat'
export const NETSTAT_ARGS = ['-ib']
export const DU = '/usr/bin/du'

const TIMEOUT_MS = 5000
const DU_TIMEOUT_MS = 15000

// One row of the process table.
export interface ProcRow {
  pid: number
  ppid: number
  rssKb: number
  cpuSeconds: number
}

// Read a ps time: M:SS.cc, H:MM:SS or D-HH:MM:SS. A bad value gives null.
function parseCpuTime(text: string): number | null {
  const m = /^(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)$/.exec(text)
  if (!m) return null
  const days = Number(m[1] ?? 0)
  // Two parts are minutes and seconds. Three parts are hours, minutes and seconds.
  const hasHours = m[2] !== undefined && m[1] === undefined
  const first = Number(m[2] ?? 0)
  const minutes = Number(m[3])
  const seconds = Number(m[4])
  if (m[1] !== undefined) return days * 86400 + first * 3600 + minutes * 60 + seconds
  return hasHours ? first * 3600 + minutes * 60 + seconds : minutes * 60 + seconds
}

// Read the output of ps. A line that does not match is skipped.
// The comm is last and can hold spaces.
export function parsePsStats(stdout: string): Map<number, ProcRow> {
  const table = new Map<number, ProcRow>()
  for (const line of stdout.split('\n')) {
    const m = /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+\S/.exec(line)
    if (!m) continue
    const cpuSeconds = parseCpuTime(m[4])
    if (cpuSeconds === null) continue
    const pid = Number(m[1])
    table.set(pid, { cpuSeconds, pid, ppid: Number(m[2]), rssKb: Number(m[3]) })
  }
  return table
}

// The child pids of each pid. Build it one time for a table and give it to treeSumIn for each
// root. A pid in skip is not a child of its parent, so a tree sum does not enter it or its
// descendants.
export function childIndex(
  table: Map<number, ProcRow>,
  skip: ReadonlySet<number> = new Set(),
): Map<number, number[]> {
  const children = new Map<number, number[]>()
  for (const row of table.values()) {
    if (skip.has(row.pid)) continue
    const list = children.get(row.ppid)
    if (list) list.push(row.pid)
    else children.set(row.ppid, [row.pid])
  }
  return children
}

// Sum the RSS and the CPU time of a root process and all its descendants.
// Each process counts once. A root that is not in the table gives zeros.
export function treeSum(
  table: Map<number, ProcRow>,
  root: number,
): { rssKb: number; cpuSeconds: number; pids: number[] } {
  return treeSumIn(table, childIndex(table), root)
}

// treeSum with a children index from childIndex.
export function treeSumIn(
  table: Map<number, ProcRow>,
  children: ReadonlyMap<number, number[]>,
  root: number,
): { rssKb: number; cpuSeconds: number; pids: number[] } {
  const sum = { cpuSeconds: 0, pids: [] as number[], rssKb: 0 }
  if (!table.has(root)) return sum
  const seen = new Set<number>()
  const stack = [root]
  while (stack.length > 0) {
    const pid = stack.pop() as number
    if (seen.has(pid)) continue
    seen.add(pid)
    const row = table.get(pid)
    if (!row) continue
    sum.pids.push(pid)
    sum.rssKb += row.rssKb
    sum.cpuSeconds += row.cpuSeconds
    for (const child of children.get(pid) ?? []) stack.push(child)
  }
  return sum
}

// Percent of one core between two samples of cumulative CPU time. Callers divide by the cores.
export function cpuPercent(prevSeconds: number, nextSeconds: number, elapsedMs: number): number {
  if (elapsedMs <= 0) return 0
  return Math.max(0, ((nextSeconds - prevSeconds) / (elapsedMs / 1000)) * 100)
}

export type Pressure = 'normal' | 'warn' | 'critical'

export function parsePressureLevel(stdout: string): Pressure | null {
  switch (stdout.trim()) {
    case '1':
      return 'normal'
    case '2':
      return 'warn'
    case '4':
      return 'critical'
    default:
      return null
  }
}

export function parseSwap(stdout: string): { usedMb: number; totalMb: number } | null {
  const total = /total\s*=\s*([\d.]+)M/.exec(stdout)
  const used = /used\s*=\s*([\d.]+)M/.exec(stdout)
  if (!total || !used) return null
  return { totalMb: Math.round(Number(total[1])), usedMb: Math.round(Number(used[1])) }
}

// A Mac with no battery line gives null.
export function parseBattery(
  stdout: string,
): { percent: number; charging: boolean; onBattery: boolean } | null {
  const line = stdout.split('\n').find(l => /\d+%/.test(l))
  if (!line) return null
  const percent = Number(/(\d+)%/.exec(line)?.[1])
  return {
    charging: /;\s*charging\b/.test(line),
    onBattery: /Battery Power/.test(stdout),
    percent,
  }
}

export function parseDefaultInterface(stdout: string): string | null {
  const m = /^\s*interface:\s*(\S+)/m.exec(stdout)
  return m ? m[1] : null
}

// The map goes from the device to the port name.
export function parseHardwarePorts(stdout: string): Map<string, string> {
  const ports = new Map<string, string>()
  let port: string | null = null
  for (const line of stdout.split('\n')) {
    const p = /^Hardware Port:\s*(.+?)\s*$/.exec(line)
    if (p) {
      port = p[1]
      continue
    }
    const d = /^Device:\s*(\S+)/.exec(line)
    if (d && port !== null) {
      ports.set(d[1], port)
      port = null
    }
  }
  return ports
}

export type LinkKind = 'wifi' | 'ethernet' | 'vpn' | 'other'

export function linkKind(device: string, ports: Map<string, string>): LinkKind {
  if (device.startsWith('utun') || device.startsWith('ipsec')) return 'vpn'
  const port = ports.get(device)
  if (port === undefined) return 'other'
  if (port === 'Wi-Fi') return 'wifi'
  if (/Ethernet|Thunderbolt/.test(port)) return 'ethernet'
  return 'other'
}

// Read the Link row of the device. The address column can be empty,
// so the fields count from the right: Obytes is the second last, Ibytes the fifth last.
export function parseNetBytes(
  stdout: string,
  device: string,
): { inBytes: number; outBytes: number } | null {
  for (const line of stdout.split('\n')) {
    const fields = line.trim().split(/\s+/)
    if (fields[0] !== device || !/^<Link#\d+>$/.test(fields[2] ?? '')) continue
    if (fields.length < 10) return null
    const inBytes = Number(fields[fields.length - 5])
    const outBytes = Number(fields[fields.length - 2])
    return Number.isFinite(inBytes) && Number.isFinite(outBytes) ? { inBytes, outBytes } : null
  }
  return null
}

// Percent of the whole Mac between two os.cpus() samples, 0 to 100.
export function cpuLoad(prev: os.CpuInfo[], next: os.CpuInfo[]): number {
  let busy = 0
  let total = 0
  const count = Math.min(prev.length, next.length)
  for (let i = 0; i < count; i++) {
    const a = prev[i].times
    const b = next[i].times
    const idle = b.idle - a.idle
    const work = b.user - a.user + (b.nice - a.nice) + (b.sys - a.sys) + (b.irq - a.irq)
    busy += work
    total += work + idle
  }
  if (total <= 0) return 0
  return Math.min(100, Math.max(0, (busy / total) * 100))
}

export function parseDuKb(stdout: string): number | null {
  const m = /^\s*(\d+)\s/.exec(stdout)
  return m ? Number(m[1]) : null
}

// Run a command. A throw, a code other than 0 and empty output give null.
async function run(
  exec: ExecFn,
  file: string,
  args: string[],
  timeoutMs = TIMEOUT_MS,
): Promise<string | null> {
  try {
    const result = await exec(file, args, { timeoutMs })
    if (result.code !== 0 || result.stdout.trim() === '') return null
    return result.stdout
  } catch {
    return null
  }
}

export async function readPsStats(exec: ExecFn): Promise<Map<number, ProcRow> | null> {
  const out = await run(exec, PS, PS_STATS_ARGS)
  if (out === null) return null
  const table = parsePsStats(out)
  return table.size > 0 ? table : null
}

export async function readPressure(exec: ExecFn): Promise<Pressure | null> {
  const out = await run(exec, SYSCTL, PRESSURE_ARGS)
  return out === null ? null : parsePressureLevel(out)
}

export async function readSwap(exec: ExecFn): Promise<{ usedMb: number; totalMb: number } | null> {
  const out = await run(exec, SYSCTL, SWAP_ARGS)
  return out === null ? null : parseSwap(out)
}

export async function readBattery(
  exec: ExecFn,
): Promise<{ percent: number; charging: boolean; onBattery: boolean } | null> {
  const out = await run(exec, PMSET, BATTERY_ARGS)
  return out === null ? null : parseBattery(out)
}

// The default interface and its kind.
export async function readLink(exec: ExecFn): Promise<{ device: string; kind: LinkKind } | null> {
  const route = await run(exec, ROUTE, ROUTE_ARGS)
  const device = route === null ? null : parseDefaultInterface(route)
  if (device === null) return null
  const ports = await run(exec, NETWORKSETUP, PORTS_ARGS)
  return { device, kind: linkKind(device, ports === null ? new Map() : parseHardwarePorts(ports)) }
}

export async function readNetBytes(
  exec: ExecFn,
  device: string,
): Promise<{ inBytes: number; outBytes: number } | null> {
  const out = await run(exec, NETSTAT, NETSTAT_ARGS)
  return out === null ? null : parseNetBytes(out, device)
}

export async function readDuKb(exec: ExecFn, path: string): Promise<number | null> {
  const out = await run(exec, DU, ['-sk', path], DU_TIMEOUT_MS)
  return out === null ? null : parseDuKb(out)
}
