import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { rename as realRename, rm as realRm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { afterEach, beforeEach, describe, expect, test } from 'vitest'
import {
  listFiles,
  listSkills,
  removeSkillsFolder,
  skillsFolderCurrent,
  skillsSourceDir,
  syncSkillsFolder,
} from '../../../src/main/skills/skills-folder'

let root: string
let source: string
let dest: string

function put(base: string, rel: string, text: string): void {
  mkdirSync(dirname(join(base, rel)), { recursive: true })
  writeFileSync(join(base, rel), text)
}

function skill(name: string, flag: string | null, extra = ''): string {
  const flagLine = flag === null ? '' : `disable-model-invocation: ${flag}\n`
  return `---\nname: ${name}\ndescription: About ${name}.\n${flagLine}${extra}---\n\nBody\n`
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'bifrost-skills-folder-'))
  source = join(root, 'source')
  dest = join(root, 'home', 'skills')
  put(source, '.claude-plugin/plugin.json', '{"name":"bifrost"}')
  put(source, 'skills/bifrost-b/SKILL.md', skill('bifrost-b', 'true'))
  put(source, 'skills/bifrost-a/SKILL.md', skill('bifrost-a', 'false'))
  put(source, 'skills/bifrost-a/rules.md', 'rules')
})
afterEach(() => {
  rmSync(root, { force: true, recursive: true })
})

describe('skillsSourceDir', () => {
  test('uses app.asar.unpacked in the packaged app', () => {
    expect(skillsSourceDir('/A/Resources/app.asar')).toBe(
      '/A/Resources/app.asar.unpacked/resources/bifrost-skills',
    )
    expect(skillsSourceDir('/repo')).toBe('/repo/resources/bifrost-skills')
  })
})

describe('listFiles', () => {
  test('gives the regular files, relative and sorted, with the dot folder', async () => {
    expect(await listFiles(source)).toEqual([
      '.claude-plugin/plugin.json',
      'skills/bifrost-a/SKILL.md',
      'skills/bifrost-a/rules.md',
      'skills/bifrost-b/SKILL.md',
    ])
  })
  test('gives an empty list for a missing folder', async () => {
    expect(await listFiles(join(root, 'none'))).toEqual([])
  })
})

describe('skillsFolderCurrent', () => {
  test('is false when dest is missing', async () => {
    expect(await skillsFolderCurrent(source, dest)).toBe(false)
  })
  test('is true after a sync', async () => {
    await syncSkillsFolder(source, dest)
    expect(await skillsFolderCurrent(source, dest)).toBe(true)
  })
  test('is false with an extra file', async () => {
    await syncSkillsFolder(source, dest)
    put(dest, 'extra.txt', 'x')
    expect(await skillsFolderCurrent(source, dest)).toBe(false)
  })
  test('is false with a changed byte', async () => {
    await syncSkillsFolder(source, dest)
    put(dest, 'skills/bifrost-a/rules.md', 'rulez')
    expect(await skillsFolderCurrent(source, dest)).toBe(false)
  })
  test('is false when the source has no files', async () => {
    expect(await skillsFolderCurrent(join(root, 'none'), join(root, 'none2'))).toBe(false)
  })
})

describe('syncSkillsFolder', () => {
  test('copies all files and leaves no temporary folder', async () => {
    await syncSkillsFolder(source, dest)
    expect(await listFiles(dest)).toEqual(await listFiles(source))
    expect(readFileSync(join(dest, 'skills/bifrost-a/rules.md'), 'utf8')).toBe('rules')
    expect(readdirSync(dirname(dest))).toEqual(['skills'])
  })
  test('swaps the whole folder, so an extra file goes', async () => {
    put(dest, 'extra.txt', 'x')
    put(dest, 'skills/own/SKILL.md', 'mine')
    await syncSkillsFolder(source, dest)
    expect(await listFiles(dest)).toEqual(await listFiles(source))
  })
  test('a failed rename keeps the old folder', async () => {
    put(dest, 'old.txt', 'old')
    let calls = 0
    const rename = async (a: string, b: string) => {
      calls++
      if (calls === 2) throw new Error('fail')
      await realRename(a, b)
    }
    await expect(syncSkillsFolder(source, dest, { rename, rm: realRm })).rejects.toThrow('fail')
    expect(readdirSync(dest)).toEqual(['old.txt'])
    expect(readdirSync(dirname(dest))).toEqual(['skills'])
  })
  test('a source with no files rejects and changes nothing', async () => {
    put(dest, 'old.txt', 'old')
    await expect(syncSkillsFolder(join(root, 'none'), dest)).rejects.toThrow()
    expect(readdirSync(dest)).toEqual(['old.txt'])
  })
})

describe('removeSkillsFolder', () => {
  test('removes the folder and accepts a missing folder', async () => {
    await syncSkillsFolder(source, dest)
    await removeSkillsFolder(dest)
    expect(readdirSync(dirname(dest))).toEqual([])
    await expect(removeSkillsFolder(dest)).resolves.toBeUndefined()
  })
})

describe('listSkills', () => {
  test('gives name, description and group, sorted by name', async () => {
    expect(await listSkills(source)).toEqual([
      { description: 'About bifrost-a.', group: 'listed', name: 'bifrost-a' },
      { description: 'About bifrost-b.', group: 'called-by-name', name: 'bifrost-b' },
    ])
  })
  test('skips a folder with no SKILL.md or a frontmatter that does not parse', async () => {
    put(source, 'skills/bifrost-c/rules.md', 'no skill file')
    put(source, 'skills/bifrost-d/SKILL.md', 'no frontmatter')
    put(source, 'skills/bifrost-e/SKILL.md', skill('bifrost-e', null))
    expect((await listSkills(source)).map(s => s.name)).toEqual(['bifrost-a', 'bifrost-b'])
  })
  test('rejects when the skills folder is missing', async () => {
    await expect(listSkills(join(root, 'none'))).rejects.toThrow()
  })
})
