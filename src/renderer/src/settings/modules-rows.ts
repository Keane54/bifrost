// The texts of Settings > Modules and of Heimdall's approval view (plan Task 9). MODULES_ROWS is
// the one source of the button labels: the section uses it, and the search of Settings finds the
// section by it. PERMISSION_LABELS is Bifrost's own text for each permission. The module only
// adds its reason.
import type { PermissionId } from '../../../shared/module-manifest'
import type { ModuleRow, ModuleUpdateResult } from '../../../shared/modules'
import { friendlyError } from '../actions/errors'

export const MODULES_ROWS = {
  checkUpdates: 'Check for updates',
  installDev: 'Load from folder (developer)',
  installFolder: 'Install from a folder',
  installGit: 'Install from a git repo',
} as const

export const MODULES_EMPTY = "You haven't installed any modules yet."

// The user-facing name of a Claude job of a module is "module job" (ruling P6).
export const PERMISSION_LABELS: Readonly<Record<PermissionId, string>> = {
  'claude-jobs': 'Run module jobs (short Claude runs with no tools)',
  'claude-jobs-auto': 'Run module jobs automatically',
  discuss: 'Ask you to start a Claude session (you always write the prompt)',
  notify: 'Show notifications',
  'read-service-status': 'Read the service status',
  'read-sessions': 'Read your session list (names, states, folders, branches and PR links)',
  'read-usage': 'Read your plan usage',
}

const WORDS = ['zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine']

// A count from 0 to 9 as a word, else as digits.
export function countWord(n: number): string {
  return Number.isInteger(n) && n >= 0 && n < WORDS.length ? WORDS[n] : String(n)
}

// "one new permission", "two new permissions".
export function newPermissionsText(n: number): string {
  return n === 1 ? 'one new permission' : `${countWord(n)} new permissions`
}

// The line of an update that waits for the user (Modules design 7), or null. The new code of a
// dev module already runs in place, with the old permissions, so its line says so.
export function pendingUpdateLine(row: ModuleRow): string | null {
  const pending = row.pendingUpdate
  if (pending === null) return null
  const n = pending.added.length
  if (row.dev) {
    const more = n === 1 ? 'one more permission' : `${countWord(n)} more permissions`
    return `This module's new version asks for ${more}. Allow it to keep using the module.`
  }
  const what = newPermissionsText(n)
  return `v${pending.version} needs ${what}. You'll keep using v${row.version} until you allow it.`
}

export function jobsTodayText(count: number): string {
  return count === 1 ? '1 module job today' : `${count} module jobs today`
}

// The source of a row as the row shows it: a folder, or the GitHub address with no https://.
export function sourceLabel(row: ModuleRow): string {
  return row.source.replace(/^https:\/\//, '')
}

// One line after Check for updates. The key is the module id, or a fixed word for the line of
// all modules, so each key is unique.
export interface CheckUpdateNote {
  key: string
  text: string
}

// The line of one result of Check for updates, or null for a module with no change.
function checkUpdateLine(r: ModuleUpdateResult): string | null {
  if (r.outcome === 'failed') return `Bifrost couldn't check ${r.name}. ${friendlyError(r.reason)}`
  if (r.outcome === 'updated') return `${r.name} is now on v${r.version}.`
  if (r.outcome === 'waiting') return `${r.name} v${r.version} needs your OK before it runs.`
  return null
}

// The lines after Check for updates. A module with no change gets no line.
export function checkUpdateNotes(results: readonly ModuleUpdateResult[]): CheckUpdateNote[] {
  if (results.length === 0) return [{ key: 'none', text: 'You have no modules to check.' }]
  const notes = results.flatMap(r => {
    const text = checkUpdateLine(r)
    return text === null ? [] : [{ key: r.id, text }]
  })
  return notes.length === 0 ? [{ key: 'all', text: 'All your modules are up to date.' }] : notes
}

export function checkUpdateLines(results: readonly ModuleUpdateResult[]): string[] {
  return checkUpdateNotes(results).map(note => note.text)
}

// The words of the section for the search of Settings: the buttons and the names of the modules.
// Load from folder (developer) is left out, because a packaged app does not show it.
export function modulesSearchWords(modules: readonly ModuleRow[]): string[] {
  return [
    MODULES_ROWS.installFolder,
    MODULES_ROWS.installGit,
    MODULES_ROWS.checkUpdates,
    'Permissions',
    ...modules.map(m => m.name),
  ]
}
