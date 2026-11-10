// Types and texts for the auto-updater.
// Main and renderer both import this file. It has no Electron or Node import.

// The releases are in a public repo. So no cause needs a GitHub login.
export type UpdateCause = 'location' | 'download' | 'install' | 'github'

export type UpdateState =
  | { kind: 'idle' } // up to date, or never checked
  | { kind: 'checking' }
  | { kind: 'downloading'; version: string; percent: number }
  | { kind: 'ready'; version: string }
  | { kind: 'failed'; cause: UpdateCause; message: string; at: number }
  // The switch is off, and no check result came after that. The result of a manual check
  // replaces it. A ready update stays ready when the switch goes off.
  | { kind: 'off' }

export interface UpdatesSnapshot {
  // False when this build cannot update (dev, test home, no app-update.yml).
  available: boolean
  state: UpdateState
  lastCheckAt: number | null
  version: string
}

export const EMPTY_UPDATES: UpdatesSnapshot = {
  available: false,
  lastCheckAt: null,
  state: { kind: 'idle' },
  version: '',
}

export const UPDATE_TEXTS = {
  check: 'Check for updates',
  failed: 'Update failed. Click for details.',
  notifyTitle: 'Bifrost update ready',
  ready: (version: string): string => `Bifrost ${version} is available, click to update.`,
  restart: 'Restart to update',
  retry: 'Try again',
  showLog: 'Show log',
  switchLabel: 'Check for updates automatically',
}

// The detail text is already masked by the caller.
export function causeText(cause: UpdateCause, detail: string): string {
  const quoted = detail ? ` The error was "${detail}".` : ''
  switch (cause) {
    case 'location':
      return 'Move Bifrost to the Applications folder to get updates.'
    case 'download':
      return `Bifrost couldn't download the update.${quoted} It will try again.`
    case 'install':
      return `Bifrost couldn't install the update.${quoted} Try again, or download the app from GitHub.`
    case 'github':
      return `Bifrost couldn't check GitHub for updates.${quoted} It will try again.`
  }
}
