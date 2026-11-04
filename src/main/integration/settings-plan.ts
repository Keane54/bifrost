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

export function planInstall(
  settings: ClaudeSettings,
  savedOriginal: StatusLineSetting | null | undefined,
): { next: ClaudeSettings; original: StatusLineSetting | null; changes: string[] } {
  const next: ClaudeSettings = structuredClone(settings)
  const changes: string[] = []

  // Hooks. Add one entry for each row that is missing.
  if (next.hooks !== undefined && !isObject(next.hooks)) {
    throw new Error('Unexpected type for the key hooks. Expect an object.')
  }
  const current = next.statusLine
  if (current !== undefined && !(isObject(current) && typeof current.command === 'string')) {
    throw new Error('Unexpected type for the key statusLine. Expect an object with a command.')
  }
  const hooks: Loose = isObject(next.hooks) ? next.hooks : {}
  for (const row of HOOK_ROWS) {
    if (hasRow(hooks, row)) continue
    const entry: Loose = {}
    if (row.matcher !== undefined) entry.matcher = row.matcher
    entry.hooks = [{ command: HOOK_COMMAND, type: 'command' }]
    const existing = hooks[row.event]
    if (existing !== undefined && !Array.isArray(existing)) {
      throw new Error(`Unexpected type for the key hooks.${row.event}. Expect an array.`)
    }
    hooks[row.event] = existing === undefined ? [entry] : [...existing, entry]
    changes.push(
      row.matcher === undefined
        ? `Add the hook for ${row.event}.`
        : `Add the hook for ${row.event} with the matcher ${row.matcher}.`,
    )
  }
  if (changes.length > 0) next.hooks = hooks

  // Statusline. Never save the wrapper as the original.
  // A statusLine that is not the wrapper is the original. Use the saved one only for the wrapper.
  let original: StatusLineSetting | null
  if (isObject(current) && !isWrapper(current)) {
    original = structuredClone(current) as unknown as StatusLineSetting
  } else {
    original = savedOriginal ?? null
  }

  if (!isWrapper(current)) {
    const wrapper: StatusLineSetting = { command: STATUSLINE_COMMAND, type: 'command' }
    if (isObject(current)) {
      if (current.refreshInterval !== undefined) {
        wrapper.refreshInterval = current.refreshInterval as number
      }
      if (current.padding !== undefined) wrapper.padding = current.padding as number
    }
    next.statusLine = wrapper
    changes.push(
      current === undefined
        ? 'Add the Bifrost wrapper as the statusLine.'
        : 'Change the statusLine command to the Bifrost wrapper.',
    )
  }

  return { changes, next, original }
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

export function checkInstall(settings: ClaudeSettings): {
  missingHooks: string[]
  statusLineInstalled: boolean
} {
  return {
    missingHooks: HOOK_ROWS.filter(row => !hasRow(settings.hooks, row)).map(rowName),
    statusLineInstalled: isWrapper(settings.statusLine),
  }
}
