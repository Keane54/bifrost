import { describe, expect, test } from 'vitest'
import type { HookEvent, HookEventName } from '../../../src/main/registry/hook-event'
import {
  INITIAL_STATE,
  type MachineState,
  onAcknowledge,
  onHookEvent,
  onParked,
  onStatus,
  onTick,
  STATUS_GRACE_MS,
} from '../../../src/main/registry/state-machine'

const ev = (name: HookEventName, at: number, extra = {}): HookEvent => ({
  at,
  name,
  sessionId: 's',
  ...extra,
})

const working = onHookEvent(INITIAL_STATE, ev('UserPromptSubmit', 1))

describe('initial state', () => {
  test('is idle with no box and nothing to acknowledge', () => {
    expect(INITIAL_STATE).toEqual({
      acknowledged: true,
      box: 'none',
      boxSince: null,
      state: 'idle',
    })
    expect(STATUS_GRACE_MS).toBe(1000)
  })
})

describe('hook events', () => {
  test('UserPromptSubmit gives working with no box', () => {
    const red = onHookEvent(INITIAL_STATE, ev('PermissionRequest', 5))
    expect(onHookEvent(red, ev('UserPromptSubmit', 6))).toMatchObject({
      acknowledged: true,
      box: 'none',
      boxSince: null,
      state: 'working',
    })
  })
  test('PostToolUse gives working with no box', () => {
    const red = onHookEvent(INITIAL_STATE, ev('PermissionRequest', 5))
    expect(onHookEvent(red, ev('PostToolUse', 6))).toMatchObject({ box: 'none', state: 'working' })
  })
  test('PreToolUse AskUserQuestion gives a red prompt box', () => {
    expect(onHookEvent(working, ev('PreToolUse', 7, { toolName: 'AskUserQuestion' }))).toEqual({
      acknowledged: false,
      box: 'red',
      boxSince: 7,
      redReason: 'prompt',
      state: 'needs-you',
    })
  })
  test('PermissionRequest gives a red prompt box', () => {
    expect(onHookEvent(working, ev('PermissionRequest', 8))).toMatchObject({
      box: 'red',
      boxSince: 8,
      redReason: 'prompt',
      state: 'needs-you',
    })
  })
  test('Notification permission_prompt gives a red prompt box', () => {
    expect(
      onHookEvent(working, ev('Notification', 9, { notificationType: 'permission_prompt' })),
    ).toMatchObject({ box: 'red', boxSince: 9, redReason: 'prompt', state: 'needs-you' })
  })
  test('PreToolUse with another tool changes nothing', () => {
    expect(onHookEvent(working, ev('PreToolUse', 7, { toolName: 'Bash' }))).toEqual(working)
  })
  test('Notification idle_prompt changes nothing', () => {
    const y = onHookEvent(INITIAL_STATE, ev('Stop', 3))
    expect(onHookEvent(y, ev('Notification', 4, { notificationType: 'idle_prompt' }))).toEqual(y)
  })
  test('Stop gives a yellow box and keeps the last message', () => {
    expect(onHookEvent(working, ev('Stop', 10, { lastAssistantMessage: 'Done' }))).toEqual({
      acknowledged: false,
      box: 'yellow',
      boxSince: 10,
      lastMessage: 'Done',
      state: 'needs-you',
    })
  })
  test('a message stays until the next Stop replaces it', () => {
    const y = onHookEvent(working, ev('Stop', 10, { lastAssistantMessage: 'Done' }))
    const w = onHookEvent(y, ev('UserPromptSubmit', 11))
    expect(w.lastMessage).toBe('Done')
    expect(onHookEvent(w, ev('Stop', 12, { lastAssistantMessage: 'Again' })).lastMessage).toBe(
      'Again',
    )
  })
  test('StopFailure gives a red error box', () => {
    expect(onHookEvent(working, ev('StopFailure', 11))).toMatchObject({
      acknowledged: false,
      box: 'red',
      boxSince: 11,
      redReason: 'error',
      state: 'error',
    })
  })
  test('a red box replaces a yellow box with a new time and a new flash', () => {
    const y = onAcknowledge(
      onHookEvent(INITIAL_STATE, ev('Stop', 1, { lastAssistantMessage: 'm' })),
    )
    expect(onHookEvent(y, ev('PermissionRequest', 50))).toMatchObject({
      acknowledged: false,
      box: 'red',
      boxSince: 50,
      lastMessage: 'm',
    })
  })
  test('SessionStart gives idle with no box', () => {
    const y = onHookEvent(INITIAL_STATE, ev('Stop', 1))
    expect(onHookEvent(y, ev('SessionStart', 2))).toMatchObject({
      acknowledged: true,
      box: 'none',
      boxSince: null,
      state: 'idle',
    })
  })
  test('SessionEnd gives parked with no box', () => {
    const y = onHookEvent(INITIAL_STATE, ev('Stop', 1))
    expect(onHookEvent(y, ev('SessionEnd', 2))).toMatchObject({
      box: 'none',
      boxSince: null,
      state: 'parked',
    })
  })
})

describe('status samples', () => {
  test('busy gives working with no box', () => {
    const y = onHookEvent(INITIAL_STATE, ev('Stop', 1))
    expect(onStatus(y, { sampledAt: 5, status: 'busy' })).toMatchObject({
      box: 'none',
      boxSince: null,
      state: 'working',
    })
  })
  test('waiting with waitingFor gives a red prompt box', () => {
    expect(onStatus(working, { sampledAt: 20, status: 'waiting', waitingFor: 'approval' })).toEqual(
      {
        acknowledged: false,
        box: 'red',
        boxSince: 20,
        redReason: 'prompt',
        state: 'needs-you',
      },
    )
  })
  test('waiting without waitingFor changes nothing', () => {
    expect(onStatus(working, { sampledAt: 20, status: 'waiting' })).toEqual(working)
  })
  test('a second waiting sample keeps the first box time', () => {
    const r = onStatus(working, { sampledAt: 20, status: 'waiting', waitingFor: 'a' })
    expect(onStatus(r, { sampledAt: 30, status: 'waiting', waitingFor: 'a' })).toEqual(r)
  })
  test('an idle sample from a poll that started before the prompt keeps the red box', () => {
    const red = onHookEvent(INITIAL_STATE, ev('PermissionRequest', 10_000))
    expect(onStatus(red, { sampledAt: 10_500, status: 'idle' }).box).toBe('red')
    expect(onStatus(red, { sampledAt: 11_500, status: 'idle' }).box).toBe('none')
  })
  test('an idle sample after the grace clears a red prompt to idle', () => {
    const red = onHookEvent(INITIAL_STATE, ev('PermissionRequest', 10_000))
    expect(onStatus(red, { sampledAt: 11_500, status: 'idle' })).toMatchObject({
      acknowledged: true,
      box: 'none',
      boxSince: null,
      state: 'idle',
    })
  })
  test('an idle sample keeps a yellow box', () => {
    const y = onHookEvent(INITIAL_STATE, ev('Stop', 0))
    expect(onStatus(y, { sampledAt: 99_000, status: 'idle' })).toEqual(y)
  })
  test('an idle sample keeps a red error box', () => {
    const e = onHookEvent(INITIAL_STATE, ev('StopFailure', 0))
    expect(onStatus(e, { sampledAt: 99_000, status: 'idle' })).toEqual(e)
  })
  test('an idle sample turns working with no box into idle', () => {
    expect(onStatus(working, { sampledAt: 5, status: 'idle' })).toMatchObject({
      box: 'none',
      state: 'idle',
    })
  })
  test('an error clears when the session works again', () => {
    const e = onHookEvent(INITIAL_STATE, ev('StopFailure', 0))
    expect(onStatus(e, { sampledAt: 5000, status: 'busy' })).toMatchObject({
      box: 'none',
      state: 'working',
    })
  })
  test('a parked session ignores status and leaves only on SessionStart', () => {
    const p = onParked(onHookEvent(INITIAL_STATE, ev('Stop', 0)))
    expect(p).toMatchObject({ box: 'none', state: 'parked' })
    expect(onStatus(p, { sampledAt: 1, status: 'busy' }).state).toBe('parked')
    expect(onHookEvent(p, ev('SessionStart', 2)).state).toBe('idle')
  })
})

describe('tick and acknowledge', () => {
  test('a yellow box becomes red after the escalation time and flashes again', () => {
    const y = onAcknowledge(onHookEvent(INITIAL_STATE, ev('Stop', 0)))
    const r = onTick(y, 600_000, 600_000)
    expect(r).toMatchObject({ acknowledged: false, box: 'red', redReason: 'escalated' })
    expect(onTick(y, 600_000, 0).box).toBe('yellow')
  })
  test('a yellow box stays yellow before the escalation time', () => {
    const y = onHookEvent(INITIAL_STATE, ev('Stop', 0))
    expect(onTick(y, 599_999, 600_000)).toEqual(y)
  })
  test('the escalation keeps the box time and the state', () => {
    const y = onHookEvent(INITIAL_STATE, ev('Stop', 100))
    expect(onTick(y, 700_100, 600_000)).toMatchObject({
      boxSince: 700_100,
      state: 'needs-you',
    })
  })
  test('a tick does not change a red box or a row with no box', () => {
    const red = onHookEvent(INITIAL_STATE, ev('PermissionRequest', 0))
    expect(onTick(red, 9e9, 1)).toEqual(red)
    expect(onTick(working, 9e9, 1)).toEqual(working)
  })
  test('acknowledge sets acknowledged and keeps the box', () => {
    const y = onHookEvent(INITIAL_STATE, ev('Stop', 0))
    expect(onAcknowledge(y)).toEqual({ ...y, acknowledged: true })
  })
})

describe('parked', () => {
  test('onParked clears the box and the reason', () => {
    const red = onHookEvent(INITIAL_STATE, ev('PermissionRequest', 0))
    const p = onParked(red)
    expect(p).toMatchObject({ acknowledged: true, box: 'none', boxSince: null, state: 'parked' })
    expect(p.redReason).toBeUndefined()
  })
})

describe('purity', () => {
  test('no function changes a frozen input', () => {
    const frozen: MachineState = Object.freeze({
      ...onHookEvent(INITIAL_STATE, ev('Stop', 0, { lastAssistantMessage: 'x' })),
    })
    const copy = { ...frozen }
    onHookEvent(frozen, ev('PermissionRequest', 1))
    onHookEvent(frozen, ev('SessionEnd', 1))
    onStatus(frozen, { sampledAt: 2, status: 'busy' })
    onStatus(frozen, { sampledAt: 2, status: 'waiting', waitingFor: 'a' })
    onTick(frozen, 700_000, 600_000)
    onAcknowledge(frozen)
    onParked(frozen)
    expect(frozen).toEqual(copy)
  })
})
