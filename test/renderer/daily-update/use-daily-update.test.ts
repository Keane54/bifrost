// The app-wide store of the Daily update snapshot, the tab store and the route of a reminder.
import { describe, expect, it, vi } from 'vitest'
import {
  createDailyStore,
  DAILY_PANEL,
  dailyMarker,
  getDailyTab,
  openDaily,
  setDailyTab,
  subscribeDailyTab,
} from '../../../src/renderer/src/daily-update/use-daily-update'
import { freshMarks } from '../../../src/shared/daily-schedule'
import { type DailySnapshot, EMPTY_DAILY_STATE } from '../../../src/shared/daily-state'

const SNAP: DailySnapshot = {
  areas: [],
  configured: false,
  deadline: '10:00',
  due: true,
  marker: false,
  running: false,
  since: {},
  state: { ...EMPTY_DAILY_STATE, marks: freshMarks('2026-11-11') },
}

function fakeApi() {
  let push: ((s: DailySnapshot) => void) | null = null
  let answer: ((s: DailySnapshot) => void) | null = null
  const off = vi.fn()
  const api = {
    onUpdate: vi.fn((cb: (s: DailySnapshot) => void) => {
      push = cb
      return off
    }),
    snapshot: vi.fn(
      () =>
        new Promise<DailySnapshot>(resolve => {
          answer = resolve
        }),
    ),
  }
  return {
    answer: (s: DailySnapshot) => answer?.(s),
    api,
    off,
    push: (s: DailySnapshot) => push?.(s),
  }
}

describe('createDailyStore', () => {
  it('has no snapshot before the first answer', () => {
    const fake = fakeApi()
    expect(createDailyStore(() => fake.api).get()).toBeNull()
  })

  it('subscribes at the first listener and loads the first snapshot', async () => {
    const fake = fakeApi()
    const store = createDailyStore(() => fake.api)
    const listener = vi.fn()
    store.subscribe(listener)
    expect(fake.api.onUpdate).toHaveBeenCalledTimes(1)
    fake.answer(SNAP)
    await Promise.resolve()
    expect(store.get()).toBe(SNAP)
    expect(listener).toHaveBeenCalled()
  })

  it('keeps an update that comes before the first answer', async () => {
    const fake = fakeApi()
    const store = createDailyStore(() => fake.api)
    store.subscribe(() => {})
    const newer = { ...SNAP, marker: true }
    fake.push(newer)
    fake.answer(SNAP)
    await Promise.resolve()
    expect(store.get()).toBe(newer)
  })

  it('stops the subscription after the last listener', () => {
    const fake = fakeApi()
    const store = createDailyStore(() => fake.api)
    const stop1 = store.subscribe(() => {})
    const stop2 = store.subscribe(() => {})
    stop1()
    expect(fake.off).not.toHaveBeenCalled()
    stop2()
    expect(fake.off).toHaveBeenCalledTimes(1)
  })
})

describe('dailyMarker', () => {
  it('is the marker of the snapshot, and false before the first snapshot', () => {
    expect(dailyMarker(null)).toBe(false)
    expect(dailyMarker(SNAP)).toBe(false)
    expect(dailyMarker({ ...SNAP, marker: true })).toBe(true)
  })
})

describe('the tab store', () => {
  it('keeps the chosen tab and tells the listeners only about a change', () => {
    setDailyTab(null)
    const listener = vi.fn()
    const stop = subscribeDailyTab(listener)
    setDailyTab('b')
    expect(getDailyTab()).toBe('b')
    setDailyTab('b')
    expect(listener).toHaveBeenCalledTimes(1)
    setDailyTab(null)
    expect(getDailyTab()).toBeNull()
    expect(listener).toHaveBeenCalledTimes(2)
    stop()
  })
})

describe('openDaily', () => {
  it('selects the tab of the reminder and opens the panel', () => {
    const dispatch = vi.fn()
    openDaily('b', dispatch)
    expect(getDailyTab()).toBe('b')
    expect(dispatch).toHaveBeenCalledWith({ panelId: 'daily-update', type: 'open' })
    expect(DAILY_PANEL).toBe('daily-update')
  })

  it('clears the choice for a reminder with no area, so the panel picks a tab', () => {
    setDailyTab('a')
    openDaily(null, vi.fn())
    expect(getDailyTab()).toBeNull()
  })
})
