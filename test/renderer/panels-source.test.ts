import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

// The repository has no DOM test. So this test reads the source text of the panel.
const PANEL = readFileSync(
  join(__dirname, '../../src/renderer/src/panels/SelectedItemPanel.tsx'),
  'utf8',
)

describe('SelectedItemPanel source', () => {
  it('shows no dash for a missing priority', () => {
    expect(PANEL).not.toContain("priority ?? '-'")
  })

  it('uses the three context bar fill classes', () => {
    for (const cls of ['bg-ctx-low', 'bg-ctx-mid', 'bg-ctx-high']) expect(PANEL).toContain(cls)
  })
})
