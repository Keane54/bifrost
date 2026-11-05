import { describe, expect, it } from 'vitest'
import type { ActionContext } from '../../../src/renderer/src/actions/action-model'
import type { ConfirmText } from '../../../src/renderer/src/actions/confirm'
import { confirmFor } from '../../../src/renderer/src/actions/confirm'
import { confirmStep } from '../../../src/renderer/src/actions/confirm-step'
import { planRun } from '../../../src/renderer/src/actions/run-plan'
import { row } from '../overview/fixtures'

const ctx = (over: Partial<ActionContext> = {}): ActionContext => ({
  apps: [
    { id: 'finder', label: 'Finder' },
    { id: 'warp', label: 'Warp' },
  ],
  chatOpen: true,
  labels: 'plain',
  running: false,
  slashFavourites: ['/compact'],
  slashRecent: [],
  ...over,
})
const owned = row({ name: 'fix-a', sessionId: 'o', shortId: 'abcd1234', state: 'idle' })
const working = row({ name: 'fix-a', sessionId: 'o', shortId: 'abcd1234', state: 'working' })
const external = row({
  cwd: '/Users/o/Developer/app',
  kind: 'external',
  name: 'ext-a',
  pid: 4242,
  sessionId: 'e',
  state: 'idle',
  terminalApp: 'Warp',
})
const parked = row({ sessionId: 'p', state: 'parked' })

describe('planRun', () => {
  it('a disabled action gives none', () => {
    const red = row({ box: 'red', sessionId: 'r', shortId: 'abcd1234', state: 'needs-you' })
    expect(planRun('send-message', red, ctx())).toEqual({ kind: 'none' })
    expect(planRun('stop', owned, ctx({ running: true }))).toEqual({ kind: 'none' })
    expect(planRun('open', undefined, ctx())).toEqual({ kind: 'none' })
  })

  it('Run slash command without a command focuses the send box with /', () => {
    expect(planRun('run-slash', owned, ctx())).toEqual({ kind: 'focus-send', text: '/' })
    expect(planRun('run-slash', owned, ctx(), '/')).toEqual({ kind: 'focus-send', text: '/' })
  })

  it('Run slash command with /compact sends /compact', () => {
    expect(planRun('run-slash', owned, ctx(), '/compact')).toEqual({
      kind: 'send',
      text: '/compact',
    })
  })

  it('Run slash command with an argument that is not a command sends nothing', () => {
    for (const arg of [null, 3, 'finder'] as const) {
      expect(planRun('run-slash', owned, ctx(), arg)).toEqual({ kind: 'focus-send', text: '/' })
    }
  })

  it('Send message focuses the send box with empty text', () => {
    expect(planRun('send-message', owned, ctx())).toEqual({ kind: 'focus-send', text: '' })
  })

  it('Stop of a working row asks first, and Stop of an idle row does not', () => {
    expect(planRun('stop', working, ctx())).toEqual({
      after: 'none',
      call: 'stop',
      confirm: confirmFor('stop', working, 'plain'),
      kind: 'call',
    })
    const plan = planRun('stop', working, ctx())
    expect(plan.kind === 'call' && plan.confirm?.body).toContain('fix-a is working right now.')
    expect(planRun('stop', owned, ctx())).toEqual({
      after: 'none',
      call: 'stop',
      confirm: null,
      kind: 'call',
    })
  })

  it('Take control asks with the terminal name and opens the chat window after', () => {
    const plan = planRun('take-control', external, ctx())
    expect(plan).toEqual({
      after: 'open-chat',
      call: 'take-control',
      confirm: confirmFor('take-control', external, 'plain'),
      kind: 'call',
    })
    expect(plan.kind === 'call' && plan.confirm?.body).toBe(
      'This closes the session in Warp and moves it into Bifrost.',
    )
  })

  it('Delete asks and closes the chat window after', () => {
    const plan = planRun('delete', owned, ctx())
    expect(plan).toEqual({
      after: 'close-chat',
      call: 'remove',
      confirm: confirmFor('delete', owned, 'plain'),
      kind: 'call',
    })
    expect(plan.kind === 'call' && plan.confirm?.body).toBe(
      'Delete fix-a? This removes the session and its conversation.',
    )
  })

  it('Take control and Delete always ask, also with the space labels', () => {
    for (const labels of ['plain', 'space'] as const) {
      const take = planRun('take-control', external, ctx({ labels }))
      const del = planRun('delete', parked, ctx({ labels }))
      expect(take.kind === 'call' && take.confirm).not.toBe(null)
      expect(del.kind === 'call' && del.confirm).not.toBe(null)
      expect(take.kind === 'call' && take.confirm).toBeTruthy()
      expect(del.kind === 'call' && del.confirm).toBeTruthy()
    }
  })

  it('Resume starts the attach of an open chat window again', () => {
    expect(planRun('resume', parked, ctx())).toEqual({
      after: 'restart-chat',
      call: 'resume',
      confirm: null,
      kind: 'call',
    })
  })

  it('Show Info gives none', () => {
    expect(planRun('show-info', owned, ctx())).toEqual({ kind: 'none' })
  })

  it('New session and Resume all give none, because they need no row', () => {
    expect(planRun('new-session', owned, ctx())).toEqual({ kind: 'none' })
    expect(planRun('resume-all', owned, ctx())).toEqual({ kind: 'none' })
  })

  it('Open and Close window change the chat window, and Rename opens the dialog', () => {
    expect(planRun('open', owned, ctx())).toEqual({ kind: 'open-chat' })
    expect(planRun('close-window', owned, ctx())).toEqual({ kind: 'close-chat' })
    expect(planRun('rename', owned, ctx())).toEqual({ kind: 'rename' })
  })

  it('Interrupt, Open in terminal and the M3 actions call the API with no confirmation', () => {
    const call = (c: string) => ({ after: 'none', call: c, confirm: null, kind: 'call' })
    expect(planRun('interrupt', working, ctx())).toEqual(call('interrupt'))
    expect(planRun('open-in-terminal', external, ctx())).toEqual(call('open-in-terminal'))
    expect(planRun('set-priority', owned, ctx(), 2)).toEqual(call('set-priority'))
    expect(planRun('copy-id', owned, ctx())).toEqual(call('copy-id'))
    expect(planRun('open-project', owned, ctx(), 'finder')).toEqual(call('open-project'))
  })
})

describe('confirmStep', () => {
  const plain: ConfirmText = { body: 'b', confirm: 'Delete session', title: 'Delete session' }
  const twice: ConfirmText = { ...plain, confirmAgain: 'Delete anyway' }

  it('a click on the confirm button of a plain dialog confirms', () => {
    expect(confirmStep('first', plain)).toEqual({ label: 'Delete session', resolve: true })
  })

  it('the first click with confirmAgain changes the label and does not confirm', () => {
    expect(confirmStep('first', twice)).toEqual({ label: 'Delete anyway', resolve: false })
  })

  it('the second click with confirmAgain confirms', () => {
    expect(confirmStep('again', twice)).toEqual({ label: 'Delete anyway', resolve: true })
  })
})
