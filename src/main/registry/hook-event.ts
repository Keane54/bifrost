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

// One state event of a session. The lines of the Live details mod give these events
// (src/main/live/live-event.ts). The names are the names of the Claude Code hooks.
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
