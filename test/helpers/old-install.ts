import {
  type ClaudeSettings,
  HOOK_COMMAND,
  HOOK_ROWS,
  STATUSLINE_COMMAND,
} from '../../src/main/integration/settings-plan'

// Settings as the old M1 install made them: one hook entry for each row, and the wrapper.
// The wrapper keeps refreshInterval and padding of the statusLine of the user.
export function oldInstalled(base: ClaudeSettings = {}): ClaudeSettings {
  const next: Record<string, unknown> = structuredClone(base)
  const hooks = { ...((next.hooks as Record<string, unknown[]> | undefined) ?? {}) }
  for (const row of HOOK_ROWS) {
    const entry: Record<string, unknown> = {}
    if (row.matcher !== undefined) entry.matcher = row.matcher
    entry.hooks = [{ command: HOOK_COMMAND, type: 'command' }]
    hooks[row.event] = [...(hooks[row.event] ?? []), entry]
  }
  next.hooks = hooks
  const old = next.statusLine as { refreshInterval?: number; padding?: number } | undefined
  const wrapper: Record<string, unknown> = { command: STATUSLINE_COMMAND, type: 'command' }
  if (old?.refreshInterval !== undefined) wrapper.refreshInterval = old.refreshInterval
  if (old?.padding !== undefined) wrapper.padding = old.padding
  next.statusLine = wrapper
  return next
}
