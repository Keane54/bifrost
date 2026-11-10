import { mkdir, mkdtemp, readdir, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, test } from 'vitest'
import { writeNoteFile } from '../../../src/main/handover/note-file'

const NAME = 'fix-login-20261110-090507.md'

// A temporary folder. The tests never write the real ~/.bifrost.
let root: string
let dir: string

beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), 'bifrost-note-file-'))
  dir = join(root, 'home', 'handovers')
})

afterEach(async () => {
  await rm(root, { force: true, recursive: true })
})

describe('writeNoteFile', () => {
  test('the folder gets mode 700 and the file gets mode 600', async () => {
    const path = await writeNoteFile(dir, NAME, '# Hand-over: x\n')
    expect(path).toBe(join(dir, NAME))
    expect(await readFile(path, 'utf8')).toBe('# Hand-over: x\n')
    expect((await stat(dir)).mode & 0o777).toBe(0o700)
    expect((await stat(path)).mode & 0o777).toBe(0o600)
  })

  test('a second write of the same name adds -2, then -3, and the first file stays', async () => {
    const first = await writeNoteFile(dir, NAME, 'first')
    const second = await writeNoteFile(dir, NAME, 'second')
    const third = await writeNoteFile(dir, NAME, 'third')
    expect(second).toBe(join(dir, 'fix-login-20261110-090507-2.md'))
    expect(third).toBe(join(dir, 'fix-login-20261110-090507-3.md'))
    expect(await readFile(first, 'utf8')).toBe('first')
    expect(await readFile(second, 'utf8')).toBe('second')
    expect((await stat(second)).mode & 0o777).toBe(0o600)
  })

  test('a folder at the name is not written over', async () => {
    await mkdir(join(dir, NAME), { recursive: true })
    const path = await writeNoteFile(dir, NAME, 'note')
    expect(path).toBe(join(dir, 'fix-login-20261110-090507-2.md'))
    expect((await stat(join(dir, NAME))).isDirectory()).toBe(true)
  })

  test('an existing folder is used', async () => {
    await mkdir(dir, { recursive: true })
    await writeFile(join(dir, 'other.md'), 'other')
    await writeNoteFile(dir, NAME, 'note')
    expect((await readdir(dir)).sort()).toEqual([NAME, 'other.md'])
  })

  test('a file name that is not a plain name is refused', async () => {
    for (const name of ['', '.', '..', '../x.md', 'a/b.md']) {
      await expect(writeNoteFile(dir, name, 'note'), name).rejects.toThrow()
    }
    await expect(readdir(root)).resolves.toEqual([])
  })
})
