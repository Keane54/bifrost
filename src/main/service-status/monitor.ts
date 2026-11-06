// The monitor runs one round of checks at the start and then 60 s after the end of each round.
// A round never starts while another round runs.
import type { ServiceStatus } from '../../shared/types'
import { NO_ANSWER, SERVICES, type ServiceDef } from './statuspage'

export const SERVICE_INTERVAL_MS = 60_000

export interface MonitorDeps {
  check(def: ServiceDef): Promise<ServiceStatus>
  emit(list: ServiceStatus[]): void
  now(): number
}

export interface ServiceMonitor {
  start(): void
  stop(): void
  current(): ServiceStatus[]
}

function unknown(def: ServiceDef, checkedAt: number, error?: string): ServiceStatus {
  return {
    checkedAt,
    ...(error === undefined ? {} : { error }),
    id: def.id,
    incidents: [],
    level: 'unknown',
    name: def.name,
    since: null,
  }
}

export function createServiceMonitor(
  deps: MonitorDeps,
  intervalMs: number = SERVICE_INTERVAL_MS,
): ServiceMonitor {
  let list: ServiceStatus[] = SERVICES.map(def => unknown(def, 0))
  let timer: ReturnType<typeof setTimeout> | null = null
  let stopped = true

  async function one(def: ServiceDef): Promise<ServiceStatus> {
    try {
      return await deps.check(def)
    } catch {
      return unknown(def, deps.now(), NO_ANSWER)
    }
  }

  async function round(): Promise<void> {
    const next = await Promise.all(SERVICES.map(one))
    if (stopped) return
    list = next
    deps.emit(list)
    timer = setTimeout(() => void round(), intervalMs)
  }

  return {
    current: () => list,
    start() {
      if (!stopped) return
      stopped = false
      void round()
    },
    stop() {
      stopped = true
      if (timer) clearTimeout(timer)
      timer = null
    },
  }
}
