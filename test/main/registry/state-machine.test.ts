import { describe, expect, test } from 'vitest'
import type { HookEvent, HookEventName } from '../../../src/main/registry/hook-event'
import {
  INITIAL_STATE,
  type MachineState,
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
  test('is idle with no box', () => {
    expect(INITIAL_STATE).toEqual({
      box: 'none',
      boxSince: null,
      confirmed: false,
      state: 'idle',
    })
    expect(STATUS_GRACE_MS).toBe(1000)
  })
})

describe('hook events', () => {
  test('UserPromptSubmit gives working with no box', () => {
    const red = onHookEvent(INITIAL_STATE, ev('PermissionRequest', 5))
    expect(onHookEvent(red, ev('UserPromptSubmit', 6))).toMatchObject({
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
      box: 'red',
      boxSince: 7,
      confirmed: false,
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
      box: 'yellow',
      boxSince: 10,
      confirmed: false,
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
      box: 'red',
      boxSince: 11,
      redReason: 'error',
      state: 'error',
    })
  })
  test('a red box replaces a yellow box with a new time', () => {
    const y = onHookEvent(INITIAL_STATE, ev('Stop', 1, { lastAssistantMessage: 'm' }))
    expect(onHookEvent(y, ev('PermissionRequest', 50))).toMatchObject({
      box: 'red',
      boxSince: 50,
      lastMessage: 'm',
    })
  })
  // D7: the mod sends SessionStart again at each reload. A reload must not clear a box.
  test('SessionStart keeps the box of a running session', () => {
    const y = onHookEvent(INITIAL_STATE, ev('Stop', 1))
    expect(onHookEvent(y, ev('SessionStart', 2))).toEqual(y)
  })
  // D6: a turn that the user stopped needs no alert.
  test('TurnAborted gives idle with no box and keeps the partial answer', () => {
    expect(onHookEvent(working, ev('TurnAborted', 10, { lastAssistantMessage: 'part' }))).toEqual({
      box: 'none',
      boxSince: null,
      confirmed: false,
      lastMessage: 'part',
      state: 'idle',
    })
  })
  test('TurnAborted with no answer keeps the last message', () => {
    const y = onHookEvent(working, ev('Stop', 5, { lastAssistantMessage: 'Done' }))
    const w = onHookEvent(y, ev('UserPromptSubmit', 6))
    expect(onHookEvent(w, ev('TurnAborted', 7))).toMatchObject({
      box: 'none',
      lastMessage: 'Done',
      state: 'idle',
    })
  })
  // Review Focus 3: turn.complete with an error and classic.StopFailure give the same error.
  test('a second StopFailure keeps the error box and its time', () => {
    const e = onHookEvent(working, ev('StopFailure', 5))
    expect(onHookEvent(e, ev('StopFailure', 6))).toEqual(e)
    expect(e).toMatchObject({ boxSince: 5, redReason: 'error' })
  })
  test('StopFailure replaces an escalated red box with an error box', () => {
    const esc = onTick(onHookEvent(working, ev('Stop', 0)), 10, 10)
    expect(onHookEvent(esc, ev('StopFailure', 20))).toMatchObject({
      boxSince: 20,
      redReason: 'error',
      state: 'error',
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
  // Changed for rule 10: busy clears a yellow box only after an idle sample confirmed it.
  test('busy gives working with no box after the box is confirmed', () => {
    const y = onStatus(onHookEvent(INITIAL_STATE, ev('Stop', 1)), { sampledAt: 3, status: 'idle' })
    expect(onStatus(y, { sampledAt: 5, status: 'busy' })).toMatchObject({
      box: 'none',
      boxSince: null,
      confirmed: false,
      state: 'working',
    })
  })
  test('busy gives working when no box exists', () => {
    expect(onStatus(INITIAL_STATE, { sampledAt: 5, status: 'busy' })).toMatchObject({
      box: 'none',
      state: 'working',
    })
  })
  test('waiting with waitingFor gives a confirmed red prompt box', () => {
    expect(onStatus(working, { sampledAt: 20, status: 'waiting', waitingFor: 'approval' })).toEqual(
      {
        box: 'red',
        boxSince: 20,
        confirmed: true,
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
  // Changed for rule 10: a waiting sample confirms the red prompt box first.
  test('an idle sample from a poll that started before the prompt keeps the red box', () => {
    const hook = onHookEvent(INITIAL_STATE, ev('PermissionRequest', 10_000))
    const red = onStatus(hook, { sampledAt: 10_200, status: 'waiting', waitingFor: 'approval' })
    expect(onStatus(red, { sampledAt: 10_500, status: 'idle' }).box).toBe('red')
    expect(onStatus(red, { sampledAt: 11_500, status: 'idle' }).box).toBe('none')
  })
  // Changed for rule 10: a waiting sample confirms the red prompt box first.
  test('an idle sample after the grace clears a confirmed red prompt to idle', () => {
    const hook = onHookEvent(INITIAL_STATE, ev('PermissionRequest', 10_000))
    const red = onStatus(hook, { sampledAt: 10_200, status: 'waiting', waitingFor: 'approval' })
    expect(onStatus(red, { sampledAt: 11_500, status: 'idle' })).toMatchObject({
      box: 'none',
      boxSince: null,
      state: 'idle',
    })
  })
  // Changed for rule 10: the idle sample keeps the box and confirms it.
  test('an idle sample keeps a yellow box and confirms it', () => {
    const y = onHookEvent(INITIAL_STATE, ev('Stop', 0))
    expect(onStatus(y, { sampledAt: 99_000, status: 'idle' })).toEqual({ ...y, confirmed: true })
  })
  // Changed for rule 10: the idle sample keeps the box and confirms it.
  test('an idle sample keeps a red error box and confirms it', () => {
    const e = onHookEvent(INITIAL_STATE, ev('StopFailure', 0))
    expect(onStatus(e, { sampledAt: 99_000, status: 'idle' })).toEqual({ ...e, confirmed: true })
  })
  test('an idle sample turns working with no box into idle', () => {
    expect(onStatus(working, { sampledAt: 5, status: 'idle' })).toMatchObject({
      box: 'none',
      state: 'idle',
    })
  })
  // Changed for rule 10: an idle sample confirms the error box first.
  test('an error clears when the session works again', () => {
    const e = onStatus(onHookEvent(INITIAL_STATE, ev('StopFailure', 0)), {
      sampledAt: 2000,
      status: 'idle',
    })
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

describe('tick', () => {
  test('a yellow box becomes red after the escalation time', () => {
    const y = onHookEvent(INITIAL_STATE, ev('Stop', 0))
    const r = onTick(y, 600_000, 600_000)
    expect(r).toMatchObject({ box: 'red', redReason: 'escalated' })
    expect(onTick(y, 600_000, 0).box).toBe('yellow')
  })
  test('a yellow box stays yellow before the escalation time', () => {
    const y = onHookEvent(INITIAL_STATE, ev('Stop', 0))
    expect(onTick(y, 599_999, 600_000)).toEqual(y)
  })
  test('the escalation sets the box time to the tick time and keeps the state', () => {
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
})

describe('parked', () => {
  test('onParked clears the box and the reason', () => {
    const red = onHookEvent(INITIAL_STATE, ev('PermissionRequest', 0))
    const p = onParked(red)
    expect(p).toMatchObject({ box: 'none', boxSince: null, state: 'parked' })
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
    onHookEvent(frozen, ev('TurnAborted', 1, { lastAssistantMessage: 'y' }))
    onHookEvent(frozen, ev('StopFailure', 1))
    onStatus(frozen, { sampledAt: 2, status: 'busy' })
    onStatus(frozen, { prevStatus: 'busy', sampledAt: 2, status: 'idle' })
    onStatus(frozen, { sampledAt: 2, status: 'waiting', waitingFor: 'a' })
    onTick(frozen, 700_000, 600_000)
    onParked(frozen)
    expect(frozen).toEqual(copy)
  })
})

describe('fix round 1', () => {
  test('a repeated prompt event keeps the box and its time', () => {
    const r = onHookEvent(INITIAL_STATE, ev('PermissionRequest', 100))
    expect(
      onHookEvent(r, ev('Notification', 200, { notificationType: 'permission_prompt' })),
    ).toEqual(r)
    expect(onHookEvent(r, ev('PreToolUse', 300, { toolName: 'AskUserQuestion' }))).toEqual(r)
    expect(onHookEvent(r, ev('PermissionRequest', 400))).toEqual(r)
  })
  test('a prompt event replaces a red error box and a red escalated box', () => {
    const e = onHookEvent(INITIAL_STATE, ev('StopFailure', 0))
    expect(onHookEvent(e, ev('PermissionRequest', 5))).toMatchObject({
      boxSince: 5,
      redReason: 'prompt',
    })
    const esc = onTick(onHookEvent(INITIAL_STATE, ev('Stop', 0)), 10, 10)
    expect(onHookEvent(esc, ev('PermissionRequest', 20))).toMatchObject({
      boxSince: 20,
      redReason: 'prompt',
    })
  })
  // Changed for rule 10: an idle sample confirms the yellow box first.
  test('a busy sample older than the box keeps the box', () => {
    const hook = onHookEvent(INITIAL_STATE, ev('Stop', 10_000))
    const y = onStatus(hook, { sampledAt: 10_001, status: 'idle' })
    expect(y.confirmed).toBe(true)
    expect(onStatus(y, { sampledAt: 9_900, status: 'busy' })).toEqual(y)
    expect(onStatus(y, { sampledAt: 10_000, status: 'busy' })).toEqual(y)
    expect(onStatus(y, { sampledAt: 10_002, status: 'busy' })).toMatchObject({
      box: 'none',
      state: 'working',
    })
  })
  test('a waiting sample older than the box keeps the box', () => {
    const y = onHookEvent(INITIAL_STATE, ev('Stop', 10_000))
    expect(onStatus(y, { sampledAt: 9_900, status: 'waiting', waitingFor: 'a' })).toEqual(y)
    expect(onStatus(y, { sampledAt: 10_001, status: 'waiting', waitingFor: 'a' })).toMatchObject({
      box: 'red',
      boxSince: 10_001,
      redReason: 'prompt',
    })
  })
  test('Stop while a red prompt box exists gives a new yellow box', () => {
    const r = onHookEvent(INITIAL_STATE, ev('PermissionRequest', 1))
    const y = onHookEvent(r, ev('Stop', 50))
    expect(y).toMatchObject({ box: 'yellow', boxSince: 50 })
    expect(y.redReason).toBeUndefined()
  })
  test('UserPromptSubmit while error gives working with no box', () => {
    const e = onHookEvent(INITIAL_STATE, ev('StopFailure', 0))
    const w = onHookEvent(e, ev('UserPromptSubmit', 1))
    expect(w).toMatchObject({ box: 'none', boxSince: null, state: 'working' })
    expect(w.redReason).toBeUndefined()
  })
  test('SessionEnd while red gives parked with no box', () => {
    const r = onHookEvent(INITIAL_STATE, ev('PermissionRequest', 0))
    expect(onHookEvent(r, ev('SessionEnd', 1))).toMatchObject({ box: 'none', state: 'parked' })
  })
  test('an unknown status string changes nothing', () => {
    const y = onHookEvent(INITIAL_STATE, ev('Stop', 0))
    expect(onStatus(y, { sampledAt: 99_999, status: 'weird' })).toEqual(y)
  })
  // Changed for rule 10: a waiting sample confirms the red prompt box first.
  test('an idle sample at exactly the grace boundary keeps the red box', () => {
    const hook = onHookEvent(INITIAL_STATE, ev('PermissionRequest', 10_000))
    const r = onStatus(hook, { sampledAt: 10_100, status: 'waiting', waitingFor: 'approval' })
    expect(onStatus(r, { sampledAt: 10_000 + STATUS_GRACE_MS, status: 'idle' })).toEqual(r)
  })
})

describe('box confirmation (spec section 7, rule 10)', () => {
  const waiting = (sampledAt: number) => ({ sampledAt, status: 'waiting', waitingFor: 'approval' })
  const busy = (sampledAt: number) => ({ sampledAt, status: 'busy' })
  const idle = (sampledAt: number) => ({ sampledAt, status: 'idle' })

  test('a busy sample while the Stop hooks run keeps the yellow box (review I4)', () => {
    const y = onHookEvent(working, ev('Stop', 10_000))
    const afterBusy = onStatus(y, busy(10_300))
    expect(afterBusy).toEqual(y)
    const afterIdle = onStatus(afterBusy, idle(12_600))
    expect(afterIdle).toMatchObject({ box: 'yellow', confirmed: true, state: 'needs-you' })
    expect(onStatus(afterIdle, busy(20_000))).toMatchObject({ box: 'none', state: 'working' })
  })

  test('busy and idle samples keep a red prompt box from a hook (review I3)', () => {
    const r = onHookEvent(working, ev('PermissionRequest', 20_000))
    const afterBusy = onStatus(r, busy(21_000))
    expect(afterBusy).toEqual(r)
    const afterIdle = onStatus(afterBusy, idle(21_500))
    expect(afterIdle).toEqual(r)
    expect(onStatus(afterIdle, idle(90_000))).toEqual(r)
  })

  test('PermissionRequest, waiting, then idle after the grace clears the box', () => {
    const r = onHookEvent(working, ev('PermissionRequest', 20_000))
    const confirmed = onStatus(r, waiting(20_500))
    expect(confirmed).toEqual({ ...r, confirmed: true })
    expect(onStatus(confirmed, idle(21_000))).toEqual(confirmed)
    expect(onStatus(confirmed, idle(21_500))).toMatchObject({ box: 'none', state: 'idle' })
  })

  test('PermissionRequest, waiting, then busy clears the box (rule 9)', () => {
    const r = onStatus(onHookEvent(working, ev('PermissionRequest', 20_000)), waiting(20_500))
    expect(onStatus(r, busy(21_000))).toMatchObject({ box: 'none', state: 'working' })
  })

  test('a red box from a status sample alone clears on idle', () => {
    const r = onStatus(working, waiting(20_000))
    expect(r).toMatchObject({ box: 'red', confirmed: true, redReason: 'prompt' })
    expect(onStatus(r, idle(22_000))).toMatchObject({ box: 'none', state: 'idle' })
  })

  test('an AskUserQuestion red box stays through busy samples', () => {
    const r = onHookEvent(working, ev('PreToolUse', 5_000, { toolName: 'AskUserQuestion' }))
    const afterBusy = onStatus(onStatus(r, busy(6_000)), busy(8_000))
    expect(afterBusy).toEqual(r)
    expect(onStatus(afterBusy, idle(9_000))).toEqual(r)
  })

  test('UserPromptSubmit clears a yellow box that no sample confirmed', () => {
    const y = onHookEvent(working, ev('Stop', 10_000))
    expect(y.confirmed).toBe(false)
    expect(onHookEvent(y, ev('UserPromptSubmit', 10_500))).toMatchObject({
      box: 'none',
      confirmed: false,
      state: 'working',
    })
  })

  test('a new box from a hook event is not confirmed', () => {
    const y = onStatus(onHookEvent(working, ev('Stop', 10_000)), idle(11_000))
    expect(y.confirmed).toBe(true)
    const again = onHookEvent(y, ev('Stop', 12_000))
    expect(again).toMatchObject({ box: 'yellow', boxSince: 12_000, confirmed: false })
    expect(onStatus(again, busy(12_500)).box).toBe('yellow')
    expect(onHookEvent(y, ev('StopFailure', 12_000)).confirmed).toBe(false)
    expect(onHookEvent(y, ev('PermissionRequest', 12_000)).confirmed).toBe(false)
  })

  test('a repeated prompt event keeps the time and the confirmed flag', () => {
    const r = onStatus(onHookEvent(working, ev('PermissionRequest', 20_000)), waiting(20_500))
    const again = onHookEvent(
      r,
      ev('Notification', 21_000, { notificationType: 'permission_prompt' }),
    )
    expect(again).toEqual(r)
    expect(again.confirmed).toBe(true)
  })

  test('a Notification after a confirmed prompt keeps the box clearable by idle', () => {
    const r = onHookEvent(working, ev('PermissionRequest', 20_000))
    const confirmed = onStatus(r, waiting(20_500))
    const again = onHookEvent(
      confirmed,
      ev('Notification', 21_000, { notificationType: 'permission_prompt' }),
    )
    expect(again).toEqual(confirmed)
    expect(onStatus(again, idle(21_500))).toMatchObject({ box: 'none', state: 'idle' })
  })

  test('a sample that is not newer than the box does not confirm it', () => {
    const y = onHookEvent(working, ev('Stop', 10_000))
    expect(onStatus(y, idle(10_000))).toEqual(y)
    const r = onHookEvent(working, ev('PermissionRequest', 10_000))
    expect(onStatus(r, waiting(9_000))).toEqual(r)
  })

  test('the escalation keeps the confirmed flag', () => {
    const y = onHookEvent(working, ev('Stop', 0))
    const open = onTick(y, 600_000, 600_000)
    expect(open).toMatchObject({ box: 'red', confirmed: false, redReason: 'escalated' })
    expect(onStatus(open, busy(600_500)).box).toBe('red')
    const done = onTick(onStatus(y, idle(1_000)), 600_000, 600_000)
    expect(done).toMatchObject({ box: 'red', confirmed: true, redReason: 'escalated' })
    expect(onStatus(done, busy(600_500))).toMatchObject({ box: 'none', state: 'working' })
  })

  test('an idle sample confirms an escalated box', () => {
    const open = onTick(onHookEvent(working, ev('Stop', 0)), 600_000, 600_000)
    const done = onStatus(open, idle(601_000))
    expect(done).toEqual({ ...open, confirmed: true })
    expect(onStatus(done, busy(602_000))).toMatchObject({ box: 'none', state: 'working' })
  })

  test('a waiting sample replaces a yellow box with a confirmed red prompt box', () => {
    const y = onHookEvent(working, ev('Stop', 10_000))
    expect(onStatus(y, waiting(11_000))).toMatchObject({
      box: 'red',
      boxSince: 11_000,
      confirmed: true,
      redReason: 'prompt',
    })
  })
})

describe('poll-only yellow box (O3)', () => {
  const yellowAt = (at: number) => ({
    box: 'yellow',
    boxSince: at,
    confirmed: true,
    state: 'needs-you',
  })

  test('an idle sample after busy gives a yellow box for a poll-only session', () => {
    const busy = onStatus(INITIAL_STATE, { sampledAt: 1000, status: 'busy' })
    expect(busy).toMatchObject({ box: 'none', state: 'working' })
    expect(
      onStatus(busy, { live: false, prevStatus: 'busy', sampledAt: 3000, status: 'idle' }),
    ).toEqual(yellowAt(3000))
  })

  test('an idle sample after waiting gives a yellow box for a poll-only session', () => {
    const red = onStatus(INITIAL_STATE, {
      sampledAt: 1000,
      status: 'waiting',
      waitingFor: 'approval',
    })
    expect(red).toMatchObject({ box: 'red', confirmed: true, redReason: 'prompt' })
    expect(onStatus(red, { prevStatus: 'waiting', sampledAt: 3000, status: 'idle' })).toEqual(
      yellowAt(3000),
    )
  })

  test('the poll-only yellow box keeps the last message', () => {
    const y = onHookEvent(working, ev('Stop', 5, { lastAssistantMessage: 'Done' }))
    const busy = onStatus(onStatus(y, { sampledAt: 900, status: 'idle' }), {
      sampledAt: 1000,
      status: 'busy',
    })
    expect(busy).toMatchObject({ box: 'none', lastMessage: 'Done', state: 'working' })
    expect(
      onStatus(busy, { prevStatus: 'busy', sampledAt: 3000, status: 'idle' }).lastMessage,
    ).toBe('Done')
  })

  test('an idle sample gives no yellow box for a live session, after idle, or as the first sample', () => {
    const busy = onStatus(INITIAL_STATE, { sampledAt: 1000, status: 'busy' })
    const idle = { box: 'none', state: 'idle' }
    expect(
      onStatus(busy, { live: true, prevStatus: 'busy', sampledAt: 3000, status: 'idle' }),
    ).toMatchObject(idle)
    expect(onStatus(busy, { prevStatus: 'idle', sampledAt: 3000, status: 'idle' })).toMatchObject(
      idle,
    )
    expect(onStatus(busy, { sampledAt: 3000, status: 'idle' })).toMatchObject(idle)
  })

  test('only an idle sample gives the poll-only yellow box', () => {
    const busy = onStatus(INITIAL_STATE, { sampledAt: 1000, status: 'busy' })
    expect(onStatus(busy, { prevStatus: 'busy', sampledAt: 3000, status: 'busy' })).toMatchObject({
      box: 'none',
      state: 'working',
    })
    expect(
      onStatus(busy, { prevStatus: 'busy', sampledAt: 3000, status: 'waiting' }),
    ).toMatchObject({ box: 'none', state: 'working' })
  })

  test('a parked session gets no poll-only yellow box', () => {
    const p = onParked(INITIAL_STATE)
    expect(onStatus(p, { prevStatus: 'busy', sampledAt: 3000, status: 'idle' })).toEqual(p)
  })

  test('a later busy sample clears the poll-only yellow box', () => {
    const busy = onStatus(INITIAL_STATE, { sampledAt: 1000, status: 'busy' })
    const y = onStatus(busy, { prevStatus: 'busy', sampledAt: 3000, status: 'idle' })
    expect(onStatus(y, { prevStatus: 'idle', sampledAt: 5000, status: 'idle' })).toEqual(y)
    expect(onStatus(y, { prevStatus: 'idle', sampledAt: 7000, status: 'busy' })).toMatchObject({
      box: 'none',
      state: 'working',
    })
  })
})
