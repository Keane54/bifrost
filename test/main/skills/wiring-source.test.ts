// Source checks of the skills wiring in ipc.ts. ipc.ts imports Electron, so a unit test cannot
// load it. These checks read its text.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

const source = readFileSync(join(__dirname, '../../../src/main/ipc.ts'), 'utf8')
const text = source.replace(/\s+/g, ' ')

describe('the skills wiring in ipc.ts', () => {
  it('makes the control with the skills IDs, folder and source', () => {
    expect(text).toContain('createSkillsControl({')
    expect(text).toContain(
      'createPluginCli(runClaude, { marketplace: SKILLS_MARKETPLACE, plugin: SKILLS_PLUGIN_ID })',
    )
    expect(text).toContain("dir: join(paths.bifrostHome, 'skills')")
    expect(text).toContain('source: skillsSourceDir(app.getAppPath())')
  })

  it('starts the skills after Live details in runFirst, with the serviceStopped checks', () => {
    expect(text).toContain(
      'if (!serviceStopped) await live.start() if (!serviceStopped) await skills.start()',
    )
  })

  it('reads the status after the start and runs the four actions in the serial runner', () => {
    expect(text.split("ipcMain.handle('skills:status'")).toHaveLength(2)
    expect(text).toContain(
      "ipcMain.handle('skills:status', e => fromPage(e, () => " +
        'serial.afterFirst(() => skills.status())))',
    )
    for (const name of ['install', 'enable', 'disable', 'uninstall']) {
      expect(text).toContain(`skillsAction('skills:${name}', () => skills.${name}())`)
    }
    expect(text).toContain(
      'const skillsAction = (channel: string, fn: () => Promise<SkillsStatus>): void => { ' +
        'ipcMain.handle(channel, e => fromPage(e, () => serial.run(fn))) }',
    )
  })
})
