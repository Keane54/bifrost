import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, expect, test } from 'vitest'
import { parseStatusJson, readStatusFiles } from '../../../src/main/registry/status-file'

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
