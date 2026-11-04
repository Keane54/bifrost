// Types that the main process and the renderer share.

export interface IntegrationStatus {
  // True when no hook is missing, Bifrost set the wrapper and both scripts exist.
  installed: boolean
  missingHooks: string[]
  statusLineInstalled: boolean
  scriptsPresent: boolean
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

// The state of one session row.
export type SessionState = 'working' | 'needs-you' | 'error' | 'idle' | 'parked'

// The box of a row. Yellow: Claude finished. Red: Claude needs the user.
export type Box = 'none' | 'yellow' | 'red'
