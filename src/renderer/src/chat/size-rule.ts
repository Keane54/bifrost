// The size rule of the chat windows (spec 8.5).
// Only the focused window sends a resize. Other windows follow the session size or zoom.
import type { TermSize } from '../../../shared/types'

export interface Px {
  w: number
  h: number
}

export const DEFAULT_TERM: TermSize = { cols: 120, rows: 32 }
export const RESIZE_DEBOUNCE_MS = 150
// After a send, a different session size is an old read for this time.
export const SESSION_ECHO_MS = 500

export interface SizeInput {
  focused: boolean
  focusGained: boolean
  // The size that fits the panel, or null when it is not known.
  fit: TermSize | null
  // The size of the session, or null when it is not known.
  session: TermSize | null
  // The size that the terminal has now.
  term: TermSize
  lastSent: TermSize | null
  lastSentAt: number | null
  now: number
}

export interface SizeDecision {
  term: TermSize
  send: TermSize | null
}

function same(a: TermSize | null, b: TermSize | null): boolean {
  return !!a && !!b && a.cols === b.cols && a.rows === b.rows
}

export function decideSize(input: SizeInput): SizeDecision {
  const { fit, session, term, lastSent, lastSentAt, now } = input
  if (input.focused && fit && (input.focusGained || !same(fit, lastSent))) {
    return { send: fit, term: fit }
  }
  if (session) {
    const recent = lastSentAt !== null && now - lastSentAt <= SESSION_ECHO_MS
    const oldRead = recent && lastSent !== null && !same(session, lastSent)
    if (!oldRead) return { send: null, term: session }
  }
  return { send: null, term }
}

// The zoom of an unfocused window. It never goes above 1.
export function fitScale(screen: Px, panel: Px | null): number {
  if (!panel || screen.w === 0 || screen.h === 0) return 1
  return Math.min(1, panel.w / screen.w, panel.h / screen.h)
}

// The size for a new terminal.
export function openSize(input: {
  focused: boolean
  fit: TermSize | null
  session: TermSize | null
}): TermSize {
  if (!input.focused && input.session) return input.session
  return input.fit ?? input.session ?? DEFAULT_TERM
}
