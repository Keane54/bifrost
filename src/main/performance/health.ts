// The health model of the Performance panel (design sections 5.1 and 6). This code is pure.
// It has no timers and no file access. The monitor gives it the samples and the health log view.

import type { HealthState, Reason } from '../../shared/performance'
import { HEALTH_WINDOW_MS, type HealthLogView, type PollPart, type StorePart } from './health-log'

export interface Sample {
  at: number
  // All Bifrost processes, chat terminals included.
  bifrostRamMb: number
  // The same, without the chat terminals.
  bifrostRamNoTermMb: number
  bifrostCpuNoTerm: number
}

export const LIMITS = {
  cpuProblem: 100,
  cpuWarn: 50,
  cpuWindowMs: 2 * 60_000,
  delayProblemMs: 1000,
  delayWarnMs: 200,
  fpsLow: 30,
  fpsLowSeconds: 10,
  growthProblemMbPerHour: 800,
  growthWarnMbPerHour: 300,
  orphanSeconds: 60,
  pollFailProblem: 10,
  pollFailWarn: 3,
  ramProblemMb: 1536,
  ramWarnMb: 1024,
  trendMinSpanMs: 30 * 60_000,
  windowMs: HEALTH_WINDOW_MS,
} as const

export interface HealthInput {
  now: number
  samples: Sample[]
  fpsLow10s: boolean
  delayP99Ms: number | null
  log: HealthLogView
  online: boolean
  // The terminals with no chat window that the monitor found older than 60 s.
  orphans: number
}

const HOUR_MS = 60 * 60_000

// The least-squares slope of the RAM without chat terminals, in MB per hour.
export function trendMbPerHour(samples: Sample[], now: number): number | null {
  const used = samples.filter(s => s.at >= now - LIMITS.windowMs)
  if (used.length < 2) return null
  const times = used.map(s => s.at)
  const span = Math.max(...times) - Math.min(...times)
  if (span < LIMITS.trendMinSpanMs) return null
  const n = used.length
  const meanT = used.reduce((a, s) => a + s.at, 0) / n
  const meanY = used.reduce((a, s) => a + s.bifrostRamNoTermMb, 0) / n
  let num = 0
  let den = 0
  for (const s of used) {
    num += (s.at - meanT) * (s.bifrostRamNoTermMb - meanY)
    den += (s.at - meanT) ** 2
  }
  if (den === 0) return null
  return (num / den) * HOUR_MS
}

function localTime(at: number): string {
  const d = new Date(at)
  const two = (n: number) => String(n).padStart(2, '0')
  return `${two(d.getHours())}:${two(d.getMinutes())}`
}

// The OK text form. The rounded MB value decides, so 1023.6 MB gives "1.0 GB".
function ramText(mb: number): string {
  const whole = Math.round(mb)
  return whole < 1024 ? `${whole} MB` : `${(mb / 1024).toFixed(1)} GB`
}

// The reason text form. A whole MB value with a fixed locale.
function ramMbText(mb: number): string {
  return `${Math.round(mb).toLocaleString('en-US')} MB`
}

// A limit in GB for a reason text, for example "1 GB" or "1.5 GB".
function limitGb(mb: number): string {
  return `${mb / 1024} GB`
}

const POLL_NAMES: Record<PollPart, string> = {
  'account-usage': 'check your account usage',
  reviews: 'check GitHub for reviews',
  'service-status': "check Claude's status",
  sessions: 'check for sessions',
}

const STORE_NAMES: Record<StorePart, string> = {
  registry: 'the session list',
  'reviews-state': 'the Reviews state',
  settings: 'your settings',
  'ui-state': 'the panel layout',
  'window-state': 'the window position',
}

export function healthReasons(
  input: HealthInput,
  formatTime: (at: number) => string = localTime,
): Reason[] {
  const problems: Reason[] = []
  const warnings: Reason[] = []
  const add = (level: Reason['level'], text: string) =>
    (level === 'problem' ? problems : warnings).push({ level, text })
  const { now, samples, log } = input

  // RAM of the newest sample.
  if (samples.length > 0) {
    const latest = samples.reduce((a, s) => (s.at >= a.at ? s : a))
    const mb = latest.bifrostRamMb
    if (mb > LIMITS.ramProblemMb) {
      add(
        'problem',
        `Bifrost is using ${ramMbText(mb)} RAM, above the ${limitGb(LIMITS.ramProblemMb)} limit.`,
      )
    } else if (mb > LIMITS.ramWarnMb) {
      add(
        'warning',
        `Bifrost is using ${ramMbText(mb)} RAM, above the ${limitGb(LIMITS.ramWarnMb)} limit.`,
      )
    }
  }

  // Memory growth.
  const trend = trendMbPerHour(samples, now)
  if (trend !== null) {
    const text = `Bifrost's memory is growing by about ${Math.round(trend)} MB an hour.`
    if (trend > LIMITS.growthProblemMbPerHour) add('problem', text)
    else if (trend > LIMITS.growthWarnMbPerHour) add('warning', text)
  }

  // CPU. No reason until the samples cover the whole 2 minutes.
  if (samples.length > 0) {
    const oldest = Math.min(...samples.map(s => s.at))
    if (now - oldest >= LIMITS.cpuWindowMs) {
      const recent = samples.filter(s => s.at >= now - LIMITS.cpuWindowMs)
      if (recent.length > 0) {
        const avg = recent.reduce((a, s) => a + s.bifrostCpuNoTerm, 0) / recent.length
        const text = `Bifrost is using ${Math.round(avg)}% CPU on average over the last ${LIMITS.cpuWindowMs / 60_000} minutes.`
        if (avg > LIMITS.cpuProblem) add('problem', text)
        else if (avg > LIMITS.cpuWarn) add('warning', text)
      }
    }
  }

  if (input.fpsLow10s) {
    add(
      'warning',
      `The Performance panel ran below ${LIMITS.fpsLow} fps for ${LIMITS.fpsLowSeconds} seconds.`,
    )
  }

  if (input.delayP99Ms !== null) {
    const ms = Math.round(input.delayP99Ms)
    const text = `Bifrost's main process was slow to respond (up to ${ms} ms).`
    if (input.delayP99Ms > LIMITS.delayProblemMs) add('problem', text)
    else if (input.delayP99Ms > LIMITS.delayWarnMs) add('warning', text)
  }

  for (const crash of log.crashes) {
    if (now - crash.at >= LIMITS.windowMs) continue
    const what = crash.kind === 'window' ? 'The window' : 'The graphics process'
    add('problem', `${what} crashed at ${formatTime(crash.at)}.`)
  }

  const parts = Object.keys(POLL_NAMES) as PollPart[]
  for (const part of parts) {
    // While offline, the network parts give no reason.
    if (!input.online && part !== 'sessions') continue
    const fails = log.failsInARow[part]
    const text = `Bifrost couldn't ${POLL_NAMES[part]} ${fails} times in a row.`
    if (fails >= LIMITS.pollFailProblem) add('problem', text)
    else if (fails >= LIMITS.pollFailWarn) add('warning', text)
  }

  if (log.liveStartFailedAt !== null) {
    add('warning', "Bifrost couldn't start the Live details link.")
  }

  if (input.orphans >= 1) {
    const n = input.orphans
    add(
      'warning',
      n === 1
        ? '1 chat terminal is running with no chat window.'
        : `${n} chat terminals are running with no chat window.`,
    )
  }

  const stores = Object.keys(STORE_NAMES) as StorePart[]
  for (const store of stores) {
    const at = log.saveFailedAt[store]
    if (at === undefined || now - at >= LIMITS.windowMs) continue
    add('warning', `Bifrost couldn't save ${STORE_NAMES[store]} at ${formatTime(at)}.`)
  }

  return [...problems, ...warnings]
}

export function healthState(reasons: Reason[]): HealthState {
  if (reasons.some(r => r.level === 'problem')) return 'problem'
  return reasons.length > 0 ? 'warning' : 'ok'
}

export function okText(sample: Sample | undefined): string | null {
  if (!sample) return null
  const cpu = `${Math.round(sample.bifrostCpuNoTerm)}%`
  return `Bifrost is using ${ramText(sample.bifrostRamMb)} RAM and ${cpu} CPU.`
}
