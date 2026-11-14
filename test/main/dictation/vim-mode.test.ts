// Tests of the vim mode check of dictation (ruling D7). Fake files stand in for the settings, so
// no test reads the real ~/.claude.json or ~/.claude/settings.json. fileStamp uses a temp folder.
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it, vi } from 'vitest'
import { createVimModeCheck, fileStamp, vimModeOf } from '../../../src/main/dictation/vim-mode'

describe('vimModeOf', () => {
  it.each([
    [{ vimMode: true }],
    [{ vimModeEnabled: true }],
    [{ isVimModeEnabled: true }],
    [{ vimMode: 'vim' }],
    [{ editorMode: 'vim' }],
    [{ editorMode: 'Vim ' }],
    [{ EDITOR_MODES: 'vim' }],
  ])('counts %j as vim mode', data => {
    expect(vimModeOf(data)).toBe(true)
  })

  it.each([
    [{}],
    [{ vimMode: false }],
    [{ vimModeEnabled: 'false' }],
    [{ editorMode: 'normal' }],
    [{ EDITOR_MODES: ['normal', 'vim'] }],
    [{ projects: { '/a': { vimMode: true } } }],
    [null],
    ['vim'],
    [[{ vimMode: true }]],
  ])('does not count %j as vim mode', data => {
    expect(vimModeOf(data)).toBe(false)
  })
})

// The fake files: a stamp and a content for each path. A content of 'bad' fails the parse.
function files(initial: Record<string, { mtimeMs: number; size: number; data: unknown }>) {
  const disk = new Map(Object.entries(initial))
  const read = vi.fn(async (file: string) => {
    const entry = disk.get(file)
    return entry === undefined || entry.data === 'bad' ? null : entry.data
  })
  const stat = vi.fn(async (file: string) => {
    const entry = disk.get(file)
    return entry === undefined ? null : { mtimeMs: entry.mtimeMs, size: entry.size }
  })
  return { disk, read, stat }
}

const JSON_FILE = '/home/.claude.json'
const SETTINGS = '/home/.claude/settings.json'

describe('createVimModeCheck', () => {
  it('reads each file and finds vim mode in any of them', async () => {
    const f = files({
      [JSON_FILE]: { data: { theme: 'dark' }, mtimeMs: 1, size: 10 },
      [SETTINGS]: { data: { editorMode: 'vim' }, mtimeMs: 1, size: 10 },
    })
    const check = createVimModeCheck([JSON_FILE, SETTINGS], f)
    await expect(check()).resolves.toBe(true)
    expect(f.read.mock.calls.map(call => call[0]).sort()).toEqual([JSON_FILE, SETTINGS].sort())
  })

  it('parses a file again only when its time or its size changes', async () => {
    const f = files({ [JSON_FILE]: { data: { theme: 'dark' }, mtimeMs: 1, size: 10 } })
    const check = createVimModeCheck([JSON_FILE], f)
    for (let i = 0; i < 5; i++) await expect(check()).resolves.toBe(false)
    expect(f.stat).toHaveBeenCalledTimes(5)
    expect(f.read).toHaveBeenCalledTimes(1)
    f.disk.set(JSON_FILE, { data: { editorMode: 'vim' }, mtimeMs: 2, size: 10 })
    await expect(check()).resolves.toBe(true)
    f.disk.set(JSON_FILE, { data: { editorMode: 'normal' }, mtimeMs: 2, size: 11 })
    await expect(check()).resolves.toBe(false)
    await expect(check()).resolves.toBe(false)
    expect(f.read).toHaveBeenCalledTimes(3)
  })

  it('keeps the last good value at a parse error, and gives false with no good value', async () => {
    const f = files({ [JSON_FILE]: { data: { vimMode: true }, mtimeMs: 1, size: 10 } })
    const check = createVimModeCheck([JSON_FILE], f)
    await expect(check()).resolves.toBe(true)
    // Claude writes the file again, and the read sees a part of it.
    f.disk.set(JSON_FILE, { data: 'bad', mtimeMs: 2, size: 4 })
    await expect(check()).resolves.toBe(true)
    await expect(check()).resolves.toBe(true)
    expect(f.read).toHaveBeenCalledTimes(2)
    const fresh = files({ [JSON_FILE]: { data: 'bad', mtimeMs: 1, size: 4 } })
    await expect(createVimModeCheck([JSON_FILE], fresh)()).resolves.toBe(false)
  })

  it('gives false for a missing file and for a stat or a read that fails', async () => {
    const f = files({ [JSON_FILE]: { data: { vimMode: true }, mtimeMs: 1, size: 10 } })
    const check = createVimModeCheck([JSON_FILE, SETTINGS], f)
    await expect(check()).resolves.toBe(true)
    f.disk.delete(JSON_FILE)
    await expect(check()).resolves.toBe(false)
    const failing = createVimModeCheck([JSON_FILE], {
      read: async () => {
        throw new Error('EACCES')
      },
      stat: async () => {
        throw new Error('EACCES')
      },
    })
    await expect(failing()).resolves.toBe(false)
  })
})

describe('fileStamp', () => {
  it('gives the time and the size of a regular file, and null for no file', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'bifrost-vim-'))
    try {
      const file = join(dir, 'settings.json')
      await writeFile(file, '{"a":1}')
      const stamp = await fileStamp(file)
      expect(stamp?.size).toBe(7)
      expect(typeof stamp?.mtimeMs).toBe('number')
      await expect(fileStamp(join(dir, 'none.json'))).resolves.toBeNull()
      await expect(fileStamp(dir)).resolves.toBeNull()
    } finally {
      await rm(dir, { force: true, recursive: true })
    }
  })
})
