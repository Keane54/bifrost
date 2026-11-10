import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  openReleaseNotesStore,
  parseReleaseNotesState,
  releaseNotesFile,
} from '../../../src/main/release-notes/state-store'

let dir: string
let file: string
beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'bifrost-release-notes-'))
  file = join(dir, 'release-notes.json')
})
afterEach(async () => {
  await rm(dir, { force: true, recursive: true })
})

describe('releaseNotesFile', () => {
  it('gives release-notes.json in the data folder', () => {
    expect(releaseNotesFile('/tmp/user-data')).toBe('/tmp/user-data/release-notes.json')
  })
})

describe('parseReleaseNotesState', () => {
  it('keeps a text and gives null for each other value', () => {
    expect(parseReleaseNotesState({ lastSeenVersion: '0.4.0' })).toEqual({
      lastSeenVersion: '0.4.0',
    })
    for (const bad of [null, undefined, 7, 'x', ['0.4.0'], {}, { lastSeenVersion: 4 }]) {
      expect(parseReleaseNotesState(bad)).toEqual({ lastSeenVersion: null })
    }
  })
})

describe('openReleaseNotesStore', () => {
  it('gives null for a missing file, and a set writes the file', async () => {
    const store = await openReleaseNotesStore(file)
    expect(store.get()).toEqual({ lastSeenVersion: null })
    await store.set({ lastSeenVersion: '0.5.0' })
    expect(store.get()).toEqual({ lastSeenVersion: '0.5.0' })
    expect(JSON.parse(await readFile(file, 'utf8'))).toEqual({ lastSeenVersion: '0.5.0' })
    const again = await openReleaseNotesStore(file)
    expect(again.get()).toEqual({ lastSeenVersion: '0.5.0' })
  })

  it('gives null for a file that is not JSON, and can write over it', async () => {
    await writeFile(file, '{not json')
    const store = await openReleaseNotesStore(file)
    expect(store.get()).toEqual({ lastSeenVersion: null })
    await store.set({ lastSeenVersion: '0.5.0' })
    expect(JSON.parse(await readFile(file, 'utf8'))).toEqual({ lastSeenVersion: '0.5.0' })
  })

  it('does not write over a file that it cannot read, and keeps the value in memory', async () => {
    // A folder at the path of the file gives EISDIR.
    await mkdir(file)
    const log = vi.fn()
    const store = await openReleaseNotesStore(file, log)
    expect(log).toHaveBeenCalledTimes(1)
    await store.set({ lastSeenVersion: '0.5.0' })
    expect(store.get()).toEqual({ lastSeenVersion: '0.5.0' })
    expect(log).toHaveBeenCalledTimes(1)
  })

  it('never rejects for a failed write, and logs it', async () => {
    const log = vi.fn()
    const store = await openReleaseNotesStore(join(dir, 'file-as-parent', 'x.json'), log)
    await writeFile(join(dir, 'file-as-parent'), 'a file')
    await expect(store.set({ lastSeenVersion: '0.5.0' })).resolves.toBeUndefined()
    expect(log).toHaveBeenCalledTimes(1)
    expect(store.get()).toEqual({ lastSeenVersion: '0.5.0' })
  })
})
