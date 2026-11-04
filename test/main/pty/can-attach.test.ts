import { expect, test } from 'vitest'
import { canAttach } from '../../../src/main/pty/can-attach'
import type { SessionRow } from '../../../src/shared/types'

const row = (o: Partial<SessionRow> = {}): SessionRow => ({
  box: 'none',
  boxSince: null,
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
