import { mkdir, mkdtemp, readdir, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { writeJsonAtomic } from '../../../src/main/store/json-file'
import { EMPTY_UPDATE_STATE, openUpdateStateStore } from '../../../src/main/updates/state-store'

// Spy on writeJsonAtomic. The spy calls the real function.
vi.mock(import('../../../src/main/store/json-file'), async original => {
  const real = await original()
  return { ...real, writeJsonAtomic: vi.fn(real.writeJsonAtomic) }
})

let dir: string
let file: string
beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'bifrost-updates-state-'))
  file = join(dir, 'updates.json')
  vi.mocked(writeJsonAtomic).mockClear()
})
afterEach(async () => {
  await rm(dir, { force: true, recursive: true })
})

describe('openUpdateStateStore', () => {
  it('gives the defaults when there is no file', async () => {
    const store = await openUpdateStateStore(file)
    expect(store.get()).toEqual({
      attemptedFrom: null,
      attemptedVersion: null,
      notifiedVersion: null,
    })
    expect(EMPTY_UPDATE_STATE).toEqual({
      attemptedFrom: null,
      attemptedVersion: null,
      notifiedVersion: null,
    })
  })

  it('reads the values from the file', async () => {
    const data = { attemptedFrom: '1.1.0', attemptedVersion: '1.2.0', notifiedVersion: '1.3.0' }
    await writeFile(file, JSON.stringify(data))
    const store = await openUpdateStateStore(file)
    expect(store.get()).toEqual(data)
  })

  it('writes the whole state with writeJsonAtomic, and a new store reads it', async () => {
    const store = await openUpdateStateStore(file)
    await store.set({ notifiedVersion: '1.1.0' })
    const saved = { attemptedFrom: null, attemptedVersion: null, notifiedVersion: '1.1.0' }
    expect(store.get()).toEqual(saved)
    expect(writeJsonAtomic).toHaveBeenCalledWith(file, saved)
    expect(JSON.parse(await readFile(file, 'utf8'))).toEqual(saved)
    expect((await stat(file)).mode & 0o777).toBe(0o600)
    expect(await readdir(dir)).toEqual(['updates.json'])
    const again = await openUpdateStateStore(file)
    expect(again.get()).toEqual(saved)
  })

  it('runs two set calls in order and keeps both fields', async () => {
    const store = await openUpdateStateStore(file)
    await Promise.all([
      store.set({ notifiedVersion: '1.1.0' }),
      store.set({ attemptedFrom: '1.0.0', attemptedVersion: '1.1.0' }),
    ])
    const again = await openUpdateStateStore(file)
    expect(again.get()).toEqual({
      attemptedFrom: '1.0.0',
      attemptedVersion: '1.1.0',
      notifiedVersion: '1.1.0',
    })
  })

  it('gives the defaults for a damaged file and does not throw', async () => {
    await writeFile(file, '{ not json')
    const logs: string[] = []
    const store = await openUpdateStateStore(file, m => logs.push(m))
    expect(store.get()).toEqual(EMPTY_UPDATE_STATE)
    expect(logs).toEqual([])
    // A later set writes a good file over the damaged file.
    await store.set({ attemptedVersion: '2.0.0' })
    expect(JSON.parse(await readFile(file, 'utf8')).attemptedVersion).toBe('2.0.0')
  })

  it('gives null for each value that is not a string', async () => {
    await writeFile(
      file,
      JSON.stringify({ attemptedFrom: false, attemptedVersion: 7, notifiedVersion: '1.1.0' }),
    )
    expect((await openUpdateStateStore(file)).get()).toEqual({
      attemptedFrom: null,
      attemptedVersion: null,
      notifiedVersion: '1.1.0',
    })
    await writeFile(file, JSON.stringify(['1.1.0']))
    expect((await openUpdateStateStore(file)).get()).toEqual(EMPTY_UPDATE_STATE)
  })

  it('does not save after a read error, and set does not reject', async () => {
    await mkdir(file)
    const logs: string[] = []
    const store = await openUpdateStateStore(file, m => logs.push(m))
    expect(store.get()).toEqual(EMPTY_UPDATE_STATE)
    expect(logs).toHaveLength(1)
    await store.set({ notifiedVersion: '1.1.0' })
    expect(store.get().notifiedVersion).toBe('1.1.0')
    expect((await stat(file)).isDirectory()).toBe(true)
    expect(writeJsonAtomic).not.toHaveBeenCalled()
  })

  it('logs a failed write, keeps the value in memory, and does not reject', async () => {
    const blocked = join(dir, 'blocked')
    // A file in place of the folder makes the write fail.
    await writeFile(blocked, 'x')
    const logs: Array<[string, unknown]> = []
    const store = await openUpdateStateStore(join(blocked, 'updates.json'), (m, e) =>
      logs.push([m, e]),
    )
    await store.set({ attemptedVersion: '1.1.0' })
    expect(store.get().attemptedVersion).toBe('1.1.0')
    expect(logs).toHaveLength(1)
    expect(logs[0]?.[1]).toBeInstanceOf(Error)
  })
})
