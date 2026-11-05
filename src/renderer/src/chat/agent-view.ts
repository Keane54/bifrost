// Detects the Claude Code agent view in the screen lines of a chat window.
// The left arrow key opens this view. Bifrost may attach again, but only a few times.
export const AGENT_VIEW_FOOTER = /enter to return · space to reply/
export const AGENT_VIEW_COUNTS = /\d+ awaiting input · \d+ working · \d+ completed/

// The footer must be on one of the last 3 non-empty lines.
// Text that a conversation quotes higher on the screen does not match.
const FOOTER_LINES = 3

export function isAgentView(lines: string[]): boolean {
  const tail = lines.filter(line => line.trim() !== '').slice(-FOOTER_LINES)
  return (
    tail.some(line => AGENT_VIEW_FOOTER.test(line)) &&
    lines.some(line => AGENT_VIEW_COUNTS.test(line))
  )
}

export const MAX_REATTACH = 3
export const REATTACH_WINDOW_MS = 60_000

// Gives up when the history has MAX_REATTACH or more attaches in the window.
export function reattachDecision(history: number[], now: number): 'reattach' | 'give-up' {
  const recent = history.filter(at => now - at < REATTACH_WINDOW_MS)
  return recent.length >= MAX_REATTACH ? 'give-up' : 'reattach'
}
