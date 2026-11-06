import { describe, expect, it } from 'vitest'
import {
  type AlertDeps,
  alertText,
  type BoxMark,
  createAlertMonitor,
  findNewBoxes,
  type NewBox,
} from '../../../src/main/alerts/alert-monitor'
import type { Box, SessionRow, SessionState } from '../../../src/shared/types'

const A = 'aaaaaaaa-0000-4000-8000-000000000001'

function row(
  sessionId: string,
  box: Box,
  boxSince: number | null,
  extra: Partial<SessionRow> = {},
): SessionRow {
  return {
    box,
    boxSince,
    cwd: '/Users/dev-user/Developer/bifrost/.m0-sandbox',
    flashing: box !== 'none',
    kind: 'owned',
    lastActivity: 0,
    name: `bifrost-test-${sessionId.slice(-1)}`,
    sessionId,
    startedAt: 0,
    state: box === 'yellow' ? 'idle' : box === 'red' ? 'needs-you' : 'working',
    status: 'busy',
    ...extra,
  } as SessionRow
}

function ids(n: number): string[] {
  return Array.from({ length: n }, (_, i) => `bbbbbbbb-0000-4000-8000-00000000000${i}`)
}

interface Fake {
  deps: AlertDeps
  notes: { title: string; body: string; sessionId: string | null }[]
  sounds: number[]
  set: { notifications: boolean; redBoxSound: boolean; focused: boolean; now: number }
}

function fake(): Fake {
  const set = { focused: false, notifications: true, now: 0, redBoxSound: true }
  const notes: Fake['notes'] = []
  const sounds: number[] = []
  const deps: AlertDeps = {
    focused: () => set.focused,
    notify: n => notes.push(n),
    now: () => set.now,
    playSound: () => sounds.push(set.now),
    settings: () => ({ notifications: set.notifications, redBoxSound: set.redBoxSound }),
  }
  return { deps, notes, set, sounds }
}

describe('findNewBoxes', () => {
  it('a null prev gives marks and no added box', () => {
    const r = findNewBoxes(null, [row(A, 'red', 5), row('x2', 'none', null)])
    expect(r.added).toEqual([])
    expect([...r.marks.entries()]).toEqual([[A, { box: 'red', since: 5 }]])
  })

  it('a session that goes away leaves the marks', () => {
    const first = findNewBoxes(null, [row(A, 'yellow', 1)])
    const next = findNewBoxes(first.marks, [])
    expect(next.marks.has(A)).toBe(false)
    expect(next.added).toEqual([])
  })

  it('a change of box or since is added', () => {
    const prev = new Map<string, BoxMark>([[A, { box: 'yellow', since: 1000 }]])
    expect(findNewBoxes(prev, [row(A, 'yellow', 1000)]).added).toEqual([])
    expect(findNewBoxes(prev, [row(A, 'yellow', 2000)]).added).toHaveLength(1)
    expect(findNewBoxes(prev, [row(A, 'red', 1000)]).added).toHaveLength(1)
  })
})

describe('alertText', () => {
  it('gives the texts for a yellow box, a red box and an error', () => {
    const box = (b: 'yellow' | 'red', state: SessionState): NewBox => ({
      box: b,
      name: 'bifrost-test-a',
      sessionId: A,
      state,
    })
    expect(alertText(box('yellow', 'idle'))).toEqual({
      body: 'Claude finished its turn.',
      title: 'bifrost-test-a',
    })
    expect(alertText(box('red', 'needs-you')).body).toBe('Claude needs you.')
    expect(alertText(box('red', 'error')).body).toBe('The session stopped with an error.')
  })
})

describe('createAlertMonitor', () => {
  it('the first update records the boxes and gives no alert', () => {
    const f = fake()
    const m = createAlertMonitor(f.deps)
    m.update([row(A, 'red', 1000)])
    expect(f.notes).toEqual([])
    expect(f.sounds).toEqual([])
  })

  it('a new yellow box gives a notification when the window is not focused', () => {
    const f = fake()
    const m = createAlertMonitor(f.deps)
    m.update([row(A, 'none', null, { name: 'bifrost-test-a' })])
    m.update([row(A, 'yellow', 1000, { name: 'bifrost-test-a' })])
    expect(f.notes).toEqual([
      { body: 'Claude finished its turn.', sessionId: A, title: 'bifrost-test-a' },
    ])
    expect(f.sounds).toEqual([])
  })

  it('no notification when the window is focused or the setting is off', () => {
    const f = fake()
    const m = createAlertMonitor(f.deps)
    m.update([row(A, 'none', null)])
    f.set.focused = true
    m.update([row(A, 'yellow', 1000)])
    expect(f.notes).toEqual([])
    f.set.focused = false
    f.set.notifications = false
    m.update([row(A, 'yellow', 2000)])
    expect(f.notes).toEqual([])
  })

  it('a new red box plays the sound one time, also when the window is focused', () => {
    const f = fake()
    f.set.focused = true
    const m = createAlertMonitor(f.deps)
    m.update([row(A, 'none', null)])
    m.update([row(A, 'red', 1000)])
    expect(f.sounds).toEqual([0])
    expect(f.notes).toEqual([])
    f.set.now = 10_000
    f.set.redBoxSound = false
    m.update([row(A, 'red', 2000)])
    expect(f.sounds).toEqual([0])
  })

  it('an escalated box is a new red box', () => {
    const f = fake()
    const m = createAlertMonitor(f.deps)
    m.update([row(A, 'yellow', 1000)])
    m.update([row(A, 'red', 601_000, { boxReason: 'escalated' })])
    expect(f.notes).toHaveLength(1)
    expect(f.notes[0]?.body).toBe('Claude needs you.')
    expect(f.sounds).toHaveLength(1)
  })

  it('the same box in the next update gives no alert', () => {
    const f = fake()
    const m = createAlertMonitor(f.deps)
    m.update([row(A, 'none', null)])
    m.update([row(A, 'red', 1000)])
    f.set.now = 5000
    m.update([row(A, 'red', 1000, { lastActivity: 99 })])
    expect(f.notes).toHaveLength(1)
    expect(f.sounds).toEqual([0])
  })

  it('a box that clears and comes back is new', () => {
    const f = fake()
    const m = createAlertMonitor(f.deps)
    m.update([row(A, 'none', null)])
    m.update([row(A, 'yellow', 1000)])
    m.update([row(A, 'none', null)])
    m.update([row(A, 'yellow', 1000)])
    expect(f.notes).toHaveLength(2)
  })

  it('more than 3 new boxes give one summary notification', () => {
    const f = fake()
    const m = createAlertMonitor(f.deps)
    const list = ids(8)
    m.update(list.map(id => row(id, 'yellow', 1000)))
    m.update(list.map(id => row(id, 'red', 601_000)))
    expect(f.notes).toEqual([{ body: '8 sessions need you.', sessionId: null, title: 'Bifrost' }])
    expect(f.sounds).toHaveLength(1)
  })

  it('3 new boxes give 3 notifications', () => {
    const f = fake()
    const m = createAlertMonitor(f.deps)
    const list = ids(3)
    m.update(list.map(id => row(id, 'none', null)))
    m.update(list.map(id => row(id, 'yellow', 1000)))
    expect(f.notes.map(n => n.sessionId)).toEqual(list)
  })

  it('the sound plays at most once each 2 seconds', () => {
    const f = fake()
    const m = createAlertMonitor(f.deps)
    m.update([row(A, 'none', null)])
    for (const [t, since] of [
      [0, 1],
      [1500, 2],
      [2000, 3],
    ] as const) {
      f.set.now = t
      m.update([row(A, 'red', since)])
    }
    expect(f.sounds).toEqual([0, 2000])
  })
})
