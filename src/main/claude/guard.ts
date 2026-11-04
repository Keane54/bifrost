import type { AgentEntry } from './agents'

// Every test session has a name that starts with this prefix.
export const TEST_PREFIX = 'bifrost-test-'

// Return true only if exactly one entry has this PID
// and the name of that entry starts with TEST_PREFIX.
export function canSignal(entries: AgentEntry[], pid: number): boolean {
  const matches = entries.filter((e) => e.pid === pid)
  return matches.length === 1 && matches[0].name.startsWith(TEST_PREFIX)
}

const RESUME_FLAGS = ['-r', '--resume', '-c', '--continue']

// Return true if the args name one test session and cannot reach another.
// Only one --name is allowed. Resume and continue flags are not allowed.
function hasSafeTestName(args: string[]): boolean {
  if (args.some((a) => RESUME_FLAGS.includes(a))) return false
  if (
    args.some(
      (a) => a.startsWith('--name=') || a.startsWith('--resume=') || a.startsWith('--continue=')
    )
  )
    return false
  const names = args.map((a, i) => (a === '--name' ? i : -1)).filter((i) => i >= 0)
  if (names.length !== 1) return false
  const value = args[names[0] + 1]
  return typeof value === 'string' && value.startsWith(TEST_PREFIX)
}

// Decide if the main process may open a PTY with these args.
// Allowed: attach to one test session, or an interactive start of a test session.
export function canOpenPty(entries: AgentEntry[], args: string[]): boolean {
  if (args[0] === 'attach') {
    if (args.length !== 2) return false
    const target = args[1]
    const matches = entries.filter(
      (e) => e.id === target || e.name === target || e.sessionId === target
    )
    return matches.length === 1 && matches[0].name.startsWith(TEST_PREFIX)
  }
  return hasSafeTestName(args)
}

// Decide if the main process may run claude with these args.
// Allowed: a background start of a test session. Nothing else.
export function canRunClaude(args: string[]): boolean {
  return args[0] === '--bg' && hasSafeTestName(args)
}
