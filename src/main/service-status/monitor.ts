// The monitor runs one round of checks at the start and then 60 s after the end of each round.
// A round never starts while another round runs.
import type { ServiceStatus } from '../../shared/types'
import { type HealthEvents, NO_HEALTH } from '../performance/health-log'
import { NO_ANSWER, SERVICES, type ServiceDef } from './statuspage'

export const SERVICE_INTERVAL_MS = 60_000
export const TEST_HOME_SERVICE = "Bifrost doesn't check status pages in a test home."

export interface MonitorDeps {
  check(def: ServiceDef): Promise<ServiceStatus>
  emit(list: ServiceStatus[]): void
  now(): number
  // The health log gets the result of each round and the stop (P5, P7). The default does nothing.
  health?: Pick<HealthEvents, 'poll' | 'stopped'>
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
  const health = deps.health ?? NO_HEALTH
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
    // A throw in the health log or in emit goes to the log. The next round always gets its
    // timer, so the loop never stops.
    try {
      // A round fails only when no service answered (P7).
      health.poll('service-status', next.every(s => s.error !== undefined) ? 'failed' : 'ok')
      deps.emit(list)
    } catch (error) {
      console.error('Bifrost cannot send the service status.', error)
    } finally {
      if (!stopped) timer = setTimeout(() => void round(), intervalMs)
    }
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
      // No more rounds come. So the failures in a row of Service status go to 0.
      health.stopped('service-status')
    },
  }
}

// The list for the page. A test home starts no monitor. Then each service is unknown ("No data"),
// with the reason.
export function serviceList(monitor: Pick<ServiceMonitor, 'current'> | null): ServiceStatus[] {
  if (monitor) return monitor.current()
  return SERVICES.map(def => unknown(def, 0, TEST_HOME_SERVICE))
}
