import type { Box, SessionState } from '../../shared/types'
import type { HookEvent } from './hook-event'

export interface MachineState {
  state: SessionState
  box: Box
  boxSince: number | null
  // False while a new box flashes. True when no box exists.
  acknowledged: boolean
  // True after a status sample confirmed the current box. False when no box exists.
  // A status sample clears only a confirmed box (spec section 7, rule 10).
  confirmed: boolean
  redReason?: 'prompt' | 'error' | 'escalated'
  lastMessage?: string
}

export const INITIAL_STATE: MachineState = {
  acknowledged: true,
  box: 'none',
  boxSince: null,
  confirmed: false,
  state: 'idle',
}

// An idle sample counts only when it starts this long after the red box.
// An older poll can finish after the prompt and report an idle that is no longer true.
export const STATUS_GRACE_MS = 1000

// Return the state with no box. Keep the last message.
function withoutBox(s: MachineState, state: SessionState): MachineState {
  const next: MachineState = {
    acknowledged: true,
    box: 'none',
    boxSince: null,
    confirmed: false,
    state,
  }
  if (s.lastMessage !== undefined) next.lastMessage = s.lastMessage
  return next
}

// Return the state with a new box. A new box flashes.
// A box from a hook event is not confirmed. A box from a status sample is confirmed.
function withBox(
  s: MachineState,
  state: SessionState,
  box: 'yellow' | 'red',
  at: number,
  redReason?: MachineState['redReason'],
  confirmed = false,
): MachineState {
  const next: MachineState = { acknowledged: false, box, boxSince: at, confirmed, state }
  if (redReason !== undefined) next.redReason = redReason
  if (s.lastMessage !== undefined) next.lastMessage = s.lastMessage
  return next
}

function isPromptBox(s: MachineState): boolean {
  return s.box === 'red' && s.redReason === 'prompt'
}

// Return the state with the confirmed flag set.
function confirm(s: MachineState): MachineState {
  return s.confirmed ? s : { ...s, confirmed: true }
}

// Return the red prompt box. A repeated prompt event keeps the box, its time and its flash state.
// The prompt can be a new prompt. So the box needs a new confirmation.
function promptBox(s: MachineState, at: number): MachineState {
  if (isPromptBox(s)) return s.confirmed ? { ...s, confirmed: false } : s
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

// Apply one sample of the session list.
// A sample confirms the current box: idle confirms a yellow box, an error box and an old
// yellow box (escalated). waiting confirms a red prompt box.
// A sample clears a box only after a sample confirmed it.
// The reason: Claude Code can report busy while the Stop hooks run.
// An interactive session can also report idle or busy at a prompt.
export function onStatus(
  s: MachineState,
  sample: { status: string; waitingFor?: string; sampledAt: number },
): MachineState {
  if (s.state === 'parked') return s
  // A sample that is not newer than the box comes from a poll that started before the box.
  if (s.boxSince !== null && sample.sampledAt <= s.boxSince) return s
  switch (sample.status) {
    case 'busy':
      if (s.box === 'none' || s.confirmed) return withoutBox(s, 'working')
      return s
    case 'waiting':
      if (!sample.waitingFor) return s
      // A red prompt box exists already. Keep its time and confirm it.
      if (isPromptBox(s)) return confirm(s)
      // The sample itself confirms the new box.
      return withBox(s, 'needs-you', 'red', sample.sampledAt, 'prompt', true)
    case 'idle':
      if (isPromptBox(s)) {
        if (!s.confirmed || s.boxSince === null) return s
        const settled = sample.sampledAt > s.boxSince + STATUS_GRACE_MS
        return settled ? withoutBox(s, 'idle') : s
      }
      if (s.box !== 'none') return confirm(s)
      if (s.state === 'working') return withoutBox(s, 'idle')
      return s
    default:
      return s
  }
}

// A yellow box changes to red after the escalation time. The confirmed flag stays.
export function onTick(s: MachineState, now: number, escalationMs: number): MachineState {
  if (s.box !== 'yellow' || escalationMs <= 0 || s.boxSince === null) return s
  if (now - s.boxSince < escalationMs) return s
  return withBox(s, s.state, 'red', now, 'escalated', s.confirmed)
}

export function onAcknowledge(s: MachineState): MachineState {
  return { ...s, acknowledged: true }
}

export function onParked(s: MachineState): MachineState {
  return withoutBox(s, 'parked')
}
