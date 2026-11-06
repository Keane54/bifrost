// The contexts of the window manager. Each value changes only when its data changes.
// A drag step does not change the state, so the users of the state do not render at each step.
import { createContext, type Dispatch, useContext } from 'react'
import type { WmAction, WmState } from './state'

// The result of a save: saved, a name that is not correct, or a full list.
export type SaveResult = 'saved' | 'name' | 'full'

// The functions of the window manager. This value does not change.
export interface WmControls {
  dispatch: Dispatch<WmAction>
  saveLayout(name: string): SaveResult
  loadLayout(name: string): void
  deleteLayout(name: string): void
  // Open the Layout menu and focus its name field (Cmd+Option+S, D9).
  openLayoutSave(): void
}

// The state of the Layout menu. The window manager keeps it, so a key can open the menu.
export interface LayoutMenuState {
  open: boolean
  // Each openLayoutSave call adds 1. Each new value focuses the name field again.
  focusRequest: number
  setOpen(open: boolean): void
}

export const WmStateContext = createContext<WmState | null>(null)
export const WmControlsContext = createContext<WmControls | null>(null)
// The names of the saved layouts, in the order of the store.
export const LayoutsContext = createContext<readonly string[]>([])
export const LayoutMenuContext = createContext<LayoutMenuState | null>(null)

export function useWmState(): WmState {
  const value = useContext(WmStateContext)
  if (!value) throw new Error('useWmState needs a WindowManager.')
  return value
}

export function useWmControls(): WmControls {
  const value = useContext(WmControlsContext)
  if (!value) throw new Error('useWmControls needs a WindowManager.')
  return value
}

export function useLayouts(): readonly string[] {
  return useContext(LayoutsContext)
}

export function useLayoutMenu(): LayoutMenuState {
  const value = useContext(LayoutMenuContext)
  if (!value) throw new Error('useLayoutMenu needs a WindowManager.')
  return value
}
