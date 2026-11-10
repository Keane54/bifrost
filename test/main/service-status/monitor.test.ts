import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  createServiceMonitor,
  serviceList,
  TEST_HOME_SERVICE,
} from '../../../src/main/service-status/monitor'
import { NO_ANSWER, SERVICES, type ServiceDef } from '../../../src/main/service-status/statuspage'
import { levelText } from '../../../src/renderer/src/service/service-view'
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

  it('a throw in emit never stops the loop (final review Minor 5)', async () => {
    const logged = vi.spyOn(console, 'error').mockImplementation(() => {})
    const check = vi.fn(async (d: ServiceDef) => status(d, Date.now()))
    const emit = vi.fn(() => {
      throw new Error('emit failed')
    })
    const m = createServiceMonitor({ check, emit, now: () => Date.now() })
    m.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(emit).toHaveBeenCalledTimes(1)
    expect(m.current().every(s => s.level === 'none')).toBe(true)
    await vi.advanceTimersByTimeAsync(60_000)
    expect(check).toHaveBeenCalledTimes(SERVICES.length * 2)
    expect(emit).toHaveBeenCalledTimes(2)
    expect(logged).toHaveBeenCalledTimes(2)
    m.stop()
    logged.mockRestore()
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

  it('the health log gets a failed round only when every service fails', async () => {
    let failing: string[] = []
    const check = async (d: ServiceDef): Promise<ServiceStatus> => {
      if (!failing.includes(d.id)) return status(d, Date.now())
      // A check that throws and a check with no answer both fail.
      if (d.id === 'github') throw new Error('boom')
      return { ...status(d, Date.now()), error: NO_ANSWER, level: 'unknown' }
    }
    const poll = vi.fn()
    const m = createServiceMonitor({
      check,
      emit: () => {},
      health: { poll, stopped: () => {} },
      now: () => Date.now(),
    })
    m.start()
    await vi.advanceTimersByTimeAsync(0)
    failing = ['claude', 'github']
    await vi.advanceTimersByTimeAsync(60_000)
    failing = SERVICES.map(d => d.id)
    await vi.advanceTimersByTimeAsync(60_000)
    failing = []
    await vi.advanceTimersByTimeAsync(60_000)
    expect(poll.mock.calls).toEqual([
      ['service-status', 'ok'],
      ['service-status', 'ok'],
      ['service-status', 'failed'],
      ['service-status', 'ok'],
    ])
    m.stop()
  })

  it('a health dep that throws never stops the loop', async () => {
    const logged = vi.spyOn(console, 'error').mockImplementation(() => {})
    const check = vi.fn(async (d: ServiceDef) => status(d, Date.now()))
    const poll = vi.fn(() => {
      throw new Error('health failed')
    })
    const m = createServiceMonitor({
      check,
      emit: () => {},
      health: { poll, stopped: () => {} },
      now: () => Date.now(),
    })
    m.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(poll).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(60_000)
    expect(check).toHaveBeenCalledTimes(SERVICES.length * 2)
    expect(poll).toHaveBeenCalledTimes(2)
    m.stop()
    logged.mockRestore()
  })

  it('stop tells the health log that Service status stopped', async () => {
    const stopped = vi.fn()
    const m = createServiceMonitor({
      check: async d => status(d, 1),
      emit: () => {},
      health: { poll: () => {}, stopped },
      now: () => 1,
    })
    m.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(stopped).not.toHaveBeenCalled()
    m.stop()
    expect(stopped.mock.calls).toEqual([['service-status']])
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

describe('serviceList', () => {
  it('a test home has no monitor, so each service shows No data with the reason', () => {
    expect(TEST_HOME_SERVICE).toBe("Bifrost doesn't check status pages in a test home.")
    const list = serviceList(null)
    expect(list.map(s => s.id)).toEqual(SERVICES.map(d => d.id))
    for (const s of list) {
      expect(s).toMatchObject({
        checkedAt: 0,
        error: TEST_HOME_SERVICE,
        incidents: [],
        level: 'unknown',
        since: null,
      })
      expect(levelText(s.level)).toBe('No data')
    }
  })

  it('with a monitor, the list is the current list of the monitor', () => {
    const current = SERVICES.map(d => status(d, 5))
    expect(serviceList({ current: () => current })).toBe(current)
  })
})
