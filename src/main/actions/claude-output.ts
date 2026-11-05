// Read the output of the claude commands that the session actions run.
import type { ExecResult } from '../claude/cli'

// A short ID goes into the claude arguments. Accept only 8 hex digits.
export const SHORT_ID = /^[0-9a-f]{8}$/

// "claude --bg" prints "backgrounded · <short id> · <name>" (M0, M4 Task 1).
// The "·" is U+00B7.
const BACKGROUNDED = /backgrounded · ([0-9a-f]{8})\b/

// The text of the trust error of "claude --bg" (M0).
const TRUST_ERROR = /Workspace not trusted/

// The longest failure text that an action gives.
const MAX_FAILURE = 300

// The short ID that "claude --bg" printed, or null.
export function parseShortId(text: string): string | null {
  return BACKGROUNDED.exec(text)?.[1] ?? null
}

export function isTrustError(text: string): boolean {
  return TRUST_ERROR.test(text)
}

// The instruction for the trust error (spec 8.9).
export function trustMessage(dir: string): string {
  return `This directory is not trusted. Run claude in ${dir} one time and accept the trust prompt. Then try again.`
}

// The first start of the background service writes this line to stderr (M0, M4 Task 1).
// It is not an error.
const SERVICE_BANNER = /^Starting background service/

// The text of a failed claude command: the stderr, else the stdout, else the exit code.
// The stderr does not count when it has only the start line of the background service.
export function failure(result: ExecResult, what: string): string {
  const stderr = result.stderr
    .split('\n')
    .filter(line => !SERVICE_BANNER.test(line.trim()))
    .join('\n')
    .trim()
  const text = stderr || result.stdout.trim() || `${what} failed with code ${result.code}`
  return text.slice(0, MAX_FAILURE)
}
