// The state of the window manager. A pure reducer keeps the frames, the stacks and the memory.
import { centreRect, clampRect, MIN_SIZE, type Rect, type Size, shownRect } from './geometry'

export type PanelKind = 'overview' | 'selected-item' | 'integration' | 'chat'

export const DEFAULT_SIZES: Record<PanelKind, Size> = {
  chat: { h: 480, w: 720 },
  integration: { h: 320, w: 520 },
  overview: { h: 360, w: 760 },
  'selected-item': { h: 300, w: 360 },
}

export interface Frame {
  id: string
  panels: string[]
  active: string
  // The rect that the user set. The screen shows shownRect(rect, bounds).
  rect: Rect
  minimised: boolean
  locked: boolean
  opacity: number
}

export interface WmState {
  // In z-order. The last frame is on top.
  frames: Frame[]
  memory: Record<string, Rect>
  bounds: Size
  nextFrame: number
}

export type WmAction =
  | { type: 'open'; panelId: string }
  | { type: 'close'; panelId: string }
  | { type: 'closeActive' }
  | { type: 'focus'; frameId: string }
  | { type: 'setRect'; frameId: string; rect: Rect }
  | { type: 'stack'; frameId: string; targetId: string }
  | { type: 'unstack'; panelId: string; rect: Rect }
  | { type: 'activate'; panelId: string }
  | { type: 'minimise'; frameId: string }
  | { type: 'restore'; frameId: string }
  | { type: 'lock'; frameId: string; locked: boolean }
  | { type: 'opacity'; frameId: string; opacity: number }
  | { type: 'bounds'; bounds: Size }
  | { type: 'load'; frames: Omit<Frame, 'id'>[]; memory: Record<string, Rect> }

const OVERVIEW = /^overview:([1-9][0-9]?)$/
// The same strict form as the main process: 8-4-4-4-12 hex digits.
const CHAT = /^chat:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export function panelKind(panelId: string): PanelKind | null {
  if (typeof panelId !== 'string') return null
  if (panelId === 'selected-item' || panelId === 'integration') return panelId
  if (OVERVIEW.test(panelId)) return 'overview'
  if (CHAT.test(panelId)) return 'chat'
  return null
}

export function initialState(bounds: Size): WmState {
  return { bounds, frames: [], memory: {}, nextFrame: 1 }
}

export function frameOf(state: WmState, panelId: string): Frame | undefined {
  return state.frames.find(f => f.panels.includes(panelId))
}

export function topFrame(state: WmState): Frame | undefined {
  for (let i = state.frames.length - 1; i >= 0; i--) {
    const frame = state.frames[i]
    if (frame && !frame.minimised) return frame
  }
  return undefined
}

// The frames as the screen shows them, with each rect inside the current bounds.
// A frame whose rect fits keeps its object.
export function shownFrames(state: Pick<WmState, 'bounds' | 'frames'>): Frame[] {
  return state.frames.map(f => {
    const rect = shownRect(f.rect, state.bounds)
    return sameRect(rect, f.rect) ? f : { ...f, rect }
  })
}

function sameRect(a: Rect, b: Rect): boolean {
  return a.x === b.x && a.y === b.y && a.w === b.w && a.h === b.h
}

function isRect(r: Rect): boolean {
  return !!r && [r.x, r.y, r.w, r.h].every(n => Number.isFinite(n))
}

// Replaces one frame and keeps the order.
function withFrame(state: WmState, next: Frame): WmState {
  return { ...state, frames: state.frames.map(f => (f.id === next.id ? next : f)) }
}

// Replaces one frame and moves it to the top.
function withFrameOnTop(state: WmState, next: Frame): WmState {
  return { ...state, frames: [...state.frames.filter(f => f.id !== next.id), next] }
}

// The panel list and the active panel after a panel leaves a frame.
// The active panel becomes the tab to the left, or else the first tab.
function without(frame: Frame, panelId: string): { panels: string[]; active: string } {
  const index = frame.panels.indexOf(panelId)
  const panels = frame.panels.filter(p => p !== panelId)
  if (frame.active !== panelId) return { active: frame.active, panels }
  return { active: panels[index - 1] ?? panels[0] ?? '', panels }
}

function close(state: WmState, panelId: string): WmState {
  const frame = frameOf(state, panelId)
  if (!frame) return state
  const memory = { ...state.memory, [panelId]: frame.rect }
  const rest = without(frame, panelId)
  if (rest.panels.length === 0) {
    return { ...state, frames: state.frames.filter(f => f.id !== frame.id), memory }
  }
  return { ...withFrame(state, { ...frame, ...rest }), memory }
}

function open(state: WmState, panelId: string): WmState {
  const kind = panelKind(panelId)
  if (!kind) return state
  const frame = frameOf(state, panelId)
  if (frame) {
    const onTop = state.frames[state.frames.length - 1] === frame
    if (frame.active === panelId && !frame.minimised && onTop) return state
    return withFrameOnTop(state, { ...frame, active: panelId, minimised: false })
  }
  const saved = state.memory[panelId]
  const rect = clampRect(
    saved && isRect(saved) ? saved : centreRect(DEFAULT_SIZES[kind], state.bounds),
    state.bounds,
    MIN_SIZE,
  )
  const created: Frame = {
    active: panelId,
    id: `f${state.nextFrame}`,
    locked: false,
    minimised: false,
    opacity: 1,
    panels: [panelId],
    rect,
  }
  return { ...state, frames: [...state.frames, created], nextFrame: state.nextFrame + 1 }
}

function stack(state: WmState, frameId: string, targetId: string): WmState {
  if (frameId === targetId) return state
  const source = state.frames.find(f => f.id === frameId)
  const target = state.frames.find(f => f.id === targetId)
  if (!source || !target) return state
  if (source.minimised || target.minimised || source.locked) return state
  const next: Frame = {
    ...target,
    active: source.active,
    panels: [...target.panels, ...source.panels],
  }
  const rest = { ...state, frames: state.frames.filter(f => f.id !== source.id) }
  return withFrameOnTop(rest, next)
}

function unstack(state: WmState, panelId: string, rect: Rect): WmState {
  const frame = frameOf(state, panelId)
  if (!frame || frame.panels.length < 2 || frame.locked || !isRect(rect)) return state
  const rest = without(frame, panelId)
  const created: Frame = {
    active: panelId,
    id: `f${state.nextFrame}`,
    locked: false,
    minimised: false,
    opacity: frame.opacity,
    panels: [panelId],
    rect: clampRect(rect, state.bounds, MIN_SIZE),
  }
  const base = withFrame(state, { ...frame, ...rest })
  return {
    ...base,
    frames: [...base.frames, created],
    memory: { ...state.memory, [panelId]: frame.rect },
    nextFrame: state.nextFrame + 1,
  }
}

function clampOpacity(value: number): number {
  return Math.round(Math.min(1, Math.max(0.3, value)) * 100) / 100
}

function load(state: WmState, input: Omit<Frame, 'id'>[], memory: Record<string, Rect>): WmState {
  const seen = new Set<string>()
  const frames: Frame[] = []
  let nextFrame = state.nextFrame
  for (const item of input) {
    const panels: string[] = []
    for (const panelId of item.panels ?? []) {
      if (panelKind(panelId) && !seen.has(panelId)) {
        seen.add(panelId)
        panels.push(panelId)
      }
    }
    const first = panels[0]
    if (first === undefined || !isRect(item.rect)) continue
    frames.push({
      active: panels.includes(item.active) ? item.active : first,
      id: `f${nextFrame}`,
      locked: item.locked === true,
      minimised: item.minimised === true,
      opacity: Number.isFinite(item.opacity) ? clampOpacity(item.opacity) : 1,
      panels,
      // Keep the rect as saved. The screen shows it inside the current bounds.
      rect: { ...item.rect },
    })
    nextFrame += 1
  }
  return { ...state, frames, memory, nextFrame }
}

export function wmReducer(state: WmState, action: WmAction): WmState {
  switch (action.type) {
    case 'open':
      return open(state, action.panelId)
    case 'close':
      return close(state, action.panelId)
    case 'closeActive': {
      const frame = topFrame(state)
      return frame ? close(state, frame.active) : state
    }
    case 'focus': {
      const frame = state.frames.find(f => f.id === action.frameId)
      if (!frame || state.frames[state.frames.length - 1] === frame) return state
      return withFrameOnTop(state, frame)
    }
    case 'setRect': {
      const frame = state.frames.find(f => f.id === action.frameId)
      if (!frame || frame.locked || frame.minimised || !isRect(action.rect)) return state
      const rect = clampRect(action.rect, state.bounds, MIN_SIZE)
      return sameRect(rect, frame.rect) ? state : withFrame(state, { ...frame, rect })
    }
    case 'stack':
      return stack(state, action.frameId, action.targetId)
    case 'unstack':
      return unstack(state, action.panelId, action.rect)
    case 'activate': {
      const frame = frameOf(state, action.panelId)
      if (!frame || frame.active === action.panelId) return state
      return withFrame(state, { ...frame, active: action.panelId })
    }
    case 'minimise': {
      const frame = state.frames.find(f => f.id === action.frameId)
      if (!frame || frame.minimised) return state
      return withFrame(state, { ...frame, minimised: true })
    }
    case 'restore': {
      const frame = state.frames.find(f => f.id === action.frameId)
      if (!frame) return state
      const onTop = state.frames[state.frames.length - 1] === frame
      if (!frame.minimised && onTop) return state
      return withFrameOnTop(state, { ...frame, minimised: false })
    }
    case 'lock': {
      const frame = state.frames.find(f => f.id === action.frameId)
      if (!frame || frame.locked === action.locked) return state
      return withFrame(state, { ...frame, locked: action.locked })
    }
    case 'opacity': {
      const frame = state.frames.find(f => f.id === action.frameId)
      if (!frame || !Number.isFinite(action.opacity)) return state
      const opacity = clampOpacity(action.opacity)
      return opacity === frame.opacity ? state : withFrame(state, { ...frame, opacity })
    }
    case 'bounds': {
      const { bounds } = action
      if (!bounds || !Number.isFinite(bounds.w) || !Number.isFinite(bounds.h)) return state
      if (bounds.w < 1 || bounds.h < 1) return state
      if (bounds.w === state.bounds.w && bounds.h === state.bounds.h) return state
      // The frame rects do not change. A smaller area changes only the shown rects.
      return { ...state, bounds }
    }
    case 'load':
      return load(state, action.frames, action.memory)
    default:
      return state
  }
}
