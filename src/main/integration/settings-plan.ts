// Pure functions that plan the changes to the Claude Code settings.
// They do no file IO. They never change their input.

export const HOOK_COMMAND = '~/.bifrost/bin/bifrost-hook'
export const STATUSLINE_COMMAND = '~/.bifrost/bin/bifrost-statusline'

export const HOOK_ROWS: ReadonlyArray<{ event: string; matcher?: string }> = [
  { event: 'SessionStart' },
  { event: 'SessionEnd' },
  { event: 'UserPromptSubmit' },
  { event: 'PreToolUse', matcher: 'AskUserQuestion' },
  { event: 'PermissionRequest', matcher: '*' },
  { event: 'PostToolUse', matcher: '*' },
  { event: 'Notification', matcher: 'permission_prompt' },
  { event: 'Notification', matcher: 'idle_prompt' },
  { event: 'Stop' },
  { event: 'StopFailure' },
]

export type ClaudeSettings = Record<string, unknown>

export interface StatusLineSetting {
  type: string
  command: string
  refreshInterval?: number
  padding?: number
}

type Row = { event: string; matcher?: string }
type Loose = Record<string, unknown>

function isObject(value: unknown): value is Loose {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isBifrostHook(hook: unknown): boolean {
  return isObject(hook) && hook.command === HOOK_COMMAND
}

function entryHasBifrostHook(entry: unknown): boolean {
  return isObject(entry) && Array.isArray(entry.hooks) && entry.hooks.some(isBifrostHook)
}

function rowName(row: Row): string {
  return row.matcher === undefined ? row.event : `${row.event}:${row.matcher}`
}

function hasRow(hooks: unknown, row: Row): boolean {
  if (!isObject(hooks)) return false
  const entries = hooks[row.event]
  if (!Array.isArray(entries)) return false
  return entries.some(
    entry => isObject(entry) && entry.matcher === row.matcher && entryHasBifrostHook(entry),
  )
}

function isWrapper(statusLine: unknown): boolean {
  return isObject(statusLine) && statusLine.command === STATUSLINE_COMMAND
}

export function planUninstall(
  settings: ClaudeSettings,
  original: StatusLineSetting | null,
): ClaudeSettings {
  const next: ClaudeSettings = structuredClone(settings)

  if (isObject(next.hooks)) {
    const hooks = next.hooks
    let touched = false
    for (const [event, entries] of Object.entries(hooks)) {
      if (!Array.isArray(entries)) continue
      const kept: unknown[] = []
      let removed = false
      for (const entry of entries) {
        if (!entryHasBifrostHook(entry)) {
          kept.push(entry)
          continue
        }
        touched = true
        removed = true
        const entryObject = entry as Loose
        const rest = (entryObject.hooks as unknown[]).filter(hook => !isBifrostHook(hook))
        if (rest.length > 0) kept.push({ ...entryObject, hooks: rest })
      }
      if (!removed) continue
      if (kept.length > 0) hooks[event] = kept
      else delete hooks[event]
    }
    if (touched && Object.keys(hooks).length === 0) delete next.hooks
  }

  if (isWrapper(next.statusLine)) {
    if (original) next.statusLine = structuredClone(original)
    else delete next.statusLine
  }

  return next
}

// True when planUninstall would change the settings: a Bifrost hook entry under any event and
// any matcher, or the wrapper. It uses the same tests as planUninstall.
export function hasBifrostEntry(settings: ClaudeSettings): boolean {
  if (isWrapper(settings.statusLine)) return true
  if (!isObject(settings.hooks)) return false
  return Object.values(settings.hooks).some(
    entries => Array.isArray(entries) && entries.some(entryHasBifrostHook),
  )
}

export function checkInstall(settings: ClaudeSettings): {
  missingHooks: string[]
  statusLineInstalled: boolean
} {
  return {
    missingHooks: HOOK_ROWS.filter(row => !hasRow(settings.hooks, row)).map(rowName),
    statusLineInstalled: isWrapper(settings.statusLine),
  }
}
