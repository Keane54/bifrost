// The texts and the rules of the setup dialog and Settings > Live details (spec 11, D10, D11).
// The functions are pure, so the tests can check each rule.
import type { Settings } from '../../../shared/settings'
import type { ClaudeVersion, LiveStatus } from '../../../shared/types'
import type { ConfirmText } from '../actions/confirm'
import { friendlyError } from '../actions/errors'

// A copy of RELOAD_NOTE in src/main/live/live-control.ts. The renderer does not import main code.
export const RELOAD_NOTE =
  'Sessions that run now get the change after /reload-plugins or a restart.'

// The setup dialog and the Live details section both show this text (D-8).
export const WITHOUT_LIVE =
  'Without Live details, Bifrost still lists your sessions and shows their boxes from the session list, a little later, but with no model, context % or cost. You can turn it on later in Settings > Live details.'

export const SETUP_INTRO =
  "Live details lets Bifrost see each session as it happens: a box the moment Claude finishes or needs you, plus the model, context % and cost. It's a small Claude Code plugin that sends events to Bifrost on this Mac. Bifrost makes these changes only if you turn it on:"

export const REMOVE_CONFIRM: ConfirmText = {
  body: 'Bifrost turns off Live details, removes the plugin and the folder ~/.bifrost/mod, and removes any old Bifrost hooks (with a backup first).',
  confirm: 'Remove',
  title: 'Remove Live details',
}

// The minimum version of Live details is 2.1.290 (LIVE_MIN_CLAUDE_VERSION, spec 11.5).
export const LIVE_VERSION_NOTE = 'Live details needs Claude Code 2.1.290 or later.'

const NOT_CHECKED = "Bifrost couldn't check Live details."
const NOT_RECEIVING =
  "Live details is on, but Bifrost isn't receiving it. Try Turn off, then Turn on."
const FILES_DIFFER =
  "Live details uses files that don't match this Bifrost. Remove it, then install it again."
const OLD_INSTALL =
  'Bifrost found its old hooks in ~/.claude/settings.json. Install or Turn on removes them first and saves a backup.'
const STEP_OLD_HOOKS =
  "Remove Bifrost's old hooks and statusLine wrapper from ~/.claude/settings.json. Your other hooks stay, and Bifrost saves a backup first."
const STEP_COPY = 'Copy the Live details plugin files to the folder ~/.bifrost/mod.'
const STEP_PLUGIN =
  'Add that folder as the plugin marketplace "bifrost-local", then install the plugin "bifrost-live" for your user with claude plugin.'

export type LiveNotice =
  | { kind: 'loading' }
  | { kind: 'not-installed' }
  | { kind: 'off' }
  | { kind: 'on'; sessions: number }
  | { kind: 'problem'; message: string }

// The state of Live details for the user (D11). A null status is still loading.
export function liveNotice(status: LiveStatus | null): LiveNotice {
  if (status === null) return { kind: 'loading' }
  switch (status.plugin) {
    case 'unknown':
      return { kind: 'problem', message: status.error ?? NOT_CHECKED }
    case 'not-installed':
      return { kind: 'not-installed' }
    case 'disabled':
      return { kind: 'off' }
    case 'enabled':
      if (!status.listening) return { kind: 'problem', message: status.error ?? NOT_RECEIVING }
      if (!status.modCurrent) return { kind: 'problem', message: FILES_DIFFER }
      return { kind: 'on', sessions: status.liveSessions }
  }
}

// The status when the status call fails. The notice then shows the reason and Try again.
export function unknownStatus(message: string): LiveStatus {
  return {
    claudeVersion: null,
    error: message,
    listening: false,
    liveSessions: 0,
    modCurrent: false,
    oldInstall: false,
    plugin: 'unknown',
    versionOk: false,
  }
}

// The note for an old hook install, or null.
export function oldInstallNote(status: LiveStatus | null): string | null {
  return status?.oldInstall === true ? OLD_INSTALL : null
}

// The changes of Install, in the order that Install makes them (spec 11.1, 11.2).
export function liveSteps(status: LiveStatus): string[] {
  return [...(status.oldInstall ? [STEP_OLD_HOOKS] : []), STEP_COPY, STEP_PLUGIN]
}

// The general warning for the version of Claude Code (spec 11.5). The minimum is 2.1.281.
// A null version is still loading.
export function versionNotice(version: ClaudeVersion | null): string | null {
  if (version === null || version.ok) return null
  if (version.version === null) return friendlyError('claude not found')
  return `Claude Code ${version.version} is older than ${version.minimum}, which Bifrost needs. Please update Claude Code.`
}

// The warning for a version of Claude Code below the minimum of Live details (ruling C5).
// With no version, versionNotice already says that Bifrost can't find Claude Code.
export function liveVersionNote(status: LiveStatus | null): string | null {
  if (status === null || status.versionOk || status.claudeVersion === null) return null
  return LIVE_VERSION_NOTE
}

// True when Bifrost has a warning about Live details or Claude Code. The side bar Settings
// button then shows a dot (D11). An old version for Live details counts only while the plugin
// is installed. After Skip, Live details off is the choice of the user.
export function hasWarning(status: LiveStatus | null, version: ClaudeVersion | null): boolean {
  if (liveNotice(status).kind === 'problem') return true
  if (oldInstallNote(status) !== null || versionNotice(version) !== null) return true
  return setupChosen(status) && liveVersionNote(status) !== null
}

// The state line of the Live details section.
export function liveStateLine(notice: LiveNotice): string {
  switch (notice.kind) {
    case 'loading':
      return 'Checking Live details...'
    case 'not-installed':
      return 'Not installed.'
    case 'off':
      return 'Off.'
    case 'on':
      return notice.sessions === 1
        ? 'On. 1 session is sending live details.'
        : `On. ${notice.sessions} sessions are sending live details.`
    case 'problem':
      return notice.message
  }
}

// The buttons of the Live details section. retry loads the status again.
export type LiveActionId = 'install' | 'enable' | 'disable' | 'remove' | 'retry'

export function liveActions(status: LiveStatus | null): LiveActionId[] {
  if (status === null) return []
  switch (status.plugin) {
    case 'unknown':
      return ['retry']
    case 'not-installed':
      return ['install']
    case 'disabled':
      return ['enable', 'remove']
    case 'enabled':
      return liveNotice(status).kind === 'on'
        ? ['disable', 'remove']
        : ['disable', 'enable', 'remove']
  }
}

// The setup dialog shows before the first choice, when the plugin is not installed or its state
// is unknown (D10). An unknown state shows the dialog with the problem.
export function shouldShowSetup(
  settings: Pick<Settings, 'setupDone'>,
  status: LiveStatus | null,
): boolean {
  if (settings.setupDone || status === null) return false
  return status.plugin === 'not-installed' || status.plugin === 'unknown'
}

// An installed plugin, on or off, is already a choice. Then setup is done with no dialog.
export function setupChosen(status: LiveStatus | null): boolean {
  return status !== null && (status.plugin === 'enabled' || status.plugin === 'disabled')
}
