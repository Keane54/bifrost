import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

// The repository has no DOM test. So this test reads the source text of the section.
const SECTION = readFileSync(
  join(__dirname, '../../../src/renderer/src/settings/GeneralSection.tsx'),
  'utf8',
)

// The JSX element of one CheckRow, from its start to its end.
function checkRow(label: string): string {
  const rows = SECTION.split('<CheckRow').slice(1)
  const row = rows.find(text => text.includes(`label='${label}'`))
  if (!row) throw new Error(`No CheckRow ${label}`)
  return row.slice(0, row.indexOf('/>'))
}

describe('Settings > General', () => {
  // the user, 2026-11-06: the background shifts slowly. A check row turns the motion off.
  it('has an Animated background check row with a friendly hint', () => {
    const row = checkRow('Animated background')
    expect(row).toContain('checked={settings.animatedBackground}')
    expect(row).toContain('save={value => update({ animatedBackground: value })}')
    expect(row).toContain(
      "hint='Slowly shifting colours behind the panels. Turn it off to save battery.'",
    )
  })
})
