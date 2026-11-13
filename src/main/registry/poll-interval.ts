// The wait between two active polls while the window is not visible.
export const HIDDEN_POLL_MS = 15_000

const REFUSED_BAD_INPUT = 'refused: bad input'

// Return the wait between two active polls.
// A visible window uses the normal wait. A window that is not visible uses at least 15 seconds.
// An unfocused window is still visible, so it keeps the normal wait.
export function pollInterval(normalMs: number, visible: boolean): number {
  return visible ? normalMs : Math.max(normalMs, HIDDEN_POLL_MS)
}

// Check the visibility that the page sends. It must be a boolean.
export function checkVisible(v: unknown): boolean {
  if (typeof v !== 'boolean') throw new Error(REFUSED_BAD_INPUT)
  return v
}
