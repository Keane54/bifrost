import { mkdtempSync, readdirSync, rmSync, utimesSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, expect, test } from 'vitest'
import { drainEventDir } from '../../../src/main/registry/event-dir'

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
