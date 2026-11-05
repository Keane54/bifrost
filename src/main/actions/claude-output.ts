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
  return `Claude Code doesn't trust this folder yet. Run claude in ${dir} once, accept the trust prompt, then try again.`
}

// The first start of the background service writes this line to stderr (M0, M4 Task 1).
// It is not an error.
const SERVICE_BANNER = /^Starting background service/

// "claude rm" keeps a worktree that has commits on no remote. Then it exits 1 and prints a line
// that starts with "kept <short id>" and a command with "--discard-unpushed <value>"
// (M4 controller check, Claude Code 2.1.318). The value goes into a claude argument. So it must
// be 40 hex digits, "@" and 32 hex digits, and nothing more.
const KEPT_LINE = /^kept /
const DISCARD_FLAG = /--discard-unpushed (\S+)/g
const DISCARD_VALUE = /^[0-9a-f]{40}@[0-9a-f]{32}$/

// The discard value of a "claude rm" refusal, or null. Text without a kept line, without the
// flag, with a value of a different form or with two different values gives null.
export function parseKept(stdout: string): { discard: string } | null {
  const lines = stdout.split('\n')
  if (!lines.some(line => KEPT_LINE.test(line))) return null
  const values = new Set<string>()
  for (const line of lines) {
    for (const match of line.matchAll(DISCARD_FLAG)) values.add(match[1] as string)
  }
  if (values.size !== 1) return null
  const [value] = values
  return DISCARD_VALUE.test(value) ? { discard: value } : null
}

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
