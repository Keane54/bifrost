// Detects the Claude Code agent view in the screen lines of a chat window.
// The left arrow key opens this view. Bifrost may attach again, but only a few times.
export const AGENT_VIEW_FOOTER = /enter to return · space to reply/
export const AGENT_VIEW_COUNTS = /\d+ awaiting input · \d+ working · \d+ completed/

// The footer must be on one of the last 3 non-empty lines.
// Text that a conversation quotes higher on the screen does not match.
const FOOTER_LINES = 3

// Spaces and box-drawing characters (U+2500 to U+257F) may frame the footer line.
const FRAME = /^[\s\u2500-\u257f]+|[\s\u2500-\u257f]+$/g

// The footer must fill its line. Text before it, such as a prompt mark, gives no match.
function isFooterLine(line: string): boolean {
  const text = line.replace(FRAME, '')
  const match = AGENT_VIEW_FOOTER.exec(text)
  return match !== null && match.index === 0
}

// A border of the prompt box or a rule line: only box-drawing characters and spaces.
const BORDER = /^[\s\u2500-\u257f]*[\u2500-\u257f][\s\u2500-\u257f]*$/

// In the agent view, the footer is the last non-empty line. A footer line with a border after it
// is in the prompt box. A paste of more than one line puts the footer on a continuation line.
// That line starts with spaces only, so the start rule of isFooterLine does not refuse it.
export function isAgentView(lines: string[]): boolean {
  const filled = lines.filter(line => line.trim() !== '')
  const start = Math.max(0, filled.length - FOOTER_LINES)
  const footer = filled.some(
    (line, i) => i >= start && isFooterLine(line) && !filled.slice(i + 1).some(l => BORDER.test(l)),
  )
  return footer && lines.some(line => AGENT_VIEW_COUNTS.test(line))
}

// One row of the terminal screen. A wrapped row continues the row above it.
export interface ScreenRow {
  text: string
  wrapped: boolean
}

// A narrow terminal wraps the footer into more than one row. This function joins the rows
// of each line. Give the text of each row without a trim, because a wrap can occur at a space.
// The trim of each line occurs after the join.
export function joinWrapped(rows: ScreenRow[]): string[] {
  const lines: string[] = []
  for (const row of rows) {
    if (row.wrapped && lines.length > 0) lines[lines.length - 1] += row.text
    else lines.push(row.text)
  }
  return lines.map(line => line.trimEnd())
}

// Bifrost reads the screen 250 ms after the last chunk. During continuous output, for example
// a spinner, it reads the screen at least each 1000 ms. So input stops soon (D10).
export const AGENT_CHECK_QUIET_MS = 250
export const AGENT_CHECK_MAX_MS = 1000

// The wait before the next check, at the time of a chunk. firstAt is the time of the first
// chunk after the last check.
export function agentCheckDelay(firstAt: number, now: number): number {
  return Math.max(0, Math.min(AGENT_CHECK_QUIET_MS, firstAt + AGENT_CHECK_MAX_MS - now))
}

export const MAX_REATTACH = 3
export const REATTACH_WINDOW_MS = 60_000

// The attaches of the history that are in the window. The owner of a history keeps only these.
export function recentAttaches(history: number[], now: number): number[] {
  return history.filter(at => now - at < REATTACH_WINDOW_MS)
}

// Gives up when the history has MAX_REATTACH or more attaches in the window.
export function reattachDecision(history: number[], now: number): 'reattach' | 'give-up' {
  return recentAttaches(history, now).length >= MAX_REATTACH ? 'give-up' : 'reattach'
}
