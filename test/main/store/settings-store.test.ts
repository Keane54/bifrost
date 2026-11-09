import { mkdir, mkdtemp, readdir, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { openSettingsStore } from '../../../src/main/store/settings-store'
import { DEFAULT_SETTINGS } from '../../../src/shared/settings'

let dir: string
let file: string
beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'bifrost-settings-'))
  file = join(dir, 'settings.json')
})
afterEach(async () => {
  await rm(dir, { force: true, recursive: true })
})

const readSaved = async (): Promise<Record<string, unknown>> =>
  JSON.parse(await readFile(file, 'utf8'))

test('openSettingsStore gives the defaults for a missing file and saves an update', async () => {
  const store = await openSettingsStore(file)
  expect(store.get()).toEqual(DEFAULT_SETTINGS)
  const next = await store.update({ labels: 'space' })
  expect(next).toEqual({ ...DEFAULT_SETTINGS, labels: 'space' })
  expect(store.get()).toBe(next)
  expect(await readSaved()).toEqual({ ...DEFAULT_SETTINGS, labels: 'space' })
  expect((await stat(file)).mode & 0o777).toBe(0o600)
})

test('openSettingsStore gives the defaults for bad JSON and saves an update', async () => {
  await writeFile(file, '{ no')
  const store = await openSettingsStore(file)
  expect(store.get()).toEqual(DEFAULT_SETTINGS)
  await store.update({ pollSeconds: 5 })
  expect(await readSaved()).toMatchObject({ pollSeconds: 5, version: 1 })
})

test('openSettingsStore keeps the good values of a damaged file', async () => {
  await writeFile(
    file,
    JSON.stringify({
      keys: { 'nope:mod': 'Mod+J', 'open:mod': 'Mod+K' },
      labels: 'space',
      pollSeconds: 0,
      slashCommands: ['/review', '/two\nlines'],
      terminalFont: { family: 'Menlo', size: 200 },
      theme: 'light',
      version: 1,
    }),
  )
  const store = await openSettingsStore(file)
  expect(store.get()).toEqual({
    ...DEFAULT_SETTINGS,
    keys: { 'open:mod': 'Mod+K' },
    labels: 'space',
    pollSeconds: 2,
    slashCommands: ['/review'],
    terminalFont: { family: 'Menlo', size: 13 },
  })
})

test('openSettingsStore does not overwrite a file that it cannot read', async () => {
  // The path is a directory, so the read fails with EISDIR.
  await mkdir(file)
  const log = vi.fn()
  const store = await openSettingsStore(file, log)
  expect(log).toHaveBeenCalledOnce()
  expect(store.get()).toEqual(DEFAULT_SETTINGS)
  const next = await store.update({ labels: 'space' })
  expect(next.labels).toBe('space')
  expect(store.get().labels).toBe('space')
  expect(log).toHaveBeenCalledOnce()
  // Nothing writes: the directory stays empty and no temporary file is next to it.
  expect((await stat(file)).isDirectory()).toBe(true)
  expect(await readdir(file)).toEqual([])
  expect(await readdir(dir)).toEqual(['settings.json'])
})

test('update rejects a bad patch with the reason and calls no listener', async () => {
  const store = await openSettingsStore(file)
  const listener = vi.fn()
  store.onChange(listener)
  await expect(store.update({ pollSeconds: 4 })).rejects.toThrow('refused: bad pollSeconds')
  await expect(store.update(null)).rejects.toThrow('refused: bad settings')
  await expect(store.update({ theme: 'light' })).rejects.toThrow('refused: unknown setting theme')
  expect(listener).not.toHaveBeenCalled()
  expect(store.get()).toEqual(DEFAULT_SETTINGS)
  await expect(readFile(file, 'utf8')).rejects.toThrow()
  // A refused update does not stop the next update.
  await store.update({ labels: 'space' })
  expect(listener).toHaveBeenCalledOnce()
})

test('update calls onChange with the new and the old settings, and not for a patch that changes nothing', async () => {
  const store = await openSettingsStore(file)
  const listener = vi.fn()
  const off = store.onChange(listener)
  const old = store.get()
  const next = await store.update({ labels: 'space' })
  expect(listener).toHaveBeenCalledOnce()
  expect(listener).toHaveBeenCalledWith(next, old)
  expect(listener.mock.calls[0][1].labels).toBe('plain')
  // A patch that changes nothing does not write and does not call the listener.
  await rm(file)
  expect(await store.update({ labels: 'space' })).toBe(next)
  expect(listener).toHaveBeenCalledOnce()
  await expect(readFile(file, 'utf8')).rejects.toThrow()
  // After off, the listener gets no call.
  off()
  await store.update({ labels: 'plain' })
  expect(listener).toHaveBeenCalledOnce()
})

test('change computes the patch from the newest settings, so two quick steps give 120', async () => {
  const store = await openSettingsStore(file)
  const step = (): Promise<unknown> =>
    store.change(settings => ({ interfaceScale: settings.interfaceScale + 10 }))
  await Promise.all([step(), step()])
  expect(store.get().interfaceScale).toBe(120)
  expect((await readSaved()).interfaceScale).toBe(120)
})

test('change rejects a bad patch with the reason, and the next change still runs', async () => {
  const store = await openSettingsStore(file)
  await expect(store.change(() => ({ interfaceScale: 155 }))).rejects.toThrow(
    'refused: bad interfaceScale',
  )
  await store.change(settings => ({ interfaceScale: settings.interfaceScale - 10 }))
  expect(store.get().interfaceScale).toBe(90)
})

test('two quick updates apply one after the other', async () => {
  const store = await openSettingsStore(file)
  await Promise.all([
    store.update({ keys: { 'open:mod': 'Mod+K' }, slashCommands: ['/a'] }),
    store.update({ labels: 'space' }),
    store.update({ pollSeconds: 10 }),
  ])
  const expected = {
    ...DEFAULT_SETTINGS,
    keys: { 'open:mod': 'Mod+K' },
    labels: 'space',
    pollSeconds: 10,
    slashCommands: ['/a'],
  }
  expect(store.get()).toEqual(expected)
  expect(await readSaved()).toEqual(expected)
})

test('the first write over a later version keeps a copy of the file, one time', async () => {
  const later = `${JSON.stringify({ labels: 'space', newThing: { a: 1 }, version: 2 }, null, 4)}\n`
  await writeFile(file, later, { mode: 0o644 })
  const backup = join(dir, 'settings.v2.backup.json')
  const store = await openSettingsStore(file)
  // The open itself writes nothing.
  expect(await readdir(dir)).toEqual(['settings.json'])
  await store.update({ pollSeconds: 5 })
  expect(await readFile(backup, 'utf8')).toBe(later)
  expect((await stat(backup)).mode & 0o777).toBe(0o600)
  expect(await readSaved()).toMatchObject({ pollSeconds: 5, version: 1 })
  // The second write does not copy again.
  await rm(backup)
  await store.update({ pollSeconds: 10 })
  expect(await readdir(dir)).toEqual(['settings.json'])
})

test('the copy replaces an old copy and gets mode 0600', async () => {
  await writeFile(file, JSON.stringify({ version: 2 }))
  const backup = join(dir, 'settings.v2.backup.json')
  await writeFile(backup, 'old', { mode: 0o644 })
  await (await openSettingsStore(file)).update({ pollSeconds: 5 })
  expect(await readFile(backup, 'utf8')).toBe(JSON.stringify({ version: 2 }))
  expect((await stat(backup)).mode & 0o777).toBe(0o600)
})

test('a file of version 1, a missing file and bad JSON give no copy', async () => {
  await writeFile(file, JSON.stringify({ version: 1 }))
  await (await openSettingsStore(file)).update({ pollSeconds: 5 })
  await rm(file)
  await (await openSettingsStore(file)).update({ pollSeconds: 5 })
  await writeFile(file, '{ "version": 3')
  await (await openSettingsStore(file)).update({ pollSeconds: 5 })
  expect(await readdir(dir)).toEqual(['settings.json'])
})

test('a failed copy keeps the later file and turns the save off', async () => {
  await writeFile(file, JSON.stringify({ version: 4 }))
  // A directory with the name of the copy makes the copy fail.
  await mkdir(join(dir, 'settings.v4.backup.json'))
  const log = vi.fn()
  const store = await openSettingsStore(file, log)
  const next = await store.update({ labels: 'space' })
  expect(next.labels).toBe('space')
  expect(log).toHaveBeenCalledOnce()
  expect(JSON.parse(await readFile(file, 'utf8'))).toEqual({ version: 4 })
  await store.update({ pollSeconds: 5 })
  expect(JSON.parse(await readFile(file, 'utf8'))).toEqual({ version: 4 })
})

test('the health log gets each write: a failed write and a good write', async () => {
  const save = vi.fn()
  const store = await openSettingsStore(file, vi.fn(), { save })
  // A folder in place of the file makes the write fail.
  await mkdir(file)
  await expect(store.update({ labels: 'space' })).rejects.toThrow()
  await rm(file, { recursive: true })
  await store.update({ labels: 'space' })
  // A refused patch and a patch that changes nothing write nothing.
  await expect(store.update({ nope: 1 })).rejects.toThrow()
  await store.update({ labels: 'space' })
  expect(save.mock.calls).toEqual([
    ['settings', false],
    ['settings', true],
  ])
})
