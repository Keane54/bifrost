export type HookEventName =
  | 'SessionStart'
  | 'SessionEnd'
  | 'UserPromptSubmit'
  | 'PreToolUse'
  | 'PermissionRequest'
  | 'PostToolUse'
  | 'Notification'
  | 'Stop'
  | 'StopFailure'
  // No hook has this name. The mod gives it for a turn that the user stopped.
  | 'TurnAborted'

export interface HookEvent {
  name: HookEventName
  sessionId: string
  at: number
  // The order number of the mod for one session. Only lines of the mod have it.
  seq?: number
  cwd?: string
  toolName?: string
  notificationType?: string
  lastAssistantMessage?: string
}

const NAMES: ReadonlySet<string> = new Set<HookEventName>([
  'SessionStart',
  'SessionEnd',
  'UserPromptSubmit',
  'PreToolUse',
  'PermissionRequest',
  'PostToolUse',
  'Notification',
  'Stop',
  'StopFailure',
])

function text(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined
}

// Read the JSON of one hook event.
// Return null for bad JSON, an unknown event name or a missing session_id.
export function parseHookEvent(input: string, at: number): HookEvent | null {
  let data: unknown
  try {
    data = JSON.parse(input)
  } catch {
    return null
  }
  if (typeof data !== 'object' || data === null) return null
  const raw = data as Record<string, unknown>
  const name = text(raw.hook_event_name)
  const sessionId = text(raw.session_id)
  if (!name || !NAMES.has(name) || !sessionId) return null
  const event: HookEvent = { at, name: name as HookEventName, sessionId }
  const cwd = text(raw.cwd)
  const toolName = text(raw.tool_name)
  const notificationType = text(raw.notification_type)
  const lastAssistantMessage = text(raw.last_assistant_message)
  if (cwd !== undefined) event.cwd = cwd
  if (toolName !== undefined) event.toolName = toolName
  if (notificationType !== undefined) event.notificationType = notificationType
  if (lastAssistantMessage !== undefined) event.lastAssistantMessage = lastAssistantMessage
  return event
}
