import { isAbsolute } from 'node:path'
import type { ExecResult, RunClaude } from '../claude/cli'

export const PLUGIN_NAME = 'bifrost-live'
export const MARKETPLACE_NAME = 'bifrost-local'
export const PLUGIN_ID = 'bifrost-live@bifrost-local'
export const PLUGIN_TIMEOUT_MS = 30_000
// A write command gets SIGTERM at the timeout. Node then waits for the end of the process.
// Bifrost waits this time more. Then the command rejects and frees the serial runner.
export const PLUGIN_GRACE_MS = 10_000
export const TIMEOUT_MESSAGE = "Claude Code didn't finish in 30 seconds."

export interface PluginEntry {
  enabled: boolean
  folder?: string
  errors: string[]
}
export interface MarketplaceEntry {
  source: string
  path?: string
}

// Read the last line of stdout that is not empty as a JSON result of "claude plugin".
// "ok" passes. A plugin that is already in the goal state passes too,
// because enable and disable exit with 1 for it.
// Other results throw an Error with the message of the line, the stderr, or the exit code.
export function checkCliResult(result: ExecResult): void {
  const lines = result.stdout.split('\n').filter(line => line.trim() !== '')
  const last = lines[lines.length - 1]
  let parsed: Record<string, unknown> | null = null
  if (last !== undefined) {
    try {
      const value: unknown = JSON.parse(last)
      if (typeof value === 'object' && value !== null) parsed = value as Record<string, unknown>
    } catch {
      // The last line is not JSON. Use the fallbacks below.
    }
  }
  if (parsed?.outcome === 'ok') return
  if (parsed?.failureCode === 'already_in_goal_state') return
  if (typeof parsed?.message === 'string' && parsed.message !== '') throw new Error(parsed.message)
  // Exit 0 with no usable result line is an error too.
  if (result.code === 0) throw new Error('Claude Code gave no result.')
  const stderr = result.stderr.trim()
  if (stderr !== '') throw new Error(stderr)
  throw new Error(`claude exited with code ${result.code}`)
}

export interface PluginCli {
  plugin(): Promise<PluginEntry | null>
  marketplace(): Promise<MarketplaceEntry | null>
  addMarketplace(dir: string): Promise<void>
  install(): Promise<void>
  enable(): Promise<void>
  disable(): Promise<void>
  uninstall(): Promise<void>
  removeMarketplace(): Promise<void>
}

// Find the JSON array in the output. It starts at the first line that begins with "[".
function readList(result: ExecResult): Record<string, unknown>[] {
  const fail = (): never => {
    throw new Error(`claude plugin list failed: ${result.stderr.trim() || result.code}`)
  }
  if (result.code !== 0) return fail()
  const lines = result.stdout.split('\n')
  const start = lines.findIndex(line => line.startsWith('['))
  if (start === -1) return fail()
  let data: unknown
  try {
    data = JSON.parse(lines.slice(start).join('\n'))
  } catch {
    return fail()
  }
  if (!Array.isArray(data)) return fail()
  return data.filter(
    (item): item is Record<string, unknown> => typeof item === 'object' && item !== null,
  )
}

// The options of a write command. A write command changes the settings or the plugin files.
// A SIGKILL can leave it half done, so it gets SIGTERM (see execFile in claude/cli.ts).
const WRITE_OPTS = { killSignal: 'SIGTERM', timeoutMs: PLUGIN_TIMEOUT_MS } as const

export function createPluginCli(run: RunClaude): PluginCli {
  // The output of a command that the timeout stopped is not complete. So Bifrost does not use it.
  const exec = async (args: string[]): Promise<ExecResult> => {
    const result = await run(args, { timeoutMs: PLUGIN_TIMEOUT_MS })
    if (result.timedOut === true) throw new Error(TIMEOUT_MESSAGE)
    return result
  }
  // Run a write command. A command that has not ended PLUGIN_GRACE_MS after the SIGTERM also
  // rejects with the timeout text.
  const command = async (args: string[]): Promise<void> => {
    let timer: ReturnType<typeof setTimeout> | undefined
    const limit = new Promise<never>((_resolve, reject) => {
      timer = setTimeout(
        () => reject(new Error(TIMEOUT_MESSAGE)),
        PLUGIN_TIMEOUT_MS + PLUGIN_GRACE_MS,
      )
    })
    try {
      const result = await Promise.race([run(args, WRITE_OPTS), limit])
      if (result.timedOut === true) throw new Error(TIMEOUT_MESSAGE)
      checkCliResult(result)
    } finally {
      clearTimeout(timer)
    }
  }
  const scope = ['--scope', 'user', '--json']
  return {
    async addMarketplace(dir) {
      if (!isAbsolute(dir) || /[\r\n]/.test(dir)) {
        throw new Error('The mod folder path must be absolute and have no line break')
      }
      await command(['plugin', 'marketplace', 'add', dir, ...scope])
    },
    disable: () => command(['plugin', 'disable', PLUGIN_ID, ...scope]),
    enable: () => command(['plugin', 'enable', PLUGIN_ID, ...scope]),
    install: () => command(['plugin', 'install', PLUGIN_ID, ...scope]),
    async marketplace() {
      const list = readList(await exec(['plugin', 'marketplace', 'list', '--json']))
      const entry = list.find(item => item.name === MARKETPLACE_NAME)
      if (!entry) return null
      const result: MarketplaceEntry = {
        source: typeof entry.source === 'string' ? entry.source : '',
      }
      if (typeof entry.path === 'string') result.path = entry.path
      return result
    },
    async plugin() {
      const list = readList(await exec(['plugin', 'list', '--json']))
      const entry = list.find(item => item.id === PLUGIN_ID)
      if (!entry) return null
      const result: PluginEntry = {
        enabled: entry.enabled === true,
        errors: Array.isArray(entry.errors)
          ? entry.errors.filter((e): e is string => typeof e === 'string')
          : [],
      }
      if (typeof entry.readFromFolder === 'string') result.folder = entry.readFromFolder
      return result
    },
    removeMarketplace: () =>
      command(['plugin', 'marketplace', 'remove', MARKETPLACE_NAME, ...scope]),
    uninstall: () => command(['plugin', 'uninstall', PLUGIN_ID, ...scope]),
  }
}
