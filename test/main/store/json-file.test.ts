import { mkdir, mkdtemp, readdir, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, expect, test } from 'vitest'
import { readJsonFile, writeJsonAtomic } from '../../../src/main/store/json-file'

let dir: string
beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'bifrost-json-'))
})
afterEach(async () => {
  await rm(dir, { force: true, recursive: true })
})

test('writeJsonAtomic writes the JSON with mode 0600 and leaves no temp file', async () => {
  const file = join(dir, 'sub', 'a.json')
  await writeJsonAtomic(file, { a: 1 })
  expect(JSON.parse(await readFile(file, 'utf8'))).toEqual({ a: 1 })
  expect((await stat(file)).mode & 0o777).toBe(0o600)
  expect(await readdir(join(dir, 'sub'))).toEqual(['a.json'])
})

test('writeJsonAtomic removes the temp file when the rename fails', async () => {
  const target = join(dir, 'target')
  await mkdir(target)
  await expect(writeJsonAtomic(target, { a: 1 })).rejects.toThrow()
  expect(await readdir(dir)).toEqual(['target'])
})

test('readJsonFile reports a missing file, bad JSON and good JSON', async () => {
  expect(await readJsonFile(join(dir, 'missing.json'))).toEqual({ missing: true, ok: false })
  const bad = join(dir, 'bad.json')
  await writeFile(bad, '{ no')
  expect(await readJsonFile(bad)).toEqual({ missing: false, ok: false })
  const good = join(dir, 'good.json')
  await writeFile(good, '{"a":[1]}')
  expect(await readJsonFile(good)).toEqual({ data: { a: [1] }, ok: true })
})

test('readJsonFile rejects other read errors', async () => {
  await expect(readJsonFile(dir)).rejects.toThrow()
})
