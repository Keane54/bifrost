// The app-wide state of the Performance panel (design section 5). One store holds the
// newest snapshot from the main process. The side bar and the panel read it, so the app has one
// subscription. The window manager reports the view and the frame rate to the main process.
import {
  createContext,
  useContext,
  useEffect,
  useMemo,
  useState,
  useSyncExternalStore,
} from 'react'
import type { BifrostApi } from '../../../shared/api'
import {
  EMPTY_PERFORMANCE,
  type HealthState,
  MAX_FPS,
  type PerformanceSnapshot,
} from '../../../shared/performance'
import { createSnapshotStore, type SnapshotStore } from '../lib/snapshot-store'
import { type Frame, panelKind } from '../wm/state'

// The panel ID of the Performance panel.
export const PERFORMANCE_PANEL = 'performance'

type PerformanceApi = Pick<BifrostApi['performance'], 'onUpdate' | 'snapshot'>

export type PerformanceStore = SnapshotStore<PerformanceSnapshot>

// A store with one subscription to the main process for all its listeners (createSnapshotStore).
export function createPerformanceStore(api: () => PerformanceApi): PerformanceStore {
  return createSnapshotStore(api, EMPTY_PERFORMANCE)
}

const store = createPerformanceStore(() => window.bifrost.performance)

// The newest snapshot, for the panel.
export function usePerformance(): PerformanceSnapshot {
  return useSyncExternalStore(store.subscribe, store.get)
}

// The health state only, for the side bar. A new snapshot with the same state does not render
// the side bar.
export function usePerformanceState(): HealthState {
  return useSyncExternalStore(store.subscribe, () => store.get().state)
}

// What the main process must know about the window (P2, P9).
export interface PerformanceView {
  // The panel is the active panel of a frame that is not minimised, and the page is visible.
  showing: boolean
  // The window has the focus.
  focused: boolean
  // The IDs of the open chat panels, also in back tabs and in minimised frames. Sorted.
  chatPanels: string[]
}

// The view from the frames of the window manager and the state of the page.
export function performanceView(
  frames: readonly Frame[],
  page: { focused: boolean; visible: boolean },
): PerformanceView {
  const showing = page.visible && frames.some(f => !f.minimised && f.active === PERFORMANCE_PANEL)
  const chats = new Set<string>()
  for (const frame of frames) {
    for (const panel of frame.panels) if (panelKind(panel) === 'chat') chats.add(panel)
  }
  return { chatPanels: [...chats].sort(), focused: page.focused, showing }
}

// A function that sends the view only when it is different from the last view that it sent.
// When a send fails, the function forgets that view, so the next report sends it again. Else the
// main process can keep an old view. A failed send of an older view does not change the record
// of a newer view.
export function createViewReporter(
  send: (view: PerformanceView) => Promise<void>,
): (view: PerformanceView) => void {
  let last: string | null = null
  return view => {
    const key = JSON.stringify([view.showing, view.focused, view.chatPanels])
    if (key === last) return
    last = key
    send(view).catch(() => {
      if (last === key) last = null
    })
  }
}

// The frame callbacks and the timers of the page. A test gives a fake.
export interface FrameClock {
  request(cb: (time: number) => void): number
  cancel(id: number): void
  after(ms: number, cb: () => void): number
  cancelAfter(id: number): void
}

const SECOND_MS = 1000
// The counter counts frames for 2 s in each 10 s (design section 7). A frame loop at the display
// rate makes the page draw each frame. So a short burst costs much less CPU than a loop that
// runs at all times.
export const BURST_MS = 2000
export const BURST_EVERY_MS = 10_000

// Count the frames in bursts. Each burst starts with a frame callback, counts the frames for 2 s
// and reports one frame rate: the frames divided by the real time of the burst. The next burst
// starts 8 s after the end of the burst. No frame callback runs between the bursts. The
// returned function stops the count at once.
export function startFpsCounter(clock: FrameClock, report: (fps: number) => void): () => void {
  let from: number | null = null
  let frames = 0
  let frameId: number | null = null
  let timerId: number | null = null
  function burst(): void {
    timerId = null
    from = null
    frames = 0
    frameId = clock.request(step)
  }
  function step(time: number): void {
    frameId = null
    if (from === null) {
      from = time
    } else {
      frames += 1
      const span = time - from
      if (span >= BURST_MS) {
        report(Math.min(MAX_FPS, Math.round((frames * SECOND_MS) / span)))
        timerId = clock.after(BURST_EVERY_MS - BURST_MS, burst)
        return
      }
    }
    frameId = clock.request(step)
  }
  burst()
  return () => {
    if (frameId !== null) clock.cancel(frameId)
    if (timerId !== null) clock.cancelAfter(timerId)
    frameId = null
    timerId = null
  }
}

const PAGE_CLOCK: FrameClock = {
  after: (ms, cb) => window.setTimeout(cb, ms),
  cancel: id => window.cancelAnimationFrame(id),
  cancelAfter: id => window.clearTimeout(id),
  request: cb => window.requestAnimationFrame(cb),
}

interface Page {
  focused: boolean
  visible: boolean
}

function readPage(): Page {
  return { focused: document.hasFocus(), visible: document.visibilityState === 'visible' }
}

// The focus and the visibility of the page. The window focus and blur events follow the key
// window of macOS in Electron.
function usePage(): Page {
  const [page, setPage] = useState(readPage)
  useEffect(() => {
    const update = (): void => {
      const next = readPage()
      setPage(p => (p.focused === next.focused && p.visible === next.visible ? p : next))
    }
    window.addEventListener('focus', update)
    window.addEventListener('blur', update)
    document.addEventListener('visibilitychange', update)
    update()
    return () => {
      window.removeEventListener('focus', update)
      window.removeEventListener('blur', update)
      document.removeEventListener('visibilitychange', update)
    }
  }, [])
  return page
}

// The one reporter of the app, so two reports cannot disagree. The window manager calls it with
// its frames. It sends the view on each change, also while the panel is closed, so the main
// process knows the open chat panels (P2). While the panel shows and the window has the focus,
// it also sends the frame rate of each burst, one time each 10 s (design section 7).
export function usePerformanceReport(frames: readonly Frame[]): void {
  const page = usePage()
  const view = useMemo(() => performanceView(frames, page), [frames, page])
  const [report] = useState(() => createViewReporter(v => window.bifrost.performance.view(v)))
  useEffect(() => report(view), [report, view])

  const counting = view.showing && view.focused
  useEffect(() => {
    if (!counting) return
    return startFpsCounter(PAGE_CLOCK, fps => {
      window.bifrost.performance.fps(fps).catch(() => {})
    })
  }, [counting])
}

// The Details row of the panel. The window manager keeps the value in the UI state (P10).
export interface PerformanceDetails {
  open: boolean
  setOpen(open: boolean): void
}

export const PerformanceDetailsContext = createContext<PerformanceDetails | null>(null)

export function usePerformanceDetails(): PerformanceDetails {
  const value = useContext(PerformanceDetailsContext)
  if (!value) throw new Error('usePerformanceDetails needs a PerformanceDetailsContext.')
  return value
}
