import { mkdirSync, mkdtempSync, readdirSync, rmSync, utimesSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, expect, test } from 'vitest'
import {
  cleanStatusTemps,
  parseStatusJson,
  readStatusFiles,
  STATUS_TEMP_MAX_AGE_MS,
} from '../../../src/main/registry/status-file'

let dir: string
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'bifrost-sessions-'))
})
afterEach(() => {
  rmSync(dir, { force: true, recursive: true })
})

test('parseStatusJson reads the four values', () => {
  const t =
    '{"model":{"display_name":"Haiku 4.5"},"context_window":{"used_percentage":12},"cost":{"total_cost_usd":0.03},"session_name":"x"}'
  expect(parseStatusJson(t, 7)).toEqual({
    contextPercent: 12,
    costUsd: 0.03,
    model: 'Haiku 4.5',
    sessionName: 'x',
    updatedAt: 7,
  })
})

test('parseStatusJson returns null for bad JSON and keeps missing values out', () => {
  expect(parseStatusJson('nope', 1)).toBeNull()
  expect(parseStatusJson('{}', 3)).toEqual({ updatedAt: 3 })
})

test('readStatusFiles skips a directory name that is not a UUID', async () => {
  const id = '123e4567-e89b-12d3-a456-426614174000'
  for (const name of [id, 'not-a-uuid']) {
    mkdirSync(join(dir, name))
    writeFileSync(join(dir, name, 'status.json'), '{"session_name":"x"}')
  }
  const map = await readStatusFiles(dir)
  expect([...map.keys()]).toEqual([id])
  expect(map.get(id)?.sessionName).toBe('x')
})

test('readStatusFiles returns an empty map for a missing directory', async () => {
  expect((await readStatusFiles('/no/such/dir')).size).toBe(0)
})

test('cleanStatusTemps deletes old temporary files and keeps the rest', async () => {
  expect(STATUS_TEMP_MAX_AGE_MS).toBe(60_000)
  const now = 1_800_000_000_000
  const id = '123e4567-e89b-12d3-a456-426614174000'
  const put = (name: string, ageMs: number): void => {
    const path = join(dir, name)
    writeFileSync(path, '{}')
    utimesSync(path, (now - ageMs) / 1000, (now - ageMs) / 1000)
  }
  mkdirSync(join(dir, id))
  mkdirSync(join(dir, 'not-a-uuid'))
  put(`${id}/.status.1`, 60_001)
  put(`${id}/.status.2`, 1000)
  put(`${id}/status.json`, 999_000)
  put('not-a-uuid/.status.3', 999_000)
  expect(await cleanStatusTemps(dir, now, 60_000)).toBe(1)
  expect(readdirSync(join(dir, id)).sort()).toEqual(['.status.2', 'status.json'])
  expect(readdirSync(join(dir, 'not-a-uuid'))).toEqual(['.status.3'])
})

test('cleanStatusTemps gives 0 for a missing directory', async () => {
  expect(await cleanStatusTemps('/no/such/dir', 0, 60_000)).toBe(0)
})
