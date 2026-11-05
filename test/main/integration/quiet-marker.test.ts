import { mkdtemp, readFile, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { createQuietMarker, QUIET_FILE } from '../../../src/main/integration/quiet-marker'
import type { SessionRow } from '../../../src/shared/types'

const A = '1db8945b-137c-4d57-aaf4-01435209b6e7'
const B = '00000000-1111-2222-3333-444444444444'
const C = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
const D = 'ffffffff-0000-1111-2222-333333333333'

const row = (o: Partial<SessionRow>): SessionRow => ({
  box: 'none',
  boxSince: null,
  cwd: '/p',
  flashing: false,
  kind: 'owned',
  lastActivity: 0,
  name: 'n',
  sessionId: A,
  startedAt: 0,
  state: 'idle',
  status: 'idle',
  ...o,
})

const SESSIONS = '/sessions'
const file = (id: string): string => join(SESSIONS, id, QUIET_FILE)

let dir: string

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'bifrost-quiet-'))
})

afterEach(async () => {
  await rm(dir, { force: true, recursive: true })
})

test('mark writes the quiet file for each owned session that is not parked', async () => {
  expect(QUIET_FILE).toBe('quiet')
  const write = vi.fn(async (_file: string) => {})
  await createQuietMarker(SESSIONS, write).mark([
    row({ kind: 'owned', sessionId: A, state: 'idle' }),
    row({ kind: 'owned', sessionId: B, state: 'parked' }),
    row({ kind: 'external', sessionId: C, state: 'idle' }),
    row({ kind: 'owned', sessionId: D, state: 'working' }),
  ])
  expect(write.mock.calls.map(call => call[0]).sort()).toEqual([file(A), file(D)].sort())
})

test('mark writes each file one time', async () => {
  const write = vi.fn(async (_file: string) => {})
  const marker = createQuietMarker(SESSIONS, write)
  const rows = [row({ sessionId: A }), row({ sessionId: D })]
  await marker.mark(rows)
  await marker.mark(rows)
  expect(write).toHaveBeenCalledTimes(2)
})

test('two calls at the same time write each file one time', async () => {
  let release = (): void => {}
  const gate = new Promise<void>(resolve => {
    release = resolve
  })
  const write = vi.fn((_file: string) => gate)
  const marker = createQuietMarker(SESSIONS, write)
  const first = marker.mark([row({ sessionId: A })])
  const second = marker.mark([row({ sessionId: A })])
  release()
  await Promise.all([first, second])
  expect(write).toHaveBeenCalledTimes(1)
})

test('mark ignores a sessionId that is not a UUID', async () => {
  const write = vi.fn(async (_file: string) => {})
  await createQuietMarker(SESSIONS, write).mark([
    row({ sessionId: '../x' }),
    row({ sessionId: `${A}/../x` }),
  ])
  expect(write).not.toHaveBeenCalled()
})

test('mark tries again after a failed write', async () => {
  const write = vi.fn(async (_file: string) => {}).mockRejectedValueOnce(new Error('disk full'))
  const marker = createQuietMarker(SESSIONS, write)
  await marker.mark([row({ sessionId: A })])
  await marker.mark([row({ sessionId: A })])
  await marker.mark([row({ sessionId: A })])
  expect(write).toHaveBeenCalledTimes(2)
})

test('mark never rejects', async () => {
  const write = vi.fn(async (_file: string) => {
    throw new Error('no access')
  })
  await expect(createQuietMarker(SESSIONS, write).mark([row({ sessionId: A })])).resolves.toBe(
    undefined,
  )
})

test('the default write makes the directory and an empty file with mode 0600', async () => {
  const sessions = join(dir, 'sessions')
  await createQuietMarker(sessions).mark([row({ sessionId: A })])
  const path = join(sessions, A, QUIET_FILE)
  expect(await readFile(path, 'utf8')).toBe('')
  expect((await stat(path)).mode & 0o777).toBe(0o600)
  expect((await stat(join(sessions, A))).mode & 0o777).toBe(0o700)
})
