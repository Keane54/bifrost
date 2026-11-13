import { describe, expect, test } from 'vitest'
import {
  canAttach,
  checkChatOpen,
  REFUSED_NOT_ATTACH,
  REFUSED_NOT_CHAT,
  REFUSED_OTHER_SESSION,
} from '../../../src/main/pty/can-attach'
import type { SessionRow } from '../../../src/shared/types'

const row = (o: Partial<SessionRow> = {}): SessionRow => ({
  box: 'none',
  boxSince: null,
  claudeName: 'alpha',
  cwd: '/p',
  flashing: false,
  kind: 'owned',
  lastActivity: 1,
  name: 'alpha',
  sessionId: 's1',
  shortId: 'aa',
  startedAt: 1,
  state: 'idle',
  status: 'idle',
  ...o,
})

test('canAttach allows only an attach to an active owned row', () => {
  expect(canAttach([row()], ['attach', 'aa'])).toBe(true)
  expect(canAttach([row({ kind: 'external' })], ['attach', 'aa'])).toBe(false)
  expect(canAttach([row({ state: 'parked' })], ['attach', 'aa'])).toBe(false)
  expect(canAttach([row()], ['attach', 'zz'])).toBe(false)
  expect(canAttach([row()], ['--bg'])).toBe(false)
  expect(canAttach([row()], ['attach', 'aa', 'x'])).toBe(false)
})

test('canAttach allows the other active states of an owned row', () => {
  for (const state of ['working', 'needs-you', 'error'] as const) {
    expect(canAttach([row({ state })], ['attach', 'aa'])).toBe(true)
  }
})

test('canAttach refuses a short id that two rows have', () => {
  const rows = [row(), row({ sessionId: 's2' })]
  expect(canAttach(rows, ['attach', 'aa'])).toBe(false)
})

test('canAttach refuses args that are not an attach to a short id', () => {
  const rows = [row(), row({ sessionId: 's2', shortId: undefined })]
  expect(canAttach(rows, [])).toBe(false)
  expect(canAttach(rows, ['attach'])).toBe(false)
  expect(canAttach(rows, ['attach', ''])).toBe(false)
  expect(canAttach(rows, ['attach', 's1'])).toBe(false)
  expect(canAttach(rows, ['logs', 'aa'])).toBe(false)
  expect(canAttach(rows, ['attach', 7] as unknown as string[])).toBe(false)
  expect(canAttach(rows, 'attach aa' as unknown as string[])).toBe(false)
  expect(canAttach(rows, null as unknown as string[])).toBe(false)
})

describe('checkChatOpen', () => {
  const S = 'f3a9c2d1-4b5e-4c6d-8e7f-0a1b2c3d4e5f'
  const T = 'a1b2c3d4-0000-4000-8000-000000000000'
  const rows = [
    row({ sessionId: S, shortId: 'abcd1234' }),
    row({ sessionId: T, shortId: 'ef567890' }),
  ]

  test('checkChatOpen allows a chat view with the attach of its own session', () => {
    expect(checkChatOpen(rows, `chat:${S}`, ['attach', 'abcd1234'])).toEqual({
      cwd: '/p',
      ok: true,
      sessionId: S,
    })
  })

  test('checkChatOpen refuses a view that is not a chat view', () => {
    for (const viewId of [`send:${S}`, 'chat:abc', `chat:${S}x`, S, 7, null]) {
      expect(checkChatOpen(rows, viewId, ['attach', 'abcd1234'])).toEqual({
        ok: false,
        reason: REFUSED_NOT_CHAT,
      })
    }
  })

  test('checkChatOpen refuses the short ID of another session', () => {
    expect(checkChatOpen(rows, `chat:${S}`, ['attach', 'ef567890'])).toEqual({
      ok: false,
      reason: REFUSED_OTHER_SESSION,
    })
  })

  test('checkChatOpen refuses an upper-case view ID, because no row has that session ID', () => {
    expect(checkChatOpen(rows, `chat:${S.toUpperCase()}`, ['attach', 'abcd1234'])).toEqual({
      ok: false,
      reason: REFUSED_OTHER_SESSION,
    })
  })

  test('checkChatOpen refuses a parked or external row and args that are not an attach', () => {
    for (const o of [{ state: 'parked' as const }, { kind: 'external' as const }]) {
      const changed = [row({ sessionId: S, shortId: 'abcd1234', ...o })]
      expect(checkChatOpen(changed, `chat:${S}`, ['attach', 'abcd1234'])).toEqual({
        ok: false,
        reason: REFUSED_NOT_ATTACH,
      })
    }
    expect(checkChatOpen(rows, `chat:${S}`, ['--bg'])).toEqual({
      ok: false,
      reason: REFUSED_NOT_ATTACH,
    })
  })
})

describe('checkChatOpen cwd', () => {
  const S = 'f3a9c2d1-4b5e-4c6d-8e7f-0a1b2c3d4e5f'
  test('gives the cwd of the row', () => {
    const r = row({ cwd: '/work/tree', sessionId: S, shortId: 'bb' })
    expect(checkChatOpen([r], `chat:${S}`, ['attach', 'bb'])).toEqual({
      cwd: '/work/tree',
      ok: true,
      sessionId: S,
    })
  })

  test('gives the root folder for a row with no cwd', () => {
    const r = row({ cwd: '', sessionId: S })
    expect(checkChatOpen([r], `chat:${S}`, ['attach', 'aa'])).toMatchObject({ cwd: '/', ok: true })
  })
})

test('checkChatOpen gives the cwd of each active kind of owned row', () => {
  const S = 'f3a9c2d1-4b5e-4c6d-8e7f-0a1b2c3d4e5f'
  for (const state of ['idle', 'working', 'needs-you', 'error'] as const) {
    const r = row({ cwd: '/wt/a', sessionId: S, state })
    expect(checkChatOpen([r], `chat:${S}`, ['attach', 'aa'])).toMatchObject({ cwd: '/wt/a' })
  }
  const parked = row({ sessionId: S, state: 'parked' })
  expect(checkChatOpen([parked], `chat:${S}`, ['attach', 'aa']).ok).toBe(false)
})
