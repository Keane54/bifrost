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
// "kept <short id> \u2014 its worktree is still at \u201c<path>\u201d" and a command with
// "--discard-unpushed <value>" (M4 controller check, Claude Code 2.1.318). The value goes into a
// claude argument. So it must be 40 hex digits, "@" and 32 hex digits, and nothing more.
// The source holds no em dash, so the special characters are written as codes.
const DASH = String.fromCharCode(0x2014)
const OPEN_QUOTE = String.fromCharCode(0x201c)
const CLOSE_QUOTE = String.fromCharCode(0x201d)
const KEPT_LINE = new RegExp(
  `^kept ([0-9a-f]{8}) ${DASH} its worktree is still at ${OPEN_QUOTE}([^${OPEN_QUOTE}${CLOSE_QUOTE}]+)${CLOSE_QUOTE}$`,
)
const DISCARD_FLAG = /--discard-unpushed (\S+)/g
const DISCARD_VALUE = /^[0-9a-f]{40}@[0-9a-f]{32}$/

// What a "claude rm" refusal gives: the discard value, and the short ID and the worktree that
// the kept line names.
export interface KeptWorktree {
  discard: string
  shortId: string
  worktree: string
}

// Read a "claude rm" refusal. This gives null for text without exactly one line that starts with
// "kept ", for a kept line of a different form, for text without the flag, for a value of a
// different form and for two different values.
export function parseKept(stdout: string): KeptWorktree | null {
  const lines = stdout.split('\n')
  const keptLines = lines.filter(line => line.startsWith('kept '))
  if (keptLines.length !== 1) return null
  const kept = KEPT_LINE.exec(keptLines[0] as string)
  if (kept === null) return null
  const values = new Set<string>()
  for (const line of lines) {
    for (const match of line.matchAll(DISCARD_FLAG)) values.add(match[1] as string)
  }
  if (values.size !== 1) return null
  const [value] = values
  if (!DISCARD_VALUE.test(value)) return null
  return { discard: value, shortId: kept[1] as string, worktree: kept[2] as string }
}

// The short ID and the worktree that a kept line names.
export interface KeptChanges {
  shortId: string
  worktree: string
}

// "claude rm" keeps a worktree with changes that are not committed. Then it prints the kept line
// first and the text "The worktree has uncommitted changes" (Task 17 bug 2). It prints no
// --discard-unpushed value, and Claude Code has no command that deletes such a worktree.
const CHANGES_TEXT = 'The worktree has uncommitted changes'

// Read a "claude rm" refusal for changes that are not committed. This gives null when the first
// line is not a kept line of the correct form, when another line starts with "kept ", and for
// text without the changes text.
export function parseKeptChanges(stdout: string): KeptChanges | null {
  const lines = stdout.split('\n')
  if (lines.filter(line => line.startsWith('kept ')).length !== 1) return null
  const kept = KEPT_LINE.exec(lines[0] as string)
  if (kept === null) return null
  if (!lines.slice(1).some(line => line.includes(CHANGES_TEXT))) return null
  return { shortId: kept[1] as string, worktree: kept[2] as string }
}

// The raw text of a failed command: the stderr, else the stdout, or '' when both are empty.
// The stderr does not count when it has only the start line of the background service.
function rawText(result: ExecResult): string {
  const stderr = result.stderr
    .split('\n')
    .filter(line => !SERVICE_BANNER.test(line.trim()))
    .join('\n')
    .trim()
  return (stderr || result.stdout.trim()).slice(0, MAX_FAILURE)
}

// The text of a failed command: the raw text, else the exit code.
export function failure(result: ExecResult, what: string): string {
  return rawText(result) || `${what} failed with code ${result.code}`
}

// The lead sentence before a raw text of claude (final review M5).
const CLAUDE_REPORTED = 'Claude Code reported a problem:'
// Node gives this text when a signal ended a command. It is not a text of claude. The app gives
// a friendly text for it (errors.ts).
const NODE_FAILED = 'Command failed:'

// The text of a failed claude command. A raw text of claude gets the lead sentence, so the user
// knows that the text comes from Claude Code. The text of the exit code and the Node text get no
// lead sentence.
export function claudeFailure(result: ExecResult, what: string): string {
  const raw = rawText(result)
  if (raw === '') return `${what} failed with code ${result.code}`
  if (raw.startsWith(NODE_FAILED)) return raw
  return `${CLAUDE_REPORTED} ${raw}`
}
