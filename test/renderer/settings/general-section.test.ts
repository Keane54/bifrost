import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { GENERAL_ROWS } from '../../../src/renderer/src/settings/general-rows'
import { searchSettings, settingsIndex } from '../../../src/renderer/src/settings/search'

// The repository has no DOM test. So this test reads the source text of the section.
const SECTION = readFileSync(
  join(__dirname, '../../../src/renderer/src/settings/GeneralSection.tsx'),
  'utf8',
)

// The JSX element of one CheckRow, from its start to its end.
function checkRow(name: string): string {
  const rows = SECTION.split('<CheckRow').slice(1)
  const row = rows.find(text => text.includes(`label={GENERAL_ROWS.${name}}`))
  if (!row) throw new Error(`No CheckRow ${name}`)
  return row.slice(0, row.indexOf('/>'))
}

describe('Settings > General', () => {
  // User decision, 2026-11-06: the background shifts slowly. A check row turns the motion off.
  it('has an Animated background check row with a friendly hint', () => {
    expect(GENERAL_ROWS.animatedBackground).toBe('Animated background')
    const row = checkRow('animatedBackground')
    expect(row).toContain('checked={settings.animatedBackground}')
    expect(row).toContain('save={value => update({ animatedBackground: value })}')
    expect(row).toContain(
      "hint='Slowly shifting colours behind the panels. Turn it off to save battery.'",
    )
  })

  it('the search of Settings finds the Animated background row', () => {
    const sections = settingsIndex({ keys: [], live: [], skills: [], slash: [] })
    for (const query of ['animated', 'background', 'Animated background']) {
      const hits = searchSettings(query, sections)
      expect(hits?.find(hit => hit.id === 'general')?.rows, query).toContain('Animated background')
    }
  })
})
