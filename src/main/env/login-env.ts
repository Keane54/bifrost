import type { ExecFn } from '../claude/cli'

export const ENV_MARKER = '__BIFROST_ENV__'

const SHELL_TIMEOUT_MS = 5000
// The login shell gets only these variables from the app.
const SHELL_KEYS = ['HOME', 'USER', 'LOGNAME', 'SHELL', 'LANG', 'TMPDIR']
// These two variables are for the helper only. They must not reach the result.
const HELPER_KEYS = ['BIFROST_NODE', 'ELECTRON_RUN_AS_NODE']

// The script prints the env as JSON between two markers.
// The shell can print a banner or other text outside the markers.
// BIFROST_NODE is the binary of the app. ELECTRON_RUN_AS_NODE makes it run as Node.
const SCRIPT = `printf '%s' '${ENV_MARKER}'; "$BIFROST_NODE" -e 'process.stdout.write(JSON.stringify(process.env))'; printf '%s' '${ENV_MARKER}'`

function stringValues(source: NodeJS.ProcessEnv): Record<string, string> {
  const env: Record<string, string> = {}
  for (const [key, value] of Object.entries(source)) {
    if (typeof value === 'string') env[key] = value
  }
  return env
}

// Read the JSON between the first two markers.
// Return null if a marker is missing, the JSON is bad, or the JSON is not an object.
// Return null also if a value is not a string, or if the env has no PATH.
export function parseLoginEnvOutput(stdout: string): Record<string, string> | null {
  const start = stdout.indexOf(ENV_MARKER)
  if (start === -1) return null
  const from = start + ENV_MARKER.length
  const end = stdout.indexOf(ENV_MARKER, from)
  if (end === -1) return null
  try {
    const parsed: unknown = JSON.parse(stdout.slice(from, end))
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return null
    const env: Record<string, string> = {}
    for (const [key, value] of Object.entries(parsed)) {
      if (typeof value !== 'string') return null
      env[key] = value
    }
    // An env without PATH is not usable.
    return typeof env.PATH === 'string' ? env : null
  } catch {
    return null
  }
}

// Get the env of an interactive login shell.
// The app can start from Finder, so its env has the short launchd PATH.
// The first claude call can start the shared background service.
// Each background session gets the env of that service.
// On any failure, return a copy of the fallback env.
export async function loadLoginEnv(
  exec: ExecFn,
  opts: { execPath: string; fallback: NodeJS.ProcessEnv; shell?: string },
): Promise<Record<string, string>> {
  const shell = opts.shell ?? opts.fallback.SHELL ?? '/bin/zsh'
  const env: Record<string, string> = {}
  for (const key of SHELL_KEYS) {
    const value = opts.fallback[key]
    if (typeof value === 'string') env[key] = value
  }
  env.BIFROST_NODE = opts.execPath
  env.ELECTRON_RUN_AS_NODE = '1'
  const result = await exec(shell, ['-lic', SCRIPT], { env, timeoutMs: SHELL_TIMEOUT_MS })
  const parsed = result.code === 0 ? parseLoginEnvOutput(result.stdout) : null
  if (!parsed) return stringValues(opts.fallback)
  for (const key of HELPER_KEYS) delete parsed[key]
  return parsed
}
