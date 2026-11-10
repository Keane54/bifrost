import { ChevronDown, ChevronLeft, ChevronRight, ChevronUp, type LucideIcon } from 'lucide-react'
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
} from 'react'
import { ActionsProvider } from '../actions/actions-context'
import { ConfirmProvider } from '../actions/ConfirmDialog'
import { ChatsProvider } from '../chat/chat-terminals'
import { KeysProvider } from '../keys/KeysProvider'
import { cx } from '../lib/cx'
import { overviewsReducer } from '../overview/config'
import { OverviewsProvider } from '../overview/overviews-context'
import {
  type PerformanceDetails,
  PerformanceDetailsContext,
  usePerformanceReport,
} from '../performance/use-performance'
import ReleaseNotesDialog from '../release-notes/ReleaseNotesDialog'
import type { History } from '../sessions/history'
import { HistoryProvider } from '../sessions/history-context'
import { LiveProvider } from '../settings/live-context'
import SetupDialog from '../settings/SetupDialog'
import { useSettings } from '../settings/settings-context'
import { SettingsNavProvider } from '../settings/settings-nav'
import { SkillsProvider } from '../settings/skills-context'
import {
  LayoutMenuContext,
  type LayoutMenuState,
  LayoutsContext,
  type WmControls,
  WmControlsContext,
  WmStateContext,
} from './context'
import Frame, { type DragMode } from './Frame'
import {
  type Edge,
  moveRect,
  type Point,
  type Rect,
  resizeRect,
  type SnapMark,
  shownRect,
  snapMarks,
  titleBar,
} from './geometry'
import { movedToStack, tearOutRect, titleBarAt, tornOut } from './hit'
import {
  deleteLayout,
  EMPTY_STORE,
  MAX_NAME,
  type PerformanceUi,
  parseUiStore,
  saveLayout,
  toSnapshot,
  type UiStore,
} from './layout'
import { blurredFrames } from './overlap'
import SideBar from './SideBar'
import {
  DEFAULT_SIZES,
  initialState,
  shownFrames,
  topFrame,
  type WmState,
  wmReducer,
} from './state'

const SAVE_DELAY_MS = 500
// The default layout: an Overview at the top left, and the Selected Item at the right of it.
const GAP = 16
const OVERVIEW_RECT: Rect = { h: 360, w: 760, x: 16, y: 16 }
const SELECTED_RECT: Rect = {
  ...DEFAULT_SIZES['selected-item'],
  x: OVERVIEW_RECT.x + OVERVIEW_RECT.w + GAP,
  y: OVERVIEW_RECT.y,
}
// The arrow of a snap mark (spec 8.1), and its size in pixels.
const MARK_SIZE = 10
const MARK_ARROWS: Record<SnapMark['dir'], LucideIcon> = {
  down: ChevronDown,
  left: ChevronLeft,
  right: ChevronRight,
  up: ChevronUp,
}

// The number in a frame ID "f<n>". The DOM keeps the frames in this order.
// So a focus does not move a DOM node. A move of a node can end its pointer capture.
function frameNumber(id: string): number {
  return Number(id.slice(1))
}

function sameMarks(a: SnapMark[], b: SnapMark[]): boolean {
  return (
    a.length === b.length &&
    a.every((m, i) => m.dir === b[i]?.dir && m.x === b[i]?.x && m.y === b[i]?.y)
  )
}

// The left or top position of a mark arrow: centred on the mark point, and inside the area.
// So the arrow of a mark on a window edge shows fully.
function markStart(at: number, areaSize: number): number {
  return Math.min(Math.max(at - MARK_SIZE / 2, 0), areaSize - MARK_SIZE)
}

function sameRect(a: Rect, b: Rect): boolean {
  return a.x === b.x && a.y === b.y && a.w === b.w && a.h === b.h
}

// The shown rects of the visible frames. The excluded frame does not count.
function visibleRects(state: WmState, excludeId?: string): Rect[] {
  return shownFrames(state)
    .filter(f => f.id !== excludeId && !f.minimised)
    .map(f => f.rect)
}

interface Drag {
  // The frame that the drag moves. A tear-out changes it to the new frame.
  frameId: string
  end(applyLast: boolean): void
}

// The rect of the dragged frame during a drag. The reducer gets the rect when the drag ends.
// So the state does not change at each drag step, and its users do not render.
interface Live {
  frameId: string
  rect: Rect
}

interface Start {
  // The parsed store, or null until ui.load ends.
  store: UiStore | null
  // False when ui.load failed. Then Bifrost does not write over the file.
  canSave: boolean
  // True when the panel area has a size.
  sized: boolean
  done: boolean
}

// The panel area with its frames, and the side bar. It owns the state of the window manager.
export default function WindowManager(): React.JSX.Element {
  const [state, dispatch] = useReducer(wmReducer, { h: 0, w: 0 }, initialState)
  // The config of each Overview panel (D1). The store saves it with the layout.
  const [overviews, dispatchOverviews] = useReducer(overviewsReducer, EMPTY_STORE.overviews)
  // The dialog history (spec 8.9, 9.6). The store saves it with the layout.
  const [history, setHistory] = useState<History>(EMPTY_STORE.history)
  // The Details row of the Performance panel (P10). The store saves it with the layout.
  const [performance, setPerformance] = useState<PerformanceUi>(EMPTY_STORE.performance)
  const [marks, setMarks] = useState<SnapMark[]>([])
  const [dragging, setDragging] = useState(false)
  const [live, setLive] = useState<Live | null>(null)
  const [dropTarget, setDropTarget] = useState<string | null>(null)
  const [layoutNames, setLayoutNames] = useState<readonly string[]>([])
  // The Layout menu of the side bar. Cmd+Option+S opens it (D9).
  const [layoutMenu, setLayoutMenu] = useState({ focusRequest: 0, open: false })
  const areaRef = useRef<HTMLDivElement>(null)
  const stateRef = useRef(state)
  // The drag reads the snap distance from this ref, so a change applies at the next drag.
  const { settings } = useSettings()
  const snapRef = useRef(settings.snapDistance)
  const overviewsRef = useRef(overviews)
  const historyRef = useRef(history)
  const performanceRef = useRef(performance)
  const storeRef = useRef<UiStore>(EMPTY_STORE)
  const start = useRef<Start>({ canSave: false, done: false, sized: false, store: null })
  const saveOn = useRef(false)
  // True when the state or the store changed after the last save.
  const dirty = useRef(false)
  const saveTimer = useRef<number | undefined>(undefined)
  const drag = useRef<Drag | null>(null)

  // The drag and save handlers read the state from this ref.
  useLayoutEffect(() => {
    stateRef.current = state
  }, [state])

  useLayoutEffect(() => {
    snapRef.current = settings.snapDistance
  }, [settings.snapDistance])

  useLayoutEffect(() => {
    overviewsRef.current = overviews
  }, [overviews])

  useLayoutEffect(() => {
    historyRef.current = history
  }, [history])

  useLayoutEffect(() => {
    performanceRef.current = performance
  }, [performance])

  // The one report of the view and the frame rate to the main process (P2, P9).
  usePerformanceReport(state.frames)

  // Send the store with the current layout, the Overview configs, the dialog history and the
  // Performance UI state now, if it has a change.
  const saveNow = useCallback(() => {
    window.clearTimeout(saveTimer.current)
    saveTimer.current = undefined
    if (!saveOn.current || !dirty.current) return
    dirty.current = false
    const store: UiStore = {
      ...storeRef.current,
      current: toSnapshot(stateRef.current),
      history: historyRef.current,
      overviews: overviewsRef.current,
      performance: performanceRef.current,
    }
    storeRef.current = store
    window.bifrost.ui
      .save(store)
      .catch(err => console.error('Bifrost cannot save the UI state.', err))
  }, [])

  // Save 500 ms after the last change. During a drag, wait for the drag to end.
  const scheduleSave = useCallback(() => {
    window.clearTimeout(saveTimer.current)
    saveTimer.current = undefined
    if (!saveOn.current || !dirty.current || drag.current) return
    saveTimer.current = window.setTimeout(saveNow, SAVE_DELAY_MS)
  }, [saveNow])

  // Keep a changed store, show its layout names and save it.
  const setStore = useCallback(
    (next: UiStore) => {
      storeRef.current = next
      setLayoutNames(next.layouts.map(l => l.name))
      dirty.current = true
      scheduleSave()
    },
    [scheduleSave],
  )

  // Apply the saved layout, or the default layout, when the load ended and the area has a size.
  // Before this, a new frame would get a size of 0.
  const tryStart = useCallback(() => {
    const s = start.current
    if (s.done || !s.sized || !s.store) return
    s.done = true
    storeRef.current = s.store
    setLayoutNames(s.store.layouts.map(l => l.name))
    // Set the ref now too. So a save before the next render does not write an empty list.
    overviewsRef.current = s.store.overviews
    dispatchOverviews({ overviews: s.store.overviews, type: 'load' })
    historyRef.current = s.store.history
    setHistory(s.store.history)
    performanceRef.current = s.store.performance
    setPerformance(s.store.performance)
    const snapshot = s.store.current
    if (snapshot) {
      dispatch({ frames: snapshot.frames, memory: snapshot.memory, type: 'load' })
    } else {
      // A new frame gets the ID f<nextFrame>.
      const n = stateRef.current.nextFrame
      dispatch({ panelId: 'overview:1', type: 'open' })
      dispatch({ frameId: `f${n}`, rect: OVERVIEW_RECT, type: 'setRect' })
      dispatch({ panelId: 'selected-item', type: 'open' })
      dispatch({ frameId: `f${n + 1}`, rect: SELECTED_RECT, type: 'setRect' })
    }
    saveOn.current = s.canSave
  }, [])

  useLayoutEffect(() => {
    const area = areaRef.current
    if (!area) return
    const measure = (): void => {
      const box = area.getBoundingClientRect()
      const bounds = { h: Math.floor(box.height), w: Math.floor(box.width) }
      // In an area with no size, each frame would show with a size of 0, and a new frame
      // would get a size of 0. So Bifrost ignores an area with no size.
      if (bounds.w <= 0 || bounds.h <= 0) return
      dispatch({ bounds, type: 'bounds' })
      start.current.sized = true
      tryStart()
    }
    measure()
    const observer = new ResizeObserver(measure)
    observer.observe(area)
    return () => observer.disconnect()
  }, [tryStart])

  useEffect(() => {
    let active = true
    window.bifrost.ui.load().then(
      data => {
        if (!active) return
        start.current.store = parseUiStore(data)
        start.current.canSave = true
        tryStart()
      },
      err => {
        if (!active) return
        console.error('Bifrost cannot load the UI state. It uses the default layout.', err)
        start.current.store = EMPTY_STORE
        tryStart()
      },
    )
    return () => {
      active = false
    }
  }, [tryStart])

  // biome-ignore lint/correctness/useExhaustiveDependencies: each change of the state starts the save timer again.
  useEffect(() => {
    dirty.current = true
    scheduleSave()
  }, [state, scheduleSave])

  // biome-ignore lint/correctness/useExhaustiveDependencies: each change of the Overview configs starts the save timer again.
  useEffect(() => {
    dirty.current = true
    scheduleSave()
  }, [overviews, scheduleSave])

  // biome-ignore lint/correctness/useExhaustiveDependencies: each change of the dialog history starts the save timer again.
  useEffect(() => {
    dirty.current = true
    scheduleSave()
  }, [history, scheduleSave])

  // biome-ignore lint/correctness/useExhaustiveDependencies: each change of the Performance UI state starts the save timer again.
  useEffect(() => {
    dirty.current = true
    scheduleSave()
  }, [performance, scheduleSave])

  const updateHistory = useCallback((fn: (h: History) => History) => setHistory(h => fn(h)), [])

  const performanceDetails = useMemo<PerformanceDetails>(
    () => ({
      open: performance.detailsOpen,
      setOpen: detailsOpen => setPerformance({ detailsOpen }),
    }),
    [performance.detailsOpen],
  )

  // When the page closes or reloads, send the pending save at once. The timer would not run.
  useEffect(() => {
    window.addEventListener('beforeunload', saveNow)
    window.addEventListener('pagehide', saveNow)
    return () => {
      window.removeEventListener('beforeunload', saveNow)
      window.removeEventListener('pagehide', saveNow)
    }
  }, [saveNow])

  // The menu item Close Panel (Cmd+W) closes the active panel.
  useEffect(() => window.bifrost.wm.onClosePanel(() => dispatch({ type: 'closeActive' })), [])

  // A drag ends when its frame closes, goes to the side bar or becomes locked.
  useEffect(() => {
    const current = drag.current
    if (!current) return
    const frame = state.frames.find(f => f.id === current.frameId)
    if (!frame || frame.minimised || frame.locked) current.end(false)
  }, [state.frames])

  useEffect(
    () => () => {
      window.clearTimeout(saveTimer.current)
      drag.current?.end(false)
    },
    [],
  )

  // Start a move, a resize or a press on a tab of a stack.
  // A move or a resize captures the pointer on the element that got the pointer down.
  // A tab press captures the pointer on the title bar only when the tab tears out.
  // The listeners are on the window. So the drag can end when its capture element leaves the page.
  const beginDrag = useCallback(
    (e: React.PointerEvent<HTMLElement>, frameId: string, mode: DragMode) => {
      if (drag.current) return
      const area = areaRef.current
      const current = stateRef.current
      const frame = current.frames.find(f => f.id === frameId)
      if (!area || !frame || frame.locked || frame.minimised) return
      const el = e.currentTarget
      const pointerId = e.pointerId
      const origin = area.getBoundingClientRect()
      // A press on a tab of a stack waits for a tear-out. A drag of the only tab is a move.
      const tab = typeof mode === 'object' && frame.panels.length > 1 ? mode.tab : null
      const edge: Edge | null = typeof mode === 'string' && mode !== 'move' ? mode : null
      const handle: Drag = { end, frameId }

      let id = frameId
      let pressing = tab !== null
      let startX = e.clientX
      let startY = e.clientY
      // The drag starts from the rect that the screen shows.
      let startRect = shownRect(frame.rect, current.bounds)
      let others = visibleRects(current, frameId)
      // The pointer down position. A tear-out does not change it.
      const down: Point = { x: e.clientX, y: e.clientY }
      // The last pointer position, in client coordinates.
      let x = e.clientX
      let y = e.clientY
      let moved = false
      // True after the pointer went STACK_DISTANCE or more from the pointer down position.
      let farEnough = false
      let raf = 0
      let ended = false
      // The rect that the frame shows now. It is null until the first step.
      let drawn: Rect | null = null

      function capture(): boolean {
        try {
          el.setPointerCapture(pointerId)
          return true
        } catch {
          return false
        }
      }
      // The pointer in the coordinates of the panel area.
      function pointer(): Point {
        return { x: x - origin.left, y: y - origin.top }
      }
      // The raw rect follows the pointer with no snap. The snapped rect is the rect that a
      // release gives (spec 8.1). Use the start rect and the total delta, not the last rect.
      // So the snap is stable.
      function compute(): { raw: Rect; snapped: Rect } {
        const bounds = stateRef.current.bounds
        const dx = x - startX
        const dy = y - startY
        const place = (snap: number): Rect =>
          edge
            ? resizeRect(startRect, edge, dx, dy, others, bounds, snap)
            : moveRect(startRect, dx, dy, others, bounds, snap)
        return { raw: place(0), snapped: place(snapRef.current) }
      }
      // A move that ends on the title bar of a different frame stacks the two frames.
      function stackTarget(): string | null {
        if (edge || !moved || !farEnough) return null
        return titleBarAt(shownFrames(stateRef.current), pointer(), id)?.id ?? null
      }
      // Draw one step at the raw rect, with the marks of the snap. The reducer gets the rect
      // only when the drag ends.
      function draw(): void {
        raf = 0
        const { raw, snapped } = compute()
        const target = stackTarget()
        // A drop on a title bar stacks the frame and applies no snap. So no mark shows.
        const next = target ? [] : snapMarks(raw, snapped, others, stateRef.current.bounds)
        const step: Live = { frameId: id, rect: raw }
        drawn = raw
        setLive(prev =>
          prev?.frameId === step.frameId && sameRect(prev.rect, step.rect) ? prev : step,
        )
        setMarks(prev => (sameMarks(prev, next) ? prev : next))
        setDropTarget(target)
      }
      // The tab went more than TEAR_DISTANCE from the title bar. It leaves the stack as a new frame.
      // Then the same drag moves the new frame.
      function tearOut(panelId: string): void {
        const s = stateRef.current
        const source = s.frames.find(f => f.id === frameId)
        // The reducer refuses these cases. Then the state does not change, so end the drag here.
        if (
          !source ||
          source.locked ||
          source.panels.length < 2 ||
          !source.panels.includes(panelId)
        ) {
          end(false)
          return
        }
        const p = pointer()
        const sourceRect = shownRect(source.rect, s.bounds)
        if (!tornOut(titleBar(sourceRect), p)) return
        // The title bar of the source frame stays on the page, so it keeps the capture.
        if (!capture()) {
          end(false)
          return
        }
        // The new frame gets the saved size of the panel, or else the size of the stack.
        const rect = tearOutRect(p, s.memory[panelId], sourceRect, s.bounds)
        // The reducer gives the new frame the ID f<nextFrame>.
        id = `f${s.nextFrame}`
        handle.frameId = id
        dispatch({ panelId, rect, type: 'unstack' })
        pressing = false
        startRect = rect
        startX = x
        startY = y
        // The new frame is not in s, so all visible frames are the others.
        others = visibleRects(s)
        moved = true
      }
      function onMove(ev: PointerEvent): void {
        if (ev.pointerId !== pointerId) return
        // No button is down. So Bifrost did not get the pointer up. End the drag.
        if (ev.buttons === 0) {
          end(false)
          return
        }
        x = ev.clientX
        y = ev.clientY
        if (!farEnough) farEnough = movedToStack(down, { x, y })
        if (pressing) {
          if (tab !== null) tearOut(tab)
          return
        }
        if (x !== startX || y !== startY) moved = true
        // Draw at most one time for each animation frame.
        if (moved && raf === 0) raf = requestAnimationFrame(draw)
      }
      function onUp(ev: PointerEvent): void {
        if (ev.pointerId !== pointerId) return
        x = ev.clientX
        y = ev.clientY
        if (!farEnough) farEnough = movedToStack(down, { x, y })
        if (!pressing && (x !== startX || y !== startY)) moved = true
        end(true)
      }
      function onCancel(ev: PointerEvent): void {
        if (ev.pointerId === pointerId) end(false)
      }
      // A pointer up stacks the frame on a title bar. Or it puts the frame at the last pointer
      // position, with the snap.
      // A cancel, a lost capture or a lost pointer up keeps the frame where it was last drawn.
      // It applies no snap.
      // A tab press that ends before a tear-out changes nothing. The click activates the tab.
      function end(applyLast: boolean): void {
        if (ended) return
        ended = true
        window.removeEventListener('pointermove', onMove)
        window.removeEventListener('pointerup', onUp)
        window.removeEventListener('pointercancel', onCancel)
        window.removeEventListener('lostpointercapture', onCancel)
        if (raf !== 0) cancelAnimationFrame(raf)
        raf = 0
        let target: string | null = null
        if (applyLast && moved && !pressing) {
          drawn = compute().snapped
          target = stackTarget()
        }
        if (el.hasPointerCapture(pointerId)) el.releasePointerCapture(pointerId)
        drag.current = null
        if (target) dispatch({ frameId: id, targetId: target, type: 'stack' })
        else if (drawn) dispatch({ frameId: id, rect: drawn, type: 'setRect' })
        setLive(null)
        setMarks([])
        setDropTarget(null)
        setDragging(false)
        scheduleSave()
      }

      if (!pressing && !capture()) return
      window.addEventListener('pointermove', onMove)
      window.addEventListener('pointerup', onUp)
      window.addEventListener('pointercancel', onCancel)
      window.addEventListener('lostpointercapture', onCancel)
      drag.current = handle
      window.clearTimeout(saveTimer.current)
      setDragging(true)
    },
    [scheduleSave],
  )

  const setLayoutMenuOpen = useCallback((open: boolean) => {
    setLayoutMenu(menu => (menu.open === open ? menu : { ...menu, open }))
  }, [])
  const layoutMenuValue = useMemo<LayoutMenuState>(
    () => ({ ...layoutMenu, setOpen: setLayoutMenuOpen }),
    [layoutMenu, setLayoutMenuOpen],
  )

  // The functions for the side bar, the menus and the keys. This value does not change.
  const controls = useMemo<WmControls>(
    () => ({
      deleteLayout: name => setStore(deleteLayout(storeRef.current, name)),
      dispatch,
      loadLayout: name => {
        const item = storeRef.current.layouts.find(l => l.name === name)
        if (!item) return
        dispatch({ frames: item.snapshot.frames, memory: item.snapshot.memory, type: 'load' })
      },
      openLayoutSave: () =>
        setLayoutMenu(menu => ({ focusRequest: menu.focusRequest + 1, open: true })),
      saveLayout: name => {
        const store = storeRef.current
        const next = saveLayout(store, name, toSnapshot(stateRef.current))
        if (next !== store) {
          setStore(next)
          return 'saved'
        }
        // saveLayout refuses a name that is not correct, or a new name when the list is full.
        const length = name.trim().length
        return length < 1 || length > MAX_NAME ? 'name' : 'full'
      },
    }),
    [setStore],
  )
  // The frames with the rects that the screen shows. The state keeps the rects that the user set.
  const { bounds, frames } = state
  const shown = useMemo(() => shownFrames({ bounds, frames }), [bounds, frames])
  const order = useMemo(
    () => [...shown].sort((a, b) => frameNumber(a.id) - frameNumber(b.id)),
    [shown],
  )
  const topId = topFrame(state)?.id
  // The frames that overlap a lower frame. Only they have the backdrop blur (user decision,
  // 2026-11-10). During a drag, the live rect of the dragged frame counts.
  const blurred = useMemo(() => blurredFrames(shown, live), [shown, live])
  // The marks and the drop outline are above all frames.
  const overlayZ = shown.length
  const dropFrame = dropTarget ? shown.find(f => f.id === dropTarget) : undefined
  const dropBar = dropFrame ? titleBar(dropFrame.rect) : null

  return (
    <WmControlsContext value={controls}>
      <WmStateContext value={state}>
        <LayoutsContext value={layoutNames}>
          <LayoutMenuContext value={layoutMenuValue}>
            {/* The side bar and the Settings panel open the Settings panel and its section. */}
            <SettingsNavProvider>
              {/* The side bar, the setup dialog and the Settings panel read the state of
                  Live details. */}
              <LiveProvider>
                <SkillsProvider>
                  {/* The send box and the New session dialog read and change the dialog history. */}
                  <HistoryProvider history={history} update={updateHistory}>
                    {/* The Performance panel reads and changes its Details row. */}
                    <PerformanceDetailsContext value={performanceDetails}>
                      {/* One confirmation dialog for Stop, Delete and Take control. */}
                      <ConfirmProvider>
                        {/* The chat terminals follow the open chat panels in the frames. */}
                        <ChatsProvider>
                          {/* The actions read the frames, the history, the confirmation and the
                            chat terminals. So the provider is inside these four. */}
                          <ActionsProvider>
                            <div className='flex h-full w-full'>
                              <SideBar />
                              {/* The Overview panels, the frame titles and the frame menus read
                                the configs. */}
                              <OverviewsProvider dispatch={dispatchOverviews} state={overviews}>
                                {/* The keys of spec 9.4 read the frames, the Overview configs, the
                                  rows and the actions. */}
                                <KeysProvider>
                                  {/* The area keeps the z-order of its frames inside it. So a
                                    popover can be above them. A text selection cannot start on
                                    the empty area. The panel content allows it. During a drag or
                                    a resize, no part of the area allows a selection. */}
                                  <div
                                    className={cx(
                                      'relative isolate min-w-0 flex-1 overflow-hidden select-none',
                                      dragging && '**:select-none',
                                    )}
                                    data-panel-area={true}
                                    ref={areaRef}
                                  >
                                    {order.map(frame => (
                                      <Frame
                                        blur={blurred.has(frame.id)}
                                        dispatch={dispatch}
                                        frame={
                                          live?.frameId === frame.id
                                            ? { ...frame, rect: live.rect }
                                            : frame
                                        }
                                        key={frame.id}
                                        onDrag={beginDrag}
                                        top={frame.id === topId}
                                        z={shown.indexOf(frame)}
                                      />
                                    ))}
                                    {/* The arrow marks of the snap that a release applies (spec
                                      8.1). The x mark has a left or right arrow, and the y mark
                                      has an up or down arrow. So the direction is a unique key. */}
                                    {marks.map(m => {
                                      const Arrow = MARK_ARROWS[m.dir]
                                      return (
                                        <Arrow
                                          aria-hidden={true}
                                          className='pointer-events-none absolute text-snap'
                                          data-snap-mark={m.dir}
                                          key={m.dir}
                                          size={MARK_SIZE}
                                          strokeWidth={3}
                                          style={{
                                            left: markStart(m.x, bounds.w),
                                            top: markStart(m.y, bounds.h),
                                            zIndex: overlayZ,
                                          }}
                                        />
                                      )
                                    })}
                                    {/* The title bar where a drop stacks the dragged frame. The
                                      outline is above all frames, because the dragged frame
                                      covers the title bar. */}
                                    {dropBar && dropFrame && (
                                      <div
                                        className='pointer-events-none absolute bg-text-strong/10 outline-2 -outline-offset-2 outline-text-strong/30'
                                        data-drop-target={dropFrame.id}
                                        style={{
                                          height: dropBar.h,
                                          left: dropBar.x,
                                          top: dropBar.y,
                                          width: dropBar.w,
                                          zIndex: overlayZ,
                                        }}
                                      />
                                    )}
                                  </div>
                                </KeysProvider>
                              </OverviewsProvider>
                            </div>
                          </ActionsProvider>
                        </ChatsProvider>
                      </ConfirmProvider>
                    </PerformanceDetailsContext>
                  </HistoryProvider>
                  {/* The setup dialog at the first start (spec 11.1). */}
                  <SetupDialog />
                  {/* What's new after an update, and the release notes of Settings > Updates. */}
                  <ReleaseNotesDialog />
                </SkillsProvider>
              </LiveProvider>
            </SettingsNavProvider>
          </LayoutMenuContext>
        </LayoutsContext>
      </WmStateContext>
    </WmControlsContext>
  )
}
