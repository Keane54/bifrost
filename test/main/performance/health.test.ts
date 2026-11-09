import { describe, expect, test } from 'vitest'
import {
  type HealthInput,
  healthReasons,
  healthState,
  LIMITS,
  okText,
  type Sample,
  trendMbPerHour,
} from '../../../src/main/performance/health'
import { HEALTH_WINDOW_MS, type HealthLogView } from '../../../src/main/performance/health-log'

const MIN = 60_000
const NOW = 100 * MIN

const fmt = (at: number) => `T${at / MIN}`

function emptyLog(): HealthLogView {
  return {
    crashes: [],
    failsInARow: { 'account-usage': 0, reviews: 0, 'service-status': 0, sessions: 0 },
    liveStartFailedAt: null,
    saveFailedAt: {},
  }
}

function sample(at: number, over: Partial<Sample> = {}): Sample {
  return { at, bifrostCpuNoTerm: 2, bifrostRamMb: 500, bifrostRamNoTermMb: 400, ...over }
}

function input(over: Partial<HealthInput> = {}): HealthInput {
  return {
    delayP99Ms: null,
    fpsLow10s: false,
    log: emptyLog(),
    now: NOW,
    online: true,
    orphans: 0,
    samples: [],
    ...over,
  }
}

function reasons(over: Partial<HealthInput> = {}) {
  return healthReasons(input(over), fmt)
}

// A ramp of samples every minute, from `from` minutes ago, with a given rise in MB per hour.
function ramp(perHour: number, spanMin: number): Sample[] {
  const out: Sample[] = []
  for (let m = spanMin; m >= 0; m--) {
    const at = NOW - m * MIN
    out.push(sample(at, { bifrostRamNoTermMb: 400 + (perHour / 60) * (spanMin - m) }))
  }
  return out
}

describe('limits', () => {
  test('the window comes from the health log', () => {
    expect(LIMITS.windowMs).toBe(HEALTH_WINDOW_MS)
  })
})

describe('RAM', () => {
  test('1024 MB gives no reason, above 1 GB is a warning', () => {
    expect(reasons({ samples: [sample(NOW, { bifrostRamMb: 1024 })] })).toEqual([])
    expect(reasons({ samples: [sample(NOW, { bifrostRamMb: 1025 })] })).toEqual([
      { level: 'warning', text: 'Bifrost is using 1.0 GB RAM, above the 1 GB limit.' },
    ])
  })
  test('above 1.5 GB is a problem that replaces the warning', () => {
    expect(reasons({ samples: [sample(NOW, { bifrostRamMb: 1536 })] })).toHaveLength(1)
    expect(reasons({ samples: [sample(NOW, { bifrostRamMb: 1537 })] })).toEqual([
      { level: 'problem', text: 'Bifrost is using 1.5 GB RAM, above the 1.5 GB limit.' },
    ])
  })
})

describe('growth', () => {
  test('300 MB an hour gives no reason, above it is a warning', () => {
    expect(reasons({ samples: ramp(300, 60) })).toEqual([])
    expect(reasons({ samples: ramp(450, 60) })).toEqual([
      { level: 'warning', text: "Bifrost's memory is growing by about 450 MB an hour." },
    ])
  })
  test('above 800 MB an hour is a problem', () => {
    expect(reasons({ samples: ramp(800, 60) })[0]?.level).toBe('warning')
    expect(reasons({ samples: ramp(900, 60) })).toEqual([
      { level: 'problem', text: "Bifrost's memory is growing by about 900 MB an hour." },
    ])
  })
  test('chat terminals do not count in the growth trend', () => {
    const samples = ramp(0, 60).map((s, i) => ({ ...s, bifrostRamMb: 400 + i * 20 }))
    expect(trendMbPerHour(samples, NOW)).toBeCloseTo(0, 5)
    expect(reasons({ samples }).filter(r => r.text.includes('growing'))).toEqual([])
  })
  test('the trend needs 30 minutes of samples', () => {
    expect(trendMbPerHour(ramp(900, 29), NOW)).toBeNull()
    expect(trendMbPerHour(ramp(900, 30), NOW)).toBeCloseTo(900, 5)
    expect(trendMbPerHour([sample(NOW)], NOW)).toBeNull()
    expect(trendMbPerHour([], NOW)).toBeNull()
  })
  test('the trend ignores samples older than 60 minutes', () => {
    const old = [sample(NOW - 90 * MIN, { bifrostRamNoTermMb: 9000 }), ...ramp(0, 60)]
    expect(trendMbPerHour(old, NOW)).toBeCloseTo(0, 5)
  })
})

describe('CPU', () => {
  const cpuSamples = (cpu: number, spanMin = 5) =>
    Array.from({ length: spanMin + 1 }, (_, i) =>
      sample(NOW - (spanMin - i) * MIN, { bifrostCpuNoTerm: cpu }),
    )
  test('50% average gives no reason, above it is a warning', () => {
    expect(reasons({ samples: cpuSamples(50) })).toEqual([])
    expect(reasons({ samples: cpuSamples(64) })).toEqual([
      { level: 'warning', text: 'Bifrost is using 64% CPU on average over the last 2 minutes.' },
    ])
  })
  test('above 100% average is a problem', () => {
    expect(reasons({ samples: cpuSamples(100) })[0]?.level).toBe('warning')
    expect(reasons({ samples: cpuSamples(101) })[0]?.level).toBe('problem')
  })
  test('only the last 2 minutes count', () => {
    const samples = [sample(NOW - 10 * MIN, { bifrostCpuNoTerm: 900 }), ...cpuSamples(2, 3)]
    expect(reasons({ samples })).toEqual([])
  })
  test('a start-up spike gives no reason before 2 minutes of samples', () => {
    const young = [
      sample(NOW - 90_000, { bifrostCpuNoTerm: 300 }),
      sample(NOW, { bifrostCpuNoTerm: 300 }),
    ]
    expect(reasons({ samples: young })).toEqual([])
    const ok = [
      sample(NOW - 2 * MIN, { bifrostCpuNoTerm: 300 }),
      sample(NOW, { bifrostCpuNoTerm: 300 }),
    ]
    expect(reasons({ samples: ok })[0]?.level).toBe('problem')
  })
})

describe('frame rate and delay', () => {
  test('low fps is a warning', () => {
    expect(reasons({ fpsLow10s: false })).toEqual([])
    expect(reasons({ fpsLow10s: true })).toEqual([
      { level: 'warning', text: 'The Performance panel ran below 30 fps for 10 seconds.' },
    ])
  })
  test('delay: 200 ms none, above is a warning, above 1 s a problem', () => {
    expect(reasons({ delayP99Ms: 200 })).toEqual([])
    expect(reasons({ delayP99Ms: 340 })).toEqual([
      { level: 'warning', text: "Bifrost's main process was slow to respond (up to 340 ms)." },
    ])
    expect(reasons({ delayP99Ms: 1000 })[0]?.level).toBe('warning')
    expect(reasons({ delayP99Ms: 1001 })[0]?.level).toBe('problem')
  })
})

describe('crashes', () => {
  test('each crash is a problem with its time', () => {
    const log = emptyLog()
    log.crashes = [
      { at: NOW - 10 * MIN, kind: 'window', reason: 'crashed' },
      { at: NOW - 5 * MIN, kind: 'gpu', reason: 'killed' },
    ]
    expect(reasons({ log })).toEqual([
      { level: 'problem', text: 'The window crashed at T90.' },
      { level: 'problem', text: 'The graphics process crashed at T95.' },
    ])
  })
  test('a crash reason clears after 60 minutes', () => {
    const log = emptyLog()
    log.crashes = [{ at: NOW - HEALTH_WINDOW_MS + 1, kind: 'window', reason: 'crashed' }]
    expect(reasons({ log })).toHaveLength(1)
    log.crashes = [{ at: NOW - HEALTH_WINDOW_MS, kind: 'window', reason: 'crashed' }]
    expect(reasons({ log })).toEqual([])
  })
})

describe('polls', () => {
  const withFails = (
    part: 'sessions' | 'reviews' | 'account-usage' | 'service-status',
    n: number,
  ) => {
    const log = emptyLog()
    log.failsInARow[part] = n
    return log
  }
  test('3 failures is a warning, 10 is a problem, 2 is nothing', () => {
    expect(reasons({ log: withFails('sessions', 2) })).toEqual([])
    expect(reasons({ log: withFails('sessions', 4) })).toEqual([
      { level: 'warning', text: "Bifrost couldn't check for sessions 4 times in a row." },
    ])
    expect(reasons({ log: withFails('reviews', 3) })[0]?.level).toBe('warning')
    expect(reasons({ log: withFails('reviews', 9) })[0]?.level).toBe('warning')
    expect(reasons({ log: withFails('reviews', 10) })[0]).toEqual({
      level: 'problem',
      text: "Bifrost couldn't check GitHub for reviews 10 times in a row.",
    })
  })
  test('each part has its own friendly name', () => {
    expect(reasons({ log: withFails('account-usage', 3) })[0]?.text).toContain(
      'check your account usage',
    )
    expect(reasons({ log: withFails('service-status', 3) })[0]?.text).toContain(
      "check Claude's status",
    )
  })
  test('offline network polls give no reason, the session list still does', () => {
    const log = emptyLog()
    log.failsInARow = { 'account-usage': 12, reviews: 12, 'service-status': 12, sessions: 5 }
    const out = reasons({ log, online: false })
    expect(out).toHaveLength(1)
    expect(out[0]?.text).toContain('check for sessions')
    expect(reasons({ log, online: true })).toHaveLength(4)
  })
})

describe('other checks', () => {
  test('a Live details start error is a warning', () => {
    const log = emptyLog()
    log.liveStartFailedAt = NOW
    expect(reasons({ log })).toEqual([
      { level: 'warning', text: "Bifrost couldn't start the Live details link." },
    ])
  })
  test('orphan terminals: singular and plural', () => {
    expect(reasons({ orphans: 0 })).toEqual([])
    expect(reasons({ orphans: 1 })).toEqual([
      { level: 'warning', text: '1 chat terminal is running with no chat window.' },
    ])
    expect(reasons({ orphans: 3 })[0]?.text).toBe(
      '3 chat terminals are running with no chat window.',
    )
  })
  test('a save failure is one warning for each store, and clears after 60 minutes', () => {
    const log = emptyLog()
    log.saveFailedAt = { registry: NOW - HEALTH_WINDOW_MS, settings: NOW - 5 * MIN }
    expect(reasons({ log })).toEqual([
      { level: 'warning', text: "Bifrost couldn't save your settings at T95." },
    ])
    log.saveFailedAt = { 'reviews-state': NOW, 'ui-state': NOW, 'window-state': NOW }
    const texts = reasons({ log }).map(r => r.text)
    expect(texts.sort()).toEqual([
      "Bifrost couldn't save the Reviews state at T100.",
      "Bifrost couldn't save the panel layout at T100.",
      "Bifrost couldn't save the window position at T100.",
    ])
  })
  test('the default time format is local HH:MM', () => {
    const log = emptyLog()
    const at = new Date(2026, 10, 9, 7, 5).getTime()
    log.saveFailedAt = { settings: at }
    const out = healthReasons(input({ log, now: at + MIN }))
    expect(out[0]?.text).toBe("Bifrost couldn't save your settings at 07:05.")
  })
})

describe('state and text', () => {
  test('no data gives no reason and the OK text names only measured values', () => {
    expect(reasons()).toEqual([])
    expect(healthState([])).toBe('ok')
    expect(okText(undefined)).toBeNull()
    expect(okText(sample(NOW, { bifrostCpuNoTerm: 2.4, bifrostRamMb: 712 }))).toBe(
      'Bifrost is using 712 MB RAM and 2% CPU.',
    )
    expect(okText(sample(NOW, { bifrostCpuNoTerm: 0.4, bifrostRamMb: 1331 }))).toBe(
      'Bifrost is using 1.3 GB RAM and 0% CPU.',
    )
  })
  test('problem reasons come before warning reasons', () => {
    const log = emptyLog()
    log.liveStartFailedAt = NOW
    log.crashes = [{ at: NOW - MIN, kind: 'gpu', reason: 'x' }]
    const out = reasons({ fpsLow10s: true, log, samples: [sample(NOW, { bifrostRamMb: 1100 })] })
    expect(out.map(r => r.level)).toEqual(['problem', 'warning', 'warning', 'warning'])
    expect(healthState(out)).toBe('problem')
    expect(healthState(out.filter(r => r.level === 'warning'))).toBe('warning')
  })
})
