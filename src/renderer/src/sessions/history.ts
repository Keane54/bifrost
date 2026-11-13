// The dialog history: recent folders, the last model and mode, and recent slash commands.
// The UI store keeps it in ui-state.json (spec 8.9, 9.6).
import {
  MODEL_CHOICES,
  type ModelChoice,
  type NewSessionSpec,
  PERMISSION_MODES,
} from '../../../shared/new-session'
import { isRecord } from '../../../shared/plain-object'
import { checkSlashCommand } from '../../../shared/settings'
import type { SessionRow } from '../../../shared/types'
import { repoPath } from '../overview/format'

export interface History {
  recentDirs: string[]
  model: ModelChoice
  permissionMode: string
  recentSlash: string[]
}

export const EMPTY_HISTORY: History = {
  model: '',
  permissionMode: '',
  recentDirs: [],
  recentSlash: [],
}
export const MAX_RECENT_DIRS = 10
export const MAX_RECENT_SLASH = 8

// checkSlashCommand gives the rules. A stored command also has no space at the start or the end.
function validSlash(text: string): boolean {
  const check = checkSlashCommand(text)
  return check.ok && check.text === text
}

// Keep the first values that pass the check. Each value stays one time.
function clean(value: unknown, ok: (text: string) => boolean, max: number): string[] {
  const out: string[] = []
  if (!Array.isArray(value)) return out
  for (const item of value) {
    if (out.length >= max) break
    if (typeof item === 'string' && ok(item) && !out.includes(item)) out.push(item)
  }
  return out
}

// Check data that the renderer read from ui-state.json. Wrong values are dropped.
export function parseHistory(data: unknown): History {
  if (!isRecord(data)) return EMPTY_HISTORY
  const model = MODEL_CHOICES.find(choice => choice.value === data.model)?.value ?? ''
  const mode = data.permissionMode
  return {
    model,
    permissionMode: typeof mode === 'string' && PERMISSION_MODES.includes(mode) ? mode : '',
    recentDirs: clean(data.recentDirs, text => text.startsWith('/'), MAX_RECENT_DIRS),
    recentSlash: clean(data.recentSlash, validSlash, MAX_RECENT_SLASH),
  }
}

function putFirst(list: string[], item: string, max: number): string[] {
  return [item, ...list.filter(entry => entry !== item)].slice(0, max)
}

// Remember the values of a session that the user started.
export function rememberSession(history: History, spec: NewSessionSpec): History {
  return {
    ...history,
    model: spec.model,
    permissionMode: spec.permissionMode,
    recentDirs: putFirst(history.recentDirs, spec.cwd, MAX_RECENT_DIRS),
  }
}

// Remember a slash command. Other text gives the same object.
export function rememberSlash(history: History, text: string): History {
  const command = text.trim()
  if (!validSlash(command)) return history
  return { ...history, recentSlash: putFirst(history.recentSlash, command, MAX_RECENT_SLASH) }
}

// The folders for the dialog: the history, then the project folder of each row.
export function recentDirectories(history: History, rows: SessionRow[]): string[] {
  const out: string[] = []
  const all = [...history.recentDirs, ...rows.map(row => repoPath(row.cwd))]
  for (const dir of all) {
    if (out.length >= MAX_RECENT_DIRS) break
    if (dir.startsWith('/') && !out.includes(dir)) out.push(dir)
  }
  return out
}
