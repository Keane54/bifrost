import type { Box, BoxReason, SessionState } from '../../shared/types'
import type { HookEvent } from './hook-event'

export interface MachineState {
  state: SessionState
  box: Box
  boxSince: number | null
  // True after a status sample confirmed the current box. False when no box exists.
  // A status sample clears only a confirmed box (spec section 7, rule 10).
  confirmed: boolean
  redReason?: BoxReason
  lastMessage?: string
}

export const INITIAL_STATE: MachineState = {
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
    box: 'none',
    boxSince: null,
    confirmed: false,
    state,
  }
  if (s.lastMessage !== undefined) next.lastMessage = s.lastMessage
  return next
}

// Return the state with a new box.
// A box from a hook event is not confirmed. A box from a status sample is confirmed.
function withBox(
  s: MachineState,
  state: SessionState,
  box: 'yellow' | 'red',
  at: number,
  redReason?: MachineState['redReason'],
  confirmed = false,
): MachineState {
  const next: MachineState = { box, boxSince: at, confirmed, state }
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
// The box keeps its confirmed flag. So a later idle or busy sample can still clear it.
function promptBox(s: MachineState, at: number): MachineState {
  if (isPromptBox(s)) return s
  return withBox(s, 'needs-you', 'red', at, 'prompt')
}

// Apply one state event of the mod.
export function onHookEvent(s: MachineState, ev: HookEvent): MachineState {
  // A parked session leaves the parked state only on SessionStart.
  // For a session that runs, SessionStart changes nothing (D7). The mod sends it again at each
  // reload, and a reload must not clear a box.
  if (s.state === 'parked') return ev.name === 'SessionStart' ? withoutBox(s, 'idle') : s
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
    // The user stopped the turn. This needs no alert (D6). Keep the partial answer.
    case 'TurnAborted': {
      const next = withoutBox(s, 'idle')
      if (ev.lastAssistantMessage !== undefined) next.lastMessage = ev.lastAssistantMessage
      return next
    }
    // The mod can send the same error two times. A repeated error keeps the box, its time and
    // its flash state.
    case 'StopFailure':
      if (s.box === 'red' && s.redReason === 'error') return s
      return withBox(s, 'error', 'red', ev.at, 'error')
    case 'SessionEnd':
      return withoutBox(s, 'parked')
    default:
      return s
  }
}

// One sample of the session list for one session.
// prevStatus is the status of the session before this sample. It is undefined for a new session.
// live is true when the mod sent a line for the session in the last LIVE_FRESH_MS.
export interface StatusSample {
  status: string
  waitingFor?: string
  sampledAt: number
  prevStatus?: string
  live?: boolean
}

// Apply one sample of the session list.
// First apply the M1 rules (statusRules). Then a session with no mod can get a yellow box (O3):
// when an idle sample follows busy or waiting and the result has no box, the turn ended.
// The sample confirms this box. So the next busy sample clears it.
// A session with the mod gets its yellow box from the Stop event, so this rule skips it.
// The first sample of a session has no prevStatus, so it gives no box.
export function onStatus(s: MachineState, sample: StatusSample): MachineState {
  const next = statusRules(s, sample)
  const turnEnded =
    sample.status === 'idle' && (sample.prevStatus === 'busy' || sample.prevStatus === 'waiting')
  if (next.box !== 'none' || next.state === 'parked' || sample.live === true || !turnEnded) {
    return next
  }
  return withBox(next, 'needs-you', 'yellow', sample.sampledAt, undefined, true)
}

// The M1 rules for one sample.
// A sample confirms the current box: idle confirms a yellow box, an error box and an old
// yellow box (escalated). waiting confirms a red prompt box.
// A sample clears a box only after a sample confirmed it.
// The reason: Claude Code can report busy while the Stop hooks run.
// An interactive session can also report idle or busy at a prompt.
function statusRules(s: MachineState, sample: StatusSample): MachineState {
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

export function onParked(s: MachineState): MachineState {
  return withoutBox(s, 'parked')
}
