// The health model of the Performance panel (design sections 5.1 and 6). This code is pure.
// It has no timers and no file access. The monitor gives it the samples and the health log view.

import type { HealthState, Reason } from '../../shared/performance'
import { HEALTH_WINDOW_MS, type HealthLogView, type PollPart, type StorePart } from './health-log'

export interface Sample {
  at: number
  // All Bifrost processes, chat terminals included.
  bifrostRamMb: number
  // The same, without the chat terminals. The RAM limits and the OK text use this value (user
  // decision, 2026-11-10): each chat window starts its own claude attach process, so the chat
  // terminals grow with the number of chats.
  bifrostRamNoTermMb: number
  // The RAM of the largest chat terminal, or 0 with no chat terminal.
  largestTerminalRamMb: number
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
  // The OK text needs a sample that is not older than this.
  okSampleMaxAgeMs: 60_000,
  orphanSeconds: 60,
  pollFailProblem: 10,
  pollFailWarn: 3,
  ramProblemMb: 1536,
  ramWarnMb: 1024,
  // One chat terminal above this RAM is a warning. It points to a problem in that one session.
  terminalRamWarnMb: 500,
  // The trend needs samples for the full 60 minutes, so one RAM step cannot give a reason.
  trendMinSpanMs: 60 * 60_000,
  windowMs: HEALTH_WINDOW_MS,
} as const

export interface HealthInput {
  now: number
  samples: Sample[]
  fpsLow10s: boolean
  // The longest main process delay of the last 60 s window in ms.
  delayMs: number | null
  log: HealthLogView
  online: boolean
  // The terminals with no chat window that the monitor found older than 60 s.
  orphans: number
}

const HOUR_MS = 60 * 60_000

// The least-squares slope of the RAM without chat terminals over the last 60 minutes, in MB per
// hour. null until the samples cover 60 minutes. A sample from before the window shows that
// the window is full, because the ticks do not fall exactly on its start.
export function trendMbPerHour(samples: Sample[], now: number): number | null {
  if (samples.length === 0) return null
  const oldest = Math.min(...samples.map(s => s.at))
  if (now - oldest < LIMITS.trendMinSpanMs) return null
  const used = samples.filter(s => s.at >= now - LIMITS.windowMs)
  if (used.length < 2) return null
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
    const mb = latest.bifrostRamNoTermMb
    const without = `Bifrost is using ${ramMbText(mb)} RAM without the chat terminals`
    if (mb > LIMITS.ramProblemMb) {
      add('problem', `${without}, above the ${limitGb(LIMITS.ramProblemMb)} limit.`)
    } else if (mb > LIMITS.ramWarnMb) {
      add('warning', `${without}, above the ${limitGb(LIMITS.ramWarnMb)} limit.`)
    }
    const term = latest.largestTerminalRamMb
    if (term > LIMITS.terminalRamWarnMb) {
      add(
        'warning',
        `A chat terminal is using ${ramMbText(term)} RAM, above the ${LIMITS.terminalRamWarnMb} MB limit.`,
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

  if (input.delayMs !== null) {
    const ms = Math.round(input.delayMs)
    const text = `Bifrost's main process was slow to respond (up to ${ms} ms).`
    if (input.delayMs > LIMITS.delayProblemMs) add('problem', text)
    else if (input.delayMs > LIMITS.delayWarnMs) add('warning', text)
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

// The OK text of the newest sample. null with no sample, or with a sample that is older than
// 60 s, for example while ps fails. Then the headline says "Checking Bifrost…".
export function okText(sample: Sample | undefined, now: number): string | null {
  if (!sample || now - sample.at > LIMITS.okSampleMaxAgeMs) return null
  const cpu = `${Math.round(sample.bifrostCpuNoTerm)}%`
  return `Bifrost is using ${ramText(sample.bifrostRamNoTermMb)} RAM and ${cpu} CPU.`
}
