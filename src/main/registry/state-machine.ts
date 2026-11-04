import type { Box, SessionState } from '../../shared/types'
import type { HookEvent } from './hook-event'

export interface MachineState {
  state: SessionState
  box: Box
  boxSince: number | null
  // False while a new box flashes. True when no box exists.
  acknowledged: boolean
  redReason?: 'prompt' | 'error' | 'escalated'
  lastMessage?: string
}

export const INITIAL_STATE: MachineState = {
  acknowledged: true,
  box: 'none',
  boxSince: null,
  state: 'idle',
}

// An idle sample counts only when it starts this long after the red box.
// An older poll can finish after the prompt and report an idle that is no longer true.
export const STATUS_GRACE_MS = 1000

// Return the state with no box. Keep the last message.
function withoutBox(s: MachineState, state: SessionState): MachineState {
  const next: MachineState = { acknowledged: true, box: 'none', boxSince: null, state }
  if (s.lastMessage !== undefined) next.lastMessage = s.lastMessage
  return next
}

// Return the state with a new box. A new box flashes.
function withBox(
  s: MachineState,
  state: SessionState,
  box: 'yellow' | 'red',
  at: number,
  redReason?: MachineState['redReason'],
): MachineState {
  const next: MachineState = { acknowledged: false, box, boxSince: at, state }
  if (redReason !== undefined) next.redReason = redReason
  if (s.lastMessage !== undefined) next.lastMessage = s.lastMessage
  return next
}

// Return the red prompt box. A repeated prompt event keeps the box, its time and its flash state.
function promptBox(s: MachineState, at: number): MachineState {
  if (s.box === 'red' && s.redReason === 'prompt') return s
  return withBox(s, 'needs-you', 'red', at, 'prompt')
}

export function onHookEvent(s: MachineState, ev: HookEvent): MachineState {
  if (ev.name === 'SessionStart') return withoutBox(s, 'idle')
  // A parked session leaves the parked state only on SessionStart.
  if (s.state === 'parked') return s
  switch (ev.name) {
    case 'UserPromptSubmit':
    case 'PostToolUse':
      return withoutBox(s, 'working')
    case 'PreToolUse':
      return ev.toolName === 'AskUserQuestion' ? promptBox(s, ev.at) : s
    case 'PermissionRequest':
      return promptBox(s, ev.at)
    case 'Notification':
      return ev.notificationType === 'permission_prompt' ? promptBox(s, ev.at) : s
    case 'Stop': {
      const next = withBox(s, 'needs-you', 'yellow', ev.at)
      if (ev.lastAssistantMessage !== undefined) next.lastMessage = ev.lastAssistantMessage
      return next
    }
    case 'StopFailure':
      return withBox(s, 'error', 'red', ev.at, 'error')
    case 'SessionEnd':
      return withoutBox(s, 'parked')
    default:
      return s
  }
}

export function onStatus(
  s: MachineState,
  sample: { status: string; waitingFor?: string; sampledAt: number },
): MachineState {
  if (s.state === 'parked') return s
  // A sample that is not newer than the box comes from a poll that started before the box.
  const old = s.boxSince !== null && sample.sampledAt <= s.boxSince
  switch (sample.status) {
    case 'busy':
      if (old) return s
      return withoutBox(s, 'working')
    case 'waiting':
      if (!sample.waitingFor || old) return s
      // A red prompt box exists already. Keep its time.
      if (s.box === 'red' && s.redReason === 'prompt') return s
      return withBox(s, 'needs-you', 'red', sample.sampledAt, 'prompt')
    case 'idle':
      if (s.box === 'red' && s.redReason === 'prompt') {
        const settled = s.boxSince !== null && sample.sampledAt > s.boxSince + STATUS_GRACE_MS
        return settled ? withoutBox(s, 'idle') : s
      }
      if (s.state === 'working' && s.box === 'none') return withoutBox(s, 'idle')
      return s
    default:
      return s
  }
}

export function onTick(s: MachineState, now: number, escalationMs: number): MachineState {
  if (s.box !== 'yellow' || escalationMs <= 0 || s.boxSince === null) return s
  if (now - s.boxSince < escalationMs) return s
  return withBox(s, s.state, 'red', now, 'escalated')
}

export function onAcknowledge(s: MachineState): MachineState {
  return { ...s, acknowledged: true }
}

export function onParked(s: MachineState): MachineState {
  return withoutBox(s, 'parked')
}
