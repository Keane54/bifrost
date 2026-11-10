import { describe, expect, test, vi } from 'vitest'
import { createUsageAlertMonitor } from '../../../src/main/usage-alerts/monitor'
import { NO_PERIODS, type NotifiedPeriods } from '../../../src/main/usage-alerts/rules'
import type { UsageAlertStore } from '../../../src/main/usage-alerts/state-store'
import type { AccountUsage, RateLimits, UsageSnapshot } from '../../../src/shared/types'

const NOW = Date.UTC(2026, 10, 10, 12, 0)
const MIN = 60_000
const HOUR = 60 * MIN
const FIVE_RESET = NOW + 2 * HOUR + 5 * MIN
const SEVEN_RESET = Date.UTC(2026, 10, 13, 13, 0)

const OFF_TEXT = {
  body: 'Claude Code stops at 100% until the limit resets at 14:05.',
  title: '5-hour limit at 92%',
}
const WARNING = 'Warning: extra usage is on'

const fiveAt = (usedPercent: number, resetsAt = FIVE_RESET): RateLimits => ({
  fiveHour: { resetsAt, usedPercent },
})

const snap = (limits: RateLimits): UsageSnapshot => ({
  limits,
  name: 'bifrost-test-a',
  sessionId: 'abcdef12-0000',
  updatedAt: NOW,
})

const account = (limits: RateLimits, extra: Partial<AccountUsage> = {}): AccountUsage => ({
  fetchedAt: NOW,
  limits,
  ...extra,
})

// A store in memory. Two monitors can share it, as two runs of Bifrost share the file.
function memoryStore(start: NotifiedPeriods = NO_PERIODS) {
  let value = { ...start }
  const writes: NotifiedPeriods[] = []
  const store: UsageAlertStore = {
    get: () => value,
    set: async next => {
      value = { ...next }
      writes.push(value)
    },
  }
  return { store, writes }
}

// Let the promises of the monitor settle.
const settle = (): Promise<void> => new Promise(resolve => setTimeout(resolve, 0))

function setup(
  options: { store?: UsageAlertStore; enabled?: boolean; flag?: () => Promise<boolean> } = {},
) {
  const memory = memoryStore()
  const store = options.store ?? memory.store
  let now = NOW
  let enabled = options.enabled ?? true
  const shown: { title: string; body: string }[] = []
  const readExtraUsage = vi.fn(options.flag ?? (async () => false))
  const monitor = createUsageAlertMonitor({
    enabled: () => enabled,
    notify: text => shown.push(text),
    now: () => now,
    readExtraUsage,
    store: Promise.resolve(store),
    timeZone: 'UTC',
  })
  return {
    monitor,
    readExtraUsage,
    setEnabled: (on: boolean) => {
      enabled = on
    },
    setNow: (ms: number) => {
      now = ms
    },
    shown,
    store,
    writes: memory.writes,
  }
}

describe('createUsageAlertMonitor', () => {
  test('session values at 90% or more show one notification', async () => {
    const t = setup()
    await settle()
    t.monitor.session(snap(fiveAt(91.6)))
    await settle()
    expect(t.shown).toEqual([OFF_TEXT])
    expect(t.store.get()).toEqual({ fiveHour: FIVE_RESET, sevenDay: null })
  })

  test('values below 90% and no values show nothing', async () => {
    const t = setup()
    await settle()
    t.monitor.session(snap(fiveAt(89)))
    t.monitor.session(null)
    t.monitor.account(null)
    await settle()
    expect(t.shown).toEqual([])
    expect(t.writes).toEqual([])
    expect(t.readExtraUsage).not.toHaveBeenCalled()
  })

  test('a limit notifies one time in each period', async () => {
    const t = setup()
    await settle()
    t.monitor.session(snap(fiveAt(92)))
    await settle()
    t.monitor.session(snap(fiveAt(95)))
    // The account values give a reset time that is 5 minutes later for the same period.
    t.monitor.account(account(fiveAt(97, FIVE_RESET + 5 * MIN), { extraUsage: false }))
    await settle()
    expect(t.shown).toHaveLength(1)
    // The next period notifies again.
    const next = FIVE_RESET + 5 * HOUR
    t.setNow(FIVE_RESET + MIN)
    t.monitor.account(account(fiveAt(93, next), { extraUsage: false, fetchedAt: FIVE_RESET }))
    await settle()
    expect(t.shown).toHaveLength(2)
    expect(t.store.get().fiveHour).toBe(next)
  })

  test('a reset time that moves later in small steps stays in the same period', async () => {
    const t = setup()
    await settle()
    t.monitor.session(snap(fiveAt(92)))
    await settle()
    expect(t.shown).toHaveLength(1)
    t.monitor.session(snap(fiveAt(93, FIVE_RESET + 10 * MIN)))
    await settle()
    expect(t.store.get().fiveHour).toBe(FIVE_RESET + 10 * MIN)
    // 16 minutes after the first reset time, but 6 minutes after the kept value.
    t.monitor.session(snap(fiveAt(94, FIVE_RESET + 16 * MIN)))
    await settle()
    expect(t.shown).toHaveLength(1)
    expect(t.store.get().fiveHour).toBe(FIVE_RESET + 16 * MIN)
    // The same value again writes nothing new.
    const writes = t.writes.length
    t.monitor.session(snap(fiveAt(95, FIVE_RESET + 16 * MIN)))
    await settle()
    expect(t.writes).toHaveLength(writes)
  })

  test('the kept period follows a later reset time also with the setting off', async () => {
    const memory = memoryStore({ fiveHour: FIVE_RESET, sevenDay: null })
    const t = setup({ enabled: false, store: memory.store })
    await settle()
    t.monitor.session(snap(fiveAt(93, FIVE_RESET + 10 * MIN)))
    await settle()
    expect(t.shown).toEqual([])
    expect(memory.store.get().fiveHour).toBe(FIVE_RESET + 10 * MIN)
  })

  test('two quick values during the read of the flag notify one time', async () => {
    let release: (on: boolean) => void = () => {}
    const t = setup({ flag: () => new Promise<boolean>(resolve => (release = resolve)) })
    await settle()
    t.monitor.session(snap(fiveAt(92)))
    t.monitor.session(snap(fiveAt(93)))
    release(false)
    await settle()
    expect(t.shown).toHaveLength(1)
    expect(t.readExtraUsage).toHaveBeenCalledTimes(1)
  })

  test('a restart does not notify again for the same period', async () => {
    const shared = memoryStore()
    const first = setup({ store: shared.store })
    await settle()
    first.monitor.session(snap(fiveAt(92)))
    await settle()
    expect(first.shown).toHaveLength(1)
    const second = setup({ store: shared.store })
    await settle()
    second.monitor.session(snap(fiveAt(92)))
    await settle()
    expect(second.shown).toEqual([])
  })

  test('the monitor checks nothing until the store opens, then the newest values', async () => {
    let open: (store: UsageAlertStore) => void = () => {}
    const memory = memoryStore({ fiveHour: FIVE_RESET, sevenDay: null })
    const shown: { title: string; body: string }[] = []
    const monitor = createUsageAlertMonitor({
      enabled: () => true,
      notify: text => shown.push(text),
      now: () => NOW,
      readExtraUsage: async () => false,
      store: new Promise<UsageAlertStore>(resolve => (open = resolve)),
      timeZone: 'UTC',
    })
    // The kept period is not known yet, so this value must wait.
    monitor.session(snap(fiveAt(92)))
    await settle()
    expect(shown).toEqual([])
    open(memory.store)
    await settle()
    // The kept period is the same period, so nothing shows.
    expect(shown).toEqual([])
    monitor.session(snap({ sevenDay: { resetsAt: SEVEN_RESET, usedPercent: 90 } }))
    await settle()
    expect(shown.map(s => s.title)).toEqual(['7-day limit at 90%'])
  })

  test('with the setting off, nothing shows and the period stays open', async () => {
    const t = setup({ enabled: false })
    await settle()
    t.monitor.session(snap(fiveAt(92)))
    await settle()
    expect(t.shown).toEqual([])
    expect(t.writes).toEqual([])
    // The setting goes on. The next value notifies.
    t.setEnabled(true)
    t.monitor.session(snap(fiveAt(92)))
    await settle()
    expect(t.shown).toEqual([OFF_TEXT])
  })

  test('both limits at 90% show two notifications', async () => {
    const t = setup()
    await settle()
    t.monitor.session(
      snap({
        fiveHour: { resetsAt: FIVE_RESET, usedPercent: 92 },
        sevenDay: { resetsAt: SEVEN_RESET, usedPercent: 95 },
      }),
    )
    await settle()
    expect(t.shown.map(s => s.title)).toEqual(['5-hour limit at 92%', '7-day limit at 95%'])
    expect(t.readExtraUsage).toHaveBeenCalledTimes(1)
  })

  test('fresh account values win over the session values', async () => {
    const t = setup()
    await settle()
    t.monitor.session(snap(fiveAt(99)))
    t.monitor.account(account(fiveAt(50), { extraUsage: false }))
    await settle()
    // The session values came first and notified. The account values are below 90%.
    expect(t.shown).toHaveLength(1)
    const u = setup()
    await settle()
    u.monitor.account(account(fiveAt(50), { extraUsage: false }))
    u.monitor.session(snap(fiveAt(99)))
    await settle()
    expect(u.shown).toEqual([])
  })

  test('account values older than 15 minutes fall back to the session values', async () => {
    const t = setup()
    await settle()
    t.monitor.account(account(fiveAt(50), { fetchedAt: NOW - 16 * MIN }))
    t.monitor.session(snap(fiveAt(92)))
    await settle()
    expect(t.shown).toEqual([OFF_TEXT])
  })

  test('fresh account values give the extra usage flag, and the file is not read', async () => {
    const t = setup({ flag: async () => true })
    await settle()
    t.monitor.account(account(fiveAt(92), { extraUsage: false }))
    await settle()
    expect(t.shown).toEqual([OFF_TEXT])
    const u = setup()
    await settle()
    u.monitor.account(account(fiveAt(92), { extraUsage: true }))
    await settle()
    expect(u.shown.map(s => s.title)).toEqual([WARNING])
    expect(t.readExtraUsage).not.toHaveBeenCalled()
    expect(u.readExtraUsage).not.toHaveBeenCalled()
  })

  test('without the flag of the account values, the monitor reads the file', async () => {
    const t = setup({ flag: async () => true })
    await settle()
    t.monitor.session(snap(fiveAt(92)))
    await settle()
    expect(t.readExtraUsage).toHaveBeenCalledTimes(1)
    expect(t.shown).toEqual([
      {
        body:
          'Your 5-hour limit is at 92%. After 100%, Claude Code spends your extra usage credits, ' +
          'which costs real money. It resets at 14:05.',
        title: WARNING,
      },
    ])
    // Fresh account values with no flag also read the file.
    const u = setup({ flag: async () => true })
    await settle()
    u.monitor.account(account(fiveAt(92)))
    await settle()
    expect(u.readExtraUsage).toHaveBeenCalledTimes(1)
    expect(u.shown.map(s => s.title)).toEqual([WARNING])
  })

  // A known "on" flag stays in memory. So stale account values after a 429 or a network error do
  // not lose the warning.
  test('fresh account values with the flag on give the warning', async () => {
    const t = setup()
    await settle()
    t.monitor.account(account(fiveAt(92), { extraUsage: true }))
    await settle()
    expect(t.shown.map(s => s.title)).toEqual([WARNING])
  })

  test('a known on flag of stale account values gives the warning without the file', async () => {
    const t = setup({ flag: async () => false })
    await settle()
    t.monitor.account(account(fiveAt(50), { extraUsage: true }))
    await settle()
    // The account values are now 20 minutes old, so the session values count.
    t.setNow(NOW + 20 * MIN)
    t.monitor.session(snap(fiveAt(92)))
    await settle()
    expect(t.shown.map(s => s.title)).toEqual([WARNING])
  })

  test('a null value and a value with no flag keep the known flag', async () => {
    const t = setup({ flag: async () => false })
    await settle()
    t.monitor.account(account(fiveAt(50), { extraUsage: true }))
    t.monitor.account(null)
    t.monitor.session(snap(fiveAt(92)))
    await settle()
    expect(t.shown.map(s => s.title)).toEqual([WARNING])
    const u = setup({ flag: async () => false })
    await settle()
    u.monitor.account(account(fiveAt(50), { extraUsage: true }))
    u.monitor.account(account(fiveAt(92)))
    await settle()
    expect(u.shown.map(s => s.title)).toEqual([WARNING])
  })

  test('a fresh off flag wins over an older on flag and over the file', async () => {
    const t = setup({ flag: async () => true })
    await settle()
    t.monitor.account(account(fiveAt(50), { extraUsage: true }))
    t.setNow(NOW + 5 * MIN)
    t.monitor.account(account(fiveAt(92), { extraUsage: false, fetchedAt: NOW + 5 * MIN }))
    await settle()
    expect(t.shown).toEqual([OFF_TEXT])
    expect(t.readExtraUsage).not.toHaveBeenCalled()
  })

  test('a failed read of the flag counts as off', async () => {
    const t = setup({ flag: async () => Promise.reject(new Error('no file')) })
    await settle()
    t.monitor.session(snap(fiveAt(92)))
    await settle()
    expect(t.shown).toEqual([OFF_TEXT])
  })
})
