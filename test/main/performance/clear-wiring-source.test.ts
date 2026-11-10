// Source checks of the Clear wiring (ipc.ts, preload, API). ipc.ts imports Electron, so a unit
// test cannot load it. These checks read its text.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

const ROOT = join(__dirname, '../../..')
const read = (file: string): string => readFileSync(join(ROOT, file), 'utf8')
const ipc = read('src/main/ipc.ts')

// One space for each run of white space, so a line break of the formatter does not matter.
const flat = (text: string): string =>
  text
    .replace(/\s+/g, ' ')
    .replace(/([([]) /g, '$1')
    .replace(/ ([)\]])/g, '$1')

describe('the Clear wiring', () => {
  it('handles performance:clear through fromPage, clears the log and refreshes the monitor', () => {
    expect(ipc).toMatch(
      /performance:clear'[\s\S]*?fromPage[\s\S]*?health\.clear\(\)[\s\S]*?monitor\.refresh\(\)/,
    )
  })

  it('writes the health log to health.log in the logs folder', () => {
    const text = flat(ipc)
    expect(text).toContain("createRotatingLog(app.getPath('logs'), 'health.log'")
    expect(text).toMatch(
      /createHealthLog\(\(\) => Date\.now\(\), \(\) => net\.isOnline\(\), [^)]*\)/,
    )
  })

  it('has performance.clear in the API and the preload', () => {
    expect(read('src/shared/api.ts')).toMatch(/clear\(\): Promise<void>/)
    expect(read('src/preload/index.ts')).toContain("clear: () => invoke('performance:clear')")
  })
})
