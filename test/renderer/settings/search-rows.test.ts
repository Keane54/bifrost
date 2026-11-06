import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

const SETTINGS = join(__dirname, '../../../src/renderer/src/settings')

// The Save rule (review of batch C, Important 1): the state of a row goes away when the row
// unmounts. A General row that a search hides keeps its hooks, so it must act as unmounted.
describe('a row that the search hides', () => {
  const general = readFileSync(join(SETTINGS, 'GeneralSection.tsx'), 'utf8')
  const row = readFileSync(join(SETTINGS, 'SettingRow.tsx'), 'utf8')
  const keys = readFileSync(join(SETTINGS, 'KeysSection.tsx'), 'utf8')

  it('gives the label of each General row to useRowSave', () => {
    const calls = [...general.matchAll(/useRowSave\(([^)]*)\)/g)].map(m => m[1])
    expect(calls).toHaveLength(8)
    for (const arg of calls) expect(arg).toMatch(/^(?:GENERAL_ROWS\.\w+|props\.label)$/)
  })

  it('removes its save state and its error while the search hides it', () => {
    expect(row).toMatch(/if \(shown\) return\s+tracker\?\.remove\(key\)\s+setError\(null\)/)
  })

  it('in Keys, shows the error at the top when the search hides the row of the error', () => {
    expect(keys).toContain('errorShownAtTop')
  })
})
