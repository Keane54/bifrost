// Snapshots and named layouts. The main process keeps the file. The renderer checks all values.
import { type OverviewConfig, parseOverviews } from '../overview/config'
import { EMPTY_HISTORY, type History, parseHistory } from '../sessions/history'
import type { Rect } from './geometry'
import { type Frame, panelKind, type WmState } from './state'

export interface LayoutSnapshot {
  frames: Omit<Frame, 'id'>[]
  memory: Record<string, Rect>
}

export interface UiStore {
  version: 1
  current: LayoutSnapshot | null
  layouts: { name: string; snapshot: LayoutSnapshot }[]
  // The config of each Overview, keyed by panel ID (D1).
  overviews: Record<string, OverviewConfig>
  // The dialog history: recent folders, last model and mode, recent slash commands.
  history: History
}

export const EMPTY_STORE: UiStore = {
  current: null,
  history: EMPTY_HISTORY,
  layouts: [],
  overviews: {},
  version: 1,
}
export const MAX_LAYOUTS = 20
export const MAX_NAME = 40

export function toSnapshot(state: WmState): LayoutSnapshot {
  return {
    frames: state.frames.map(({ id: _id, ...rest }) => ({
      ...rest,
      panels: [...rest.panels],
      rect: { ...rest.rect },
    })),
    memory: Object.fromEntries(Object.entries(state.memory).map(([k, r]) => [k, { ...r }])),
  }
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function parseRect(value: unknown): Rect | null {
  if (!isObject(value)) return null
  const { x, y, w, h } = value
  if (![x, y, w, h].every(n => typeof n === 'number' && Number.isFinite(n))) return null
  if ((w as number) <= 0 || (h as number) <= 0) return null
  return { h: h as number, w: w as number, x: x as number, y: y as number }
}

function parseFrame(value: unknown): Omit<Frame, 'id'> | null {
  if (!isObject(value) || !Array.isArray(value.panels)) return null
  const rect = parseRect(value.rect)
  if (!rect) return null
  const panels: string[] = []
  for (const id of value.panels) {
    if (typeof id === 'string' && panelKind(id) && !panels.includes(id)) panels.push(id)
  }
  const first = panels[0]
  if (first === undefined) return null
  // An M2 store has an opacity value on each frame. The parse ignores it (spec 8.1).
  return {
    active:
      typeof value.active === 'string' && panels.includes(value.active) ? value.active : first,
    locked: value.locked === true,
    minimised: value.minimised === true,
    panels,
    rect,
  }
}

function parseSnapshot(value: unknown): LayoutSnapshot | null {
  if (!isObject(value)) return null
  const frames = Array.isArray(value.frames)
    ? value.frames.map(parseFrame).filter((f): f is Omit<Frame, 'id'> => f !== null)
    : []
  const memory: Record<string, Rect> = {}
  if (isObject(value.memory)) {
    for (const [id, raw] of Object.entries(value.memory)) {
      const rect = parseRect(raw)
      if (rect && panelKind(id)) memory[id] = rect
    }
  }
  return { frames, memory }
}

function validName(name: string): boolean {
  return name.length >= 1 && name.length <= MAX_NAME
}

// Check data that the renderer read from ui-state.json. Wrong values give the empty store
// or lose only the item that holds them.
export function parseUiStore(data: unknown): UiStore {
  if (!isObject(data) || data.version !== 1) return EMPTY_STORE
  const layouts: UiStore['layouts'] = []
  if (Array.isArray(data.layouts)) {
    for (const item of data.layouts) {
      if (layouts.length >= MAX_LAYOUTS) break
      if (!isObject(item) || typeof item.name !== 'string') continue
      const name = item.name.trim()
      if (!validName(name) || layouts.some(l => l.name === name)) continue
      const snapshot = parseSnapshot(item.snapshot)
      if (snapshot) layouts.push({ name, snapshot })
    }
  }
  return {
    current: parseSnapshot(data.current),
    history: parseHistory(data.history),
    layouts,
    overviews: parseOverviews(data.overviews),
    version: 1,
  }
}

export function saveLayout(store: UiStore, name: string, snapshot: LayoutSnapshot): UiStore {
  const trimmed = name.trim()
  if (!validName(trimmed)) return store
  const index = store.layouts.findIndex(l => l.name === trimmed)
  if (index >= 0) {
    const layouts = store.layouts.map((l, i) => (i === index ? { name: trimmed, snapshot } : l))
    return { ...store, layouts }
  }
  if (store.layouts.length >= MAX_LAYOUTS) return store
  return { ...store, layouts: [...store.layouts, { name: trimmed, snapshot }] }
}

export function deleteLayout(store: UiStore, name: string): UiStore {
  return { ...store, layouts: store.layouts.filter(l => l.name !== name) }
}
