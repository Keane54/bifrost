import { existsSync } from 'node:fs'
import { chmod, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, expect, test } from 'vitest'
import { ACTIVE_FILE, createActiveMarker } from '../../../src/main/integration/active-marker'

let dir: string
let home: string

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'bifrost-active-'))
  home = join(dir, 'bifrost-home')
})

afterEach(async () => {
  await rm(dir, { force: true, recursive: true })
})

test('create makes the directory and an empty file with mode 0600', async () => {
  expect(ACTIVE_FILE).toBe('active')
  await createActiveMarker(home).create()
  const file = join(home, 'active')
  expect(await readFile(file, 'utf8')).toBe('')
  expect((await stat(file)).mode & 0o777).toBe(0o600)
})

test('create sets mode 0600 on a file that exists and a second create works', async () => {
  const marker = createActiveMarker(home)
  await marker.create()
  const file = join(home, 'active')
  await writeFile(file, 'x')
  await chmod(file, 0o644)
  await marker.create()
  expect(await readFile(file, 'utf8')).toBe('')
  expect((await stat(file)).mode & 0o777).toBe(0o600)
})

test('remove deletes the file', async () => {
  const marker = createActiveMarker(home)
  await marker.create()
  marker.remove()
  expect(existsSync(join(home, 'active'))).toBe(false)
})

test('remove of a missing file does not throw', () => {
  const marker = createActiveMarker(home)
  expect(() => marker.remove()).not.toThrow()
  expect(() => createActiveMarker('/no/such/dir').remove()).not.toThrow()
})
