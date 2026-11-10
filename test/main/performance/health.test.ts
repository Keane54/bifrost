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
  return {
    at,
    bifrostCpuNoTerm: 2,
    bifrostRamMb: 500,
    bifrostRamNoTermMb: 400,
    largestTerminalRamMb: 0,
    ...over,
  }
}

function input(over: Partial<HealthInput> = {}): HealthInput {
  return {
    delayMs: null,
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

// A ramp of samples every minute, from `from` minutes ago, with a given rise in MB per hour. The
// ramp starts at `base` MB.
function ramp(perHour: number, spanMin: number, base = 400): Sample[] {
  const out: Sample[] = []
  for (let m = spanMin; m >= 0; m--) {
    const at = NOW - m * MIN
    out.push(sample(at, { bifrostRamNoTermMb: base + (perHour / 60) * (spanMin - m) }))
  }
  return out
}

describe('limits', () => {
  test('the window comes from the health log', () => {
    expect(LIMITS.windowMs).toBe(HEALTH_WINDOW_MS)
  })
})

// User decision, 2026-11-10: the RAM limits count Bifrost without the chat terminals. Each chat
// window starts its own claude attach process, so the terminals grow with the number of chats.
describe('RAM', () => {
  const ram = (mb: number) =>
    reasons({ samples: [sample(NOW, { bifrostRamMb: mb + 300, bifrostRamNoTermMb: mb })] })
  test('1024 MB gives no reason, above 1 GB is one warning', () => {
    expect(ram(1024)).toEqual([])
    expect(ram(1229)).toEqual([
      {
        level: 'warning',
        text: "Bifrost's own processes are using 1.2 GB RAM, above the 1 GB limit.",
      },
    ])
  })
  test('a value that one decimal gives as the limit shows two decimals, rounded up', () => {
    expect(ram(1025)).toEqual([
      {
        level: 'warning',
        text: "Bifrost's own processes are using 1.01 GB RAM, above the 1 GB limit.",
      },
    ])
    expect(ram(1537)).toEqual([
      {
        level: 'problem',
        text: "Bifrost's own processes are using 1.51 GB RAM, above the 1.5 GB limit.",
      },
    ])
  })
  test('at 1.5 GB it is a warning, above it one problem that replaces the warning', () => {
    expect(ram(1536)).toEqual([
      {
        level: 'warning',
        text: "Bifrost's own processes are using 1.5 GB RAM, above the 1 GB limit.",
      },
    ])
    expect(ram(1843.2)).toEqual([
      {
        level: 'problem',
        text: "Bifrost's own processes are using 1.8 GB RAM, above the 1.5 GB limit.",
      },
    ])
  })
  test('the chat terminals do not count toward the limits', () => {
    const many = sample(NOW, { bifrostRamMb: 2400, bifrostRamNoTermMb: 600 })
    expect(reasons({ samples: [many] })).toEqual([])
  })
  test('one chat terminal above 500 MB is one warning', () => {
    const term = (mb: number) => reasons({ samples: [sample(NOW, { largestTerminalRamMb: mb })] })
    expect(LIMITS.terminalRamWarnMb).toBe(500)
    expect(term(500)).toEqual([])
    expect(term(612.4)).toEqual([
      { level: 'warning', text: 'A chat terminal is using 612 MB RAM, above the 500 MB limit.' },
    ])
  })
  // The OK text gives the total with the chat terminals, the same as the trend line.
  test('the OK text rounds before it picks MB or GB', () => {
    expect(okText(sample(NOW, { bifrostRamMb: 1023.4 }), NOW)).toContain('1023 MB')
    expect(okText(sample(NOW, { bifrostRamMb: 1023.6 }), NOW)).toContain('1.0 GB')
  })
})

describe('growth', () => {
  test('299 MB an hour gives no reason, 301 is one warning', () => {
    expect(reasons({ samples: ramp(299, 60) })).toEqual([])
    expect(reasons({ samples: ramp(301, 60) })).toEqual([
      { level: 'warning', text: "Bifrost's memory is growing by about 301 MB an hour." },
    ])
  })
  test('799 MB an hour is one warning, 801 is one problem', () => {
    // The ramps start low, so their last sample stays below the 1 GB RAM limit.
    expect(reasons({ samples: ramp(799, 60, 100) })).toEqual([
      { level: 'warning', text: "Bifrost's memory is growing by about 799 MB an hour." },
    ])
    expect(reasons({ samples: ramp(801, 60, 100) })).toEqual([
      { level: 'problem', text: "Bifrost's memory is growing by about 801 MB an hour." },
    ])
  })
  test('chat terminals do not count in the growth trend', () => {
    const samples = ramp(0, 60).map((s, i) => ({ ...s, bifrostRamMb: 400 + i * 20 }))
    expect(trendMbPerHour(samples, NOW)).toBeCloseTo(0, 5)
    expect(reasons({ samples }).filter(r => r.text.includes('growing'))).toEqual([])
  })
  test('the trend needs a full 60 minutes of samples', () => {
    expect(LIMITS.trendMinSpanMs).toBe(60 * MIN)
    expect(trendMbPerHour(ramp(900, 30), NOW)).toBeNull()
    expect(trendMbPerHour(ramp(900, 59), NOW)).toBeNull()
    expect(trendMbPerHour(ramp(900, 60), NOW)).toBeCloseTo(900, 5)
    expect(trendMbPerHour([sample(NOW)], NOW)).toBeNull()
    expect(trendMbPerHour([], NOW)).toBeNull()
  })
  test('one RAM step of 120 MB after 30 minutes gives no reason', () => {
    // With 30 minutes of samples, this step was a trend of about 350 MB an hour.
    const step = ramp(0, 30).map((s, i) => (i < 15 ? s : { ...s, bifrostRamNoTermMb: 520 }))
    expect(reasons({ samples: step })).toEqual([])
  })
  test('a sample before the window shows that the window is full', () => {
    // The samples of the last 60 minutes start 15 s after the start of the window. The one
    // sample before the window shows that Bifrost ran for the full 60 minutes.
    const inside = ramp(900, 60).slice(1)
    expect(trendMbPerHour(inside, NOW)).toBeNull()
    const before = sample(NOW - 60 * MIN - 15_000, { bifrostRamNoTermMb: 9000 })
    expect(trendMbPerHour([before, ...inside], NOW)).toBeCloseTo(900, 5)
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
  test('50% average gives no reason, 51% is one warning', () => {
    expect(reasons({ samples: cpuSamples(50) })).toEqual([])
    expect(reasons({ samples: cpuSamples(51) })).toEqual([
      { level: 'warning', text: 'Bifrost is using 51% CPU on average over the last 2 minutes.' },
    ])
  })
  test('100% average is one warning, 101% is one problem', () => {
    expect(reasons({ samples: cpuSamples(100) })).toEqual([
      { level: 'warning', text: 'Bifrost is using 100% CPU on average over the last 2 minutes.' },
    ])
    expect(reasons({ samples: cpuSamples(101) })).toEqual([
      { level: 'problem', text: 'Bifrost is using 101% CPU on average over the last 2 minutes.' },
    ])
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
    expect(reasons({ samples: ok })).toEqual([
      { level: 'problem', text: 'Bifrost is using 300% CPU on average over the last 2 minutes.' },
    ])
  })
})

describe('frame rate and delay', () => {
  test('low fps is a warning', () => {
    expect(reasons({ fpsLow10s: false })).toEqual([])
    expect(reasons({ fpsLow10s: true })).toEqual([
      { level: 'warning', text: 'The Performance panel ran below 30 fps for 10 seconds.' },
    ])
  })
  test('delay: 200 ms none, 201 one warning, 1000 one warning, 1001 one problem', () => {
    expect(reasons({ delayMs: 200 })).toEqual([])
    expect(reasons({ delayMs: 201 })).toEqual([
      { level: 'warning', text: "Bifrost's main process was slow to respond (up to 201 ms)." },
    ])
    expect(reasons({ delayMs: 1000 })).toEqual([
      { level: 'warning', text: "Bifrost's main process was slow to respond (up to 1000 ms)." },
    ])
    expect(reasons({ delayMs: 1001 })).toEqual([
      { level: 'problem', text: "Bifrost's main process was slow to respond (up to 1001 ms)." },
    ])
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
    expect(reasons({ log: withFails('reviews', 3) })).toEqual([
      { level: 'warning', text: "Bifrost couldn't check GitHub for reviews 3 times in a row." },
    ])
    expect(reasons({ log: withFails('reviews', 9) })).toEqual([
      { level: 'warning', text: "Bifrost couldn't check GitHub for reviews 9 times in a row." },
    ])
    expect(reasons({ log: withFails('reviews', 10) })).toEqual([
      { level: 'problem', text: "Bifrost couldn't check GitHub for reviews 10 times in a row." },
    ])
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
    expect(okText(undefined, NOW)).toBeNull()
    expect(okText(sample(NOW, { bifrostCpuNoTerm: 2.4, bifrostRamMb: 712 }), NOW)).toBe(
      'Bifrost is using 712 MB RAM and 2% CPU.',
    )
    expect(okText(sample(NOW, { bifrostCpuNoTerm: 0.4, bifrostRamMb: 1331 }), NOW)).toBe(
      'Bifrost is using 1.3 GB RAM and 0% CPU.',
    )
  })
  test('the OK text needs a sample from the last 60 s', () => {
    expect(LIMITS.okSampleMaxAgeMs).toBe(60_000)
    expect(okText(sample(NOW - 60_000), NOW)).toBe('Bifrost is using 500 MB RAM and 2% CPU.')
    expect(okText(sample(NOW - 60_001), NOW)).toBeNull()
  })
  test('problem reasons come before warning reasons', () => {
    const log = emptyLog()
    log.liveStartFailedAt = NOW
    log.crashes = [{ at: NOW - MIN, kind: 'gpu', reason: 'x' }]
    const out = reasons({
      fpsLow10s: true,
      log,
      samples: [sample(NOW, { bifrostRamNoTermMb: 1100 })],
    })
    expect(out.map(r => r.level)).toEqual(['problem', 'warning', 'warning', 'warning'])
    expect(healthState(out)).toBe('problem')
    expect(healthState(out.filter(r => r.level === 'warning'))).toBe('warning')
  })
})
