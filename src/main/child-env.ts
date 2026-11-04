// The child processes must not see the terminal or the Claude Code session that started Bifrost.
// Claude Code changes its behavior when it sees these variables.
// From Finder, these variables are not set. The child env must be the same in development.
const REMOVED_KEYS = ['CLAUDECODE', 'TERM_PROGRAM', 'TERM_PROGRAM_VERSION', 'TERM_SESSION_ID']
const REMOVED_PREFIXES = ['CLAUDE_CODE_', 'WARP_']

function isRemoved(key: string): boolean {
  return REMOVED_KEYS.includes(key) || REMOVED_PREFIXES.some((p) => key.startsWith(p))
}

// Make the env for a child process from the source env.
// Remove the variables above. Keep all other variables, for example HOME, PATH and LANG.
// For a PTY, set TERM and COLORTERM for xterm.js.
// The function does not change the source env.
export function childEnv(
  source: NodeJS.ProcessEnv,
  opts: { pty: boolean }
): Record<string, string> {
  const env: Record<string, string> = {}
  for (const [key, value] of Object.entries(source)) {
    if (value !== undefined && !isRemoved(key)) env[key] = value
  }
  if (opts.pty) {
    env.TERM = 'xterm-256color'
    env.COLORTERM = 'truecolor'
  }
  return env
}
