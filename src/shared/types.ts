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
