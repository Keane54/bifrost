// The types of the Performance panel. Main sends a snapshot. The renderer shows it.

export type HealthState = 'ok' | 'warning' | 'problem'

export interface Reason {
  level: 'warning' | 'problem'
  text: string
}

export interface ProcGroup {
  name: string
  count: number
  ramMb: number
  cpu: number
}

export interface SessionUse {
  sessionId: string
  name: string
  ramMb: number
  cpu: number
}

export interface PerformanceSnapshot {
  state: HealthState
  reasons: Reason[]
  okText: string | null
  bifrost: {
    ramMb: number
    cpu: number
    groups: ProcGroup[]
    trend: Array<{ at: number; ramMb: number; cpu: number }>
    fps: number | null
    delayMs: number | null
  } | null
  sessions: {
    ramMb: number
    cpu: number
    top: SessionUse[]
    more: { count: number; ramMb: number; cpu: number }
  } | null
  mac: {
    pressure: 'normal' | 'warn' | 'critical' | null
    swap: { usedMb: number; totalMb: number } | null
    cpuLoad: number | null
    thermal: string | null
    battery: { percent: number; charging: boolean } | null
  } | null
  network: {
    online: boolean
    kind: 'wifi' | 'ethernet' | 'vpn' | 'other' | null
    downBps: number | null
    upBps: number | null
    anthropicMs: number | 'no-answer' | 'unreachable' | null
    githubMs: number | 'no-answer' | 'unreachable' | null
  } | null
  limits: {
    github: { remaining: number; limit: number; resetAt: number } | { unavailable: string } | null
    freeDiskGb: number | null
    clonesMb: number | null
  }
}

export const EMPTY_PERFORMANCE: PerformanceSnapshot = {
  bifrost: null,
  limits: { clonesMb: null, freeDiskGb: null, github: null },
  mac: null,
  network: null,
  okText: null,
  reasons: [],
  sessions: null,
  state: 'ok',
}
