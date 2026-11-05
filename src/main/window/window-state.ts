import type { DisplayMode } from '../../shared/types'
import { readJsonFile, writeJsonAtomic } from '../store/json-file'

export interface Bounds {
  x: number
  y: number
  width: number
  height: number
}

export interface WindowState {
  mode: DisplayMode
  bounds: Bounds | null
}

const MODES: readonly string[] = ['window', 'borderless', 'fullscreen']
const MIN_WIDTH = 400
const MIN_HEIGHT = 300
// The part of the top edge area that must be on a screen, so the user can grab the window.
const GRAB_WIDTH = 100
const GRAB_HEIGHT = 40

export function isDisplayMode(value: unknown): value is DisplayMode {
  return typeof value === 'string' && MODES.includes(value)
}

function parseBounds(value: unknown): Bounds | null {
  if (typeof value !== 'object' || value === null) return null
  const v = value as Record<string, unknown>
  const { x, y, width, height } = v
  if (
    typeof x !== 'number' ||
    typeof y !== 'number' ||
    typeof width !== 'number' ||
    typeof height !== 'number' ||
    ![x, y, width, height].every(Number.isFinite) ||
    width < MIN_WIDTH ||
    height < MIN_HEIGHT
  ) {
    return null
  }
  return { height, width, x, y }
}

// Read the saved window state. A bad value gives the defaults.
export function parseWindowState(data: unknown): WindowState {
  if (typeof data !== 'object' || data === null) return { bounds: null, mode: 'window' }
  const v = data as Record<string, unknown>
  return {
    bounds: parseBounds(v.bounds),
    mode: isDisplayMode(v.mode) ? v.mode : 'window',
  }
}

// Return the saved bounds if the top edge area of the window is on a screen.
// If not, return only the size. Then Electron puts the window in the centre.
export function restoreBounds(
  saved: Bounds | null,
  workAreas: Bounds[],
  fallback: { width: number; height: number },
): Partial<Bounds> & { width: number; height: number } {
  if (!saved) return fallback
  // The top edge area is the top 40 pixels of the window, over its full width.
  // At least 100 x 40 pixels of it must be inside one work area.
  const strip = { bottom: saved.y + GRAB_HEIGHT, left: saved.x, right: saved.x + saved.width }
  const visible = workAreas.some(area => {
    const width = Math.min(strip.right, area.x + area.width) - Math.max(strip.left, area.x)
    const top = Math.max(saved.y, area.y)
    const height = Math.min(strip.bottom, area.y + area.height) - top
    return width >= GRAB_WIDTH && height >= GRAB_HEIGHT
  })
  return visible ? saved : fallback
}

export interface WindowStateStore {
  // The state that Bifrost read at open, or the defaults.
  readonly state: WindowState
  // Change a part of the state and write the file. Writes run in the order of the calls.
  update(part: Partial<WindowState>): Promise<void>
}

// Open window-state.json. A missing or damaged file gives the defaults.
// If the file cannot be read, Bifrost does not write over it.
export async function openWindowStateStore(
  file: string,
  log: (message: string, error: unknown) => void = console.error,
): Promise<WindowStateStore> {
  let state: WindowState = { bounds: null, mode: 'window' }
  let canWrite = true
  try {
    const result = await readJsonFile(file)
    if (result.ok) state = parseWindowState(result.data)
  } catch (error) {
    canWrite = false
    log(`Bifrost cannot read ${file}. Bifrost does not save the window state.`, error)
  }
  let queue: Promise<void> = Promise.resolve()
  return {
    get state() {
      return state
    },
    update(part) {
      state = { ...state, ...part }
      if (!canWrite) return Promise.resolve()
      const snapshot = state
      const run = queue.then(() => writeJsonAtomic(file, snapshot))
      queue = run.catch(() => {})
      return run
    },
  }
}
