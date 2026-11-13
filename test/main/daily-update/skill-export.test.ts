import { mkdtemp, readFile, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { skillExportFile, writeSkillExport } from '../../../src/main/daily-update/skill-export'
import { type DailyUpdateSettings, DEFAULT_DAILY_UPDATE } from '../../../src/shared/daily-update'

let home: string
beforeEach(async () => {
  home = await mkdtemp(join(tmpdir(), 'bifrost-daily-export-'))
})
afterEach(async () => {
  await rm(home, { force: true, recursive: true })
})

const area = (id: string, on: boolean) => ({
  channel: '#c',
  description: 'd',
  id,
  name: id,
  on,
  takesRest: false,
})

const settings: DailyUpdateSettings = {
  ...DEFAULT_DAILY_UPDATE,
  areas: [area('a', true), area('b', false)],
  source: { server: 'board', tools: ['mcp__board__list'] },
  you: 'Sam',
}

describe('writeSkillExport', () => {
  it('gives the path', () => {
    expect(skillExportFile('/h')).toBe('/h/daily-update/settings.json')
  })

  it('holds only you, source, format, mergedPrs and the areas that are on', async () => {
    const file = skillExportFile(home)
    await writeSkillExport(file, settings)
    const data = JSON.parse(await readFile(file, 'utf8'))
    expect(data).toEqual({
      areas: [area('a', true)],
      format: settings.format,
      mergedPrs: true,
      source: settings.source,
      version: 1,
      you: 'Sam',
    })
  })

  it('holds mergedPrs false when the user turned the merged PRs off', async () => {
    const file = skillExportFile(home)
    await writeSkillExport(file, { ...settings, mergedPrs: false })
    expect(JSON.parse(await readFile(file, 'utf8')).mergedPrs).toBe(false)
  })

  it('the file has mode 600', async () => {
    const file = skillExportFile(home)
    await writeSkillExport(file, settings)
    expect((await stat(file)).mode & 0o777).toBe(0o600)
  })
})
