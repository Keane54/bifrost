// Types that the main process and the renderer share.

export interface IntegrationStatus {
  // True when no hook is missing, Bifrost set the wrapper and both scripts are current.
  installed: boolean
  missingHooks: string[]
  statusLineInstalled: boolean
  scriptsPresent: boolean
  // True when both scripts have the text that an install writes now.
  scriptsCurrent: boolean
  error?: string
}

export interface InstallPreview {
  changes: string[]
  backupPath: string | null
  originalCommand: string | null
}

export interface ClaudeVersion {
  // The version that claude reports, or null when it did not report one.
  version: string | null
  // True when the version is at least the minimum.
  ok: boolean
  minimum: string
}

// The size of a terminal in cells.
export interface TermSize {
  cols: number
  rows: number
}

// The state of one session row.
export type SessionState = 'working' | 'needs-you' | 'error' | 'idle' | 'parked'

// The box of a row. Yellow: Claude finished. Red: Claude needs the user.
export type Box = 'none' | 'yellow' | 'red'

// Owned: the supervisor runs the session in the background. External: a terminal app owns it.
export type SessionKind = 'owned' | 'external'

// The priority of a session. 1 is the highest.
export type Priority = 1 | 2 | 3 | 4 | 5

// One row of the session list. The main process sends rows to the renderer.
export interface SessionRow {
  sessionId: string
  shortId?: string
  name: string
  kind: SessionKind
  pid?: number
  cwd: string
  status: string
  waitingFor?: string
  state: SessionState
  box: Box
  boxSince: number | null
  // True when the box is not 'none' and nobody acknowledged it.
  flashing: boolean
  lastMessage?: string
  lastActivity: number
  startedAt: number
  model?: string
  contextPercent?: number
  costUsd?: number
  branch?: string
  priority?: Priority
}

// How the Bifrost window shows on the screen.
// borderless is the simple full screen of macOS. fullscreen is the native full screen.
export type DisplayMode = 'window' | 'borderless' | 'fullscreen'

// An app that can open the project directory of a session.
export type ProjectAppId = 'finder' | 'vscode' | 'zed' | 'warp' | 'ghostty' | 'iterm2' | 'terminal'

export interface ProjectApp {
  id: ProjectAppId
  label: string
}
