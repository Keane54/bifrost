import type { AgentEntry } from './agents'

// Every test session has a name that starts with this prefix.
export const TEST_PREFIX = 'bifrost-test-'

// Return true only if exactly one entry has this PID
// and the name of that entry starts with TEST_PREFIX.
export function canSignal(entries: AgentEntry[], pid: number): boolean {
  const matches = entries.filter((e) => e.pid === pid)
  return matches.length === 1 && matches[0].name.startsWith(TEST_PREFIX)
}

// The guard accepts only these flags. Each flag takes one value in the next arg.
const VALUE_FLAGS = ['--model', '--name', '--permission-mode']

// Claude Code reads these words as subcommands. A flag value must not be one of them.
const VERBS = [
  'logs',
  'attach',
  'stop',
  'kill',
  'respawn',
  'rm',
  'agents',
  'update',
  'mcp',
  'plugin',
  'doctor',
  'install',
  'config'
]

// A model or permission mode value is one word of letters, digits and . _ : [ ] -.
// It starts with a letter or a digit, so it cannot be a flag.
const SAFE_VALUE = /^[A-Za-z0-9][A-Za-z0-9._:[\]-]*$/

function isSafeValue(value: string): boolean {
  return SAFE_VALUE.test(value) && !VERBS.includes(value)
}

// A prompt does not start with a dash, so claude cannot read it as a flag.
// A prompt has a space between two words, so claude cannot read it as a subcommand.
function isPrompt(arg: string): boolean {
  return !arg.startsWith('-') && /\s/.test(arg.trim())
}

// Return true only if the args start one test session and do nothing else.
// The args must be the allowed flags with their values, in any order.
// Each flag can occur one time. --name is necessary and must be a test name.
// If bg is true, --bg must be the first arg.
// If prompt is true, the last arg can be one prompt.
function isTestStart(args: unknown, rules: { bg: boolean; prompt: boolean }): boolean {
  if (!Array.isArray(args) || !args.every((a) => typeof a === 'string')) return false
  let i = 0
  if (rules.bg) {
    if (args[0] !== '--bg') return false
    i = 1
  }
  const seen: string[] = []
  while (i < args.length) {
    const arg = args[i]
    if (VALUE_FLAGS.includes(arg)) {
      if (seen.includes(arg)) return false
      seen.push(arg)
      const value: string | undefined = args[i + 1]
      if (value === undefined) return false
      const ok = arg === '--name' ? value.startsWith(TEST_PREFIX) : isSafeValue(value)
      if (!ok) return false
      i += 2
    } else {
      // Any other arg must be the prompt, and the prompt must be the last arg.
      if (!rules.prompt || i !== args.length - 1 || !isPrompt(arg)) return false
      i += 1
    }
  }
  return seen.includes('--name')
}

// Decide if the main process may open a PTY with these args.
// Allowed: "attach <target>" for one test session, or an interactive start of a test session.
// The interactive start accepts only --model, --name and --permission-mode. It has no prompt.
export function canOpenPty(entries: AgentEntry[], args: string[]): boolean {
  if (!Array.isArray(args)) return false
  if (args[0] === 'attach') {
    if (args.length !== 2) return false
    const target = args[1]
    if (typeof target !== 'string' || target === '') return false
    const matches = entries.filter(
      (e) => e.id === target || e.name === target || e.sessionId === target
    )
    return matches.length === 1 && matches[0].name.startsWith(TEST_PREFIX)
  }
  return isTestStart(args, { bg: false, prompt: false })
}

// Decide if the main process may run claude with these args.
// Allowed: a background start of a test session. Nothing else.
// The start accepts --bg first, then --model, --name and --permission-mode, then one prompt.
export function canRunClaude(args: string[]): boolean {
  return isTestStart(args, { bg: true, prompt: true })
}
