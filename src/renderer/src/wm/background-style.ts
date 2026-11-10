// The animated background (spec 8.10). This module is pure.
import { cx } from '../lib/cx'

// The number of colour fields. app.css has one rule and one animation for each field.
export const BACKGROUND_FIELDS = 6

// moving: the fields drift. paused: the fields stop where they are, and continue from there.
// still: the fields stay at their still position, the first step of each cycle.
export type BackgroundMotion = 'moving' | 'paused' | 'still'

export interface MotionInput {
  // The Animated background setting is on, after the settings load.
  animated: boolean
  // The fields moved before in this run of the app.
  ran: boolean
  // The window has the focus, and the page is visible.
  active: boolean
  // The system asks for reduced motion (prefers-reduced-motion: reduce).
  reduced: boolean
}

// The fields move only with the setting on and an active window. An inactive window pauses them.
// A setting that goes off after the fields moved also pauses them, so they do not jump. A setting
// that is off from the start keeps them at the still position. With reduced motion, the fields
// stay at the still position in each case.
export function backgroundMotion({
  animated,
  ran,
  active,
  reduced,
}: MotionInput): BackgroundMotion {
  if (reduced) return 'still'
  if (animated) return active ? 'moving' : 'paused'
  return ran ? 'paused' : 'still'
}

// True when the window has the focus and the page is visible. In Electron, the page loses the
// focus when the Bifrost window is not the key window.
export function windowActive(page: {
  hasFocus(): boolean
  visibilityState: DocumentVisibilityState
}): boolean {
  return page.hasFocus() && page.visibilityState === 'visible'
}

// The class of the background layer for each motion. With reduced motion, app.css also keeps the
// fields at the still position for each class, also before the view reads the media query.
export function backgroundClass(motion: BackgroundMotion): string {
  return cx(
    'background',
    motion === 'paused' && 'background-paused',
    motion === 'still' && 'background-still',
  )
}
