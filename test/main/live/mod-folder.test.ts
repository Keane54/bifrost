import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs'
import { rename as realRename, rm as realRm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { afterEach, beforeEach, describe, expect, test } from 'vitest'
import {
  MOD_FILES,
  modFolderCurrent,
  modSourceDir,
  removeModFolder,
  syncModFolder,
  syncWith,
} from '../../../src/main/live/mod-folder'

let root: string
let source: string
let parent: string
let dest: string

function put(base: string, rel: string, text: string) {
  mkdirSync(dirname(join(base, rel)), { recursive: true })
  writeFileSync(join(base, rel), text)
}
function fillSource() {
  for (const f of MOD_FILES) put(source, f, `content of ${f}`)
}
const mode = (p: string) => statSync(p).mode & 0o777

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'bifrost-mod-'))
  source = join(root, 'source')
  parent = join(root, 'home')
  dest = join(parent, 'mod')
  mkdirSync(parent)
  fillSource()
})
afterEach(() => rmSync(root, { force: true, recursive: true }))

describe('mod folder', () => {
  test('syncModFolder copies only the four mod files', async () => {
    put(source, 'tests/register.test.ts', 'x')
    put(source, '.claude-plugin/types/x.d.ts', 'x')
    put(source, 'tsconfig.json', '{}')
    await syncModFolder(source, dest)
    const found: string[] = []
    const walk = (d: string) => {
      for (const e of readdirSync(d, { withFileTypes: true })) {
        const p = join(d, e.name)
        if (e.isDirectory()) {
          expect(mode(p)).toBe(0o700)
          walk(p)
        } else {
          expect(mode(p)).toBe(0o600)
          found.push(p.slice(dest.length + 1))
        }
      }
    }
    walk(dest)
    expect(found.sort()).toEqual([...MOD_FILES].sort())
    expect(mode(dest)).toBe(0o700)
    expect(readFileSync(join(dest, 'hooks/register.ts'), 'utf8')).toBe(
      'content of hooks/register.ts',
    )
  })
  test('modFolderCurrent is true after a sync and false after a change of one file', async () => {
    expect(await modFolderCurrent(source, dest)).toBe(false)
    await syncModFolder(source, dest)
    expect(await modFolderCurrent(source, dest)).toBe(true)
    writeFileSync(join(dest, 'hooks/hooks.json'), 'changed')
    expect(await modFolderCurrent(source, dest)).toBe(false)
  })
  test('syncModFolder replaces an old folder and leaves no temporary folder', async () => {
    put(dest, 'old.txt', 'old')
    await syncModFolder(source, dest)
    expect(readdirSync(dest).sort()).toEqual(['.claude-plugin', 'hooks'])
    expect(readdirSync(parent)).toEqual(['mod'])
  })
  test('syncModFolder changes nothing when a source file is missing', async () => {
    rmSync(join(source, 'hooks/register.ts'))
    put(dest, 'old.txt', 'old')
    await expect(syncModFolder(source, dest)).rejects.toThrow()
    expect(readdirSync(dest)).toEqual(['old.txt'])
    expect(readdirSync(parent)).toEqual(['mod'])
  })
  test('syncModFolder removes the temporary folder and keeps dest when a write fails', async () => {
    put(dest, 'old.txt', 'old')
    chmodSync(parent, 0o500)
    try {
      await expect(syncModFolder(source, dest)).rejects.toThrow()
    } finally {
      chmodSync(parent, 0o700)
    }
    expect(readdirSync(parent)).toEqual(['mod'])
    expect(readdirSync(dest)).toEqual(['old.txt'])
  })
  test('a failed removal of the old folder does not reject and dest is current', async () => {
    put(dest, 'old.txt', 'old')
    const rm = async (p: string, o: { force: true; recursive: true }) => {
      if (p.endsWith('.old')) throw new Error('busy')
      await realRm(p, o)
    }
    await expect(syncWith(source, dest, { rename: realRename, rm })).resolves.toBeUndefined()
    expect(await modFolderCurrent(source, dest)).toBe(true)
  })
  test('a failed restore names the old folder and keeps the first error', async () => {
    put(dest, 'old.txt', 'old')
    let calls = 0
    const rename = async (a: string, b: string) => {
      calls++
      if (calls > 1) throw new Error(`fail ${calls}`)
      await realRename(a, b)
    }
    const rm = async () => {
      throw new Error('cleanup failed')
    }
    const err = await syncWith(source, dest, { rename, rm }).catch((e: Error) => e)
    expect((err as Error).message).toMatch(/fail 2/)
    expect((err as Error).message).toMatch(/\.old/)
    expect((err as Error).message).not.toMatch(/cleanup failed/)
  })
  test('removeModFolder removes the folder and accepts a missing folder', async () => {
    await syncModFolder(source, dest)
    await removeModFolder(dest)
    expect(readdirSync(parent)).toEqual([])
    await expect(removeModFolder(dest)).resolves.toBeUndefined()
  })
  test('modSourceDir uses app.asar.unpacked in the packaged app', () => {
    expect(modSourceDir('/A/Resources/app.asar')).toBe(
      '/A/Resources/app.asar.unpacked/resources/live-mod',
    )
    expect(modSourceDir('/repo')).toBe('/repo/resources/live-mod')
  })
})
