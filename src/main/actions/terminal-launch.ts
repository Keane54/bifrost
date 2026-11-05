// Open in terminal (spec 9.1, D7).
// An owned session attaches in the terminal app of the user. An external session brings its
// own terminal app to the front. The renderer sends the session ID only.
import { join } from 'node:path'
import type { SessionRow } from '../../shared/types'
import type { ExecFn } from '../claude/cli'
import type { TerminalApp } from '../registry/terminal-app'
import { OPEN } from './actions'
import { failure, SHORT_ID } from './claude-output'
import { type InstalledApp, TERMINAL_ORDER } from './project-apps'
import { NO_CLAUDE } from './session-actions'

export type TerminalId = 'warp' | 'ghostty' | 'iterm2' | 'terminal'
type LaunchMethod = 'command-file' | 'clipboard'

// How Bifrost starts the attach command in each terminal app (M4 Task 1 ruling).
export const LAUNCH: Record<TerminalId, LaunchMethod> = {
  ghostty: 'clipboard',
  iterm2: 'clipboard',
  terminal: 'command-file',
  warp: 'command-file',
}

// The command file stays this long. Then Bifrost removes it.
export const SCRIPT_KEEP_MS = 30_000

const OPEN_TIMEOUT_MS = 10_000

const REFUSED_UNKNOWN = 'refused: unknown session'
const REFUSED_PARKED = 'refused: the session is parked'
const REFUSED_BAD_ID = 'refused: bad session ID'
const REFUSED_NO_TERMINAL = 'refused: no terminal app is installed'
const REFUSED_NO_APP = 'refused: the terminal app of the session is not known'

export interface TerminalLauncherDeps {
  rows(): SessionRow[]
  apps(): Promise<InstalledApp[]>
  terminalOf(sessionId: string): TerminalApp | undefined
  // The claude path, or null when Bifrost cannot find claude.
  claudePath(): Promise<string | null>
  exec: ExecFn
  writeScript(file: string, text: string): Promise<void>
  remove(file: string): Promise<void>
  writeClipboard(text: string): void
  // The icon of the app bundle as a data URL, or null.
  fileIcon(path: string): Promise<string | null>
  runDir: string
}

export interface TerminalLauncher {
  openInTerminal(sessionId: unknown): Promise<{ notice: string | null }>
  terminalIcon(sessionId: unknown): Promise<string | null>
}

// The shell script of the command file. A quote in the path becomes '\''.
export function attachScript(claudePath: string, shortId: string): string {
  return `#!/bin/sh\nexec '${claudePath.replaceAll("'", "'\\''")}' attach ${shortId}\n`
}

export function attachCommand(shortId: string): string {
  return `claude attach ${shortId}`
}

export function createTerminalLauncher(
  deps: TerminalLauncherDeps,
  launch: Record<TerminalId, LaunchMethod> = LAUNCH,
): TerminalLauncher {
  // The icon of each bundle. A null result stays in the cache, so Bifrost asks one time.
  const icons = new Map<string, Promise<string | null>>()

  const find = (sessionId: unknown): SessionRow => {
    const row = deps.rows().find(r => r.sessionId === sessionId)
    if (!row) throw new Error(REFUSED_UNKNOWN)
    return row
  }

  const openOwned = async (row: SessionRow): Promise<{ notice: string | null }> => {
    if (row.shortId === undefined || !SHORT_ID.test(row.shortId)) throw new Error(REFUSED_BAD_ID)
    const shortId = row.shortId
    const installed = await deps.apps()
    const app = TERMINAL_ORDER.map(id => installed.find(a => a.id === id)).find(a => a)
    if (!app) throw new Error(REFUSED_NO_TERMINAL)

    if (launch[app.id as TerminalId] === 'command-file') {
      const path = await deps.claudePath()
      if (!path) throw new Error(NO_CLAUDE)
      const file = join(deps.runDir, `attach-${shortId}.command`)
      await deps.writeScript(file, attachScript(path, shortId))
      // The timer must not keep the process alive.
      const timer = setTimeout(() => {
        deps.remove(file).catch(() => {})
      }, SCRIPT_KEEP_MS)
      timer.unref?.()
      const result = await deps.exec(OPEN, ['-a', app.path, file], { timeoutMs: OPEN_TIMEOUT_MS })
      if (result.code !== 0) throw new Error(failure(result, 'open'))
      return { notice: null }
    }

    const command = attachCommand(shortId)
    deps.writeClipboard(command)
    const result = await deps.exec(OPEN, ['-a', app.path])
    if (result.code !== 0) throw new Error(failure(result, 'open'))
    return {
      notice: `Copied "${command}". Paste it into ${app.label} to open the session.`,
    }
  }

  return {
    async openInTerminal(sessionId) {
      const row = find(sessionId)
      if (row.state === 'parked') throw new Error(REFUSED_PARKED)
      if (row.kind === 'owned') return openOwned(row)
      const terminal = deps.terminalOf(row.sessionId)
      if (!terminal) throw new Error(REFUSED_NO_APP)
      const result = await deps.exec(OPEN, ['-a', terminal.bundle])
      if (result.code !== 0) throw new Error(failure(result, 'open'))
      return { notice: null }
    },

    async terminalIcon(sessionId) {
      const row = deps.rows().find(r => r.sessionId === sessionId)
      if (row?.kind !== 'external') return null
      const terminal = deps.terminalOf(row.sessionId)
      if (!terminal) return null
      let icon = icons.get(terminal.bundle)
      if (!icon) {
        icon = deps.fileIcon(terminal.bundle)
        icons.set(terminal.bundle, icon)
      }
      return icon
    },
  }
}
