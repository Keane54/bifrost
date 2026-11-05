import {
  createContext,
  type Dispatch,
  useCallback,
  useContext,
  useEffect,
  useLayoutEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
} from 'react'
import { cx } from '../lib/cx'
import Frame, { type DragMode } from './Frame'
import { type Guide, moveRect, type Rect, resizeRect } from './geometry'
import { EMPTY_STORE, parseUiStore, toSnapshot, type UiStore } from './layout'
import SideBar from './SideBar'
import {
  DEFAULT_SIZES,
  initialState,
  topFrame,
  type WmAction,
  type WmState,
  wmReducer,
} from './state'

export interface WmContextValue {
  state: WmState
  dispatch: Dispatch<WmAction>
}

export const WmContext = createContext<WmContextValue | null>(null)

export function useWm(): WmContextValue {
  const value = useContext(WmContext)
  if (!value) throw new Error('useWm needs a WindowManager.')
  return value
}

const SAVE_DELAY_MS = 500
// The default layout: an Overview at the top left, and the Selected Item at the right of it.
const GAP = 16
const OVERVIEW_RECT: Rect = { h: 360, w: 760, x: 16, y: 16 }
const SELECTED_RECT: Rect = {
  ...DEFAULT_SIZES['selected-item'],
  x: OVERVIEW_RECT.x + OVERVIEW_RECT.w + GAP,
  y: OVERVIEW_RECT.y,
}

// The number in a frame ID "f<n>". The DOM keeps the frames in this order.
// Thus a focus does not move a DOM node. A move of a node can end its pointer capture.
function frameNumber(id: string): number {
  return Number(id.slice(1))
}

function sameGuides(a: Guide[], b: Guide[]): boolean {
  return a.length === b.length && a.every((g, i) => g.axis === b[i]?.axis && g.at === b[i]?.at)
}

interface Drag {
  frameId: string
  end(applyLast: boolean): void
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
  const [guides, setGuides] = useState<Guide[]>([])
  const [dragging, setDragging] = useState(false)
  const areaRef = useRef<HTMLDivElement>(null)
  const stateRef = useRef(state)
  const storeRef = useRef<UiStore>(EMPTY_STORE)
  const start = useRef<Start>({ canSave: false, done: false, sized: false, store: null })
  const saveOn = useRef(false)
  const saveTimer = useRef<number | undefined>(undefined)
  const drag = useRef<Drag | null>(null)

  // The drag and save handlers read the state from this ref.
  useLayoutEffect(() => {
    stateRef.current = state
  }, [state])

  // Save 500 ms after the last change. During a drag, wait for the drag to end.
  const scheduleSave = useCallback(() => {
    window.clearTimeout(saveTimer.current)
    if (!saveOn.current || drag.current) return
    saveTimer.current = window.setTimeout(() => {
      const store: UiStore = { ...storeRef.current, current: toSnapshot(stateRef.current) }
      storeRef.current = store
      window.bifrost.ui
        .save(store)
        .catch(err => console.error('Bifrost cannot save the UI state.', err))
    }, SAVE_DELAY_MS)
  }, [])

  // Apply the saved layout, or the default layout, when the load ended and the area has a size.
  // Before this, a frame rect would clamp to a size of 0.
  const tryStart = useCallback(() => {
    const s = start.current
    if (s.done || !s.sized || !s.store) return
    s.done = true
    storeRef.current = s.store
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
      // An area with no size would clamp each frame to a size of 0. Then the save
      // would write that layout. So Bifrost ignores an area with no size.
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
    scheduleSave()
  }, [state, scheduleSave])

  // A drag ends when its frame closes or goes to the side bar.
  useEffect(() => {
    const current = drag.current
    if (current && !state.frames.some(f => f.id === current.frameId && !f.minimised)) {
      current.end(false)
    }
  }, [state.frames])

  useEffect(
    () => () => {
      window.clearTimeout(saveTimer.current)
      drag.current?.end(false)
    },
    [],
  )

  // Start a move or a resize. The element that got the pointer down captures the pointer.
  const beginDrag = useCallback(
    (e: React.PointerEvent<HTMLElement>, frameId: string, mode: DragMode) => {
      if (drag.current) return
      const current = stateRef.current
      const frame = current.frames.find(f => f.id === frameId)
      if (!frame || frame.locked || frame.minimised) return
      const el = e.currentTarget
      const pointerId = e.pointerId
      try {
        el.setPointerCapture(pointerId)
      } catch {
        return
      }

      const startX = e.clientX
      const startY = e.clientY
      const startRect = frame.rect
      const bounds = current.bounds
      const others = current.frames.filter(f => f.id !== frameId && !f.minimised).map(f => f.rect)
      let dx = 0
      let dy = 0
      let moved = false
      let raf = 0
      let ended = false

      // Use the start rect and the total delta, not the last rect. Thus the snap is stable.
      const apply = (): void => {
        raf = 0
        const result =
          mode === 'move'
            ? moveRect(startRect, dx, dy, others, bounds)
            : resizeRect(startRect, mode, dx, dy, others, bounds)
        dispatch({ frameId, rect: result.rect, type: 'setRect' })
        setGuides(prev => (sameGuides(prev, result.guides) ? prev : result.guides))
      }
      const track = (ev: PointerEvent): void => {
        dx = ev.clientX - startX
        dy = ev.clientY - startY
        if (dx !== 0 || dy !== 0) moved = true
      }
      // Dispatch at most one time for each animation frame.
      const onMove = (ev: PointerEvent): void => {
        if (ev.pointerId !== pointerId) return
        track(ev)
        if (moved && raf === 0) raf = requestAnimationFrame(apply)
      }
      const onUp = (ev: PointerEvent): void => {
        if (ev.pointerId !== pointerId) return
        track(ev)
        end(true)
      }
      const onCancel = (ev: PointerEvent): void => {
        if (ev.pointerId === pointerId) end(false)
      }
      // A pointer up puts the frame at the last pointer position.
      // A cancel or a lost capture keeps the frame where it was last drawn.
      function end(applyLast: boolean): void {
        if (ended) return
        ended = true
        el.removeEventListener('pointermove', onMove)
        el.removeEventListener('pointerup', onUp)
        el.removeEventListener('pointercancel', onCancel)
        el.removeEventListener('lostpointercapture', onCancel)
        if (raf !== 0) cancelAnimationFrame(raf)
        raf = 0
        if (applyLast && moved) apply()
        if (el.hasPointerCapture(pointerId)) el.releasePointerCapture(pointerId)
        drag.current = null
        setGuides([])
        setDragging(false)
        scheduleSave()
      }

      el.addEventListener('pointermove', onMove)
      el.addEventListener('pointerup', onUp)
      el.addEventListener('pointercancel', onCancel)
      el.addEventListener('lostpointercapture', onCancel)
      drag.current = { end, frameId }
      window.clearTimeout(saveTimer.current)
      setDragging(true)
    },
    [scheduleSave],
  )

  const value = useMemo(() => ({ dispatch, state }), [state])
  const order = useMemo(
    () => [...state.frames].sort((a, b) => frameNumber(a.id) - frameNumber(b.id)),
    [state.frames],
  )
  const topId = topFrame(state)?.id
  const guideZ = state.frames.length

  return (
    <WmContext value={value}>
      <div className='flex h-full w-full'>
        <SideBar />
        <div
          className={cx('relative min-w-0 flex-1 overflow-hidden', dragging && 'select-none')}
          data-panel-area={true}
          ref={areaRef}
        >
          {order.map(frame => (
            <Frame
              dispatch={dispatch}
              frame={frame}
              key={frame.id}
              onDrag={beginDrag}
              top={frame.id === topId}
              z={state.frames.indexOf(frame)}
            />
          ))}
          {guides.map(g => (
            <div
              className={cx(
                'pointer-events-none absolute bg-snap',
                g.axis === 'x' ? 'inset-y-0 w-px' : 'inset-x-0 h-px',
              )}
              data-guide={g.axis}
              key={`${g.axis}:${g.at}`}
              style={
                g.axis === 'x'
                  ? { left: Math.min(g.at, state.bounds.w - 1), zIndex: guideZ }
                  : { top: Math.min(g.at, state.bounds.h - 1), zIndex: guideZ }
              }
            />
          ))}
        </div>
      </div>
    </WmContext>
  )
}
