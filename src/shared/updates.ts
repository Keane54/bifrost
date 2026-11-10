// Types and texts for the auto-updater.
// Main and renderer both import this file. It has no Electron or Node import.

export type UpdateCause =
  | 'gh-missing'
  | 'gh-logged-out'
  | 'no-access'
  | 'location'
  | 'download'
  | 'install'
  | 'github'

export type UpdateState =
  | { kind: 'idle' } // up to date, or never checked
  | { kind: 'checking' }
  | { kind: 'downloading'; version: string; percent: number }
  | { kind: 'ready'; version: string }
  | { kind: 'failed'; cause: UpdateCause; message: string; at: number }
  | { kind: 'off' } // switch off and nothing ready

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

const SIGN_IN = 'Sign in with gh auth login to get updates.'

// The detail text is already masked by the caller.
export function causeText(cause: UpdateCause, detail: string): string {
  const quoted = detail ? ` The error was "${detail}".` : ''
  switch (cause) {
    case 'gh-missing':
      return `Install the GitHub CLI (gh) first. ${SIGN_IN}`
    case 'gh-logged-out':
      return SIGN_IN
    case 'location':
      return 'Move Bifrost to the Applications folder to get updates.'
    case 'no-access':
      return "Your GitHub account can't read the Bifrost releases."
    case 'download':
      return `Bifrost couldn't download the update.${quoted} It will try again.`
    case 'install':
      return `Bifrost couldn't install the update.${quoted} Try again, or download the app from GitHub.`
    case 'github':
      return `Bifrost couldn't check GitHub for updates.${quoted} It will try again.`
  }
}
