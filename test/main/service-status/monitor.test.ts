import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createServiceMonitor } from '../../../src/main/service-status/monitor'
import { SERVICES, type ServiceDef } from '../../../src/main/service-status/statuspage'
import type { ServiceStatus } from '../../../src/shared/types'

function status(def: ServiceDef, checkedAt: number): ServiceStatus {
  return { checkedAt, id: def.id, incidents: [], level: 'none', name: def.name, since: null }
}

beforeEach(() => {
  vi.useFakeTimers()
})
afterEach(() => {
  vi.useRealTimers()
})

describe('createServiceMonitor', () => {
  it('current starts with each service unknown and not checked', () => {
    const m = createServiceMonitor({ check: async d => status(d, 1), emit: () => {}, now: () => 1 })
    expect(m.current().map(s => [s.id, s.level, s.checkedAt])).toEqual([
      ['claude', 'unknown', 0],
      ['github', 'unknown', 0],
      ['sentry', 'unknown', 0],
    ])
  })

  it('the monitor checks all services at once at the start and each 60 s after the end of a round', async () => {
    const check = vi.fn(async (d: ServiceDef) => status(d, Date.now()))
    const emit = vi.fn()
    const m = createServiceMonitor({ check, emit, now: () => Date.now() })
    m.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(check).toHaveBeenCalledTimes(SERVICES.length)
    expect(emit).toHaveBeenCalledTimes(1)
    expect(m.current().every(s => s.level === 'none')).toBe(true)
    await vi.advanceTimersByTimeAsync(59_999)
    expect(check).toHaveBeenCalledTimes(SERVICES.length)
    await vi.advanceTimersByTimeAsync(1)
    expect(check).toHaveBeenCalledTimes(SERVICES.length * 2)
    expect(emit).toHaveBeenCalledTimes(2)
    m.stop()
  })

  it('the monitor never runs two rounds at a time', async () => {
    let running = 0
    let peak = 0
    const check = vi.fn(async (d: ServiceDef) => {
      running++
      peak = Math.max(peak, running)
      await new Promise(r => setTimeout(r, 90_000))
      running--
      return status(d, 1)
    })
    const m = createServiceMonitor({ check, emit: () => {}, now: () => 1 })
    m.start()
    await vi.advanceTimersByTimeAsync(89_000)
    expect(check).toHaveBeenCalledTimes(SERVICES.length)
    await vi.advanceTimersByTimeAsync(1_000)
    // The round ended at 90 s. The next one starts at 150 s.
    await vi.advanceTimersByTimeAsync(59_000)
    expect(check).toHaveBeenCalledTimes(SERVICES.length)
    await vi.advanceTimersByTimeAsync(1_000)
    expect(check).toHaveBeenCalledTimes(SERVICES.length * 2)
    expect(peak).toBe(SERVICES.length)
    m.stop()
  })

  it('a check that throws gives unknown for that service only', async () => {
    const emit = vi.fn()
    const check = async (d: ServiceDef): Promise<ServiceStatus> => {
      if (d.id === 'github') throw new Error('boom')
      return status(d, 7)
    }
    const m = createServiceMonitor({ check, emit, now: () => 7 })
    m.start()
    await vi.advanceTimersByTimeAsync(0)
    const levels = Object.fromEntries(m.current().map(s => [s.id, s.level]))
    expect(levels).toEqual({ claude: 'none', github: 'unknown', sentry: 'none' })
    expect(m.current().find(s => s.id === 'github')).toMatchObject({ checkedAt: 7 })
    m.stop()
  })

  it('stop ends the rounds and a late round does not emit', async () => {
    let release: () => void = () => {}
    const gate = new Promise<void>(r => {
      release = r
    })
    const check = vi.fn(async (d: ServiceDef) => {
      await gate
      return status(d, 1)
    })
    const emit = vi.fn()
    const m = createServiceMonitor({ check, emit, now: () => 1 })
    m.start()
    await vi.advanceTimersByTimeAsync(0)
    m.stop()
    release()
    await vi.advanceTimersByTimeAsync(200_000)
    expect(emit).not.toHaveBeenCalled()
    expect(check).toHaveBeenCalledTimes(SERVICES.length)
  })
})
