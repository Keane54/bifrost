import { mkdtempSync, readdirSync, rmSync, utimesSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, expect, test } from 'vitest'
import {
  cleanEventDir,
  drainEventDir,
  PARTIAL_GRACE_MS,
} from '../../../src/main/registry/event-dir'

let dir: string
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'bifrost-events-'))
})
afterEach(() => {
  rmSync(dir, { force: true, recursive: true })
})

function put(name: string, text: string, mtimeSeconds: number): void {
  const path = join(dir, name)
  writeFileSync(path, text)
  utimesSync(path, mtimeSeconds, mtimeSeconds)
}

const stop = (id: string) => `{"hook_event_name":"Stop","session_id":"${id}"}`

test('drainEventDir sorts by mtime, deletes the files and ignores temporary files', async () => {
  put('b.json', stop('b'), 1)
  put('a.json', stop('a'), 2)
  put('bad.json', 'not json', 3)
  put('.tmp.1', stop('t'), 1)
  const result = await drainEventDir(dir)
  expect(result.events.map(e => e.sessionId)).toEqual(['b', 'a'])
  expect(result.events.map(e => e.at)).toEqual([1000, 2000])
  expect(result.errors).toBe(1)
  expect(readdirSync(dir)).toEqual(['.tmp.1'])
})

test('drainEventDir counts an empty file as an error and deletes it', async () => {
  put('empty.json', '', 1)
  expect(await drainEventDir(dir)).toEqual({ errors: 1, events: [] })
  expect(readdirSync(dir)).toEqual([])
})

test('drainEventDir sorts files with the same mtime by name', async () => {
  put('2.json', stop('two'), 5)
  put('1.json', stop('one'), 5)
  const result = await drainEventDir(dir)
  expect(result.events.map(e => e.sessionId)).toEqual(['one', 'two'])
})

test('drainEventDir returns nothing for a missing directory', async () => {
  expect(await drainEventDir('/no/such/dir')).toEqual({ errors: 0, events: [] })
})

// The mtime of each file below is NOW minus the given age, in milliseconds.
const NOW = 1_800_000_000_000

function putAged(name: string, text: string, ageMs: number): void {
  put(name, text, (NOW - ageMs) / 1000)
}

test('drainEventDir keeps a young file that does not parse and counts no error', async () => {
  expect(PARTIAL_GRACE_MS).toBe(5000)
  putAged('partial.json', '{"hook_event_name":"St', 1000)
  putAged('a.json', stop('a'), 2000)
  const result = await drainEventDir(dir, NOW)
  expect(result).toEqual({ errors: 0, events: [expect.objectContaining({ sessionId: 'a' })] })
  expect(readdirSync(dir)).toEqual(['partial.json'])
})

test('drainEventDir deletes an old file that does not parse and counts it', async () => {
  putAged('bad.json', '{"hook_event_name":"St', PARTIAL_GRACE_MS)
  putAged('empty.json', '', PARTIAL_GRACE_MS + 1000)
  expect(await drainEventDir(dir, NOW)).toEqual({ errors: 2, events: [] })
  expect(readdirSync(dir)).toEqual([])
})

test('drainEventDir reads a partial file at a later drain when it is complete', async () => {
  putAged('late.json', '{"hook_event_name":"St', 100)
  expect(await drainEventDir(dir, NOW)).toEqual({ errors: 0, events: [] })
  putAged('late.json', stop('late'), 100)
  const result = await drainEventDir(dir, NOW + 500)
  expect(result.events.map(e => e.sessionId)).toEqual(['late'])
  expect(readdirSync(dir)).toEqual([])
})

test('cleanEventDir deletes old event files and temporary files and keeps young files', async () => {
  putAged('old.json', stop('old'), 60_001)
  putAged('old-bad.json', 'not json', 120_000)
  putAged('young.json', stop('young'), 60_000)
  putAged('.tmp.123', stop('t'), 0)
  putAged('notes.txt', 'x', 120_000)
  putAged('.hidden.json', 'x', 120_000)
  expect(await cleanEventDir(dir, NOW, 60_000)).toBe(3)
  expect(readdirSync(dir).sort()).toEqual(['.hidden.json', 'notes.txt', 'young.json'])
})

test('cleanEventDir gives 0 for a missing directory', async () => {
  expect(await cleanEventDir('/no/such/dir', NOW, 60_000)).toBe(0)
})
