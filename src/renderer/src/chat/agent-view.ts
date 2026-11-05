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

export function isAgentView(lines: string[]): boolean {
  const tail = lines.filter(line => line.trim() !== '').slice(-FOOTER_LINES)
  return tail.some(isFooterLine) && lines.some(line => AGENT_VIEW_COUNTS.test(line))
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
