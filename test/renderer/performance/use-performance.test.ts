// The app-wide Performance store and the reports to the main process (P2, P9).
import { describe, expect, it, vi } from 'vitest'
import {
  BURST_EVERY_MS,
  BURST_MS,
  createPerformanceStore,
  createViewReporter,
  type FrameClock,
  type PerformanceView,
  performanceView,
  startFpsCounter,
} from '../../../src/renderer/src/performance/use-performance'
import type { Frame } from '../../../src/renderer/src/wm/state'
import { EMPTY_PERFORMANCE, type PerformanceSnapshot } from '../../../src/shared/performance'

const CHAT_A = 'chat:123e4567-e89b-12d3-a456-426614174000'
const CHAT_B = 'chat:023e4567-e89b-12d3-a456-426614174000'
const rect = { h: 100, w: 100, x: 0, y: 0 }

function frame(id: string, panels: string[], more: Partial<Frame> = {}): Frame {
  return { active: panels[0] ?? '', id, locked: false, minimised: false, panels, rect, ...more }
}

const PAGE = { focused: true, visible: true }

function fakeApi() {
  let push: ((s: PerformanceSnapshot) => void) | null = null
  let answer: ((s: PerformanceSnapshot) => void) | null = null
  const off = vi.fn()
  const api = {
    onUpdate: vi.fn((cb: (s: PerformanceSnapshot) => void) => {
      push = cb
      return off
    }),
    snapshot: vi.fn(
      () =>
        new Promise<PerformanceSnapshot>(resolve => {
          answer = resolve
        }),
    ),
  }
  return {
    answer: (s: PerformanceSnapshot) => answer?.(s),
    api,
    off,
    push: (s: PerformanceSnapshot) => push?.(s),
  }
}

const warning: PerformanceSnapshot = {
  ...EMPTY_PERFORMANCE,
  reasons: [{ level: 'warning', text: 'A' }],
  state: 'warning',
}
const problem: PerformanceSnapshot = { ...warning, state: 'problem' }

describe('createPerformanceStore', () => {
  it('starts with the empty snapshot', () => {
    const fake = fakeApi()
    expect(createPerformanceStore(() => fake.api).get()).toBe(EMPTY_PERFORMANCE)
  })

  it('makes one subscription for all listeners (the side bar and the panel)', () => {
    const fake = fakeApi()
    const store = createPerformanceStore(() => fake.api)
    const offA = store.subscribe(() => {})
    const offB = store.subscribe(() => {})
    expect(fake.api.onUpdate).toHaveBeenCalledTimes(1)
    expect(fake.api.snapshot).toHaveBeenCalledTimes(1)
    offA()
    expect(fake.off).not.toHaveBeenCalled()
    offB()
    expect(fake.off).toHaveBeenCalledTimes(1)
  })

  it('tells each listener about a pushed snapshot', () => {
    const fake = fakeApi()
    const store = createPerformanceStore(() => fake.api)
    const a = vi.fn()
    const b = vi.fn()
    store.subscribe(a)
    store.subscribe(b)
    fake.push(warning)
    expect(store.get()).toBe(warning)
    expect(a).toHaveBeenCalledTimes(1)
    expect(b).toHaveBeenCalledTimes(1)
  })

  it('keeps an update that comes before the first answer', async () => {
    const fake = fakeApi()
    const store = createPerformanceStore(() => fake.api)
    store.subscribe(() => {})
    fake.push(problem)
    fake.answer(warning)
    await Promise.resolve()
    expect(store.get()).toBe(problem)
  })

  it('uses the first answer when no update came before it', async () => {
    const fake = fakeApi()
    const store = createPerformanceStore(() => fake.api)
    store.subscribe(() => {})
    fake.answer(warning)
    await Promise.resolve()
    expect(store.get()).toBe(warning)
  })

  it('ignores an answer that comes after the last listener left', async () => {
    const fake = fakeApi()
    const store = createPerformanceStore(() => fake.api)
    store.subscribe(() => {})()
    fake.answer(warning)
    await Promise.resolve()
    expect(store.get()).toBe(EMPTY_PERFORMANCE)
  })
})

describe('performanceView', () => {
  it('shows while the panel is the active panel of a frame that is not minimised', () => {
    expect(performanceView([frame('f1', ['performance'])], PAGE).showing).toBe(true)
  })

  it('does not show in a back tab, in a minimised frame or in a hidden page', () => {
    const back = frame('f1', ['reviews', 'performance'])
    expect(performanceView([back], PAGE).showing).toBe(false)
    const min = frame('f1', ['performance'], { minimised: true })
    expect(performanceView([min], PAGE).showing).toBe(false)
    const hidden = { focused: false, visible: false }
    expect(performanceView([frame('f1', ['performance'])], hidden).showing).toBe(false)
    expect(performanceView([], PAGE).showing).toBe(false)
  })

  it('gives the window focus', () => {
    expect(performanceView([], PAGE).focused).toBe(true)
    expect(performanceView([], { focused: false, visible: true }).focused).toBe(false)
  })

  it('lists each open chat panel one time, sorted, also in back tabs and minimised frames', () => {
    const view = performanceView(
      [
        frame('f1', [CHAT_A, 'settings']),
        frame('f2', ['watchlist', CHAT_B], { minimised: true }),
        frame('f3', [CHAT_A]),
      ],
      PAGE,
    )
    expect(view.chatPanels).toEqual([CHAT_B, CHAT_A])
  })
})

describe('createViewReporter', () => {
  const view = (more: Partial<PerformanceView> = {}): PerformanceView => ({
    chatPanels: [],
    focused: true,
    showing: false,
    ...more,
  })

  it('sends the first view, and then only a changed view', () => {
    const send = vi.fn(async (_v: PerformanceView) => {})
    const report = createViewReporter(send)
    report(view())
    report(view())
    expect(send).toHaveBeenCalledTimes(1)
    report(view({ showing: true }))
    report(view({ focused: false, showing: true }))
    report(view({ chatPanels: [CHAT_A], focused: false, showing: true }))
    report(view({ chatPanels: [CHAT_A], focused: false, showing: true }))
    expect(send.mock.calls.map(c => c[0])).toEqual([
      view(),
      view({ showing: true }),
      view({ focused: false, showing: true }),
      view({ chatPanels: [CHAT_A], focused: false, showing: true }),
    ])
  })

  // A view that the main process did not get goes again at the next report.
  it('sends a view again after its send failed', async () => {
    const send = vi
      .fn(async (_v: PerformanceView) => {})
      .mockRejectedValueOnce(new Error('refused: bad input'))
    const report = createViewReporter(send)
    report(view({ showing: true }))
    await Promise.resolve()
    await Promise.resolve()
    report(view({ showing: true }))
    expect(send).toHaveBeenCalledTimes(2)
    await Promise.resolve()
    report(view({ showing: true }))
    expect(send).toHaveBeenCalledTimes(2)
  })

  it('keeps a newer view as sent when an older send fails', async () => {
    let fail: (err: Error) => void = () => {}
    const send = vi
      .fn(async (_v: PerformanceView) => {})
      .mockImplementationOnce(
        () =>
          new Promise<void>((_resolve, reject) => {
            fail = reject
          }),
      )
    const report = createViewReporter(send)
    report(view())
    report(view({ showing: true }))
    fail(new Error('refused: bad input'))
    await Promise.resolve()
    await Promise.resolve()
    report(view({ showing: true }))
    expect(send).toHaveBeenCalledTimes(2)
  })
})

describe('startFpsCounter', () => {
  // A fake clock: a queue of frame callbacks and a list of timers. The test runs each one.
  function fakeClock() {
    const frames = new Map<number, (t: number) => void>()
    const timers = new Map<number, { ms: number; cb: () => void }>()
    let next = 1
    const clock: FrameClock = {
      after: (ms, cb) => {
        timers.set(next, { cb, ms })
        return next++
      },
      cancel: id => {
        frames.delete(id)
      },
      cancelAfter: id => {
        timers.delete(id)
      },
      request: cb => {
        frames.set(next, cb)
        return next++
      },
    }
    // Run the waiting frame callback at the time t.
    const frameAt = (t: number): void => {
      const [id, cb] = [...frames][0] ?? []
      if (id === undefined || cb === undefined) return
      frames.delete(id)
      cb(t)
    }
    // Run the waiting timer and give its time.
    const runTimer = (): number | undefined => {
      const [id, timer] = [...timers][0] ?? []
      if (id === undefined || timer === undefined) return undefined
      timers.delete(id)
      timer.cb()
      return timer.ms
    }
    return { clock, frameAt, frames, runTimer, timers }
  }

  it('counts the frames of one 2 s burst and reports one value', () => {
    const fake = fakeClock()
    const report = vi.fn()
    startFpsCounter(fake.clock, report)
    expect(fake.frames.size).toBe(1)
    // 60 fps for 2 s. The first frame starts the count.
    for (let i = 0; i < 120; i++) fake.frameAt((i * 1000) / 60)
    expect(report).not.toHaveBeenCalled()
    fake.frameAt(2000)
    expect(report.mock.calls).toEqual([[60]])
    // No frame callback waits between the bursts. One timer waits for the next burst.
    expect(fake.frames.size).toBe(0)
    expect(fake.timers.size).toBe(1)
  })

  it('starts a burst every 10 s, with the real time of each burst', () => {
    const fake = fakeClock()
    const report = vi.fn()
    startFpsCounter(fake.clock, report)
    for (let i = 0; i <= 60; i++) fake.frameAt((i * 2000) / 60)
    expect(report).toHaveBeenLastCalledWith(30)
    // The next burst starts 8 s after the end of this one.
    expect(fake.runTimer()).toBe(BURST_EVERY_MS - BURST_MS)
    expect(fake.frames.size).toBe(1)
    // A slow frame: 50 frames in 2.5 s is 20 fps.
    const start = 10_000
    for (let i = 0; i < 50; i++) fake.frameAt(start + i * 40)
    fake.frameAt(start + 2500)
    expect(report).toHaveBeenLastCalledWith(20)
    expect(report).toHaveBeenCalledTimes(2)
    expect(BURST_MS).toBe(2000)
    expect(BURST_EVERY_MS).toBe(10_000)
  })

  it('stops at once, during a burst and between bursts', () => {
    const fake = fakeClock()
    const report = vi.fn()
    const stop = startFpsCounter(fake.clock, report)
    fake.frameAt(0)
    fake.frameAt(16)
    stop()
    expect(fake.frames.size).toBe(0)
    expect(fake.timers.size).toBe(0)
    const later = fakeClock()
    const stopLater = startFpsCounter(later.clock, report)
    for (let i = 0; i <= 60; i++) later.frameAt((i * 2000) / 60)
    expect(later.timers.size).toBe(1)
    stopLater()
    expect(later.frames.size).toBe(0)
    expect(later.timers.size).toBe(0)
    expect(report).toHaveBeenCalledTimes(1)
  })
})
