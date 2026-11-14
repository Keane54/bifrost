import { mkdir, mkdtemp, readFile, rm, stat, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  copyModule,
  hashModule,
  MAX_FILE_BYTES,
  MAX_FILES,
  MAX_MODULE_BYTES,
} from '../../../src/main/modules/module-files'

const MANIFEST = {
  description: 'A test.',
  id: 'demo',
  minBifrost: '0.5.0',
  name: 'Demo',
  panels: [{ entry: 'panels/main.html', icon: 'chart-bar', id: 'main', title: 'Demo' }],
  permissions: [],
  version: '1.0.0',
}

let root: string
let src: string
let dest: string
beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), 'bifrost-module-files-'))
  src = join(root, 'src')
  dest = join(root, 'dest')
  await mkdir(join(src, 'panels'), { recursive: true })
  await writeFile(join(src, 'bifrost-module.json'), JSON.stringify(MANIFEST))
  await writeFile(join(src, 'panels', 'main.html'), '<p>hi</p>')
})
afterEach(async () => {
  await rm(root, { force: true, recursive: true })
})

describe('copyModule', () => {
  it('copies the files and skips dot files and dot folders', async () => {
    await mkdir(join(src, '.git'))
    await writeFile(join(src, '.git', 'HEAD'), 'x')
    await writeFile(join(src, '.DS_Store'), 'x')
    const result = await copyModule(src, dest)
    expect(result.ok).toBe(true)
    expect(await readFile(join(dest, 'panels', 'main.html'), 'utf8')).toBe('<p>hi</p>')
    await expect(stat(join(dest, '.git'))).rejects.toThrow()
    await expect(stat(join(dest, '.DS_Store'))).rejects.toThrow()
    if (result.ok) expect(result.hash).toBe(await hashModule(dest))
  })
  it('refuses a symbolic link to a file', async () => {
    await writeFile(join(root, 'outside.txt'), 'x')
    await symlink(join(root, 'outside.txt'), join(src, 'panels', 'link.html'))
    const result = await copyModule(src, dest)
    expect(result.ok).toBe(false)
    await expect(stat(dest)).rejects.toThrow()
  })
  it('refuses a symbolic link to a folder', async () => {
    await symlink(root, join(src, 'loop'))
    expect((await copyModule(src, dest)).ok).toBe(false)
  })
  it('refuses a dangling symbolic link', async () => {
    await symlink(join(root, 'nothing'), join(src, 'dangling'))
    expect((await copyModule(src, dest)).ok).toBe(false)
  })
  it('refuses a file over the file limit', async () => {
    await writeFile(join(src, 'big.bin'), Buffer.alloc(MAX_FILE_BYTES + 1))
    expect((await copyModule(src, dest)).ok).toBe(false)
  })
  it('refuses more files than the limit', async () => {
    await mkdir(join(src, 'many'))
    for (let i = 0; i < MAX_FILES; i += 1) await writeFile(join(src, 'many', `f${i}`), '')
    expect((await copyModule(src, dest)).ok).toBe(false)
  }, 30_000)
  it('refuses a total over the module limit', async () => {
    const chunk = Buffer.alloc(MAX_FILE_BYTES)
    for (let i = 0; i < MAX_MODULE_BYTES / MAX_FILE_BYTES; i += 1) {
      await writeFile(join(src, `c${i}.bin`), chunk)
    }
    expect((await copyModule(src, dest)).ok).toBe(false)
  }, 30_000)
  it('refuses a root that is a symbolic link', async () => {
    const link = join(root, 'rootlink')
    await symlink(src, link)
    expect((await copyModule(link, dest)).ok).toBe(false)
  })
  it('counts folders toward the file limit', async () => {
    for (let i = 0; i <= MAX_FILES; i += 1) await mkdir(join(src, `d${i}`))
    expect((await copyModule(src, dest)).ok).toBe(false)
  }, 30_000)
  it('refuses a file that becomes a symbolic link after the walk', async () => {
    await writeFile(join(root, 'secret.txt'), 'secret')
    const result = await copyModule(src, dest, {
      beforeCopy: async () => {
        await rm(join(src, 'panels', 'main.html'))
        await symlink(join(root, 'secret.txt'), join(src, 'panels', 'main.html'))
      },
    })
    expect(result.ok).toBe(false)
    await expect(stat(dest)).rejects.toThrow()
  })
  it('refuses a folder that becomes a symbolic link after the walk', async () => {
    await mkdir(join(root, 'evil', 'panels'), { recursive: true })
    await writeFile(join(root, 'evil', 'panels', 'main.html'), 'evil')
    const result = await copyModule(src, dest, {
      beforeCopy: async () => {
        await rm(join(src, 'panels'), { recursive: true })
        await symlink(join(root, 'evil', 'panels'), join(src, 'panels'))
      },
    })
    expect(result.ok).toBe(false)
    await expect(stat(dest)).rejects.toThrow()
  })
  it('refuses a missing manifest', async () => {
    await rm(join(src, 'bifrost-module.json'))
    expect((await copyModule(src, dest)).ok).toBe(false)
  })
  it('refuses a manifest that is not valid', async () => {
    await writeFile(join(src, 'bifrost-module.json'), '{ nope')
    expect((await copyModule(src, dest)).ok).toBe(false)
    await writeFile(join(src, 'bifrost-module.json'), JSON.stringify({ ...MANIFEST, id: 'X' }))
    expect((await copyModule(src, dest)).ok).toBe(false)
  })
  it('refuses a missing source', async () => {
    expect((await copyModule(join(root, 'none'), dest)).ok).toBe(false)
  })
})

describe('hashModule', () => {
  it('is the same for two copies and changes with one byte', async () => {
    const a = await copyModule(src, join(root, 'a'))
    const b = await copyModule(src, join(root, 'b'))
    if (!a.ok || !b.ok) throw new Error('copy failed')
    expect(a.hash).toBe(b.hash)
    await writeFile(join(root, 'b', 'panels', 'main.html'), '<p>hj</p>')
    expect(await hashModule(join(root, 'b'))).not.toBe(a.hash)
  })
  it('changes when a file is renamed', async () => {
    const a = await copyModule(src, join(root, 'a'))
    if (!a.ok) throw new Error('copy failed')
    await writeFile(join(src, 'panels', 'other.html'), '<p>hi</p>')
    const b = await copyModule(src, join(root, 'b'))
    expect(b.ok && b.hash).not.toBe(a.hash)
  })
})
